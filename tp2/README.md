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
├── tb/            testbenches, uno por módulo de rtl/ + tb_uart_alu_top.v (end-to-end),
│                  más 3 testbenches dedicados a la paridad opcional (parity_en_i=1)
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

### Paridad opcional en runtime (`parity_en_i`)

El enunciado marca el bit de paridad como opcional en la trama (ver
"Trama UART" más arriba). La decisión original de este TP fue no
incluirlo: con sobremuestreo ×16 y muestreo en el punto medio de cada
bit, el margen de ruido ya alcanza para un enlace tan corto como el de
este TP (el FTDI que hace de puente USB-serie está integrado en la misma
placa, no hay un cable largo expuesto a ruido externo).

Se agregó después como capability completa, sin tocar el comportamiento
por defecto ya verificado. Sigue el mismo patrón que `baud_sel_i`: no es
un parámetro de compilación sino una **entrada en tiempo real**
(`parity_en_i`, pensada para SW2 de la Basys3) — se puede prender/apagar
sin resintetizar. Es únicamente on/off: cuando está activa, la paridad
siempre es **EVEN** (única variante soportada — no hay forma de elegir
ODD, ni por switch ni por parámetro, para no complicar la interfaz sin
un beneficio real):

- `uart_rx`/`uart_tx` ganan `parity_en_i` (switch en bajo = comportamiento
  original bit a bit idéntico; en alto = con paridad EVEN). `uart_alu_top`
  reenvía `parity_en_i` tal cual a los dos — los dos extremos de un
  enlace tienen que coincidir en la trama que usan.
- **Se latchea una sola vez por trama**, al detectar el start bit (Rx) o
  al aceptar el byte a transmitir (Tx) — no se lee en vivo durante toda
  la recepción/transmisión. Así, si alguien mueve el switch a mitad de un
  envío, no corrompe ESE byte, solo afecta al próximo. Mismo criterio de
  "cambiar solo entre transacciones completas" que ya vale para
  `baud_sel_i`, pero acá además garantizado por diseño en vez de depender
  solo de la disciplina del operador. Probado explícitamente en
  simulación: `tb_uart_alu_top_parity.v` cambia el switch en caliente
  entre dos operaciones y confirma que el sistema sigue funcionando de
  los dos lados del cambio.
- Ante un error de paridad, **el byte no se descarta**: `uart_rx` lo
  sigue entregando igual por `dout_o`/`rx_done_tick_o`, y levanta
  `parity_err_o` aparte como flag informativo. Este protocolo no tiene
  ACK/NACK ni forma de pedir un reenvío, así que descartar en silencio
  desincronizaría la FSM de comandos de `alu_link` de una forma peor que
  la que se intenta evitar (ver "Lecciones de diseño" más abajo).
- `uart_alu_top` expone `parity_err_o` a nivel de top como señal
  informativa (no se propaga al protocolo `CMD_LOAD`/`CMD_READ` de
  `alu_link`), mapeada a LD0 de la Basys3 (`U16` en el `.xdc`) — ambos
  pines (LD0/`U16` y SW2/`W16`) ya se verificaron contra el master XDC
  oficial de Digilent.
- Con SW2 abajo el comportamiento es bit a bit idéntico al ya sintetizado,
  implementado y probado en una Basys 3 real (ver más abajo) — **una
  sola síntesis alcanza para las dos configuraciones**, no hace falta
  recompilar para pasar de sin paridad a con paridad, solo mover el
  switch.
- `alu_client.py`/`alu_gui.py` también soportan paridad (flag `--parity`
  / checkbox "Paridad EVEN activa" en la GUI, apagado por defecto) — ver
  "Cliente de host en Python" más abajo. Es la contraparte obligatoria
  del lado PC: la paridad la arma/verifica en hardware el puente FTDI de
  la placa, no el script Python, así que los dos extremos tienen que
  coincidir para que el enlace funcione en absoluto (no es un "mejor si
  coincide", es un requisito) — acá el operador tiene que mirar en qué
  posición está SW2 y activar/desactivar lo mismo del lado PC, no hay
  forma de que el software lo detecte solo.

**Cómo probarlo en hardware real:** una sola síntesis (la que ya está
hecha, o una nueva si se resintetiza por cualquier otro motivo) sirve
para las dos configuraciones — programar la placa y:
- **SW2 abajo** (default): probar exactamente como antes, sin la flag
  `--parity` (o el checkbox destildado en la GUI).
- **SW2 arriba**: agregar `--parity` del lado host (o tildar el checkbox
  en la GUI). Si se te olvida este paso, la comunicación no va a
  funcionar en absoluto — no es un error sutil, los dos extremos del
  framing físico quedan desalineados.

### Yendo a hardware real (Basys 3)

`tp2/constraints/uart_alu_top.xdc` asigna los pines físicos de la Basys3
(`clk_i`→W5, `rst_i`→BTN_CENTER, `rx_i`/`tx_o`→puente FTDI integrado,
`baud_sel_i[0]`→SW0, `baud_sel_i[1]`→SW1). Para el preset por defecto
(`BAUD_RATE1`=19200, `baud_sel_i=2'b01`): **SW0 arriba, SW1 abajo**
(bit0=SW0 es el menos significativo, no al revés — es fácil confundirse
acá; SW2 es independiente de esto, controla `parity_en_i`, ver "Paridad
opcional en runtime" más abajo). El default de `CLK_FREQ` en `uart_alu_top.v` se
corrigió a `100_000_000` porque esa es la frecuencia real del oscilador de
la placa (antes estaba en 50MHz, un valor genérico que solo tenía sentido
en simulación — de haberse sintetizado así, todos los baud rates hubiesen
salido a la mitad de la velocidad real y el UART no habría sincronizado con
la PC). Ya se creó el proyecto en Vivado, se sintetizó/implementó y se generó el
bitstream (`tp2/synt/tp2_uart/`) dos veces: una primera vez (31/07) con
el diseño base, ya probada en una Basys3 real hablándole con
`alu_client.py` por USB (ver informe 4.3); y una segunda (04/09), ya con
la capability de paridad y el pin de `parity_en_i` corregido (ver
"Paridad opcional en runtime" más arriba). Las dos completaron
`write_bitstream` sin errores de DRC; queda un warning no bloqueante
(`PDRC-153`, gated clock sobre lógica interna de `baud_generator.v`) que
no afecta timing ni el funcionamiento ya observado en hardware real, así
que se documenta así y no se persigue más. Falta todavía probar esta
segunda síntesis en la placa física.

### Cliente de host en Python (`tp2/host/`)

`tp2/host/alu_client.py` es un cliente de línea de comandos (pyserial) que
habla este protocolo desde una PC real: arma el `CMD_LOAD` con la
operación pedida, dispara uno o más `CMD_READ` (con `--reread N` se puede
pedir el mismo resultado varias veces sin recargar, para probar en vivo la
razón de ser del comando separado) y parsea la respuesta. La flag
`--parity` (apagada por defecto) activa el bit de paridad EVEN del
puerto — tiene que coincidir con la posición del switch `parity_en_i`
(ver "Paridad opcional" más arriba). Uso:

```
pip install -r tp2/host/requirements.txt
python tp2/host/alu_client.py --port COM12 --baud 19200 ADD 100 50
python tp2/host/alu_client.py --port COM12 --baud 19200 --parity ADD 100 50
```

### GUI de escritorio (`tp2/host/alu_gui.py`)

Pensada para la defensa: en vez de escribir comandos, `tp2/host/alu_gui.py`
(tkinter, sin dependencias más allá de `pyserial`) permite elegir puerto,
baud rate y paridad, armar y enviar un `CMD_LOAD` con opcode/A/B desde
combos, pedir `CMD_READ` (o releerlo varias veces sin recargar, con un botón
dedicado que repite la operación N veces) y ver el resultado con indicadores
de `co`/`zero`. Un log en la parte inferior muestra, byte a byte, exactamente
lo que se envía y se recibe — útil para mostrar en vivo cómo se arma cada
trama del protocolo. No reimplementa el protocolo: reutiliza el armado/
parseo de paquetes de `alu_client.py` (un solo lugar si el protocolo
cambia) — la apertura del puerto en sí, en cambio, está en los dos
scripts por separado, así que el combo de paridad usa el mismo mapeo
`PARITY_TO_PYSERIAL` importado de `alu_client.py` en vez de duplicarlo. La
comunicación serie corre en un thread aparte del `mainloop` de tkinter para
no congelar la UI mientras espera una respuesta.

```
python tp2/host/alu_gui.py
```

## Ver el tráfico en GTKWave

Los dos testbenches end-to-end (`tb_uart_alu_top.v`,
`tb_uart_alu_top_parity.v`) vuelcan un `.vcd` cada vez que se corren
(`$dumpfile`/`$dumpvars(0, ...)` recursivo sobre todo el árbol de
instancias — no solo el top, también los registros internos de cada
FSM) — no hace falta nada especial, el mismo `iverilog`/`vvp` de siempre
ya lo genera en el directorio donde se corre `vvp`:

```bash
iverilog -g2012 -o sim tp2/tb/tb_uart_alu_top.v tp2/rtl/uart_alu_top.v \
  tp2/rtl/baud_generator.v tp2/rtl/uart_rx.v tp2/rtl/uart_tx.v \
  tp2/rtl/uart_interface.v tp2/rtl/alu_link.v tp1/ALU.v
vvp sim              # genera tb_uart_alu_top.vcd en el directorio actual
gtkwave tb_uart_alu_top.vcd
```

(la versión `_parity` compila igual, cambiando `tb_uart_alu_top.v` por
`tb_uart_alu_top_parity.v` y el nombre del `.vcd`; las dos necesitan
`-g2012`, ver 4.1 del informe).

Señales útiles para arrastrar al panel de ondas (buscar por instancia en
el árbol de jerarquía de GTKWave — el DUT se llama `dut`):

| Señal | Para qué sirve |
|---|---|
| `tb_rx` / `tb_tx` | La línea serie cruda — señalar a ojo el bit de start, cada bit de dato (LSB primero), el de paridad si está activo, y el stop. |
| `dut.u_uart_rx.state_reg`, `dut.u_uart_tx.state_reg` | Estado de cada FSM en cada instante. Clic derecho → Data Format → Decimal para no leer binario crudo. Legend: `0=IDLE 1=START 2=DATA 3=PARITY 4=STOP` (Rx/Tx). |
| `dut.u_alu_link.state_reg` | Estado del protocolo de aplicación. Legend: `0=RECV_CMD 1=RECV_OP 2=RECV_A 3=RECV_B 4=SEND_RESULT 5=WAIT_RESULT_SENT 6=SEND_STATUS`. |
| `dut.u_uart_rx.tick_cnt_reg`, `dut.u_uart_rx.bit_idx_reg` | El sobremuestreo ×16 y en qué bit de dato está parado — para mostrar por qué el muestreo cae en el punto medio de cada bit. |
| `dut.u_interface.rx_empty_o`, `dut.u_interface.tx_full_o`, `dut.u_alu_link.rd_o`, `dut.u_alu_link.wr_o` | El handshake entre `alu_link` y el Interface Circuit. |
| `dut.u_uart_rx.parity_err_o` (solo en `tb_uart_alu_top_parity.vcd`) | Se mantiene en 0 en todo este testbench (no inyecta ruido). Para *ver* un `1` de verdad, correr `tb_uart_rx_parity.v` en vez de este — ese sí corrompe paridad a propósito. |

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
- [x] Paridad opcional en runtime (`parity_en_i`, siempre EVEN), switch en bajo por defecto — ver "Paridad opcional" más arriba

TP2 completo. Todos los módulos tienen su testbench verificado con Icarus
Verilog (`iverilog`/`vvp`), no solo revisados a ojo: `tb_baud_generator.v`
(25/25 ticks, 4 presets + cambio en caliente), `tb_uart_rx.v` (16/16),
`tb_uart_tx.v` (16/16), `tb_uart_interface.v` (17/17), `tb_alu_link.v`
(30/30, protocolo CMD_LOAD/CMD_READ a alta velocidad simulando pulsos) y
`tb_uart_alu_top.v` (21/21, end-to-end con timing de UART real de punta a
punta, incluyendo cambio de baud rate en caliente entre operaciones). Las
9 simulaciones (las 6 originales + las 3 de paridad, ver abajo) se
verificaron con Icarus Verilog 12.0, sin errores.

Testbenches de paridad (`parity_en_i=1`, sin modificar ninguno de los 6
anteriores): `tb_uart_rx_parity.v` (34/34, paridad EVEN correcta aceptada
sin error y paridad corrompida inyectada a propósito, detectada sin
perder el byte), `tb_uart_tx_parity.v` (17/17, loopback contra `uart_rx`
con paridad activa) y `tb_uart_alu_top_parity.v` (8/8, end-to-end, incluye cambio de
`parity_en_i` en caliente entre dos operaciones). `tb_alu_link.v`,
`tb_uart_alu_top.v` y `tb_uart_alu_top_parity.v` necesitan compilarse con
`iverilog -g2012` (declaran variables locales dentro de un bloque sin
nombre); el resto compila con las opciones por defecto.

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
