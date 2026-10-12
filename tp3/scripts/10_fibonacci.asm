# 10_fibonacci.asm -- los primeros 12 números de Fibonacci en la memoria
#
# Resultado esperado en la pestaña "Memoria de datos" (0x0 .. 0x2C):
#   0, 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89
# Termina en 80 ciclos.
        addi x1, x0, 0        # f(n-2)
        addi x2, x0, 1        # f(n-1)
        addi x3, x0, 0        # dirección actual
        addi x4, x0, 48       # dirección final: 12 palabras * 4 bytes
        sw   x1, 0(x3)        # mem[0x0] = 0
        sw   x2, 4(x3)        # mem[0x4] = 1
        addi x3, x3, 8
loop:
        add  x5, x1, x2       # f(n) = f(n-2) + f(n-1)
        sw   x5, 0(x3)
        addi x1, x2, 0        # corre la ventana
        addi x2, x5, 0
        addi x3, x3, 4
        bne  x3, x4, loop
        halt
