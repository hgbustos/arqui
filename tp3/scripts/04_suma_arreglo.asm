# 04_suma_arreglo.asm -- datos iniciales en la memoria (CMD_LOAD_DATA)
#
# Antes de correrlo, cargar 04_datos.txt en la memoria de datos:
#   GUI: pestaña "Memoria de datos" -> "Abrir archivo..." -> "Cargar en dmem"
#   CLI: --data tp3/scripts/04_datos.txt
#
# Suma las 5 palabras de 0x0..0x10 y deja el total en 0x14.
# Resultado esperado: x3 = 45 y mem[0x14] = 45, en 37 ciclos. En paso a
# paso se ve un stall load-use en cada vuelta (lw x4 -> add x3, x3, x4).
        addi x1, x0, 0        # x1 = dirección actual
        addi x2, x0, 20       # x2 = dirección donde termina el arreglo
        addi x3, x0, 0        # x3 = suma
loop:
        lw   x4, 0(x1)        # x4 = número en la dirección x1
        add  x3, x3, x4       # suma += x4
        addi x1, x1, 4        # siguiente palabra (4 bytes)
        bne  x1, x2, loop     # si no llegué al final, sigo
        sw   x3, 20(x0)       # total en la dirección 0x14
        halt
