#!/usr/bin/env python3
"""
test_riscv_protocol.py — pruebas unitarias de riscv_protocol.py.

Uso:
    py test_riscv_protocol.py -v

El caso 'TestParseDumpSintetico' arma un stream de bytes a mano con los
MISMOS valores de prueba que usa tp3/tb/tb_dump_unit.v (registros
0x100+i, latches con constantes AAAA/BBBB/CCCC reconocibles, dmem
0xDDDD0000+i) a propósito: si ese testbench ya probó que dump_unit.v
serializa esos valores en ese orden exacto, y este test prueba que
parse_dump() los reconstruye de vuelta correctamente a partir del mismo
layout, ambos lados de la UART quedan cruzados contra la misma
especificación (tp3/docs/debug_protocol.md) sin haber compartido código
entre Verilog y Python.
"""
import unittest

from riscv_protocol import (
    CMD_DUMP, CMD_LOAD_DATA, CMD_LOAD_PROG, CMD_RESET, CMD_RUN, CMD_STEP,
    FIXED_WORDS, SYNC_WORD, ProtocolError,
    build_dump_packet, build_load_data_packet, build_load_prog_packet,
    build_reset_packet, build_run_packet, build_step_packet,
    expected_dump_size, parse_dump, to_signed32,
)


def _word_le(value: int) -> bytes:
    return (value & 0xFFFFFFFF).to_bytes(4, "little")


class TestPaquetesDeComando(unittest.TestCase):
    def test_load_prog_framing(self):
        pkt = build_load_prog_packet([0x11223344, 0xAABBCCDD])
        self.assertEqual(pkt[0], CMD_LOAD_PROG)
        self.assertEqual(pkt[1], 2)  # N_lo
        self.assertEqual(pkt[2], 0)  # N_hi
        self.assertEqual(pkt[3:7], _word_le(0x11223344))
        self.assertEqual(pkt[7:11], _word_le(0xAABBCCDD))
        self.assertEqual(len(pkt), 3 + 2 * 4)

    def test_load_data_usa_su_propio_comando(self):
        pkt = build_load_data_packet([0xDEADBEEF])
        self.assertEqual(pkt[0], CMD_LOAD_DATA)

    def test_load_packet_n_cero_solo_cabecera(self):
        pkt = build_load_prog_packet([])
        self.assertEqual(pkt, bytes([CMD_LOAD_PROG, 0, 0]))

    def test_demasiadas_palabras_lanza_error(self):
        with self.assertRaises(ProtocolError):
            build_load_prog_packet([0] * 70000)

    def test_comandos_simples_son_un_solo_byte(self):
        self.assertEqual(build_run_packet(), bytes([CMD_RUN]))
        self.assertEqual(build_step_packet(), bytes([CMD_STEP]))
        self.assertEqual(build_dump_packet(), bytes([CMD_DUMP]))
        self.assertEqual(build_reset_packet(), bytes([CMD_RESET]))


class TestParseDumpSintetico(unittest.TestCase):
    def setUp(self):
        self.dmem_words = 4
        words = [0] * (FIXED_WORDS + self.dmem_words)

        words[0] = SYNC_WORD
        words[1] = 0b101  # stalled=1, branch_taken=0, core_halted=1
        words[2] = 12345

        words[3] = 0x00000010  # if_id.pc
        words[4] = 0x00000013  # if_id.instr

        words[5] = 0x00000014          # id_ex.pc
        words[6] = 0x002081B3          # id_ex.instr
        words[7] = 0xAAAA0001          # id_ex.rs1_data
        words[8] = 0xAAAA0002          # id_ex.rs2_data
        words[9] = 0xAAAA0003          # id_ex.imm
        words[10] = 0b0010001          # id_ex.control: is_jal=1, reg_write=1

        words[11] = 0x00000018         # ex_mem.pc
        words[12] = 0x00302023         # ex_mem.instr
        words[13] = 0xBBBB0001         # ex_mem.ex_result
        words[14] = 0xBBBB0002         # ex_mem.rs2_data
        words[15] = 0b00100            # ex_mem.control: mem_write=1

        words[16] = 0x0000001C         # mem_wb.pc
        words[17] = 0x0000006F         # mem_wb.instr
        words[18] = 0xCCCC0001         # mem_wb.result
        words[19] = 0xCCCC0002         # mem_wb.mem_read_data
        words[20] = 0b011              # mem_wb.control: mem_to_reg=1, reg_write=1

        for i in range(32):
            words[21 + i] = 0x100 + i
        for i in range(self.dmem_words):
            words[FIXED_WORDS + i] = 0xDDDD0000 + i

        self.raw = b"".join(_word_le(w) for w in words)
        self.state = parse_dump(self.raw, self.dmem_words)

    def test_tamano_esperado(self):
        self.assertEqual(len(self.raw), expected_dump_size(self.dmem_words))

    def test_status_y_ciclos(self):
        self.assertTrue(self.state.core_halted)
        self.assertFalse(self.state.branch_taken)
        self.assertTrue(self.state.stalled)
        self.assertEqual(self.state.cycle_count, 12345)

    def test_if_id(self):
        self.assertEqual(self.state.if_id.pc, 0x10)
        self.assertEqual(self.state.if_id.instr, 0x13)

    def test_id_ex_datos_y_control(self):
        le = self.state.id_ex
        self.assertEqual(le.pc, 0x14)
        self.assertEqual(le.instr, 0x002081B3)
        self.assertEqual(le.rs1_data, 0xAAAA0001)
        self.assertEqual(le.rs2_data, 0xAAAA0002)
        self.assertEqual(le.imm, 0xAAAA0003)
        self.assertTrue(le.reg_write)
        self.assertTrue(le.is_jal)
        self.assertFalse(le.mem_read)
        self.assertFalse(le.mem_write)
        self.assertFalse(le.mem_to_reg)
        self.assertFalse(le.is_jalr)
        self.assertFalse(le.is_halt)

    def test_ex_mem_datos_y_control(self):
        le = self.state.ex_mem
        self.assertEqual(le.ex_result, 0xBBBB0001)
        self.assertEqual(le.rs2_data, 0xBBBB0002)
        self.assertTrue(le.mem_write)
        self.assertFalse(le.reg_write)
        self.assertFalse(le.mem_read)
        self.assertFalse(le.mem_to_reg)
        self.assertFalse(le.is_halt)

    def test_mem_wb_datos_y_control(self):
        le = self.state.mem_wb
        self.assertEqual(le.result, 0xCCCC0001)
        self.assertEqual(le.mem_read_data, 0xCCCC0002)
        self.assertTrue(le.reg_write)
        self.assertTrue(le.mem_to_reg)
        self.assertFalse(le.is_halt)

    def test_registros(self):
        self.assertEqual(len(self.state.registers), 32)
        for i in range(32):
            self.assertEqual(self.state.registers[i], 0x100 + i)

    def test_dmem(self):
        self.assertEqual(len(self.state.dmem), self.dmem_words)
        for i in range(self.dmem_words):
            self.assertEqual(self.state.dmem[i], 0xDDDD0000 + i)


class TestParseDumpErrores(unittest.TestCase):
    def test_tamano_incorrecto(self):
        with self.assertRaises(ProtocolError):
            parse_dump(b"\x00" * 10, dmem_words=4)

    def test_sync_incorrecto(self):
        words = [0] * (FIXED_WORDS + 4)
        words[0] = 0x12345678  # no es SYNC_WORD
        raw = b"".join(_word_le(w) for w in words)
        with self.assertRaises(ProtocolError):
            parse_dump(raw, dmem_words=4)


class TestToSigned32(unittest.TestCase):
    def test_positivo_sin_cambios(self):
        self.assertEqual(to_signed32(42), 42)

    def test_negativo(self):
        self.assertEqual(to_signed32(0xFFFFFFFF), -1)
        self.assertEqual(to_signed32(0xFFFFFFCE), -50)

    def test_limite_positivo(self):
        self.assertEqual(to_signed32(0x7FFFFFFF), 0x7FFFFFFF)

    def test_limite_negativo(self):
        self.assertEqual(to_signed32(0x80000000), -0x80000000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
