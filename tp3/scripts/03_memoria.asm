# 03_memoria.asm -- loads y stores de byte, media palabra y palabra
#
# mem[0x0] = 0x80FF7F01 -> bytes: [0x0]=01 [0x1]=7F [0x2]=FF [0x3]=80
#
# Resultado esperado (18 ciclos):
#   x10 = 0x80FF7F01  el lw justo después del sw ya ve el valor nuevo
#   x2  = -1          lb del byte FF: se copia el signo
#   x3  = 255         lbu del mismo byte: se completa con ceros
#   x4  = -32513      lh de la media palabra alta 80FF
#   x5  = 33023       lhu de la misma media palabra
#   x6  = 127         lb del byte 7F (positivo)
#   x8  = 0x00ABAB01  sb cambió sólo el byte 1 y sh sólo los bytes 2-3
#   x9  = 0x00ABAB01  lw desalineado (0x2) lee la palabra alineada de 0x0
#   mem[0x0] = 0x00ABAB01
        lui  x1, 0x80FF8
        addi x1, x1, -255     # x1 = 0x80FF7F01
        sw   x1, 0(x0)
        lw   x10, 0(x0)
        lb   x2, 2(x0)
        lbu  x3, 2(x0)
        lh   x4, 2(x0)
        lhu  x5, 2(x0)
        lb   x6, 1(x0)
        addi x7, x0, 0xAB
        sb   x7, 1(x0)        # byte 1 <- AB (dato adelantado desde el addi)
        sh   x7, 2(x0)        # bytes 2-3 <- 00AB
        lw   x8, 0(x0)
        lw   x9, 2(x0)        # dirección desalineada
        halt
