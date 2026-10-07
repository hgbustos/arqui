#!/usr/bin/env python3
"""
riscv_pipeview.py — interpreta un volcado de la Debug Unit (DumpState de
riscv_protocol.py) como "qué está pasando en cada etapa del pipeline", para
que riscv_gui.py lo dibuje. No toca tkinter ni el puerto serie: es lógica
pura, y se prueba contra trazas reales del RTL (test_riscv_pipeview.py).

Dos piezas:

  - analyze(state): la foto de UN ciclo. Qué instrucción hay en cada una de
    las 5 etapas (IF = PC + imem, ID/EX/MEM/WB = el latch anterior a cada
    una, la misma convención del Patterson), si es una burbuja, qué
    operandos usa y de dónde vienen (las flechas de forwarding), y una
    explicación en castellano de los eventos del ciclo (stall, flush, HALT).

  - PipelineHistory: el diagrama multiciclo (filas = instrucciones,
    columnas = ciclos) que se arma juntando volcados de ciclos
    consecutivos, como los que produce el modo paso a paso.

Lo que decide el hardware (stall, flush, qué fuente elige cada mux de
forwarding) se toma TAL CUAL del volcado (STATUS), no se recalcula acá. Lo
único que se calcula en Python son valores para mostrar: el resultado de la
ALU del ciclo actual (no está en ningún latch todavía) y los operandos que
ve cada etapa.
"""
from __future__ import annotations

from dataclasses import dataclass, field

from riscv_asm import (
    NOP_WORD, OP_BRANCH, OP_HALT, OP_IMM, OP_JAL, OP_JALR, OP_LOAD, OP_LUI, OP_R, OP_STORE,
    REG_NAMES, disassemble_word,
)
from riscv_protocol import (
    FWD_EX_EXMEM, FWD_EX_MEMWB, FWD_ID_EX, FWD_ID_EXMEM, FWD_ID_MEMWB, DumpState, to_signed32,
)

M32 = 0xFFFFFFFF
STAGES = ("IF", "ID", "EX", "MEM", "WB")
LATCH_OF_STAGE = {"IF": "PC", "ID": "IF/ID", "EX": "ID/EX", "MEM": "EX/MEM", "WB": "MEM/WB"}


# =============================================================================
# Decodificación (espejo de control_unit.v, incluido el chequeo de
# funct3/funct7 que decide si una instrucción es un HALT implícito)
# =============================================================================
@dataclass(frozen=True)
class Decoded:
    cls: str          # R, I, LOAD, STORE, BRANCH, JAL, JALR, LUI, HALT, ILLEGAL
    rd: int
    rs1: int
    rs2: int
    funct3: int
    funct7: int
    uses_rs1: bool
    uses_rs2: bool
    writes_rd: bool   # la instrucción escribe rd (y rd != x0)


def _supported(op: int, f3: int, f7: int) -> bool:
    if op == OP_R:
        return f7 == 0 or (f7 == 0b0100000 and f3 in (0b000, 0b101))
    if op == OP_IMM:
        if f3 == 0b001:
            return f7 == 0
        if f3 == 0b101:
            return f7 in (0, 0b0100000)
        return True
    if op == OP_LOAD:
        return f3 in (0b000, 0b001, 0b010, 0b100, 0b101)
    if op == OP_STORE:
        return f3 in (0b000, 0b001, 0b010)
    if op == OP_BRANCH:
        return f3 in (0b000, 0b001)
    if op == OP_JALR:
        return f3 == 0
    return op in (OP_JAL, OP_LUI, OP_HALT)


_CLASS = {OP_R: "R", OP_IMM: "I", OP_LOAD: "LOAD", OP_STORE: "STORE", OP_BRANCH: "BRANCH",
          OP_JAL: "JAL", OP_JALR: "JALR", OP_LUI: "LUI", OP_HALT: "HALT"}


def decode(word: int) -> Decoded:
    op, rd, f3 = word & 0x7F, (word >> 7) & 31, (word >> 12) & 7
    rs1, rs2, f7 = (word >> 15) & 31, (word >> 20) & 31, (word >> 25) & 0x7F
    cls = _CLASS[op] if _supported(op, f3, f7) else "ILLEGAL"
    uses_rs1 = cls in ("R", "I", "LOAD", "STORE", "BRANCH", "JALR")
    uses_rs2 = cls in ("R", "STORE", "BRANCH")
    writes_rd = cls in ("R", "I", "LOAD", "JAL", "JALR", "LUI") and rd != 0
    return Decoded(cls, rd, rs1, rs2, f3, f7, uses_rs1, uses_rs2, writes_rd)


def _sx(value: int, bits: int) -> int:
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def _imm(word: int, cls: str) -> int:
    if cls in ("I", "LOAD", "JALR"):
        return _sx(word >> 20, 12)
    if cls == "STORE":
        return _sx(((word >> 25) << 5) | ((word >> 7) & 31), 12)
    if cls == "BRANCH":
        return _sx((((word >> 31) & 1) << 12) | (((word >> 7) & 1) << 11)
                   | (((word >> 25) & 0x3F) << 5) | (((word >> 8) & 0xF) << 1), 13)
    if cls == "JAL":
        return _sx((((word >> 31) & 1) << 20) | (((word >> 12) & 0xFF) << 12)
                   | (((word >> 20) & 1) << 11) | (((word >> 21) & 0x3FF) << 1), 21)
    if cls == "LUI":
        return word & 0xFFFFF000
    return 0


def is_bubble(pc: int, instr: int) -> bool:
    """NOP con pc=0: lo que meten en un latch el reset, una burbuja de
    stall (id_ex_reg.v) o un flush (if_id_reg.v). Un 'nop' real en la
    dirección 0 se ve igual -- ambigüedad aceptada, sólo afecta el dibujo."""
    return instr == NOP_WORD and pc == 0


def reg(n: int) -> str:
    return REG_NAMES[n]


# =============================================================================
# Valores que ve cada etapa (sólo para mostrar)
# =============================================================================
def wb_value(s: DumpState) -> int:
    """Lo que escribe WB (y lo que adelanta MEM/WB): mux mem_to_reg."""
    return s.mem_wb.mem_read_data if s.mem_wb.mem_to_reg else s.mem_wb.result


def ex_operands(s: DumpState) -> tuple[int, int]:
    """rs1/rs2 tal como llegan a EX después de los muxes de forwarding."""
    def pick(sel: int, latched: int) -> int:
        if sel == FWD_EX_EXMEM:
            return s.ex_mem.ex_result
        if sel == FWD_EX_MEMWB:
            return wb_value(s)
        return latched
    return pick(s.forwarding.a_ex, s.id_ex.rs1_data), pick(s.forwarding.b_ex, s.id_ex.rs2_data)


def _alu(d: Decoded, a: int, b: int) -> int:
    alt = (d.funct7 >> 5) & 1
    f3 = d.funct3
    if d.cls == "I" and f3 not in (0b001, 0b101):
        alt = 0  # en I-type aritmético instr[30] es parte del inmediato
    if f3 == 0b000:
        r = a - b if (alt and d.cls == "R") else a + b
    elif f3 == 0b001:
        r = a << (b & 31)
    elif f3 == 0b010:
        r = int(_sx(a, 32) < _sx(b, 32))
    elif f3 == 0b011:
        r = int((a & M32) < (b & M32))
    elif f3 == 0b100:
        r = a ^ b
    elif f3 == 0b101:
        r = (_sx(a, 32) >> (b & 31)) if alt else ((a & M32) >> (b & 31))
    elif f3 == 0b110:
        r = a | b
    else:
        r = a & b
    return r & M32


def ex_result(s: DumpState) -> int | None:
    """Salida de EX en este ciclo (ALU, o PC+4 para jal/jalr), la que entra
    a EX/MEM en el próximo flanco y la que adelanta la fuente 'EX' hacia ID.
    None si EX no produce nada útil (burbuja, branch, HALT)."""
    if is_bubble(s.id_ex.pc, s.id_ex.instr):
        return None
    d = decode(s.id_ex.instr)
    a, b = ex_operands(s)
    if d.cls in ("JAL", "JALR"):
        return (s.id_ex.pc + 4) & M32
    if d.cls == "LUI":
        return s.id_ex.imm & M32
    if d.cls in ("LOAD", "STORE"):
        return (a + s.id_ex.imm) & M32
    if d.cls == "R":
        return _alu(d, a, b)
    if d.cls == "I":
        return _alu(d, a, s.id_ex.imm & M32)
    return None


def id_operand(s: DumpState, which: str) -> tuple[int | None, str]:
    """Valor de rs1/rs2 que ve branch_unit en ID, y de dónde sale."""
    d = decode(s.if_id.instr)
    num = d.rs1 if which == "rs1" else d.rs2
    sel = s.forwarding.a_id if which == "rs1" else s.forwarding.b_id
    if sel == FWD_ID_EX:
        return ex_result(s), "EX"
    if sel == FWD_ID_EXMEM:
        return s.ex_mem.ex_result, "EX/MEM"
    if sel == FWD_ID_MEMWB:
        return wb_value(s), "MEM/WB"
    return (0 if num == 0 else s.registers[num]), "banco"


# =============================================================================
# Foto de un ciclo
# =============================================================================
@dataclass
class StageView:
    stage: str             # IF, ID, EX, MEM, WB
    pc: int
    instr: int
    text: str              # desensamblado, o "burbuja"
    kind: str              # instr | bubble | halt
    tags: list[str] = field(default_factory=list)     # stall, flush, taken, halt_wait
    details: list[str] = field(default_factory=list)  # líneas cortas para el recuadro


@dataclass
class ForwardArrow:
    src: str      # etapa donde está el productor: EX, MEM, WB
    dst: str      # etapa que consume: EX (ALU) o ID (comparador de saltos)
    operand: str  # rs1 / rs2
    regnum: int
    value: int | None


@dataclass
class PipelineView:
    stages: dict[str, StageView]
    arrows: list[ForwardArrow]
    events: list[str]


def _stage_raw(s: DumpState, stage: str) -> tuple[int, int]:
    return {
        "IF": (s.if_stage.pc, s.if_stage.instr),
        "ID": (s.if_id.pc, s.if_id.instr),
        "EX": (s.id_ex.pc, s.id_ex.instr),
        "MEM": (s.ex_mem.pc, s.ex_mem.instr),
        "WB": (s.mem_wb.pc, s.mem_wb.instr),
    }[stage]


def _hx(v: int | None) -> str:
    return "?" if v is None else f"0x{v & M32:08x}"


def stall_reason(s: DumpState) -> tuple[str, int, str] | None:
    """('load-use' | 'load-salto' | 'halt', registro, etapa del load) o None."""
    if not s.stalled:
        return None
    if not s.hazard_stall:
        return ("halt", 0, "")
    d = decode(s.if_id.instr)
    used = {r for r, u in ((d.rs1, d.uses_rs1), (d.rs2, d.uses_rs2)) if u and r != 0}
    rd_ex = decode(s.id_ex.instr).rd
    if s.id_ex.mem_read and rd_ex in used:
        return ("load-use", rd_ex, "EX")
    rd_mem = decode(s.ex_mem.instr).rd
    if s.ex_mem.mem_read and rd_mem in used:
        return ("load-salto", rd_mem, "MEM")
    return ("load-use", 0, "")  # no debería pasar: el hardware frenó por algo que no vemos


def analyze(s: DumpState) -> PipelineView:
    stages: dict[str, StageView] = {}
    for st in STAGES:
        pc, instr = _stage_raw(s, st)
        if st != "IF" and is_bubble(pc, instr):
            stages[st] = StageView(st, pc, instr, "burbuja", "bubble")
            continue
        d = decode(instr)
        kind = "halt" if d.cls in ("HALT", "ILLEGAL") else "instr"
        stages[st] = StageView(st, pc, instr, disassemble_word(instr, pc), kind)

    arrows: list[ForwardArrow] = []
    events: list[str] = []
    reason = stall_reason(s)
    flush = s.branch_taken and not s.hazard_stall

    # ---- IF ----
    v = stages["IF"]
    if s.stalled:
        v.tags.append("stall")
        v.details.append("PC congelado")
    elif flush:
        v.tags.append("flush")
        v.details.append("se descarta (salto)")
    else:
        v.details.append(f"próximo PC = {_hx(s.if_stage.pc + 4)}")

    # ---- ID ----
    v = stages["ID"]
    d = decode(s.if_id.instr)
    if v.kind != "bubble":
        srcs = []
        for which, num, used in (("rs1", d.rs1, d.uses_rs1), ("rs2", d.rs2, d.uses_rs2)):
            if used:
                srcs.append(f"{which}={reg(num)}")
        if srcs:
            v.details.append("lee " + " ".join(srcs))
        if reason and reason[0] in ("load-use", "load-salto"):
            v.tags.append("stall")
            v.details.append(f"STALL: espera {reg(reason[1])}")
        elif reason and reason[0] == "halt":
            v.tags.append("halt_wait")
            v.details.append("HALT retenido en ID")
        if d.cls in ("BRANCH", "JALR") and not s.hazard_stall:
            for which, used, sel in (("rs1", d.uses_rs1, s.forwarding.a_id),
                                     ("rs2", d.uses_rs2, s.forwarding.b_id)):
                if not used:
                    continue
                val, src = id_operand(s, which)
                num = d.rs1 if which == "rs1" else d.rs2
                if sel:
                    arrows.append(ForwardArrow({"EX": "EX", "EX/MEM": "MEM", "MEM/WB": "WB"}[src],
                                               "ID", which, num, val))
            if d.cls == "BRANCH":
                a, _ = id_operand(s, "rs1")
                b, _ = id_operand(s, "rs2")
                cmp_txt = "==" if a == b else "!="
                v.details.append(f"{_hx(a)} {cmp_txt} {_hx(b)}")
        if s.branch_taken and not s.hazard_stall:
            v.tags.append("taken")
            v.details.append("salto TOMADO")
        elif d.cls == "BRANCH" and not s.hazard_stall:
            v.details.append("no se toma")

    # ---- EX ----
    v = stages["EX"]
    if v.kind == "instr":
        d = decode(s.id_ex.instr)
        a, b = ex_operands(s)
        res = ex_result(s)
        for which, used, sel, val in (("rs1", d.uses_rs1, s.forwarding.a_ex, a),
                                      ("rs2", d.uses_rs2, s.forwarding.b_ex, b)):
            if used and d.cls not in ("BRANCH", "JALR") and sel:
                num = d.rs1 if which == "rs1" else d.rs2
                arrows.append(ForwardArrow("MEM" if sel == FWD_EX_EXMEM else "WB",
                                           "EX", which, num, val))
        if d.cls in ("R",):
            v.details.append(f"A={_hx(a)} B={_hx(b)}")
        elif d.cls in ("I", "LOAD", "STORE"):
            v.details.append(f"A={_hx(a)} imm={to_signed32(s.id_ex.imm)}")
        if d.cls in ("LOAD", "STORE"):
            v.details.append(f"dirección = {_hx(res)}")
        elif d.cls in ("JAL", "JALR"):
            v.details.append(f"enlace = PC+4 = {_hx(res)}")
        elif res is not None:
            v.details.append(f"ALU = {_hx(res)}")
        if d.cls == "STORE":
            v.details.append(f"dato a guardar = {_hx(b)}")
        if d.cls == "BRANCH":
            v.details.append("ya resuelto en ID (no usa la ALU)")
    elif v.kind == "halt":
        v.details.append("HALT drenando")

    # ---- MEM ----
    v = stages["MEM"]
    if v.kind == "instr":
        e = s.ex_mem
        if e.mem_read:
            v.details.append(f"lee mem[{_hx(e.ex_result)}]")
        elif e.mem_write:
            v.details.append(f"mem[{_hx(e.ex_result)}] <- {_hx(e.rs2_data)}")
        elif e.reg_write:
            v.details.append(f"resultado = {_hx(e.ex_result)}")
        else:
            v.details.append("no accede a memoria")
    elif v.kind == "halt":
        v.details.append("HALT drenando")

    # ---- WB ----
    v = stages["WB"]
    if v.kind == "instr":
        rd = decode(s.mem_wb.instr).rd
        if s.mem_wb.reg_write and rd != 0:
            v.details.append(f"{reg(rd)} <- {_hx(wb_value(s))}")
        else:
            v.details.append("no escribe registros")
    elif v.kind == "halt" and s.core_halted:
        v.details.append("HALT en WB: fin")

    # ---- Eventos del ciclo, en castellano ----
    if s.core_halted:
        events.append("HALT llegó a WB: todas las instrucciones anteriores ya terminaron y "
                      "el pipeline quedó vacío. Ejecución terminada.")
    elif reason and reason[0] == "halt":
        illegal = decode(s.if_id.instr).cls == "ILLEGAL"
        quien = "Instrucción fuera del subset (HALT implícito)" if illegal else "HALT"
        events.append(f"{quien} en ID: se dejan de buscar instrucciones (PC e IF/ID "
                      f"congelados); las anteriores siguen hasta WB.")
    elif reason:
        kind, r, where = reason
        if kind == "load-use":
            extra = ""
            if decode(s.if_id.instr).cls in ("BRANCH", "JALR"):
                extra = (" Como es un salto (se resuelve en ID), va a hacer falta un "
                         "ciclo más de stall.")
            events.append(f"STALL (load-use): la instrucción en ID necesita {reg(r)}, que "
                          f"todavía está cargando el load en {where}. PC e IF/ID quedan "
                          f"congelados y entra una burbuja a EX.{extra}")
        else:
            events.append(f"STALL (load antes de salto): el salto se resuelve en ID y "
                          f"necesita {reg(r)}, pero el load recién lo tiene al final de MEM. "
                          f"Se frena un ciclo más.")
    if flush:
        events.append("Salto tomado en ID: el PC carga el destino y la instrucción que se "
                      "buscó en IF se descarta (flush de IF/ID, 1 ciclo perdido).")
    for a in arrows:
        src_latch = {"EX": "la salida de la ALU (EX)", "MEM": "EX/MEM", "WB": "MEM/WB"}[a.src]
        dst_txt = "la ALU (EX)" if a.dst == "EX" else "el comparador de saltos (ID)"
        events.append(f"Forwarding: {reg(a.regnum)} = {_hx(a.value)} desde {src_latch} "
                      f"hacia {a.operand} de {dst_txt}.")
    return PipelineView(stages, arrows, events)


# =============================================================================
# Diagrama multiciclo
# =============================================================================
@dataclass
class HistRow:
    label: str
    pc: int | None
    kind: str                                         # instr | bubble | halt
    cells: dict[int, tuple[str, str]] = field(default_factory=dict)  # ciclo -> (etapa, marca)
    halt_copied: bool = False


class PipelineHistory:
    """Arma el diagrama multiciclo a partir de volcados de ciclos
    CONSECUTIVOS (modo paso a paso). Las reglas de movimiento son las del
    hardware, tomadas de los bits de STATUS del ciclo anterior:

      - EX->MEM->WB avanzan siempre (sólo los congela la Debug Unit).
      - stalled: IF e ID se quedan; a EX entra una burbuja (stall de datos)
        o una copia del HALT (HALT en ID; sólo la primera se dibuja, como
        continuación del propio HALT).
      - branch_taken sin stall: la instrucción de IF se descarta (flush).

    Cada resultado se contrasta contra los PCs del volcado nuevo; si algo
    no coincide (o los ciclos no son consecutivos, p.ej. después de un
    CMD_RUN) el diagrama vuelve a empezar desde ese volcado.
    """

    def __init__(self, max_rows: int = 60):
        self.max_rows = max_rows
        self.reset()

    def reset(self) -> None:
        self.rows: list[HistRow] = []
        self.occ: dict[str, HistRow | None] = {st: None for st in STAGES}
        self.prev: DumpState | None = None
        self.restarts = 0

    # -- helpers --
    def _new_row(self, s: DumpState, stage: str) -> HistRow:
        pc, instr = _stage_raw(s, stage)
        kind = "halt" if decode(instr).cls in ("HALT", "ILLEGAL") else "instr"
        row = HistRow(f"0x{pc:04x}  {disassemble_word(instr, pc).split('  ;')[0]}", pc, kind)
        self.rows.append(row)
        return row

    def _seed(self, s: DumpState) -> None:
        self.rows = []
        self.occ = {st: None for st in STAGES}
        for st in reversed(STAGES):  # WB primero: la fila más vieja arriba
            pc, instr = _stage_raw(s, st)
            if st != "IF" and is_bubble(pc, instr):
                continue
            self.occ[st] = self._new_row(s, st)

    def _consistent(self, s: DumpState) -> bool:
        for st in STAGES:
            row = self.occ[st]
            pc, instr = _stage_raw(s, st)
            if row is None:
                continue
            if row.kind == "bubble":
                if not is_bubble(pc, instr):
                    return False
            elif row.pc != pc:
                return False
        return True

    def _mark(self, s: DumpState) -> None:
        c = s.cycle_count
        flush = s.branch_taken and not s.hazard_stall
        for st in STAGES:
            row = self.occ[st]
            if row is None:
                continue
            mark = ""
            if st in ("IF", "ID") and s.hazard_stall:
                mark = "stall"
            elif st == "IF" and s.stalled:
                mark = "stall"
            elif st == "IF" and flush:
                mark = "flush"
            elif st == "ID" and s.stalled and row.kind == "halt" and not s.core_halted:
                mark = "halt"
            elif st == "ID" and flush:
                mark = "taken"
            elif row.kind == "bubble":
                mark = "bubble"
            # La etapa más avanzada gana (HALT: está en ID y su copia en EX/MEM/WB)
            row.cells[c] = (st, mark)

    def push(self, s: DumpState) -> None:
        p = self.prev
        if p is not None and s.cycle_count == p.cycle_count:
            self.prev = s  # mismo ciclo (CMD_DUMP, o STEP con el core ya detenido)
            return
        if p is None or s.cycle_count != p.cycle_count + 1:
            if p is not None:
                self.restarts += 1
            self._seed(s)
        else:
            new = {st: None for st in STAGES}
            new["WB"] = self.occ["MEM"]
            new["MEM"] = self.occ["EX"]
            if p.stalled:
                new["IF"] = self.occ["IF"]
                new["ID"] = self.occ["ID"]
                if p.hazard_stall:
                    bubble = HistRow("(burbuja)", None, "bubble")
                    self.rows.append(bubble)
                    new["EX"] = bubble
                else:
                    halt_row = self.occ["ID"]
                    if halt_row is not None and not halt_row.halt_copied:
                        halt_row.halt_copied = True
                        new["EX"] = halt_row
            else:
                new["ID"] = None if p.branch_taken else self.occ["IF"]
                new["EX"] = self.occ["ID"]
                new["IF"] = None  # se crea abajo, ya con el volcado nuevo
            self.occ = new
            if self.occ["IF"] is None and not p.stalled:
                self.occ["IF"] = self._new_row(s, "IF")
            if not self._consistent(s):
                self.restarts += 1
                self._seed(s)
        self._mark(s)
        self.prev = s
        self._trim()

    def _trim(self) -> None:
        live = {id(r) for r in self.occ.values() if r is not None}
        while len(self.rows) > self.max_rows and id(self.rows[0]) not in live:
            self.rows.pop(0)

    def cycles(self) -> list[int]:
        cs = sorted({c for r in self.rows for c in r.cells})
        return cs


_MARK_CHAR = {"stall": "*", "flush": "x", "taken": "!", "halt": "h", "bubble": "", "": ""}


def render_text(history: PipelineHistory, label_width: int = 26) -> str:
    """El diagrama multiciclo como texto (una fila por instrucción, una
    columna de 5 caracteres por ciclo). Marcas: '*' stall, 'x' se descarta
    por un salto, '!' salto tomado, 'h' HALT retenido en ID."""
    cycles = history.cycles()
    if not cycles:
        return ""
    lines = [" " * label_width + "".join(f"{c:<5d}" for c in cycles)]
    for row in history.rows:
        cells = []
        for c in cycles:
            if c in row.cells:
                st, mark = row.cells[c]
                cells.append(f"{st + _MARK_CHAR[mark]:<5s}")
            else:
                cells.append(" " * 5)
        lines.append(f"{row.label[:label_width - 1]:<{label_width}s}" + "".join(cells).rstrip())
    return "\n".join(lines)


def load_trace(path: str, dmem_words: int) -> list[DumpState]:
    """Lee una traza de volcados (una línea de palabras hex por volcado,
    el formato que escribe tp3/tb/tb_pipeline_trace.v)."""
    from riscv_protocol import parse_dump
    states = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip():
                raw = b"".join(int(w, 16).to_bytes(4, "little") for w in line.split())
                states.append(parse_dump(raw, dmem_words))
    return states
