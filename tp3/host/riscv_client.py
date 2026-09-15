#!/usr/bin/env python3
"""
riscv_client.py — cliente de linea de comandos para riscv_uart_top.v (TP3),
analogo a tp2/host/alu_client.py pero para el pipeline RISC-V completo.

Ensambla un programa .asm (riscv_asm.py), lo carga por CMD_LOAD_PROG y lo
corre (CMD_RUN) o lo pasea paso a paso (CMD_STEP repetido), mostrando el
volcado de estado completo (registros, los 4 latches de pipeline
desensamblados, memoria de datos) despues de cada uno. Protocolo:
tp3/docs/debug_protocol.md.

Uso:
    python riscv_client.py --port COM4 programa.asm
    python riscv_client.py --port COM4 --mode step --steps 20 programa.asm
    python riscv_client.py --port COM4 --data datos.txt programa.asm
"""
import argparse
import sys

import serial

from riscv_asm import AsmError, assemble_file, disassemble_word, parse_word_list_file
from riscv_protocol import (
    DumpState, ProtocolError,
    build_dump_packet, build_load_data_packet, build_load_prog_packet,
    build_run_packet, build_step_packet,
    expected_dump_size, parse_dump, to_signed32,
)

BAUD_TO_SEL = {9600: 0b00, 19200: 0b01, 57600: 0b10, 115200: 0b11}


def format_dump(state: DumpState) -> str:
    lines = [
        f"--- estado (ciclo {state.cycle_count}) ---",
        f"halted={int(state.core_halted)}  stalled={int(state.stalled)}  "
        f"branch_taken={int(state.branch_taken)}",
        "",
        "Registros:",
    ]
    for row in range(0, 32, 4):
        cols = [f"x{i:<2}=0x{state.registers[i]:08x}" for i in range(row, row + 4)]
        lines.append("  " + "  ".join(cols))

    lines += [
        "",
        f"IF/ID   pc=0x{state.if_id.pc:08x}  "
        f"{disassemble_word(state.if_id.instr, state.if_id.pc)}",
        f"ID/EX   pc=0x{state.id_ex.pc:08x}  "
        f"{disassemble_word(state.id_ex.instr, state.id_ex.pc)}"
        f"   rs1=0x{state.id_ex.rs1_data:08x} rs2=0x{state.id_ex.rs2_data:08x}"
        f" imm={to_signed32(state.id_ex.imm)}",
        f"EX/MEM  pc=0x{state.ex_mem.pc:08x}  "
        f"{disassemble_word(state.ex_mem.instr, state.ex_mem.pc)}"
        f"   result=0x{state.ex_mem.ex_result:08x}",
        f"MEM/WB  pc=0x{state.mem_wb.pc:08x}  "
        f"{disassemble_word(state.mem_wb.instr, state.mem_wb.pc)}"
        f"   result=0x{state.mem_wb.result:08x} mem_data=0x{state.mem_wb.mem_read_data:08x}",
        "",
        f"Memoria de datos ({len(state.dmem)} palabras):",
    ]
    for row in range(0, len(state.dmem), 4):
        cols = [f"[{row + i:3d}]=0x{state.dmem[row + i]:08x}"
                for i in range(4) if row + i < len(state.dmem)]
        lines.append("  " + "  ".join(cols))
    return "\n".join(lines)


def _read_dump(ser: serial.Serial, dmem_words: int) -> DumpState:
    expected = expected_dump_size(dmem_words)
    raw = ser.read(expected)
    if len(raw) != expected:
        raise ProtocolError(
            f"se esperaban {expected} bytes de volcado, se recibieron {len(raw)} "
            f"(timeout o desconexion?)"
        )
    return parse_dump(raw, dmem_words)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Cliente serie para el pipeline RISC-V + Debug Unit de TP3.")
    parser.add_argument("--port", required=True, help="Puerto serie, ej. COM4 o /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200, choices=sorted(BAUD_TO_SEL),
                         help="Baud rate (debe coincidir con baud_sel_i de la FPGA)")
    parser.add_argument("--timeout", type=float, default=5.0, help="Timeout de lectura en segundos")
    parser.add_argument("--dmem-words", type=int, default=256,
                         help="Cantidad de palabras de dmem del bitstream "
                              "(DMEM_DEPTH_WORDS de riscv_uart_top.v)")
    parser.add_argument("--data", help="Archivo con datos iniciales para CMD_LOAD_DATA "
                                        "(un numero de 32 bits por linea, no es un .asm)")
    parser.add_argument("--mode", choices=["run", "step"], default="run")
    parser.add_argument("--steps", type=int, default=1,
                         help="Con --mode step, cuantos CMD_STEP mandar (se corta antes si el core llega a HALT)")
    parser.add_argument("program", help="Archivo .asm del programa a ensamblar y cargar")
    args = parser.parse_args()

    try:
        prog_words = assemble_file(args.program)
    except (AsmError, OSError) as e:
        print(f"Error ensamblando '{args.program}': {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Programa ensamblado: {len(prog_words)} instrucciones")

    data_words = None
    if args.data:
        try:
            data_words = parse_word_list_file(args.data)
        except (AsmError, OSError) as e:
            print(f"Error leyendo '{args.data}': {e}", file=sys.stderr)
            sys.exit(1)

    sel = BAUD_TO_SEL[args.baud]
    print(f"Conectando a {args.port} @ {args.baud} bps (baud_sel_i={sel:02b})")
    try:
        ser = serial.Serial(args.port, args.baud, timeout=args.timeout)
    except serial.SerialException as e:
        print(f"Error abriendo {args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        with ser:
            if data_words is not None:
                ser.write(build_load_data_packet(data_words))
                ser.flush()
                print(f"CMD_LOAD_DATA enviado ({len(data_words)} palabras)")

            ser.write(build_load_prog_packet(prog_words))
            ser.flush()
            print(f"CMD_LOAD_PROG enviado ({len(prog_words)} palabras)")

            if args.mode == "run":
                ser.write(build_run_packet())
                ser.flush()
                state = _read_dump(ser, args.dmem_words)
                print(format_dump(state))
            else:
                for step in range(1, args.steps + 1):
                    ser.write(build_step_packet())
                    ser.flush()
                    state = _read_dump(ser, args.dmem_words)
                    print(f"\n===== Paso {step} =====")
                    print(format_dump(state))
                    if state.core_halted:
                        print("\n(el core llego a HALT, no hace falta seguir pidiendo pasos)")
                        break
    except ProtocolError as e:
        print(f"Error de protocolo: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
