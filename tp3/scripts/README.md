# Programas de prueba para la placa

Programas en ensamblador para cargar en la Basys 3, cada uno pensado para
mostrar una parte del enunciado. El encabezado de cada archivo explica qué
mirar y qué resultado tiene que dar.

Todos los resultados y ciclos de esta tabla se verificaron corriendo cada
programa sobre el RTL real (Icarus Verilog) y sobre un modelo de referencia
de la ISA, y dan lo mismo con el núcleo congelado al azar entre ciclos (lo
que pasa en paso a paso).

| Archivo | Qué muestra | Resultado esperado | Ciclos |
|---|---|---|---|
| `01_suma.asm` | Carga y modo continuo | x2 = 15, mem[0x0] = 15 | 32 |
| `02_riesgos.asm` | Paso a paso: forwarding, stalls, flush, HALT | x4 = 20, x6 = 0x24, x9 = 0, mem[0x0] = 10 | 19 |
| `03_memoria.asm` | lb/lh/lw/lbu/lhu y sb/sh/sw | ver tabla en el archivo; mem[0x0] = 0x00ABAB01 | 18 |
| `04_suma_arreglo.asm` + `04_datos.txt` | Datos iniciales (CMD_LOAD_DATA) | x3 = 45, mem[0x14] = 45 | 37 |
| `05_contador.asm` | La memoria de datos persiste; los resets no la borran | mem[0x0] + 1 en cada Run | 8 |
| `06_sin_halt.asm` | Programa sin `halt` (HALT implícito) | x1 = 7, x2 = 10 | 6 |
| `07_loop_infinito.asm` | Programa que no termina y pausa (CMD_BREAK) | x5 ≈ ciclos / 3 al pausar | — |
| `08_alu.asm` | Todas las operaciones de la ALU (R, I, lui) | un valor por instrucción, en los comentarios | 26 |
| `09_llamada.asm` | Llamada a función y retorno (jal/jalr) | mem[0x0] = 42, mem[0x4] = 12 | 64 |
| `10_fibonacci.asm` | Un arreglo calculado en la memoria | 0, 1, 1, 2, 3, 5, … 89 en 0x0..0x2C | 80 |

## Cómo cargarlos

**GUI** (`py tp3/host/riscv_gui.py`, puerto de la placa a 115200): pestaña
*Programa* → *Abrir archivo .asm…* → *Ensamblar y cargar*, y después *Run*
o *Step* en la pestaña *Ejecución*. Los datos de `04_datos.txt` se cargan
en la pestaña *Memoria de datos* → *Abrir archivo…* → *Cargar en dmem*.

**CLI**:

```
py tp3/host/riscv_client.py --port COM4 tp3/scripts/01_suma.asm
py tp3/host/riscv_client.py --port COM4 --mode step --steps 25 tp3/scripts/02_riesgos.asm
py tp3/host/riscv_client.py --port COM4 --data tp3/scripts/04_datos.txt tp3/scripts/04_suma_arreglo.asm
```

La memoria de datos no se borra al cargar otro programa (sólo con
CMD_LOAD_DATA), así que lo que deja un programa lo ve el siguiente: por
ejemplo, `05_contador.asm` parte del valor que haya en mem[0x0].
