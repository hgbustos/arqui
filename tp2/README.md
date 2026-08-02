# TP2 — Máquinas de Estado Finitas: UART

Fuente: `5 - Maquinas de Estado Finitas - 2019.pdf` (cátedra Arquitectura de Computadoras).

## Objetivo

Diseñar e implementar en Verilog un periférico **UART** (Universal Asynchronous
Receiver/Transmitter) que permita comunicar la FPGA con una PC por puerto serie,
y usarlo para **operar la ALU del TP1 a distancia**: los operandos y el opcode se
envían por serie, y el resultado se lee de vuelta también por serie.

Todo el diseño debe modelarse como **máquinas de estado finitas (FSM)** síncronas,
aplicando los criterios de diseño vistos en la teoría (Moore vs. Mealy,
codificación de estados, FSM seguras vs. rápidas).

## Estructura de archivos

```
tp2/
├── rtl/           módulos de diseño (baud_generator, uart_rx/tx, uart_interface,
│                  alu_link, uart_alu_top)
├── tb/            testbenches, uno por módulo de rtl/ + tb_uart_alu_top.v (end-to-end)
├── constraints/   uart_alu_top.xdc (pines Basys 3)
└── host/          alu_client.py, cliente de línea de comandos por puerto serie
```

## Arquitectura general

```
        RX ──────────────▶ ┌──────────┐  d_out, rx_done  ┌───────────────────┐  r_data, rx_empty  ┌─────┐
                            │    Rx    │─────────────────▶│                   │───────────────────▶│     │
   ┌────────────┐   tick    │ (FSM)    │                  │  Interface        │◀────────────────────│ ALU │
   │ Baud Rate  │──────────▶│          │                  │  Circuit          │       rd            │(TP1)│
   │ Generator  │           └──────────┘                  │                   │                     │     │
   │ (rate,clk) │                                          │                   │◀────────────────────│     │
   └────────────┘   tick    ┌──────────┐  d_in, tx_start   │                   │   w_data, wr        │     │
                            │    Tx    │◀─────────────────│                   │───────────────────▶│     │
        TX ◀────────────────│ (FSM)    │  tx_done          └───────────────────┘       tx_full        └─────┘
                            └──────────┘
```

Bloques:

- **Baud Rate Generator**: contador que genera un pulso `tick` (`s_tick`) 16
  veces por cada período de baud rate. Es un contador módulo `Clock /
  (BaudRate × 16)`. Ejemplo del enunciado: clock de placa 50 MHz, baud rate
  19200 → `50e6 / (19200*16) ≈ 163` → contador módulo 163.
- **Rx (receptor)**: FSM que muestrea la línea serie `rx` usando los ticks del
  generador y arma el byte recibido en un shift register. Señales: `rx`, `clk`,
  `s_tick` (entradas) / `dout`, `rx_done_tick` (salidas).
- **Tx (transmisor)**: FSM simétrica al Rx, que serializa un byte a transmitir
  hacia la línea `tx`. Señales: `tx_start`, `d_in`, `clk`, `tick` (entradas) /
  `tx`, `tx_done` (salidas).
- **Interface Circuit**: adapta el Rx/Tx (que trabajan a nivel de trama serie)
  a una interfaz tipo registro/FIFO simple para que la ALU pueda leer y
  escribir bytes:
  - Hacia la ALU: `r_data` (dato recibido), `rx_empty` (flag: no hay dato
    nuevo para leer). La ALU pulsa `rd` para consumir el dato recibido.
  - Desde la ALU: `w_data` (dato a transmitir), `tx_full` (flag: el
    transmisor está ocupado). La ALU pulsa `wr` para encolar un dato a
    enviar.
- **ALU (TP1)**: el módulo ya implementado (`tp1/ALU.v`), que en este TP pasa
  a recibir opcode/operandos y a devolver el resultado a través del
  Interface Circuit en lugar de switches/leds físicos.

## Trama UART (frame)

```
 start bit   data byte (6~8 bits)   parity bit (opcional)   stop bit(s)
 (nivel 0)                                                  (nivel 1)
    S     D0 D1 D2 D3 D4 D5 D6 D7        PB                    P
```

- Línea en reposo (idle) en `1`.
- El bit de **start** es un `0` que marca el comienzo de la trama.
- Le siguen **N bits de datos** (para este TP: `N = 8`, un byte).
- Opcionalmente un bit de **paridad**.
- Uno o más **bits de stop** (`M`, nivel `1`) que cierran la trama.
- Es comunicación **asíncrona**: no viaja una señal de clock junto con los
  datos (a diferencia de la transferencia síncrona); el receptor debe
  reconstruir el timing a partir del propio flanco de bajada del start bit,
  apoyándose en el `tick` de 16x del Baud Rate Generator.

## Máquina de estados del Receptor (Rx)

Asumiendo `N` bits de datos y `M` bits de stop, la secuencia es:

1. **idle**: esperar a que la entrada `rx` sea `0` → ahí arranca el bit de
   start. Iniciar el contador de ticks (`s`).
2. **start**: cuando el contador llega a `7`, la entrada está en el punto
   medio del bit de start (mitigando ruido/glitches en los bordes).
   Reiniciar el contador.
3. **data**: cuando el contador llega a `15`, la señal avanzó un bit
   completo y está en la mitad del bit de dato actual. Muestrear ese valor
   y meterlo en un shift register (`b <= {rx, b[7:1]}`). Reiniciar el
   contador. Repetir este paso `N-1` veces más para completar los `N` bits.
4. Si se usa paridad, repetir el muestreo una vez más para el bit de
   paridad.
5. **stop**: repetir el muestreo `M` veces para los bits de stop.
6. Levantar `rx_done_tick = 1` (un pulso) y volver a `idle`.

El diagrama de estados del PDF define 4 macro-estados: `idle → start → data
(loop) → stop (loop) → idle`, con un contador de ticks (`s`) y un contador de
bits (`n`) como variables auxiliares de cada estado.

El transmisor (Tx) es conceptualmente el inverso: arranca cuando llega
`tx_start`, saca el bit de start, después los `N` bits de datos vía shift
register, y termina con los `M` bits de stop, avisando `tx_done`.

## Repaso teórico aplicado al diseño (de la parte de FSM del PDF)

Todo el sistema (Rx, Tx, Interface Circuit) se modela como FSMs síncronas
con el patrón estándar en Verilog:

```verilog
always @(posedge clk)                 // registro de estado (memoria)
    if (reset) state <= IDLE;
    else       state <= next_state;

always @(*)                            // lógica de próximo estado
    case (state)
        ...
        default: next_state = IDLE;    // fault recovery
    endcase

always @(*)                            // lógica de salida
    case (state)
        ...
        default: ...                   // fault recovery
    endcase
```

Puntos a decidir conscientemente en el diseño:

- **Moore vs. Mealy**: salida en función solo del estado (Moore) vs. en
  función del estado *y* la entrada (Mealy). El Rx/Tx de este TP es
  naturalmente Moore para las salidas de datos, pero algunas señales de
  control pueden convenir como Mealy.
- **Codificación de estados**: binaria (mínimos FFs), one-hot/one-cold
  (mejor para FPGA / máxima frecuencia), Gray (mínimo consumo, pero
  inviable con transiciones complejas), u output-equals-state (elimina
  lógica de salida, mínimo delay clock-to-output).
- **FSM segura vs. rápida**: una FSM segura vuelve a un estado de
  recuperación ante una entrada o estado inválido (rama `default` en los
  `case`); una FSM rápida omite esa lógica para ganar velocidad/área a
  costa de robustez.
- **Trade-offs** (tabla del PDF): máxima frecuencia → one-hot/one-cold;
  mínima área → binaria; mínimo delay clock-to-output y salida libre de
  glitches → output-equals-state o salida registrada; mínimo consumo →
  código Gray.

## Protocolo implementado (Interface Circuit)

El PDF define la interfaz genérica del Interface Circuit
(`r_data`/`rd`/`rx_empty`, `w_data`/`wr`/`tx_full`) pero no dice qué
significa cada byte — eso lo definimos nosotros. Se implementó separando
dos responsabilidades:

- **`uart_interface.v`** — el "Interface Circuit" propiamente dicho: un
  buffer de 1 palabra por sentido (no una FIFO profunda, alcanza con eso)
  que adapta `uart_rx`/`uart_tx` a la interfaz de lectura/escritura
  genérica. No sabe nada de opcodes, operandos ni comandos: es 100%
  reutilizable sea cual sea el protocolo que se construya arriba.
- **`alu_link.v`** — el protocolo específico de este TP sobre esa interfaz,
  equivalente a `tp1/ALU_top.v` pero alimentado por UART en vez de
  switches/botones. Instancia la `ALU` de `tp1/ALU.v` sin modificarla.

### Por qué un byte de comando en vez de "opcode+A+B → respuesta automática"

La primera versión de `alu_link` usaba un protocolo de 3 bytes de entrada
(opcode, A, B) que disparaba automáticamente 2 bytes de salida (resultado,
estado). Funcionaba y estaba bien probado, pero tenía un supuesto implícito
que no escala: "el primer byte siempre es un opcode de ALU" y "toda carga
implica una respuesta inmediata". Se rediseñó a un esquema de **comando +
trigger** pensando en que este mismo Interface Circuit va a tener que
encajar en el TP final (pipeline completo): ahí hace falta cargar datos
(instrucciones, registros) sin una respuesta por cada byte, y leer
resultados bajo demanda en un momento distinto al de la carga — un
protocolo de comandos generaliza a eso (agregar un comando nuevo es un
`case` más, no un protocolo nuevo), mientras que el formato posicional fijo
no.

Comandos soportados (primer byte de cada transacción):

| Comando | Valor | Efecto |
|---|---|---|
| `CMD_LOAD` | `0x01` | Le siguen 3 bytes: opcode (bits `[5:0]`), operando A, operando B. Carga los registros; **no** responde nada. |
| `CMD_READ` | `0x02` | Sin bytes adicionales. Dispara el envío de los 2 bytes de respuesta sobre el último opcode/A/B cargados. Se puede pedir varias veces seguidas sin recargar (relee el mismo resultado). |
| cualquier otro | — | Se descarta (se consume el byte, sin efecto), para no trabarse ante ruido o un comando futuro todavía no implementado. |

Formato de la respuesta a un `CMD_READ` (siempre estos 2 bytes, en este orden):

| # | Byte | Contenido |
|---|------|-----------|
| 1 | resultado | `alu_out[7:0]` |
| 2 | estado | `{6'b0, co, zero}` (bit1=co, bit0=zero) |

La FSM de `alu_link` tiene 7 estados: `RECV_CMD` (dispatcher) → `RECV_OP →
RECV_A → RECV_B → RECV_CMD` para un `CMD_LOAD`, o `RECV_CMD → SEND_RESULT →
WAIT_RESULT_SENT → SEND_STATUS → RECV_CMD` para un `CMD_READ`. No hay
estado de "compute" separado: como la ALU es puramente combinacional, para
cuando la FSM llega a `SEND_RESULT` los registros `reg_A`/`reg_B`/
`reg_opcode` ya están estables desde el último `CMD_LOAD` y
`alu_out`/`alu_zero`/`alu_co` ya son válidos.

### Baud rate seleccionable en runtime

`baud_rate_generator` soporta 4 presets de baud rate parametrizables
(`BAUD_RATE0..3`, por defecto 9600/19200/57600/115200) elegidos en runtime
con la entrada `baud_sel_i` (2 bits), sin resintetizar. Al cambiar de
preset el contador se reinicia limpio (si no, arrastraría la cuenta vieja y
generaría un tick con período mezclado de dos bases de tiempo distintas).
En la Basys3, `baud_sel_i` se pensó para conectarse a 2 switches físicos;
en la simulación (`tb_baud_generator.v`, `tb_uart_alu_top.v`) se verifica
tanto cada preset por separado como el cambio en caliente entre ellos con
tráfico UART real circulando.

### Yendo a hardware real (Basys 3)

`tp2/constraints/uart_alu_top.xdc` asigna los pines físicos de la Basys3
(`clk_i`→W5, `rst_i`→BTN_CENTER, `rx_i`/`tx_o`→puente FTDI integrado,
`baud_sel_i[0]`→SW0, `baud_sel_i[1]`→SW1). Para el preset por defecto
(`BAUD_RATE1`=19200, `baud_sel_i=2'b01`): **SW0 arriba, SW1 y el resto
abajo** (bit0=SW0 es el menos significativo, no al revés — es fácil
confundirse acá). El default de `CLK_FREQ` en `uart_alu_top.v` se
corrigió a `100_000_000` porque esa es la frecuencia real del oscilador de
la placa (antes estaba en 50MHz, un valor genérico que solo tenía sentido
en simulación — de haberse sintetizado así, todos los baud rates hubiesen
salido a la mitad de la velocidad real y el UART no habría sincronizado con
la PC). Ya se creó el proyecto en Vivado, se sintetizó/implementó y se
generó el bitstream (`tp2/synt/tp2_uart/`, `write_bitstream` completó sin
errores), y se probó en una Basys3 real hablándole con `alu_client.py` por
USB. Queda como nota menor (no bloqueante, no se tocó): el log de
implementación deja un DRC warning (`PDRC-153`, gated clock) sobre
`baud_sel_reg` en `baud_generator.v` — Vivado decidió implementar ese
registro con clock gateado en vez de usar el pin de enable, que en general
es mejor evitar por área/performance aunque acá no impidió que la placa
funcionara correctamente.

### Cliente de host en Python (`tp2/host/`)

`tp2/host/alu_client.py` es un cliente de línea de comandos (pyserial) que
habla este protocolo desde una PC real: arma el `CMD_LOAD` con la
operación pedida, dispara uno o más `CMD_READ` (con `--reread N` se puede
pedir el mismo resultado varias veces sin recargar, para probar en vivo la
razón de ser del comando separado) y parsea la respuesta. Uso:

```
pip install -r tp2/host/requirements.txt
python tp2/host/alu_client.py --port COM12 --baud 19200 ADD 100 50
```

### GUI de escritorio (`tp2/host/alu_gui.py`)

Pensada para la defensa: en vez de escribir comandos, `tp2/host/alu_gui.py`
(tkinter, sin dependencias más allá de `pyserial`) permite elegir puerto y
baud rate, armar y enviar un `CMD_LOAD` con opcode/A/B desde combos, pedir
`CMD_READ` (o releerlo varias veces sin recargar, con un botón dedicado que
repite la operación N veces) y ver el resultado con indicadores de `co`/
`zero`. Un log en la parte inferior muestra, byte a byte, exactamente lo que
se envía y se recibe — útil para mostrar en vivo cómo se arma cada trama del
protocolo. No reimplementa el protocolo: reutiliza el armado/parseo de
paquetes de `alu_client.py` (un solo lugar si el protocolo cambia). La
comunicación serie corre en un thread aparte del `mainloop` de tkinter para
no congelar la UI mientras espera una respuesta.

```
python tp2/host/alu_gui.py
```

## Estado de avance

- [x] Baud Rate Generator (`baud_generator.v`), con 4 presets seleccionables en runtime
- [x] Rx (`uart_rx.v`)
- [x] Tx (`uart_tx.v`)
- [x] Interface Circuit + protocolo de comandos (`uart_interface.v`, `alu_link.v`)
- [x] Top de integración con la `ALU` de TP1 (`uart_alu_top.v`)
- [x] Testbench end-to-end sobre el sistema completo (`tb_uart_alu_top.v`)
- [x] Cliente de host en Python (`tp2/host/alu_client.py`)
- [x] Sintetizado, implementado y probado en una Basys 3 real (`tp2/synt/`)
- [x] GUI de escritorio para la defensa (`tp2/host/alu_gui.py`)

TP2 completo. Todos los módulos tienen su testbench verificado con Icarus
Verilog (`iverilog`/`vvp`), no solo revisados a ojo: `tb_baud_generator.v`
(25/25 ticks, 4 presets + cambio en caliente), `tb_uart_rx.v` (16/16),
`tb_uart_tx.v` (16/16), `tb_uart_interface.v` (17/17), `tb_alu_link.v`
(30/30, protocolo CMD_LOAD/CMD_READ a alta velocidad simulando pulsos) y
`tb_uart_alu_top.v` (21/21, end-to-end con timing de UART real de punta a
punta, incluyendo cambio de baud rate en caliente entre operaciones). Las 6
simulaciones se re-verificaron de forma independiente con Icarus Verilog
12.0, sin errores.

## Lecciones de diseño (de los bugs que aparecieron al integrar)

Cada módulo funcionaba perfecto por separado, pero integrar el sistema
completo destapó dos clases de bug real que vale la pena registrar porque
son exactamente el tipo de cosa que la teoría de FSM de la cátedra advierte
indirectamente (diseño síncrono cuidadoso, señales bien registradas):

1. **Un pulso de "dato listo" combinacional, leído por el bloque clocked de
   OTRO módulo en el mismo flanco, puede llegar "viejo".**
   `uart_rx` originalmente calculaba `rx_done_tick_o` de forma puramente
   combinacional (en el `always @*` de próximo estado) y actualizaba
   `dout_o` en un bloque `always @(posedge clk)` **separado** que
   reevaluaba la misma condición. Funcionaban bien vistos desde adentro,
   pero `uart_interface` (otro módulo, mismo clock) los muestrea en su
   propio bloque `always @(posedge clk)`, y ahí no hay garantía de que
   la versión combinacional ya esté resuelta en ese mismo flanco. Resultado:
   `uart_interface` capturaba el dato *anterior*, no el recién llegado.
   **Arreglo:** registrar `dout_o` y `rx_done_tick_o` (y lo mismo para
   `tx_done_tick_o` en `uart_tx`) en el **mismo** bloque `always @(posedge
   clk)` que el resto del estado, a partir de un `_next` calculado en el
   bloque combinacional — así quedan estables un ciclo entero antes de que
   cualquier otro módulo los necesite leer.
2. **Un handshake que "asume" en vez de confirmar, se rompe si dos pasos
   pasan demasiado rápido.** `alu_link` pasaba de `SEND_RESULT` a
   `SEND_STATUS` apenas veía `tx_full_i` en bajo, y escribía el segundo
   byte inmediatamente — pero el primer byte recién se estaba por aceptar,
   así que el segundo intento de escritura se perdía o pisaba al primero.
   **Arreglo:** un handshake explícito de dos pasos — sostener la escritura
   hasta *ver* `tx_full_i` en alto (confirma que se aceptó) y, para el
   segundo byte, esperar a que vuelva a bajar (confirma que el primero ya
   se transmitió) antes de intentar escribir. Nunca hay que asumir timing;
   hay que observar la señal de estado.

Un tercer bug, más sutil, fue del *testbench* y no del diseño: `wait(señal
=== 1)` no bloquea si la señal ya está en 1 en el instante en que se evalúa
— así que un segundo `recv_byte()` llamado muy pronto podía "recapturar" la
cola del pulso del primer byte en vez de esperar genuinamente al segundo.
Se resolvió esperando explícitamente a que la señal vuelva a bajar antes de
dar por terminada cada lectura.

## Entregable esperado

- Módulo **Baud Rate Generator** (contador módulo `N` configurable según
  clock/baud rate deseados).
- Módulo **Rx** (FSM receptora) con salidas `dout` y `rx_done_tick`.
- Módulo **Tx** (FSM transmisora) con entradas `tx_start`/`din` y salidas
  `tx`, `tx_done`.
- Módulo **Interface Circuit** que exponga a la ALU la interfaz
  `r_data`/`rd`/`rx_empty` (lectura) y `w_data`/`wr`/`tx_full` (escritura).
- Módulo **top** que instancie Baud Rate Generator + Rx + Tx + Interface
  Circuit + la `ALU` del TP1, análogo a `tp1/ALU_top.v` pero con la UART en
  lugar de switches/botones/leds como entrada/salida.
- Testbench(es) que verifiquen Rx, Tx y la integración end-to-end (enviar
  opcode + operandos por "rx" simulado, verificar que "tx" devuelva el
  resultado esperado).
