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
import time
import unittest
from unittest.mock import patch

from riscv_protocol import CMD_BREAK, CMD_LOAD_PROG, CMD_RUN, CMD_STEP, FIXED_WORDS, SYNC_WORD

import riscv_client


class FakeSerial:
    """Simula pyserial.Serial: sin puerto real, graba lo escrito y sirve
    una respuesta pre-cargada byte a byte al leer."""

    def __init__(self, *args, **kwargs):
        self.written = bytearray()
        self._response = b""
        self._pos = 0
        self.timeout = kwargs.get("timeout")

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
        if not chunk and self.timeout:
            time.sleep(self.timeout)  # como pyserial: sin datos, bloquea hasta el timeout
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeSerialSinHalt(FakeSerial):
    """Simula un programa que nunca llega a HALT (loop infinito): la FPGA
    no manda nada hasta recibir la pausa (CMD_BREAK), y recién ahí entrega
    el volcado pre-cargado."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.break_received = False

    def write(self, data: bytes) -> int:
        if bytes(data) == bytes([CMD_BREAK]):
            self.break_received = True
        return super().write(data)

    def read(self, n: int) -> bytes:
        if not self.break_received:
            if self.timeout:
                time.sleep(self.timeout)
            return b""
        return super().read(n)


def _word_le(value: int) -> bytes:
    return (value & 0xFFFFFFFF).to_bytes(4, "little")


def _build_synthetic_dump(dmem_words: int, x1: int, x2: int, x3: int,
                          halted: bool = True, x5: int = 0) -> bytes:
    words = [0] * (FIXED_WORDS + dmem_words)
    words[0] = SYNC_WORD
    words[1] = 0b001 if halted else 0b000  # core_halted
    words[2] = 999    # cycle_count
    words[21 + 1] = x1
    words[21 + 2] = x2
    words[21 + 3] = x3
    words[21 + 5] = x5
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
        # El volcado llego enseguida (HALT): no hizo falta ninguna pausa.
        self.assertEqual(len(fake.written), load_packet_len + 1)

        # Lo que el cliente imprimio: el volcado sintetico decodificado.
        out = captured.getvalue()
        self.assertIn("halted=1", out)
        self.assertIn("x1 =0x0000000a", out)
        self.assertIn("x2 =0x00000020", out)
        self.assertIn("x3 =0x0000002a", out)
        self.assertIn("[  0]=0x0000002a", out)  # dmem[0] = 42


class TestPausaDeUnProgramaSinHalt(unittest.TestCase):
    def setUp(self):
        fd, self.asm_path = tempfile.mkstemp(suffix=".asm")
        with os.fdopen(fd, "w") as f:
            f.write(
                "loop:\n"
                "addi x5, x5, 1\n"
                "jal  x0, loop\n"
            )

    def tearDown(self):
        os.remove(self.asm_path)

    def test_run_sin_halt_se_pausa_con_cmd_break(self):
        fake = FakeSerialSinHalt(timeout=0.2)
        fake.set_response(_build_synthetic_dump(dmem_words=4, x1=0, x2=0, x3=0,
                                                halted=False, x5=1234))

        argv = ["riscv_client.py", "--port", "COM_FALSO", "--dmem-words", "4",
                "--timeout", "0.2", self.asm_path]
        captured = io.StringIO()
        with patch("riscv_client.serial.Serial", return_value=fake), \
             patch("sys.argv", argv), \
             patch("sys.stdout", captured):
            riscv_client.main()

        # Tras CMD_RUN y el timeout sin respuesta, el cliente manda la pausa.
        load_packet_len = 3 + 2 * 4
        self.assertEqual(fake.written[load_packet_len], CMD_RUN)
        self.assertEqual(fake.written[load_packet_len + 1], CMD_BREAK)
        self.assertEqual(len(fake.written), load_packet_len + 2)

        out = captured.getvalue()
        self.assertIn("halted=0", out)
        self.assertIn("x5 =0x000004d2", out)  # 1234: el estado en que quedo el loop
        self.assertIn("se pauso con CMD_BREAK", out)


class TestModoPasoAPaso(unittest.TestCase):
    """--mode step con los volcados de la traza real del RTL
    (testdata/pipeline_trace.hex, ver test_riscv_pipeview.py): cada paso
    se explica y al final se imprime el diagrama multiciclo."""

    def setUp(self):
        fd, self.asm_path = tempfile.mkstemp(suffix=".asm")
        with os.fdopen(fd, "w") as f:
            f.write("halt\n")  # el contenido no importa: las respuestas vienen de la traza

    def tearDown(self):
        os.remove(self.asm_path)

    def test_step_explica_cada_ciclo_y_dibuja_el_diagrama(self):
        trace = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "testdata", "pipeline_trace.hex")
        with open(trace, encoding="utf-8") as f:
            dumps = [b"".join(int(w, 16).to_bytes(4, "little") for w in line.split())
                     for line in f if line.strip()]
        fake = FakeSerial()
        fake.set_response(b"".join(dumps[1:]))  # respuestas a los CMD_STEP (ciclos 1..19)

        argv = ["riscv_client.py", "--port", "COM_FALSO", "--dmem-words", "4",
                "--mode", "step", "--steps", "50", self.asm_path]
        captured = io.StringIO()
        with patch("riscv_client.serial.Serial", return_value=fake), \
             patch("sys.argv", argv), \
             patch("sys.stdout", captured):
            riscv_client.main()

        load_packet_len = 3 + 1 * 4
        steps = bytes(fake.written[load_packet_len:])
        self.assertEqual(steps, bytes([CMD_STEP]) * 19)  # corta solo al llegar a HALT
        out = captured.getvalue()
        self.assertIn("STALL (load-use)", out)
        self.assertIn("Salto tomado en ID", out)
        self.assertIn("HALT llegó a WB", out)
        self.assertIn("0x0010  add x4, x3, x2", out)
        self.assertIn("IDh", out)  # el HALT retenido en ID, en el diagrama


class TestTamanioAntesDeAbrirElPuerto(unittest.TestCase):
    """Un programa o unos datos que no entran en la memoria del bitstream
    se rechazan antes de abrir el puerto: el hardware no avisaria (la
    direccion da la vuelta y pisa el principio de la memoria)."""

    def setUp(self):
        self.tmp = []

    def tearDown(self):
        for p in self.tmp:
            os.remove(p)

    def _tmp(self, suffix, text):
        fd, path = tempfile.mkstemp(suffix=suffix)
        with os.fdopen(fd, "w") as f:
            f.write(text)
        self.tmp.append(path)
        return path

    def _run_main_expecting_error(self, argv):
        captured_err = io.StringIO()
        with patch("riscv_client.serial.Serial") as serial_mock, \
             patch("sys.argv", argv), \
             patch("sys.stdout", io.StringIO()), \
             patch("sys.stderr", captured_err):
            with self.assertRaises(SystemExit) as ctx:
                riscv_client.main()
        self.assertEqual(ctx.exception.code, 1)
        serial_mock.assert_not_called()
        return captured_err.getvalue()

    def test_programa_mas_grande_que_la_imem(self):
        asm = self._tmp(".asm", "nop\n" * 5 + "halt\n")  # 6 palabras
        err = self._run_main_expecting_error(
            ["riscv_client.py", "--port", "COM_FALSO", "--imem-words", "4", asm])
        self.assertIn("imem", err)

    def test_datos_mas_grandes_que_la_dmem(self):
        asm = self._tmp(".asm", "halt\n")
        datos = self._tmp(".txt", "1\n2\n3\n4\n5\n")  # 5 palabras
        err = self._run_main_expecting_error(
            ["riscv_client.py", "--port", "COM_FALSO", "--dmem-words", "4",
             "--data", datos, asm])
        self.assertIn("dmem", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
