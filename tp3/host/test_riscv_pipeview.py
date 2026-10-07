#!/usr/bin/env python3
"""
Tests de riscv_pipeview.py contra una traza REAL del RTL:
testdata/pipeline_trace.hex la genera tp3/tb/tb_pipeline_trace.v corriendo
un programa en modo paso a paso con riscv_core + dump_unit (los mismos
bytes que llegarían por UART). Si cambia el RTL, regenerarla desde la raíz
del repo con:

    iverilog -g2012 -I tp3/tb -o trace.vvp tp1/ALU.v tp3/rtl/core/*.v \\
        tp3/rtl/debug/dump_unit.v tp3/tb/tb_pipeline_trace.v && vvp -n trace.vvp

Programa de la traza (ver tb_pipeline_trace.v):
    0x00 addi x1, x0, 5      0x18 lw   x5, 0(x0)
    0x04 add  x2, x1, x1     0x1C bne  x5, x2, 8
    0x08 sw   x2, 0(x0)      0x20 jal  x6, 12
    0x0C lw   x3, 0(x0)      0x24 addi x9, x0, 1   (descartada)
    0x10 add  x4, x3, x2     0x28 halt
    0x14 beq  x4, x2, 8      0x2C jalr x0, 4(x6)

Uso:
    python test_riscv_pipeview.py
"""
import os
import unittest

from riscv_pipeview import (
    PipelineHistory, analyze, decode, ex_result, id_operand, load_trace, render_text,
)

TRACE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "testdata", "pipeline_trace.hex")
DMEM_WORDS = 4

# Derivado a mano del programa y confirmado contra la traza:
#   *  stall (PC e IF/ID congelados)    x  se descarta por un salto
#   !  salto tomado en ID               h  HALT retenido en ID
EXPECTED_DIAGRAM = """\
                          0    1    2    3    4    5    6    7    8    9    10   11   12   13   14   15   16   17   18   19
0x0000  addi x1, x0, 5    IF   ID   EX   MEM  WB
0x0004  add x2, x1, x1         IF   ID   EX   MEM  WB
0x0008  sw x2, 0(x0)                IF   ID   EX   MEM  WB
0x000c  lw x3, 0(x0)                     IF   ID   EX   MEM  WB
0x0010  add x4, x3, x2                        IF   ID*  ID   EX   MEM  WB
0x0014  beq x4, x2, 8                              IF*  IF   ID   EX   MEM  WB
(burbuja)                                               EX   MEM  WB
0x0018  lw x5, 0(x0)                                         IF   ID   EX   MEM  WB
0x001c  bne x5, x2, 8                                             IF   ID*  ID*  ID   EX   MEM  WB
0x0020  jal x6, 12                                                     IF*  IF*  IF   ID!  EX   MEM  WB
(burbuja)                                                                   EX   MEM  WB
(burbuja)                                                                        EX   MEM  WB
0x0024  addi x9, x0, 1                                                                IFx
0x002c  jalr x0, 4(x6)                                                                     IF   ID!  EX   MEM  WB
0x0030  (vacio: opcode 0x                                                                       IFx
0x0028  halt                                                                                         IF   IDh  EX   MEM  WB
0x002c  jalr x0, 4(x6)                                                                                    IF*  IF*  IF*  IF*"""


def _strip(text: str) -> str:
    return "\n".join(line.rstrip() for line in text.splitlines())


class TestTrazaReal(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.states = load_trace(TRACE, DMEM_WORDS)
        cls.by_cycle = {s.cycle_count: s for s in cls.states}

    def test_traza_completa_y_consecutiva(self):
        self.assertEqual([s.cycle_count for s in self.states], list(range(20)))
        self.assertTrue(self.states[-1].core_halted)

    def test_diagrama_multiciclo(self):
        h = PipelineHistory()
        for s in self.states:
            h.push(s)
        self.assertEqual(h.restarts, 0)
        self.assertEqual(_strip(render_text(h)), _strip(EXPECTED_DIAGRAM))

    def _arrows(self, cycle):
        return {(a.src, a.dst, a.operand, a.regnum, a.value)
                for a in analyze(self.by_cycle[cycle]).arrows}

    def test_forwarding_ex_mem_a_la_alu(self):
        # c3: add x2, x1, x1 en EX, addi x1 en MEM
        self.assertEqual(self._arrows(3), {("MEM", "EX", "rs1", 1, 5), ("MEM", "EX", "rs2", 1, 5)})

    def test_forwarding_del_dato_de_un_store(self):
        # c4: sw x2 en EX toma el dato (rs2) del add x2 que está en MEM
        self.assertEqual(self._arrows(4), {("MEM", "EX", "rs2", 2, 10)})
        self.assertIn("dato a guardar = 0x0000000a", analyze(self.by_cycle[4]).stages["EX"].details)

    def test_stall_load_use(self):
        v = analyze(self.by_cycle[5])
        self.assertIn("stall", v.stages["ID"].tags)
        self.assertIn("stall", v.stages["IF"].tags)
        self.assertTrue(any("load-use" in e and "x3" in e for e in v.events))
        self.assertEqual(analyze(self.by_cycle[6]).stages["EX"].kind, "bubble")

    def test_forwarding_ex_a_id_y_mem_wb_a_ex(self):
        # c7: beq x4 en ID toma x4 de la salida actual de la ALU (add x4 en
        # EX, que a su vez toma x3 del lw que está en MEM/WB)
        self.assertEqual(self._arrows(7), {("EX", "ID", "rs1", 4, 20), ("WB", "EX", "rs1", 3, 10)})
        self.assertIn("no se toma", analyze(self.by_cycle[7]).stages["ID"].details)

    def test_load_antes_de_salto_dos_ciclos(self):
        self.assertTrue(any("load-use" in e and "un ciclo más" in e
                            for e in analyze(self.by_cycle[9]).events))
        self.assertTrue(any("load antes de salto" in e for e in analyze(self.by_cycle[10]).events))
        self.assertEqual(self._arrows(11), {("WB", "ID", "rs1", 5, 10)})

    def test_branch_taken_durante_stall_no_es_un_salto(self):
        # c9: branch_unit compara con un dato todavía viejo y da "tomado",
        # pero el stall bloquea el PC y el flush: no se muestra como salto.
        s = self.by_cycle[9]
        self.assertTrue(s.branch_taken and s.hazard_stall)
        v = analyze(s)
        self.assertNotIn("taken", v.stages["ID"].tags)
        self.assertNotIn("flush", v.stages["IF"].tags)

    def test_jal_tomado_descarta_if(self):
        v = analyze(self.by_cycle[12])
        self.assertIn("taken", v.stages["ID"].tags)
        self.assertIn("flush", v.stages["IF"].tags)
        self.assertEqual(analyze(self.by_cycle[13]).stages["ID"].kind, "bubble")

    def test_jalr_con_forwarding_ex_mem_a_id(self):
        self.assertEqual(self._arrows(14), {("MEM", "ID", "rs1", 6, 0x24)})
        # En IF hay memoria vacía (HALT implícito) que el salto descarta
        v = analyze(self.by_cycle[14])
        self.assertEqual(v.stages["IF"].kind, "halt")
        self.assertIn("flush", v.stages["IF"].tags)

    def test_halt_drena_hasta_wb(self):
        for c in (16, 17, 18):
            v = analyze(self.by_cycle[c])
            self.assertIn("halt_wait", v.stages["ID"].tags)
            self.assertTrue(any("HALT en ID" in e for e in v.events))
        v = analyze(self.by_cycle[19])
        self.assertTrue(any("pipeline quedó vacío" in e for e in v.events))
        self.assertEqual([v.stages[st].kind for st in ("ID", "EX", "MEM", "WB")], ["halt"] * 4)

    def test_alu_de_python_coincide_con_el_hardware(self):
        # Lo que la GUI muestra como salida de EX tiene que ser exactamente
        # lo que el hardware latchea en EX/MEM en el ciclo siguiente.
        checked = 0
        for a, b in zip(self.states, self.states[1:]):
            r = ex_result(a)
            if r is not None and decode(a.id_ex.instr).cls != "BRANCH":
                self.assertEqual(r, b.ex_mem.ex_result, f"ciclo {a.cycle_count}")
                checked += 1
        self.assertEqual(checked, 8)  # addi, add, sw, lw, add, lw, jal, jalr

    def test_comparacion_de_saltos_coincide_con_el_hardware(self):
        checked = 0
        for s in self.states:
            d = decode(s.if_id.instr)
            if d.cls == "BRANCH" and not s.hazard_stall:
                a, _ = id_operand(s, "rs1")
                b, _ = id_operand(s, "rs2")
                self.assertEqual((a == b) != bool(d.funct3 & 1), s.branch_taken)
                checked += 1
        self.assertEqual(checked, 2)  # beq en c7 y bne en c11


class TestHistorialReinicio(unittest.TestCase):
    def setUp(self):
        self.states = load_trace(TRACE, DMEM_WORDS)

    def test_ciclos_no_consecutivos_reinician(self):
        h = PipelineHistory()
        h.push(self.states[0])
        h.push(self.states[5])  # como después de un CMD_RUN pausado
        self.assertEqual(h.restarts, 1)
        self.assertEqual(h.cycles(), [5])
        # Arranca de nuevo con lo que hay en cada etapa (las burbujas no)
        self.assertEqual(len(h.rows), 5)

    def test_mismo_ciclo_no_agrega_columna(self):
        h = PipelineHistory()
        for s in (self.states[0], self.states[1], self.states[1]):  # STEP + DUMP
            h.push(s)
        self.assertEqual(h.cycles(), [0, 1])
        self.assertEqual(h.restarts, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
