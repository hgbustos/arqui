# 08_alu.asm -- todas las operaciones de la ALU: R-type, I-type y lui
#
# Valores de entrada: x1 = 0x80000000, x2 = -7 (0xFFFFFFF9), x3 = 5.
# El resultado esperado de cada instrucción está en su comentario.
# Termina en 26 ciclos.
        lui   x1, 0x80000       # x1  = 0x80000000
        addi  x2, x0, -7        # x2  = 0xFFFFFFF9 (-7)
        addi  x3, x0, 5         # x3  = 5
        add   x4, x2, x3        # x4  = -2          (0xFFFFFFFE)
        sub   x5, x3, x2        # x5  = 12          5 - (-7)
        sll   x6, x3, x3        # x6  = 160         5 << 5
        srl   x7, x2, x3        # x7  = 0x07FFFFFF  >> lógico: entran ceros
        sra   x8, x2, x3        # x8  = -1          >> aritmético: se copia el signo
        and   x9, x2, x3        # x9  = 1
        or    x10, x2, x3       # x10 = -3          (0xFFFFFFFD)
        xor   x11, x2, x3       # x11 = -4          (0xFFFFFFFC)
        slt   x12, x2, x3       # x12 = 1           -7 < 5 con signo
        sltu  x13, x2, x3       # x13 = 0           0xFFFFFFF9 < 5 sin signo: no
        addi  x14, x3, -10      # x14 = -5
        andi  x15, x2, 0x0F0    # x15 = 0xF0
        ori   x16, x3, 0x700    # x16 = 0x705
        xori  x17, x3, -1       # x17 = -6          (~5)
        slti  x18, x2, -6       # x18 = 1           -7 < -6
        sltiu x19, x3, -1       # x19 = 1           5 < 0xFFFFFFFF sin signo
        slli  x20, x3, 28       # x20 = 0x50000000
        srli  x21, x1, 31       # x21 = 1
        srai  x22, x1, 31       # x22 = -1          (0xFFFFFFFF)
        halt
