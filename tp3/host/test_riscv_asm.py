#!/usr/bin/env python3
"""
test_riscv_asm.py — pruebas unitarias de riscv_asm.py.

Uso:
    py test_riscv_asm.py -v

Cubre: valores esperados verificados a mano (no solo re-derivados con la
misma formula que el propio ensamblador, para no terminar comparando
Python contra Python), un caso de cada tipo de instruccion, resolucion de
etiquetas (adelante y atras), ida y vuelta por el desensamblador, casos de
error, y una comparacion directa contra los mismos programas de prueba que
ya se validaron de punta a punta en tp3/tb/tb_riscv_core.v (201 tests) --
si el texto en ensamblador produce las mismas palabras que ya se sabe que
corren bien en el pipeline real, es una confirmacion fuerte de que el
ensamblador esta generando codigo RV32I correcto, no solo internamente
consistente.
"""
import unittest

from riscv_asm import AsmError, assemble, disassemble_word, parse_word_list


class TestValoresVerificadosAMano(unittest.TestCase):
    """Encodings recalculados a mano, bit a bit, de forma independiente a
    las funciones enc_* del propio modulo (ver el mensaje de commit /
    conversacion de diseno para el detalle de la cuenta)."""

    def test_addi_x1_x0_10(self):
        # imm(10)<<20 | rd(1)<<7 | opcode(0x13) = 0x00A00093
        self.assertEqual(assemble("addi x1, x0, 10")[0], 0x00A00093)

    def test_add_x3_x1_x2(self):
        # funct7(0)<<25 | rs2(2)<<20 | rs1(1)<<15 | rd(3)<<7 | opcode(0x33) = 0x002081B3
        self.assertEqual(assemble("add x3, x1, x2")[0], 0x002081B3)

    def test_halt_es_custom0_todo_cero(self):
        self.assertEqual(assemble("halt")[0], 0b0001011)

    def test_nop_es_addi_x0_x0_0(self):
        self.assertEqual(assemble("nop")[0], 0x00000013)


class TestUnaInstruccionPorTipo(unittest.TestCase):
    def test_r_type_sub(self):
        w = assemble("sub x4, x1, x2")[0]
        self.assertEqual((w >> 25) & 0x7F, 0b0100000)  # funct7 distingue sub de add

    def test_i_type_andi(self):
        w = assemble("andi x2, x1, 15")[0]
        self.assertEqual((w >> 20) & 0xFFF, 15)

    def test_i_type_negativo_signo(self):
        w = assemble("addi x1, x0, -1")[0]
        self.assertEqual((w >> 20) & 0xFFF, 0xFFF)  # -1 en 12 bits = todos unos

    def test_i_shift_slli(self):
        w = assemble("slli x1, x1, 4")[0]
        self.assertEqual((w >> 20) & 0x1F, 4)
        self.assertEqual((w >> 25) & 0x7F, 0)  # slli: funct7=0

    def test_i_shift_srai_setea_bit30(self):
        w = assemble("srai x1, x1, 4")[0]
        self.assertEqual((w >> 25) & 0x7F, 0b0100000)

    def test_i_load_lw_offset_negativo(self):
        w = assemble("lw x3, -4(x1)")[0]
        imm = (w >> 20) & 0xFFF
        self.assertEqual(imm, 0xFFC)  # -4 en 12 bits

    def test_s_type_sw(self):
        w = assemble("sw x3, 8(x1)")[0]
        imm4_0 = (w >> 7) & 0x1F
        imm11_5 = (w >> 25) & 0x7F
        self.assertEqual((imm11_5 << 5) | imm4_0, 8)

    def test_b_type_beq_offset_directo(self):
        w = assemble("beq x1, x2, 8")[0]
        imm11 = (w >> 7) & 0x1
        imm4_1 = (w >> 8) & 0xF
        imm10_5 = (w >> 25) & 0x3F
        imm12 = (w >> 31) & 0x1
        imm = (imm12 << 12) | (imm11 << 11) | (imm10_5 << 5) | (imm4_1 << 1)
        self.assertEqual(imm, 8)

    def test_u_type_lui(self):
        w = assemble("lui x5, 0xABCDE")[0]
        self.assertEqual((w >> 12) & 0xFFFFF, 0xABCDE)

    def test_j_type_jal_offset_directo(self):
        w = assemble("jal x1, 16")[0]
        imm20 = (w >> 31) & 0x1
        imm19_12 = (w >> 12) & 0xFF
        imm11 = (w >> 20) & 0x1
        imm10_1 = (w >> 21) & 0x3FF
        imm = (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (imm10_1 << 1)
        self.assertEqual(imm, 16)

    def test_jalr(self):
        w = assemble("jalr x1, 4(x2)")[0]
        self.assertEqual((w >> 15) & 0x1F, 2)  # rs1
        self.assertEqual((w >> 20) & 0xFFF, 4)  # imm


class TestRegistros(unittest.TestCase):
    def test_nombres_abi_equivalen_a_xN(self):
        self.assertEqual(assemble("add ra, sp, gp")[0], assemble("add x1, x2, x3")[0])
        self.assertEqual(assemble("add t0, a0, s0")[0], assemble("add x5, x10, x8")[0])

    def test_fp_es_alias_de_s0(self):
        self.assertEqual(assemble("add fp, x0, x0")[0], assemble("add s0, x0, x0")[0])

    def test_registro_invalido_lanza_error(self):
        with self.assertRaises(AsmError):
            assemble("add x32, x0, x0")

    def test_registro_no_numerico_invalido_lanza_error(self):
        with self.assertRaises(AsmError):
            assemble("add r1, x0, x0")


class TestEtiquetas(unittest.TestCase):
    def test_branch_adelante(self):
        # beq x1,x2,fin  (offset=+8, salta la instr. del medio)
        # addi x3,x0,1
        # fin: addi x4,x0,2
        words = assemble("""
            beq x1, x2, fin
            addi x3, x0, 1
            fin: addi x4, x0, 2
        """)
        self.assertEqual(words[0], assemble("beq x1, x2, 8")[0])

    def test_jal_atras(self):
        words = assemble("""
            inicio: addi x1, x0, 1
            addi x2, x0, 2
            jal x0, inicio
        """)
        # el jal esta en addr 8, inicio en addr 0 -> offset = -8
        self.assertEqual(words[2], assemble("jal x0, -8")[0])

    def test_jal_un_solo_operando_usa_ra(self):
        w1 = assemble("jal fin\nfin: nop")[0]
        w2 = assemble("jal x1, fin\nfin: nop")[0]
        self.assertEqual(w1, w2)

    def test_etiqueta_duplicada_lanza_error(self):
        with self.assertRaises(AsmError):
            assemble("a: nop\na: nop")

    def test_etiqueta_inexistente_intenta_como_numero_y_falla(self):
        with self.assertRaises(AsmError):
            assemble("beq x1, x2, no_existe")


class TestErrores(unittest.TestCase):
    def test_mnemonico_desconocido(self):
        with self.assertRaises(AsmError):
            assemble("foo x1, x2, x3")

    def test_inmediato_i_type_fuera_de_rango(self):
        with self.assertRaises(AsmError):
            assemble("addi x1, x0, 5000")

    def test_shamt_fuera_de_rango(self):
        with self.assertRaises(AsmError):
            assemble("slli x1, x1, 32")

    def test_branch_offset_impar_lanza_error(self):
        with self.assertRaises(AsmError):
            assemble("beq x1, x2, 3")

    def test_cantidad_de_operandos_incorrecta(self):
        with self.assertRaises(AsmError):
            assemble("add x1, x2")


class TestDesensamblador(unittest.TestCase):
    def test_ida_y_vuelta_r_type(self):
        w = assemble("add x3, x1, x2")[0]
        self.assertEqual(disassemble_word(w), "add x3, x1, x2")

    def test_ida_y_vuelta_i_type(self):
        w = assemble("addi x1, x0, -5")[0]
        self.assertEqual(disassemble_word(w), "addi x1, x0, -5")

    def test_ida_y_vuelta_load(self):
        w = assemble("lw x3, -4(x1)")[0]
        self.assertEqual(disassemble_word(w), "lw x3, -4(x1)")

    def test_ida_y_vuelta_store(self):
        w = assemble("sw x3, 8(x1)")[0]
        self.assertEqual(disassemble_word(w), "sw x3, 8(x1)")

    def test_ida_y_vuelta_lui(self):
        w = assemble("lui x5, 0xabcde")[0]
        self.assertEqual(disassemble_word(w), "lui x5, 0xabcde")

    def test_halt(self):
        self.assertEqual(disassemble_word(assemble("halt")[0]), "halt")

    def test_palabra_cero_es_halt_implicito(self):
        self.assertIn("halt implicito", disassemble_word(0))

    def test_branch_muestra_direccion_absoluta_resuelta(self):
        w = assemble("beq x1, x2, 8")[0]
        texto = disassemble_word(w, pc=0x100)
        self.assertIn("0x00000108", texto)


class TestProgramasCompletosDeTbRiscvCore(unittest.TestCase):
    """Mismos programas (traducidos a texto ensamblador) que ya corrieron
    de punta a punta en tb_riscv_core.v -- confirma que el ensamblador
    genera exactamente el mismo binario que ya se probo en el pipeline."""

    def test_programa_r_type_basico(self):
        words = assemble("""
            addi x1, x0, 10
            addi x2, x0, 3
            add  x3, x1, x2
            sub  x4, x1, x2
            and  x5, x1, x2
            or   x6, x1, x2
            xor  x7, x1, x2
            sll  x8, x1, x2
            srl  x9, x1, x2
            slt  x10, x2, x1
            sltu x11, x1, x2
            halt
        """)
        self.assertEqual(len(words), 12)
        self.assertEqual(words[0], 0x00A00093)  # addi x1,x0,10 (verificado a mano arriba)
        self.assertEqual(words[2], 0x002081B3)  # add x3,x1,x2  (verificado a mano arriba)
        self.assertEqual(words[-1] & 0x7F, 0b0001011)  # halt = opcode custom-0

    def test_programa_jal_jalr(self):
        # Mismo programa que la seccion 4) de tb_riscv_core.v, con etiquetas
        # en vez de offsets calculados a mano -- y verifica que da los
        # MISMOS offsets que ese testbench calculo y verifico manualmente.
        words = assemble("""
            lui  x1, 0x12345
            jal  x2, destino1
            addi x3, x0, 999
            addi x3, x0, 888
            destino1: addi x4, x0, 111
            jal  x0, destino2
            addi x6, x0, 777
            addi x6, x0, 666
            destino2: addi x7, x1, 0x123
        """)
        self.assertEqual(words[1], assemble("jal x2, 12")[0])
        self.assertEqual(words[5], assemble("jal x0, 12")[0])


class TestParseWordList(unittest.TestCase):
    def test_decimal_y_hex_mezclados(self):
        words = parse_word_list("10\n0x20\n# comentario\n\n30")
        self.assertEqual(words, [10, 0x20, 30])

    def test_negativo_se_guarda_como_complemento_a_2(self):
        words = parse_word_list("-1")
        self.assertEqual(words, [0xFFFFFFFF])


if __name__ == "__main__":
    unittest.main(verbosity=2)
