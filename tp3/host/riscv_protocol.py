#!/usr/bin/env python3
"""
riscv_protocol.py — framing del protocolo de la Debug Unit de TP3, sin
ninguna dependencia de E/S (nada de pyserial acá): arma los paquetes que
hay que mandar por UART y decodifica el volcado de estado que vuelve.
Implementación fiel de tp3/docs/debug_protocol.md -- ver ese archivo para
el porqué de cada decisión de formato.

Al no tocar el puerto serie, se puede probar con datos sintéticos sin
hardware real de por medio (ver test_riscv_protocol.py) y lo reutilizan
tanto riscv_client.py (CLI) como riscv_gui.py (GUI) sin duplicar el
parseo -- mismo criterio que tp2/host/alu_gui.py reusando
tp2/host/alu_client.py.
"""
from __future__ import annotations

from dataclasses import dataclass

# =============================================================================
# Comandos (Host -> FPGA)
# =============================================================================
CMD_LOAD_PROG = 0x10
CMD_LOAD_DATA = 0x11
CMD_RUN = 0x20
CMD_STEP = 0x21
CMD_DUMP = 0x22
CMD_RESET = 0x23

SYNC_WORD = 0xAA55AA55
FIXED_WORDS = 53  # cantidad de palabras fijas antes de la seccion de dmem


class ProtocolError(Exception):
    """Error de framing: paquete mal armado, o volcado que no calza con
    lo que describe tp3/docs/debug_protocol.md."""


def to_signed32(value: int) -> int:
    """Reinterpreta una palabra de 32 bits sin signo como entero con signo
    (complemento a 2) -- util para mostrar inmediatos/resultados con signo
    en la UI sin tener que repetir esta cuenta en cada lugar que la usa."""
    value &= 0xFFFFFFFF
    return value - (1 << 32) if value & 0x80000000 else value


# =============================================================================
# Paquetes de comando (Host -> FPGA)
# =============================================================================
def build_load_packet(cmd: int, words: list[int]) -> bytes:
    """Arma [cmd][N_lo][N_hi][word0 LE]...[word(N-1) LE], el framing comun
    a CMD_LOAD_PROG y CMD_LOAD_DATA."""
    if not (0 <= len(words) <= 0xFFFF):
        raise ProtocolError(f"cantidad de palabras fuera de rango (16 bits): {len(words)}")
    packet = bytearray([cmd & 0xFF, len(words) & 0xFF, (len(words) >> 8) & 0xFF])
    for w in words:
        packet += (w & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(packet)


def build_load_prog_packet(words: list[int]) -> bytes:
    return build_load_packet(CMD_LOAD_PROG, words)


def build_load_data_packet(words: list[int]) -> bytes:
    return build_load_packet(CMD_LOAD_DATA, words)


def build_run_packet() -> bytes:
    return bytes([CMD_RUN])


def build_step_packet() -> bytes:
    return bytes([CMD_STEP])


def build_dump_packet() -> bytes:
    return bytes([CMD_DUMP])


def build_reset_packet() -> bytes:
    return bytes([CMD_RESET])


# =============================================================================
# Volcado de estado (FPGA -> Host)
# =============================================================================
@dataclass
class LatchIfId:
    pc: int
    instr: int


@dataclass
class LatchIdEx:
    pc: int
    instr: int
    rs1_data: int
    rs2_data: int
    imm: int
    reg_write: bool
    mem_read: bool
    mem_write: bool
    mem_to_reg: bool
    is_jal: bool
    is_jalr: bool
    is_halt: bool


@dataclass
class LatchExMem:
    pc: int
    instr: int
    ex_result: int
    rs2_data: int
    reg_write: bool
    mem_read: bool
    mem_write: bool
    mem_to_reg: bool
    is_halt: bool


@dataclass
class LatchMemWb:
    pc: int
    instr: int
    result: int
    mem_read_data: int
    reg_write: bool
    mem_to_reg: bool
    is_halt: bool


@dataclass
class DumpState:
    core_halted: bool
    branch_taken: bool
    stalled: bool
    cycle_count: int
    if_id: LatchIfId
    id_ex: LatchIdEx
    ex_mem: LatchExMem
    mem_wb: LatchMemWb
    registers: list[int]  # 32 elementos, x0..x31
    dmem: list[int]       # DMEM_DEPTH_WORDS elementos, dmem[0]..dmem[D-1]


def expected_dump_size(dmem_words: int) -> int:
    """Tamano en bytes de un volcado completo para una dmem de
    'dmem_words' palabras -- tiene que coincidir con el DMEM_DEPTH_WORDS
    real de la instancia de riscv_uart_top.v con la que se esta hablando."""
    return (FIXED_WORDS + dmem_words) * 4


def parse_dump(raw: bytes, dmem_words: int) -> DumpState:
    """Decodifica un volcado completo (los bytes crudos recibidos por
    UART tras un CMD_RUN/CMD_STEP/CMD_DUMP) segun el mapa de palabras de
    tp3/docs/debug_protocol.md."""
    expected = expected_dump_size(dmem_words)
    if len(raw) != expected:
        raise ProtocolError(
            f"volcado de tamano incorrecto: {len(raw)} bytes recibidos, "
            f"se esperaban {expected} (dmem_words={dmem_words})"
        )

    words = [int.from_bytes(raw[i:i + 4], "little") for i in range(0, len(raw), 4)]

    if words[0] != SYNC_WORD:
        raise ProtocolError(
            f"marca de sincronismo incorrecta: 0x{words[0]:08X} "
            f"(se esperaba 0x{SYNC_WORD:08X}) -- el stream esta desalineado"
        )

    status = words[1]
    core_halted = bool(status & 0x1)
    branch_taken = bool(status & 0x2)
    stalled = bool(status & 0x4)
    cycle_count = words[2]

    if_id = LatchIfId(pc=words[3], instr=words[4])

    idex_ctrl = words[10]
    id_ex = LatchIdEx(
        pc=words[5], instr=words[6], rs1_data=words[7], rs2_data=words[8], imm=words[9],
        reg_write=bool(idex_ctrl & 0x01), mem_read=bool(idex_ctrl & 0x02),
        mem_write=bool(idex_ctrl & 0x04), mem_to_reg=bool(idex_ctrl & 0x08),
        is_jal=bool(idex_ctrl & 0x10), is_jalr=bool(idex_ctrl & 0x20),
        is_halt=bool(idex_ctrl & 0x40),
    )

    exmem_ctrl = words[15]
    ex_mem = LatchExMem(
        pc=words[11], instr=words[12], ex_result=words[13], rs2_data=words[14],
        reg_write=bool(exmem_ctrl & 0x01), mem_read=bool(exmem_ctrl & 0x02),
        mem_write=bool(exmem_ctrl & 0x04), mem_to_reg=bool(exmem_ctrl & 0x08),
        is_halt=bool(exmem_ctrl & 0x10),
    )

    memwb_ctrl = words[20]
    mem_wb = LatchMemWb(
        pc=words[16], instr=words[17], result=words[18], mem_read_data=words[19],
        reg_write=bool(memwb_ctrl & 0x01), mem_to_reg=bool(memwb_ctrl & 0x02),
        is_halt=bool(memwb_ctrl & 0x04),
    )

    registers = words[21:21 + 32]
    dmem = words[FIXED_WORDS:FIXED_WORDS + dmem_words]

    return DumpState(
        core_halted=core_halted, branch_taken=branch_taken, stalled=stalled,
        cycle_count=cycle_count, if_id=if_id, id_ex=id_ex, ex_mem=ex_mem, mem_wb=mem_wb,
        registers=registers, dmem=dmem,
    )
