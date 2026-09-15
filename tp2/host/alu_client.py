#!/usr/bin/env python3
"""
alu_client.py — cliente de linea de comandos para hablar con uart_alu_top
(TP2) por puerto serie real.

Protocolo (ver tp2/README.md, seccion "Protocolo implementado"):

    CMD_LOAD (0x01) + opcode + A + B   -> carga los operandos, no responde nada.
    CMD_READ (0x02)                    -> pide el resultado; la FPGA responde
                                           2 bytes: resultado, estado
                                           (estado: bit1=carry-out, bit0=zero).

CMD_LOAD y CMD_READ son pasos separados a proposito: se puede pedir CMD_READ
varias veces sin volver a cargar (releer el mismo resultado), que es
justamente lo que agrega valor sobre un protocolo de "pedido -> respuesta
automatica" de un solo paso.

--parity activa el bit de paridad EVEN del framing fisico del puerto
(manejado en hardware por el puente FTDI de la placa, no por este script -
ver tp2/informe.md 2.4 "capas del enlace"). Tiene que coincidir con la
posicion del switch parity_en_i de la FPGA (SW2 en la Basys3): igual que
con --baud, hay que mirar el switch fisico y activar/desactivar esta
misma flag, no hay negociacion automatica. Sin la flag (default): sin
paridad, igual que parity_en_i en bajo.

Uso:
    python alu_client.py --port COM12 --baud 19200 ADD 100 50
    python alu_client.py --port COM12 --baud 19200 --reread 2 SUB 10 50
    python alu_client.py --port COM12 --baud 19200 --parity ADD 100 50
"""
import argparse
import sys
from enum import IntEnum

import serial

CMD_LOAD = 0x01
CMD_READ = 0x02

BAUD_TO_SEL = {9600: 0b00, 19200: 0b01, 57600: 0b10, 115200: 0b11}

def pyserial_parity(enabled: bool):
    """Traduce el on/off de parity_en_i al valor de paridad real de pyserial."""
    return serial.PARITY_EVEN if enabled else serial.PARITY_NONE


class OpCode(IntEnum):
    ADD = 0b100000
    SUB = 0b100010
    AND = 0b100100
    OR  = 0b100101
    XOR = 0b100110
    SRA = 0b000011
    SRL = 0b000010
    NOR = 0b100111


def build_load_packet(op: int, a: int, b: int) -> bytes:
    return bytes([CMD_LOAD, op & 0x3F, a & 0xFF, b & 0xFF])


def build_read_packet() -> bytes:
    return bytes([CMD_READ])


def parse_response(raw: bytes):
    if len(raw) < 2:
        raise ValueError(f"Respuesta incompleta ({len(raw)} byte(s), se esperaban 2)")
    result_byte, status_byte = raw[0], raw[1]
    return {
        "result_unsigned": result_byte,
        "result_signed": result_byte if result_byte < 128 else result_byte - 256,
        "co": bool(status_byte & 0b10),
        "zero": bool(status_byte & 0b01),
    }


def send_and_read(ser: serial.Serial, packet: bytes, expected_bytes: int = 0) -> bytes:
    ser.write(packet)
    ser.flush()
    print(f"[TX] {' '.join(f'{b:02X}' for b in packet)}")
    if expected_bytes == 0:
        return b""
    raw = ser.read(expected_bytes)
    print(f"[RX] {raw.hex(' ').upper() or '(nada, timeout)'}")
    return raw


def main():
    parser = argparse.ArgumentParser(description="Cliente serie para el ALU+UART del TP2.")
    parser.add_argument("--port", required=True, help="Puerto serie, ej. COM12 o /dev/ttyUSB0")
    parser.add_argument("--baud", type=int, default=19200, choices=sorted(BAUD_TO_SEL),
                         help="Baud rate (debe coincidir con baud_sel_i de la FPGA)")
    parser.add_argument("--parity", action="store_true",
                         help="Activa el bit de paridad EVEN del puerto (debe coincidir con el "
                              "switch parity_en_i de la FPGA, SW2 en la Basys3). Sin esta flag: "
                              "sin paridad, switch en bajo (el default, el probado en hardware).")
    parser.add_argument("--timeout", type=float, default=1.0, help="Timeout de lectura en segundos")
    parser.add_argument("--reread", type=int, default=0,
                         help="Cantidad de CMD_READ adicionales a pedir sin volver a cargar")
    parser.add_argument("op", choices=[o.name for o in OpCode], help="Operacion de la ALU")
    parser.add_argument("a", type=lambda x: int(x, 0), help="Operando A (decimal o 0x..)")
    parser.add_argument("b", type=lambda x: int(x, 0), help="Operando B (decimal o 0x..)")
    args = parser.parse_args()

    for value, name in ((args.a, "A"), (args.b, "B")):
        if not (0 <= value <= 255):
            parser.error(f"El operando {name}={value} no entra en un byte (0-255)")

    opcode = OpCode[args.op]

    sel = BAUD_TO_SEL[args.baud]
    sw0 = "arriba" if sel & 0b01 else "abajo"  # baud_sel_i[0] -> SW0
    sw1 = "arriba" if sel & 0b10 else "abajo"  # baud_sel_i[1] -> SW1
    paridad_str = "EVEN" if args.parity else "ninguna"
    print(f"Conectando a {args.port} @ {args.baud} bps, paridad={paridad_str} "
          f"(baud_sel_i={sel:02b} -> SW0 {sw0}, SW1 {sw1}; SW2 -> parity_en_i, "
          f"tiene que coincidir con --parity)")

    try:
        ser = serial.Serial(args.port, args.baud, parity=pyserial_parity(args.parity),
                             timeout=args.timeout)
    except serial.SerialException as e:
        print(f"Error abriendo {args.port}: {e}", file=sys.stderr)
        sys.exit(1)

    with ser:
        send_and_read(ser, build_load_packet(opcode, args.a, args.b))

        for attempt in range(1 + args.reread):
            raw = send_and_read(ser, build_read_packet(), expected_bytes=2)
            try:
                parsed = parse_response(raw)
            except ValueError as e:
                print(f"Error: {e}", file=sys.stderr)
                sys.exit(1)

            label = "resultado" if attempt == 0 else f"reread #{attempt}"
            print(f"{label}: {opcode.name}({args.a}, {args.b}) = "
                  f"{parsed['result_unsigned']} (signed {parsed['result_signed']}) "
                  f"| co={int(parsed['co'])} zero={int(parsed['zero'])}\n")


if __name__ == "__main__":
    main()
