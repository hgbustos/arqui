#!/usr/bin/env python3
"""
test_riscv_client.py — prueba de integracion de riscv_client.py sin
hardware real: reemplaza serial.Serial por un objeto falso que graba lo
que se le escribe y devuelve un volcado sintetico pre-armado, y corre
main() de punta a punta (ensamblar -> armar paquetes -> "enviar" ->
"recibir" -> parsear -> imprimir). Confirma que todo el camino de datos de
la CLI es correcto, no solo cada pieza por separado.

Uso:
    py test_riscv_client.py -v
"""
import io
import os
import tempfile
import unittest
from unittest.mock import patch

from riscv_protocol import CMD_LOAD_PROG, CMD_RUN, FIXED_WORDS, SYNC_WORD

import riscv_client


class FakeSerial:
    """Simula pyserial.Serial: sin puerto real, graba lo escrito y sirve
    una respuesta pre-cargada byte a byte al leer."""

    def __init__(self, *args, **kwargs):
        self.written = bytearray()
        self._response = b""
        self._pos = 0

    def set_response(self, data: bytes) -> None:
        self._response = data
        self._pos = 0

    def write(self, data: bytes) -> int:
        self.written += bytes(data)
        return len(data)

    def flush(self) -> None:
        pass

    def read(self, n: int) -> bytes:
        chunk = self._response[self._pos:self._pos + n]
        self._pos += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _word_le(value: int) -> bytes:
    return (value & 0xFFFFFFFF).to_bytes(4, "little")


def _build_synthetic_dump(dmem_words: int, x1: int, x2: int, x3: int) -> bytes:
    words = [0] * (FIXED_WORDS + dmem_words)
    words[0] = SYNC_WORD
    words[1] = 0b001  # core_halted=1
    words[2] = 999    # cycle_count
    words[21 + 1] = x1
    words[21 + 2] = x2
    words[21 + 3] = x3
    words[FIXED_WORDS + 0] = x3  # dmem[0] = x3, como en el programa de prueba
    return b"".join(_word_le(w) for w in words)


class TestClienteDePuntaAPunta(unittest.TestCase):
    def setUp(self):
        fd, self.asm_path = tempfile.mkstemp(suffix=".asm")
        with os.fdopen(fd, "w") as f:
            f.write(
                "addi x1, x0, 10\n"
                "addi x2, x0, 32\n"
                "add  x3, x1, x2\n"
                "sw   x3, 0(x0)\n"
                "halt\n"
            )

    def tearDown(self):
        os.remove(self.asm_path)

    def test_cmd_load_prog_y_run_con_volcado_sintetico(self):
        fake = FakeSerial()
        fake.set_response(_build_synthetic_dump(dmem_words=4, x1=10, x2=32, x3=42))

        argv = ["riscv_client.py", "--port", "COM_FALSO", "--dmem-words", "4",
                self.asm_path]
        captured = io.StringIO()
        with patch("riscv_client.serial.Serial", return_value=fake), \
             patch("sys.argv", argv), \
             patch("sys.stdout", captured):
            riscv_client.main()

        # Lo que el cliente realmente mando por el puerto (falso): primero
        # CMD_LOAD_PROG con las 5 instrucciones, despues CMD_RUN.
        self.assertEqual(fake.written[0], CMD_LOAD_PROG)
        self.assertEqual(fake.written[1], 5)  # 5 instrucciones, byte bajo
        self.assertEqual(fake.written[2], 0)  # byte alto
        load_packet_len = 3 + 5 * 4
        self.assertEqual(fake.written[load_packet_len], CMD_RUN)

        # Lo que el cliente imprimio: el volcado sintetico decodificado.
        out = captured.getvalue()
        self.assertIn("halted=1", out)
        self.assertIn("x1 =0x0000000a", out)
        self.assertIn("x2 =0x00000020", out)
        self.assertIn("x3 =0x0000002a", out)
        self.assertIn("[  0]=0x0000002a", out)  # dmem[0] = 42


if __name__ == "__main__":
    unittest.main(verbosity=2)
