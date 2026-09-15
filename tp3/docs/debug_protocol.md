# Protocolo de la Debug Unit (TP3)

Especificación exacta del protocolo que implementan `tp3/rtl/debug/debug_unit.v`
y `tp3/rtl/debug/dump_unit.v` sobre la UART (capa física y de transporte
reutilizadas sin cambios de TP2: `baud_generator.v`, `uart_rx.v`, `uart_tx.v`,
`uart_interface.v`). Sigue el mismo patrón "comando + trigger" que
`tp2/rtl/alu_link.v`: un byte de comando decide qué sigue, y un comando de
carga nunca dispara una respuesta por su cuenta — sólo `CMD_RUN`/`CMD_STEP`/
`CMD_DUMP` disparan el volcado de estado (siempre completo, nunca
diferencial: decisión consciente por simplicidad, con el costo de ancho de
banda documentado más abajo).

`debug_unit.v` sólo necesita el lado Rx del Interface Circuit; `dump_unit.v`
sólo necesita el lado Tx. No hay arbitraje entre ambos: cada uno usa una
mitad distinta del puerto de `uart_interface.v`, nunca contienden.

## Comandos (Host → FPGA)

Un byte, primero de cada transacción.

| Comando | Valor | Efecto |
|---|---|---|
| `CMD_LOAD_PROG` | `0x10` | Carga un programa nuevo en `imem`. Ver framing abajo. Dispara soft-reset + limpieza completa de `imem`. No responde nada. |
| `CMD_LOAD_DATA` | `0x11` | Carga datos iniciales en `dmem`. Mismo framing y mismo soft-reset, pero limpia y escribe `dmem` en vez de `imem`. No responde nada. |
| `CMD_RUN` | `0x20` | Modo continuo: libera el pipeline hasta que el core se detiene (HALT explícito o implícito) y dispara un volcado completo. |
| `CMD_STEP` | `0x21` | Modo paso a paso: libera el pipeline exactamente 1 ciclo de reloj y dispara un volcado completo. |
| `CMD_DUMP` | `0x22` | Dispara un volcado completo sin avanzar la ejecución (para ver el estado recién cargado, por ejemplo). |
| `CMD_RESET` | `0x23` | Soft-reset manual (PC, banco de registros, los 4 latches de pipeline) sin tocar `imem`/`dmem`. No responde nada. |
| cualquier otro | — | Se descarta (se consume el byte, sin efecto), igual que en `alu_link.v`. |

`CMD_RUN`/`CMD_STEP` sobre un core ya detenido son un no-op seguro: la
condición de halt frena `PC`/`IF-ID` sin importar `global_stall_i` (ver
`hazard_unit.v`), así que "correr" o "step-ear" un core ya parado sólo
vuelve a disparar el mismo volcado, sin ejecutar nada nuevo.

### Framing de `CMD_LOAD_PROG` / `CMD_LOAD_DATA`

Todos los campos multi-byte de este protocolo van en **little-endian**.

```
[CMD_LOAD_PROG|CMD_LOAD_DATA] [N_lo] [N_hi] [w0_b0 w0_b1 w0_b2 w0_b3] ... [w(N-1)_b0..b3]
```

1. Byte de comando.
2. Cantidad de palabras `N` a cargar, 16 bits little-endian (`N_lo` primero).
   `N=0` es válido (sólo limpia la memoria destino, no escribe nada).
3. `N` palabras de 32 bits, cada una en 4 bytes little-endian, que se
   escriben en la memoria destino empezando en la dirección `0x0` e
   incrementando de a 4.

**Reprogramación (respuesta a la pregunta abierta del enunciado):** ambos
comandos disparan primero un soft-reset (PC=0, banco de registros y los 4
latches de pipeline en 0) y una limpieza COMPLETA de su memoria destino
(no sólo las `N` palabras) antes de escribir. Para `imem` esto es
deliberado más allá de la higiene: cualquier dirección más allá del
programa recién cargado queda en `0x00000000`, que `control_unit.v` trata
como HALT implícito (ver más abajo) — es la mitad de la respuesta a "¿qué
pasa si no hay HALT en memoria?". `dmem` en cambio persiste entre
programas salvo que llegue un `CMD_LOAD_DATA` explícito (análogo a que una
computadora real no borra la RAM sola al reiniciar).

## Volcado de estado (FPGA → Host)

Disparado siempre por `CMD_RUN` (al terminar), `CMD_STEP` (tras el ciclo) o
`CMD_DUMP` (inmediato). Es la MISMA estructura en los tres casos: una
secuencia de palabras de 32 bits, cada una en 4 bytes little-endian, en
este orden exacto.

| # palabra | Contenido | Detalle |
|---|---|---|
| 0 | `SYNC` | `0xAA55AA55` fijo — marca de sincronismo para que el host se pueda recuperar si perdió un byte. |
| 1 | `STATUS` | bit0=`core_halted`, bit1=`branch_taken`, bit2=`stalled` (`~pc_write_en`), resto en 0. |
| 2 | `CYCLE_COUNT` | Ciclos transcurridos desde el último reset/soft-reset. |
| 3–4 | IF/ID | `pc`, `instr` |
| 5–10 | ID/EX | `pc`, `instr`, `rs1_data`, `rs2_data`, `imm`, `control` |
| 11–15 | EX/MEM | `pc`, `instr`, `ex_result`, `rs2_data`, `control` |
| 16–20 | MEM/WB | `pc`, `instr`, `result`, `mem_read_data`, `control` |
| 21–52 | Registros | `x0`..`x31`, 32 palabras en orden |
| 53–(53+D−1) | `dmem` | `dmem[0]`..`dmem[D-1]` completa (`D` = `DMEM_DEPTH_WORDS`) |

Cada campo `control` empaqueta las señales de control de esa etapa en los
bits bajos (resto en 0) — un campo por instrucción, no un bit aparte por
señal, para que el framing entero sea uniforme (siempre "mandar una palabra
de 32 bits", nunca bit-packing fino que complique al parser del host):

| Etapa | bit0 | bit1 | bit2 | bit3 | bit4 | bit5 | bit6 |
|---|---|---|---|---|---|---|---|
| ID/EX | reg_write | mem_read | mem_write | mem_to_reg | is_jal | is_jalr | is_halt |
| EX/MEM | reg_write | mem_read | mem_write | mem_to_reg | is_halt | — | — |
| MEM/WB | reg_write | mem_to_reg | is_halt | — | — | — | — |

`ex_result` (EX/MEM) y `result` (MEM/WB) ya son el valor final resuelto
(salida de la ALU, o PC+4 si la instrucción era jal/jalr — ese mux se
resuelve en EX, ver `riscv_core.v`): la Debug Unit no necesita saber si
la instrucción era un salto para interpretar el campo.

### Costo de ancho de banda (decisión documentada)

El volcado es siempre completo (nunca diferencial) por simplicidad: no hace
falta rastrear qué cambió, ni tener dos formatos de paquete distintos según
el modo. El costo es tamaño: con el `DMEM_DEPTH_WORDS` que usa
`riscv_uart_top.v` (256 palabras = 1KB, deliberadamente chico frente al
default de 1024 de `riscv_core.v` — ver ese archivo), el volcado pesa
`(53 + 256) × 4 = 1236` bytes. A 115200 baudios (~11.5 KB/s) son ~107ms por
volcado — aceptable para un paso a paso interactivo. Con el default de 1024
palabras hubiese sido ~4.3KB (~375ms), notoriamente más lento; se
documenta como la alternativa considerada y por qué se prefirió una `dmem`
más chica para el top sintetizable en vez de un formato diferencial más
complejo.

## Respuestas (FPGA → Host): resumen

| Comando | Respuesta |
|---|---|
| `CMD_LOAD_PROG` / `CMD_LOAD_DATA` / `CMD_RESET` | Ninguna. |
| `CMD_RUN` / `CMD_STEP` / `CMD_DUMP` | Un volcado completo (ver arriba). |

No hay eco del byte de comando (a diferencia de otros diseños de
referencia consultados sólo para calibrar alcance): innecesario acá porque
el propio volcado, o su ausencia, ya le confirma al host qué pasó.
