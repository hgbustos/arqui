#!/usr/bin/env python3
"""
riscv_client.py — cliente de linea de comandos para riscv_uart_top.v (TP3),
analogo a tp2/host/alu_client.py pero para el pipeline RISC-V completo.

Ensambla un programa .asm (riscv_asm.py), lo carga por CMD_LOAD_PROG y lo
corre (CMD_RUN) o lo pasea paso a paso (CMD_STEP repetido), mostrando el
volcado de estado completo (registros, los 4 latches de pipeline
desensamblados, memoria de datos) despues de cada uno. Protocolo:
tp3/docs/debug_protocol.md.

En modo run, si el volcado no empieza a llegar dentro de --timeout
segundos (un programa que nunca llega a HALT, como un loop infinito), la
CLI manda una pausa (CMD_BREAK): la Debug Unit detiene el core y vuelca el
estado en el que quedó.

Uso:
    python riscv_client.py --port COM4 programa.asm
    python riscv_client.py --port COM4 --mode step --steps 20 programa.asm
    python riscv_client.py --port COM4 --data datos.txt programa.asm
"""
import argparse
import sys
import time
from typing import Callable

import serial

from riscv_asm import AsmError, assemble_file, disassemble_word, parse_word_list_file
from riscv_pipeview import PipelineHistory, analyze, render_text
from riscv_protocol import (
    DMEM_WORDS_DEFAULT, IMEM_WORDS_DEFAULT, DumpState, ProtocolError,
    build_break_packet, build_load_data_packet, build_load_prog_packet,
    build_run_packet, build_step_packet,
    expected_dump_size, parse_dump, to_signed32,
)

BAUD_TO_SEL = {9600: 0b00, 19200: 0b01, 57600: 0b10, 115200: 0b11}

POLL_S = 0.1  # cada cuánto se revisa si hay que mandar la pausa mientras corre un CMD_RUN


def format_dump(state: DumpState) -> str:
    lines = [
        f"--- estado (ciclo {state.cycle_count}) ---",
        f"halted={int(state.core_halted)}  stalled={int(state.stalled)}  "
        f"hazard_stall={int(state.hazard_stall)}  branch_taken={int(state.branch_taken)}  "
        f"fwd(a_ex,b_ex,a_id,b_id)=({state.forwarding.a_ex},{state.forwarding.b_ex},"
        f"{state.forwarding.a_id},{state.forwarding.b_id})",
        "",
        "Registros:",
    ]
    for row in range(0, 32, 4):
        cols = [f"x{i:<2}=0x{state.registers[i]:08x}" for i in range(row, row + 4)]
        lines.append("  " + "  ".join(cols))

    lines += [
        "",
        f"IF      pc=0x{state.if_stage.pc:08x}  "
        f"{disassemble_word(state.if_stage.instr, state.if_stage.pc)}",
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


def read_run_dump(ser: serial.Serial, dmem_words: int,
                  should_pause: Callable[[], bool],
                  response_timeout: float) -> tuple[DumpState, bool]:
    """Lee el volcado de un CMD_RUN ya enviado.

    Un programa sin HALT alcanzable (p.ej. un loop infinito) nunca termina
    el modo continuo, así que no se puede esperar el volcado con un timeout
    fijo: se sondea el puerto de a poco (POLL_S) y, la primera vez que
    'should_pause()' devuelve True, se manda CMD_BREAK -- la Debug Unit
    detiene el core y vuelca el estado. Si después de la pausa no llega
    nada en 'response_timeout' segundos, la FPGA no está respondiendo.

    Devuelve (estado, se_mando_la_pausa). Ojo: que se haya mandado la pausa
    no implica que el programa no haya terminado -- si el HALT llegó justo
    antes, el volcado es el del HALT y el CMD_BREAK tardío se descarta en
    la FPGA. Lo que distingue un caso del otro es 'estado.core_halted'.
    """
    expected = expected_dump_size(dmem_words)
    old_timeout = ser.timeout
    ser.timeout = POLL_S
    first = b""
    pause_sent_at = None
    try:
        while not first:
            first = ser.read(1)
            if first:
                break
            if pause_sent_at is None:
                if should_pause():
                    ser.write(build_break_packet())
                    ser.flush()
                    pause_sent_at = time.monotonic()
            elif time.monotonic() - pause_sent_at > response_timeout:
                raise ProtocolError(
                    "se mando CMD_BREAK pero no llego ningun volcado "
                    "(FPGA desconectada o sin programar?)")
    finally:
        ser.timeout = old_timeout

    raw = first + ser.read(expected - len(first))
    if len(raw) != expected:
        raise ProtocolError(
            f"se esperaban {expected} bytes de volcado, se recibieron {len(raw)} "
            f"(timeout o desconexion?)"
        )
    return parse_dump(raw, dmem_words), pause_sent_at is not None


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Cliente serie para el pipeline RISC-V + Debug Unit de TP3.")
    parser.add_argument("--port", required=True, help="Puerto serie, ej. COM4 o /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=115200, choices=sorted(BAUD_TO_SEL),
                         help="Baud rate (debe coincidir con baud_sel_i de la FPGA)")
    parser.add_argument("--timeout", type=float, default=5.0,
                         help="Timeout de lectura en segundos. Con --mode run, si el volcado "
                              "no empieza a llegar en este tiempo se manda una pausa (CMD_BREAK)")
    parser.add_argument("--dmem-words", type=int, default=DMEM_WORDS_DEFAULT,
                         help="Cantidad de palabras de dmem del bitstream "
                              "(DMEM_DEPTH_WORDS de riscv_uart_top.v)")
    parser.add_argument("--imem-words", type=int, default=IMEM_WORDS_DEFAULT,
                         help="Cantidad de palabras de imem del bitstream "
                              "(IMEM_DEPTH_WORDS de riscv_uart_top.v): un programa "
                              "mas largo se rechaza antes de mandarlo")
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

    # Los paquetes se arman (y validan contra el tamaño de las memorias)
    # antes de abrir el puerto: un programa que no entra no llega a la FPGA.
    try:
        prog_packet = build_load_prog_packet(prog_words, args.imem_words)
        data_packet = (build_load_data_packet(data_words, args.dmem_words)
                       if data_words is not None else None)
    except ProtocolError as e:
        print(f"Error: {e}", file=sys.stderr)
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
            if data_packet is not None:
                ser.write(data_packet)
                ser.flush()
                print(f"CMD_LOAD_DATA enviado ({len(data_words)} palabras)")

            ser.write(prog_packet)
            ser.flush()
            print(f"CMD_LOAD_PROG enviado ({len(prog_words)} palabras)")

            if args.mode == "run":
                ser.write(build_run_packet())
                ser.flush()
                started = time.monotonic()
                state, paused = read_run_dump(
                    ser, args.dmem_words,
                    should_pause=lambda: time.monotonic() - started > args.timeout,
                    response_timeout=args.timeout)
                print(format_dump(state))
                if paused and not state.core_halted:
                    print(f"\n(el programa no llego a HALT en {args.timeout:g} s y se pauso "
                          f"con CMD_BREAK -- loop infinito? Arriba esta el estado en que quedo)")
            else:
                history = PipelineHistory()
                for step in range(1, args.steps + 1):
                    ser.write(build_step_packet())
                    ser.flush()
                    state = _read_dump(ser, args.dmem_words)
                    history.push(state)
                    print(f"\n===== Paso {step} =====")
                    print(format_dump(state))
                    for event in analyze(state).events:
                        print(f"  > {event}")
                    if state.core_halted:
                        print("\n(el core llego a HALT, no hace falta seguir pidiendo pasos)")
                        break
                print("\nDiagrama multiciclo (* stall, x descartada por un salto, "
                      "! salto tomado, h HALT retenido en ID):")
                print(render_text(history))
    except ProtocolError as e:
        print(f"Error de protocolo: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
