#!/usr/bin/env python3
"""
riscv_asm.py — ensamblador y desensamblador del subset de RV32I que pide
TP3 (R/I/S/B/U/J + una instrucción HALT propia en el opcode reservado
custom-0), usado por riscv_client.py y riscv_gui.py para traducir
programas .asm a las palabras de 32 bits que consume CMD_LOAD_PROG (ver
tp3/docs/debug_protocol.md), y por el desensamblador para mostrar
instrucciones legibles por etapa de pipeline en la GUI.

Las tablas de opcode/funct3/funct7 tienen que coincidir exactamente con
tp3/rtl/core/control_unit.v y alu_control.v (y con
tp3/tb/riscv_isa_encode.vh, su equivalente en Verilog para armar programas
de prueba) -- es la misma codificación RV32I estándar, pero está duplicada
en tres lugares a propósito (Verilog RTL, Verilog de testbench, Python) sin
un mecanismo de import compartido entre lenguajes, así que hay que
mantenerla sincronizada a mano si cambia.

Sintaxis soportada (una instrucción por línea, comentarios con '#' o '//'):

    etiqueta:
        addi x1, x0, 10        # R/I-type: mnemonico rd, rs1, rs2/imm
        lw   x2, 4(x1)         # loads/stores: mnemonico rd/rs2, imm(rs1)
        beq  x1, x2, etiqueta  # branches: mnemonico rs1, rs2, imm-o-etiqueta
        jal  x1, etiqueta      # jal acepta tambien la forma de 1 operando: jal etiqueta (rd=ra implicito)
        lui  x3, 0x12345       # U-type: mnemonico rd, imm20
        halt                   # sin operandos
        nop                    # pseudo-instruccion: addi x0, x0, 0

Los registros aceptan tanto la forma numerica (x0..x31) como los nombres
ABI estandar de RISC-V (zero, ra, sp, gp, tp, t0-t6, s0/fp, s1-s11, a0-a7).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

# =============================================================================
# Registros
# =============================================================================
_ABI_NAMES = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23,
    "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}
REGISTERS = {f"x{i}": i for i in range(32)}
REGISTERS.update(_ABI_NAMES)
REG_NAMES = [f"x{i}" for i in range(32)]  # nombre canonico por indice, para el desensamblador


class AsmError(Exception):
    """Error de ensamblado: mensaje ya incluye numero de linea y contexto."""


# =============================================================================
# Opcodes (deben coincidir con control_unit.v)
# =============================================================================
OP_R = 0b0110011
OP_IMM = 0b0010011
OP_LOAD = 0b0000011
OP_STORE = 0b0100011
OP_BRANCH = 0b1100011
OP_JAL = 0b1101111
OP_JALR = 0b1100111
OP_LUI = 0b0110111
OP_HALT = 0b0001011  # custom-0

NOP_WORD = 0x00000013  # addi x0, x0, 0

# Tabla de instrucciones: mnemonico -> (formato, opcode, funct3, funct7).
# funct3/funct7 son None cuando el formato no los usa (U, J, HALT).
# Un solo lugar del que salen tanto el ensamblador como el desensamblador
# (arma su tabla inversa a partir de esta), para no tener dos tablas que
# se puedan desincronizar entre si.
INSTR_TABLE = {
    # R-type
    "add":  ("R", OP_R, 0b000, 0b0000000),
    "sub":  ("R", OP_R, 0b000, 0b0100000),
    "sll":  ("R", OP_R, 0b001, 0b0000000),
    "slt":  ("R", OP_R, 0b010, 0b0000000),
    "sltu": ("R", OP_R, 0b011, 0b0000000),
    "xor":  ("R", OP_R, 0b100, 0b0000000),
    "srl":  ("R", OP_R, 0b101, 0b0000000),
    "sra":  ("R", OP_R, 0b101, 0b0100000),
    "or":   ("R", OP_R, 0b110, 0b0000000),
    "and":  ("R", OP_R, 0b111, 0b0000000),
    # I-type aritmetico
    "addi":  ("I", OP_IMM, 0b000, None),
    "slti":  ("I", OP_IMM, 0b010, None),
    "sltiu": ("I", OP_IMM, 0b011, None),
    "xori":  ("I", OP_IMM, 0b100, None),
    "ori":   ("I", OP_IMM, 0b110, None),
    "andi":  ("I", OP_IMM, 0b111, None),
    # I-type shift (shamt de 5 bits en vez de un inmediato de 12)
    "slli": ("I_SHIFT", OP_IMM, 0b001, 0b0000000),
    "srli": ("I_SHIFT", OP_IMM, 0b101, 0b0000000),
    "srai": ("I_SHIFT", OP_IMM, 0b101, 0b0100000),
    # I-type load (sintaxis imm(rs1))
    "lb":  ("I_LOAD", OP_LOAD, 0b000, None),
    "lh":  ("I_LOAD", OP_LOAD, 0b001, None),
    "lw":  ("I_LOAD", OP_LOAD, 0b010, None),
    "lbu": ("I_LOAD", OP_LOAD, 0b100, None),
    "lhu": ("I_LOAD", OP_LOAD, 0b101, None),
    # jalr (I-type, mismo formato que addi)
    "jalr": ("I", OP_JALR, 0b000, None),
    # S-type (sintaxis imm(rs1), como los loads pero la fuente es rs2)
    "sb": ("S", OP_STORE, 0b000, None),
    "sh": ("S", OP_STORE, 0b001, None),
    "sw": ("S", OP_STORE, 0b010, None),
    # B-type
    "beq": ("B", OP_BRANCH, 0b000, None),
    "bne": ("B", OP_BRANCH, 0b001, None),
    # U-type
    "lui": ("U", OP_LUI, None, None),
    # J-type
    "jal": ("J", OP_JAL, None, None),
    # custom
    "halt": ("HALT", OP_HALT, None, None),
}

_MNEMONIC_BY_KEY = {}  # (opcode, funct3, funct7-o-None) -> mnemonico, para desensamblar
for _mnem, (_fmt, _op, _f3, _f7) in INSTR_TABLE.items():
    if _fmt in ("R",):
        _MNEMONIC_BY_KEY[(_op, _f3, _f7)] = _mnem
    elif _fmt in ("I_SHIFT",):
        _MNEMONIC_BY_KEY[(_op, _f3, _f7)] = _mnem
    elif _fmt in ("I", "I_LOAD", "S", "B"):
        _MNEMONIC_BY_KEY[(_op, _f3, None)] = _mnem
    else:  # U, J, HALT: el opcode solo ya identifica la instruccion
        _MNEMONIC_BY_KEY[(_op, None, None)] = _mnem


# =============================================================================
# Encoders de bajo nivel (deben coincidir bit a bit con
# tp3/tb/riscv_isa_encode.vh)
# =============================================================================
def _mask(value: int, bits: int) -> int:
    return value & ((1 << bits) - 1)


def enc_r(funct7: int, rs2: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (_mask(funct7, 7) << 25) | (_mask(rs2, 5) << 20) | (_mask(rs1, 5) << 15) \
        | (_mask(funct3, 3) << 12) | (_mask(rd, 5) << 7) | _mask(opcode, 7)


def enc_i(imm: int, rs1: int, funct3: int, rd: int, opcode: int) -> int:
    return (_mask(imm, 12) << 20) | (_mask(rs1, 5) << 15) | (_mask(funct3, 3) << 12) \
        | (_mask(rd, 5) << 7) | _mask(opcode, 7)


def enc_s(imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm11_5 = (imm >> 5) & 0x7F
    imm4_0 = imm & 0x1F
    return (imm11_5 << 25) | (_mask(rs2, 5) << 20) | (_mask(rs1, 5) << 15) \
        | (_mask(funct3, 3) << 12) | (imm4_0 << 7) | _mask(opcode, 7)


def enc_b(imm: int, rs2: int, rs1: int, funct3: int, opcode: int) -> int:
    imm12 = (imm >> 12) & 0x1
    imm11 = (imm >> 11) & 0x1
    imm10_5 = (imm >> 5) & 0x3F
    imm4_1 = (imm >> 1) & 0xF
    return (imm12 << 31) | (imm10_5 << 25) | (_mask(rs2, 5) << 20) | (_mask(rs1, 5) << 15) \
        | (_mask(funct3, 3) << 12) | (imm4_1 << 8) | (imm11 << 7) | _mask(opcode, 7)


def enc_u(imm20: int, rd: int, opcode: int) -> int:
    return (_mask(imm20, 20) << 12) | (_mask(rd, 5) << 7) | _mask(opcode, 7)


def enc_j(imm: int, rd: int, opcode: int) -> int:
    imm20 = (imm >> 20) & 0x1
    imm19_12 = (imm >> 12) & 0xFF
    imm11 = (imm >> 11) & 0x1
    imm10_1 = (imm >> 1) & 0x3FF
    return (imm20 << 31) | (imm10_1 << 21) | (imm11 << 20) | (imm19_12 << 12) \
        | (_mask(rd, 5) << 7) | _mask(opcode, 7)


# =============================================================================
# Parsing de operandos
# =============================================================================
def _parse_register(tok: str, lineno: int) -> int:
    tok = tok.strip()
    if tok not in REGISTERS:
        raise AsmError(f"linea {lineno}: registro invalido '{tok}'")
    return REGISTERS[tok]


def _parse_int(tok: str, lineno: int) -> int:
    tok = tok.strip()
    try:
        return int(tok, 0)  # soporta decimal, 0x.., 0b..
    except ValueError:
        raise AsmError(f"linea {lineno}: numero invalido '{tok}'")


def _check_range(value: int, lo: int, hi: int, lineno: int, what: str) -> None:
    if not (lo <= value <= hi):
        raise AsmError(f"linea {lineno}: {what}={value} fuera de rango [{lo}, {hi}]")


_OFFSET_RE = re.compile(r"^\s*(-?\w+)\s*\(\s*(\w+)\s*\)\s*$")


def _parse_offset(tok: str, lineno: int) -> tuple[int, int]:
    """Parsea la sintaxis 'imm(reg)' que usan loads y stores."""
    m = _OFFSET_RE.match(tok)
    if not m:
        raise AsmError(f"linea {lineno}: se esperaba 'imm(registro)', se encontro '{tok}'")
    imm = _parse_int(m.group(1), lineno)
    reg = _parse_register(m.group(2), lineno)
    return imm, reg


# =============================================================================
# Ensamblador (dos pasadas)
# =============================================================================
@dataclass
class AssembledLine:
    lineno: int
    label: str | None
    mnemonic: str | None
    operands: list[str]


_LABEL_RE = re.compile(r"^(\w+):\s*(.*)$")


def _strip_comment(line: str) -> str:
    for marker in ("#", "//"):
        idx = line.find(marker)
        if idx != -1:
            line = line[:idx]
    return line.strip()


def _tokenize(text: str) -> list[AssembledLine]:
    lines: list[AssembledLine] = []
    for i, raw in enumerate(text.splitlines(), start=1):
        line = _strip_comment(raw)
        if not line:
            continue
        label = None
        m = _LABEL_RE.match(line)
        if m:
            label = m.group(1)
            line = m.group(2).strip()
        if not line:
            # Linea que era solo una etiqueta: se registra pero no genera instruccion.
            lines.append(AssembledLine(i, label, None, []))
            continue
        parts = line.split(None, 1)
        mnemonic = parts[0].lower()
        operand_str = parts[1] if len(parts) > 1 else ""
        operands = [op.strip() for op in operand_str.split(",")] if operand_str else []
        lines.append(AssembledLine(i, label, mnemonic, operands))
    return lines


def assemble(text: str) -> list[int]:
    """Ensambla el texto completo de un programa .asm y devuelve la lista
    de palabras de 32 bits, en orden, listas para CMD_LOAD_PROG."""
    tokenized = _tokenize(text)

    # --- Pasada 1: direcciones de las etiquetas ---
    labels: dict[str, int] = {}
    addr = 0
    for tl in tokenized:
        if tl.label is not None:
            if tl.label in labels:
                raise AsmError(f"linea {tl.lineno}: etiqueta '{tl.label}' duplicada")
            labels[tl.label] = addr
        if tl.mnemonic is not None:
            addr += 4

    # --- Pasada 2: codificacion ---
    words: list[int] = []
    addr = 0
    for tl in tokenized:
        if tl.mnemonic is None:
            continue
        words.append(_encode_instruction(tl, addr, labels))
        addr += 4
    return words


def assemble_file(path: str) -> list[int]:
    with open(path, "r", encoding="utf-8") as f:
        return assemble(f.read())


def parse_word_list(text: str) -> list[int]:
    """Parsea un archivo de datos simple para CMD_LOAD_DATA: un numero de
    32 bits por linea (decimal o hex con prefijo 0x), mismos comentarios
    que el ensamblador. No pasa por INSTR_TABLE -- los datos iniciales de
    dmem no son instrucciones, no hace falta el ensamblador completo para
    ellos."""
    words = []
    for i, raw in enumerate(text.splitlines(), start=1):
        line = _strip_comment(raw)
        if not line:
            continue
        words.append(_parse_int(line, i) & 0xFFFFFFFF)
    return words


def parse_word_list_file(path: str) -> list[int]:
    with open(path, "r", encoding="utf-8") as f:
        return parse_word_list(f.read())


def _resolve_branch_target(tok: str, lineno: int, addr: int, labels: dict[str, int]) -> int:
    """El operando de un salto puede ser una etiqueta (se resuelve a un
    offset PC-relativo) o un numero literal (ya es el offset)."""
    tok = tok.strip()
    if tok in labels:
        return labels[tok] - addr
    return _parse_int(tok, lineno)


def _encode_instruction(tl: AssembledLine, addr: int, labels: dict[str, int]) -> int:
    mnem = tl.mnemonic
    ops = tl.operands
    lineno = tl.lineno

    if mnem == "nop":
        if ops:
            raise AsmError(f"linea {lineno}: 'nop' no lleva operandos")
        return NOP_WORD

    if mnem not in INSTR_TABLE:
        raise AsmError(f"linea {lineno}: instruccion desconocida '{mnem}'")
    fmt, opcode, funct3, funct7 = INSTR_TABLE[mnem]

    if fmt == "R":
        if len(ops) != 3:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 3 operandos (rd, rs1, rs2)")
        rd = _parse_register(ops[0], lineno)
        rs1 = _parse_register(ops[1], lineno)
        rs2 = _parse_register(ops[2], lineno)
        return enc_r(funct7, rs2, rs1, funct3, rd, opcode)

    if fmt == "I":
        if mnem == "jalr":
            # jalr rd, imm(rs1)  -- misma sintaxis offset(base) que los loads
            if len(ops) != 2:
                raise AsmError(f"linea {lineno}: 'jalr' espera 2 operandos (rd, imm(rs1))")
            rd = _parse_register(ops[0], lineno)
            imm, rs1 = _parse_offset(ops[1], lineno)
        else:
            if len(ops) != 3:
                raise AsmError(f"linea {lineno}: '{mnem}' espera 3 operandos (rd, rs1, imm)")
            rd = _parse_register(ops[0], lineno)
            rs1 = _parse_register(ops[1], lineno)
            imm = _parse_int(ops[2], lineno)
        _check_range(imm, -2048, 2047, lineno, "inmediato")
        return enc_i(imm, rs1, funct3, rd, opcode)

    if fmt == "I_SHIFT":
        if len(ops) != 3:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 3 operandos (rd, rs1, shamt)")
        rd = _parse_register(ops[0], lineno)
        rs1 = _parse_register(ops[1], lineno)
        shamt = _parse_int(ops[2], lineno)
        _check_range(shamt, 0, 31, lineno, "shamt")
        imm = (funct7 << 5) | shamt
        return enc_i(imm, rs1, funct3, rd, opcode)

    if fmt == "I_LOAD":
        if len(ops) != 2:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 2 operandos (rd, imm(rs1))")
        rd = _parse_register(ops[0], lineno)
        imm, rs1 = _parse_offset(ops[1], lineno)
        _check_range(imm, -2048, 2047, lineno, "inmediato")
        return enc_i(imm, rs1, funct3, rd, opcode)

    if fmt == "S":
        if len(ops) != 2:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 2 operandos (rs2, imm(rs1))")
        rs2 = _parse_register(ops[0], lineno)
        imm, rs1 = _parse_offset(ops[1], lineno)
        _check_range(imm, -2048, 2047, lineno, "inmediato")
        return enc_s(imm, rs2, rs1, funct3, opcode)

    if fmt == "B":
        if len(ops) != 3:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 3 operandos (rs1, rs2, offset/etiqueta)")
        rs1 = _parse_register(ops[0], lineno)
        rs2 = _parse_register(ops[1], lineno)
        imm = _resolve_branch_target(ops[2], lineno, addr, labels)
        if imm % 2 != 0:
            raise AsmError(f"linea {lineno}: el offset de '{mnem}' debe ser par (es {imm})")
        _check_range(imm, -4096, 4094, lineno, "offset")
        return enc_b(imm, rs2, rs1, funct3, opcode)

    if fmt == "U":
        if len(ops) != 2:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 2 operandos (rd, imm20)")
        rd = _parse_register(ops[0], lineno)
        imm20 = _parse_int(ops[1], lineno)
        _check_range(imm20, 0, 0xFFFFF, lineno, "inmediato de 20 bits")
        return enc_u(imm20, rd, opcode)

    if fmt == "J":
        if len(ops) == 1:
            # jal etiqueta  ->  rd=ra (x1) implicito, convencion estandar de RISC-V
            rd = 1
            target_tok = ops[0]
        elif len(ops) == 2:
            rd = _parse_register(ops[0], lineno)
            target_tok = ops[1]
        else:
            raise AsmError(f"linea {lineno}: '{mnem}' espera 1 o 2 operandos (rd, offset/etiqueta)")
        imm = _resolve_branch_target(target_tok, lineno, addr, labels)
        if imm % 2 != 0:
            raise AsmError(f"linea {lineno}: el offset de '{mnem}' debe ser par (es {imm})")
        _check_range(imm, -1048576, 1048574, lineno, "offset")
        return enc_j(imm, rd, opcode)

    if fmt == "HALT":
        if ops:
            raise AsmError(f"linea {lineno}: 'halt' no lleva operandos")
        return enc_r(0, 0, 0, 0, 0, opcode)  # todos los campos en 0 salvo el opcode

    raise AsmError(f"linea {lineno}: formato interno desconocido '{fmt}' para '{mnem}'")


# =============================================================================
# Desensamblador
# =============================================================================
def _sign_extend(value: int, bits: int) -> int:
    sign_bit = 1 << (bits - 1)
    return (value & (sign_bit - 1)) - (value & sign_bit)


def disassemble_word(word: int, pc: int = 0) -> str:
    """Devuelve una linea legible tipo 'addi x1, x0, 10' para una palabra
    de instruccion. 'pc' se usa solo para mostrar la direccion absoluta de
    destino de saltos/branches como comentario, no afecta la decodificacion."""
    word &= 0xFFFFFFFF
    opcode = word & 0x7F
    rd = (word >> 7) & 0x1F
    funct3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    funct7 = (word >> 25) & 0x7F
    funct7_b5 = (word >> 30) & 0x1

    if opcode == OP_R:
        mnem = _MNEMONIC_BY_KEY.get((opcode, funct3, funct7))
        if mnem is None:
            return f".word 0x{word:08x}  ; R-type desconocida"
        return f"{mnem} {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {REG_NAMES[rs2]}"

    if opcode in (OP_IMM, OP_LOAD, OP_JALR):
        imm12 = _sign_extend(word >> 20, 12)
        if opcode == OP_IMM and funct3 in (0b001, 0b101):
            mnem = _MNEMONIC_BY_KEY.get((opcode, funct3, funct7_b5 << 5))
            shamt = rs2  # mismo campo que rs2, pero interpretado como shamt de 5 bits
            if mnem is None:
                return f".word 0x{word:08x}  ; shift-imm desconocida"
            return f"{mnem} {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {shamt}"
        mnem = _MNEMONIC_BY_KEY.get((opcode, funct3, None))
        if mnem is None:
            return f".word 0x{word:08x}  ; I-type desconocida"
        if opcode == OP_LOAD:
            return f"{mnem} {REG_NAMES[rd]}, {imm12}({REG_NAMES[rs1]})"
        if opcode == OP_JALR:
            target = (pc + imm12) & 0xFFFFFFFF  # aproximado: no conoce el valor real de rs1
            return f"{mnem} {REG_NAMES[rd]}, {imm12}({REG_NAMES[rs1]})"
        return f"{mnem} {REG_NAMES[rd]}, {REG_NAMES[rs1]}, {imm12}"

    if opcode == OP_STORE:
        imm11_5 = (word >> 25) & 0x7F
        imm4_0 = (word >> 7) & 0x1F
        imm = _sign_extend((imm11_5 << 5) | imm4_0, 12)
        mnem = _MNEMONIC_BY_KEY.get((opcode, funct3, None))
        if mnem is None:
            return f".word 0x{word:08x}  ; store desconocida"
        return f"{mnem} {REG_NAMES[rs2]}, {imm}({REG_NAMES[rs1]})"

    if opcode == OP_BRANCH:
        imm12 = (word >> 31) & 0x1
        imm10_5 = (word >> 25) & 0x3F
        imm4_1 = (word >> 8) & 0xF
        imm11 = (word >> 7) & 0x1
        raw = (imm12 << 12) | (imm11 << 11) | (imm10_5 << 5) | (imm4_1 << 1)
        imm = _sign_extend(raw, 13)
        mnem = _MNEMONIC_BY_KEY.get((opcode, funct3, None))
        if mnem is None:
            return f".word 0x{word:08x}  ; branch desconocida"
        target = (pc + imm) & 0xFFFFFFFF
        return f"{mnem} {REG_NAMES[rs1]}, {REG_NAMES[rs2]}, {imm}  ; -> 0x{target:08x}"

    if opcode == OP_LUI:
        imm20 = (word >> 12) & 0xFFFFF
        return f"lui {REG_NAMES[rd]}, 0x{imm20:05x}"

    if opcode == OP_JAL:
        imm20 = (word >> 31) & 0x1
        imm19_12 = (word >> 12) & 0xFF
        imm11 = (word >> 20) & 0x1
        imm10_1 = (word >> 21) & 0x3FF
        raw = (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (imm10_1 << 1)
        imm = _sign_extend(raw, 21)
        target = (pc + imm) & 0xFFFFFFFF
        return f"jal {REG_NAMES[rd]}, {imm}  ; -> 0x{target:08x}"

    if opcode == OP_HALT:
        return "halt"

    if word == 0:
        return "(vacio: opcode 0x00 no valido -> halt implicito)"

    return f".word 0x{word:08x}  ; opcode 0x{opcode:02x} desconocido"
