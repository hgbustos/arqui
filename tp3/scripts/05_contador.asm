# 05_contador.asm -- la memoria de datos persiste; los resets no la borran
#
# Suma 1 a mem[0x0] cada vez que corre (8 ciclos). Probar:
#   1. Cargarlo y Run          -> mem[0x0] = lo que había + 1
#   2. Run otra vez            -> no cambia: el núcleo ya está en HALT
#   3. Reset (CMD_RESET) + Run -> +1 otra vez
#   4. Botón del medio de la placa (BTNC) + Run -> +1 otra vez
# Los dos resets reinician PC, registros y latches, pero no las memorias:
# el programa sigue cargado y el dato persiste. Sólo CMD_LOAD_DATA (o
# apagar la placa) cambia la memoria de datos.
        lw   x5, 0(x0)        # traer: x5 <- mem[0]
        addi x5, x5, 1        # trabajar con el registro
        sw   x5, 0(x0)        # guardar: mem[0] <- x5
        halt
