# 09_llamada.asm -- llamada a función y retorno (jal / jalr)
#
# mult(a0, a1) multiplica por sumas sucesivas (no hay 'mul' en el subset).
# Se llama dos veces con el mismo código: 'jal ra, mult' guarda en ra la
# dirección de retorno y 'jalr x0, 0(ra)' vuelve.
#
# Resultado esperado: mem[0x0] = 42 (6 * 7), mem[0x4] = 12 (3 * 4),
# a0 (x10) = 12 y ra (x1) = 0x1C (retorno de la segunda llamada), en 64 ciclos.
        addi a0, x0, 6        # primer argumento
        addi a1, x0, 7        # segundo argumento
        jal  ra, mult         # llamada
        sw   a0, 0(x0)        # mem[0] = 42
        addi a0, x0, 3
        addi a1, x0, 4
        jal  ra, mult         # segunda llamada, mismo código
        sw   a0, 4(x0)        # mem[4] = 12
        halt
mult:                         # a0 = a0 * a1 (con a1 > 0); usa t0
        addi t0, x0, 0        # acumulador
mloop:
        add  t0, t0, a0
        addi a1, a1, -1
        bne  a1, x0, mloop
        addi a0, t0, 0        # resultado en a0
        jalr x0, 0(ra)        # retorno
