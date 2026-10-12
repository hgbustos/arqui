# 06_sin_halt.asm -- programa sin instrucción de parada (HALT implícito)
#
# No termina en 'halt': la palabra siguiente vale 0x00000000, porque cada
# carga limpia la memoria de programa completa, y eso no es una
# instrucción válida -> el núcleo la trata como HALT.
#
# Resultado esperado: x1 = 7, x2 = 10, termina solo en 6 ciclos.
        addi x1, x0, 7
        addi x2, x1, 3
