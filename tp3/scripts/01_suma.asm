# 01_suma.asm -- carga de un programa y modo continuo (Run)
#
# En C:  for (i = 1; i <= 5; i++) suma += i;   mem[0] = suma;
#
# Resultado esperado: x2 = 15 y mem[0x0] = 15, en 32 ciclos.
# En el loop, 'slt' + 'beq' reemplazan a un 'bge' (no está en el subset).
        addi x1, x0, 5        # n = 5
        addi x2, x0, 0        # suma = 0
        addi x3, x0, 1        # i = 1
loop:
        add  x2, x2, x3       # suma += i
        addi x3, x3, 1        # i++
        slt  x4, x1, x3       # x4 = (n < i)
        beq  x4, x0, loop     # si i <= n, sigo
        sw   x2, 0(x0)        # mem[0] = suma
        halt
