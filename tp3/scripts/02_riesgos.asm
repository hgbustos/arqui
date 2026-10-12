# 02_riesgos.asm -- paso a paso: todos los riesgos en 19 ciclos
#
# Es el mismo programa que tp3/tb/tb_pipeline_trace.v (la traza que usa la
# GUI). Cargarlo, "Ver estado" (ciclo 0) y avanzar con Step:
#   ciclo 3      forwarding de x1 desde EX/MEM a los dos operandos de la ALU
#   ciclo 4      forwarding de x2 al dato del sw
#   ciclos 5-6   STALL load-use (el add necesita x3, que el lw todavía lee)
#   ciclo 7      forwarding de x4 desde la salida de la ALU al comparador de ID
#   ciclos 9-11  stall de 2 ciclos: load antes de un salto que se resuelve en ID
#   ciclo 12     salto tomado (jal): la instrucción de IF se descarta (flush)
#   ciclo 14     jalr tomado, con x6 adelantado desde EX/MEM
#   ciclos 16-19 HALT en ID, drenaje, y HALT en WB: fin
#
# Resultado esperado: x4 = 20, x6 = 0x24, x9 = 0 (descartada), mem[0x0] = 10.
        addi x1, x0, 5        # 0x00
        add  x2, x1, x1       # 0x04  x2 = 10   (A y B desde EX/MEM)
        sw   x2, 0(x0)        # 0x08  mem[0] = 10 (dato desde EX/MEM)
        lw   x3, 0(x0)        # 0x0C  x3 = 10
        add  x4, x3, x2       # 0x10  x4 = 20   (load-use)
        beq  x4, x2, 8        # 0x14  no se toma (x4 desde EX)
        lw   x5, 0(x0)        # 0x18  x5 = 10
        bne  x5, x2, 8        # 0x1C  load antes de un salto; no se toma
        jal  x6, 12           # 0x20  salta a 0x2C, x6 = 0x24
        addi x9, x0, 1        # 0x24  se descarta (flush del jal)
        halt                  # 0x28
        jalr x0, 4(x6)        # 0x2C  salta a x6 + 4 = 0x28
