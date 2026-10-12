# 07_loop_infinito.asm -- un programa que nunca termina y la pausa (CMD_BREAK)
#
# Run no vuelve nunca: en la GUI se habilita "Pausa" (la CLI la manda sola
# después de --timeout). Al pausar: halted = 0, y x5 vale un tercio de los
# ciclos, porque cada vuelta son 3 ciclos (addi, jal y la instrucción que el
# salto descarta). Ciclos / segundos esperados ~= 65 millones: el clock real.
# Pausar antes del minuto: CYCLE_COUNT es de 32 bits y da la vuelta a los 66 s.
# Después de la pausa, Step avanza un ciclo y Run sigue desde donde quedó.
loop:
        addi x5, x5, 1
        jal  x0, loop
