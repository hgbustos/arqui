# Fase 4 — Proyecto Vivado (Basys 3)

**El proyecto ya está creado: `synt/project_1/project_1.xpr`** (part
`xc7a35tcpg236-1`, top `riscv_uart_top`, fuentes y `.xdc` referenciados
desde el repo, sin copiar). Ya se corrió una primera síntesis +
implementación (resultados en `tp3/informe.md` §3.6 y §3.8). Los pasos
1-3 de abajo quedan como referencia de cómo se armó; lo que falta está en
**"Pendiente"**, al final de este archivo. Mismo patrón que
`tp2/synt/tp2_uart/` (donde los pasos dicen `tp3_riscv`, el proyecto real
quedó con el nombre por defecto, `project_1`).

## Pasos

Instrucciones para Vivado 2023.1 (la versión con la que se armó
`tp2/synt/tp2_uart/`) — los nombres de menú pueden variar un poco en
otras versiones, pero el flujo es el mismo.

### 1. Crear el proyecto

1. Quick Start → **Create Project** (o File → Project → New).
2. Project name: `tp3_riscv`. Project location: esta carpeta
   (`tp3/synt/`), con "Create project subdirectory" tildado — Vivado crea
   `tp3/synt/tp3_riscv/` solo.
3. Project Type: **RTL Project**, con **"Do not specify sources at this
   time"** tildado (agregamos los archivos después, con más control).
4. Pestaña **Boards** → buscar "basys3" → seleccionar **Basys 3**
   (misma placa que TP2; ya deberían estar los board files de Digilent
   instalados si compilaron TP2 en esta máquina).
5. Finish.

### 2. Agregar los archivos de diseño

1. Flow Navigator → **Add Sources** → **"Add or create design
   sources"** → Next.
2. **Add Files** (selección múltiple con Ctrl) — estos 5 sueltos:
   - `tp1/ALU.v`
   - `tp2/rtl/baud_generator.v`
   - `tp2/rtl/uart_rx.v`
   - `tp2/rtl/uart_tx.v`
   - `tp2/rtl/uart_interface.v`

   (No uses "Add Directories" sobre `tp2/rtl/` completa: esa carpeta
   también tiene `alu_link.v`/`uart_alu_top.v` de TP2, que no van acá.)
3. **Add Directories** — estas 2 carpetas completas (17 archivos, se
   suman solos):
   - `tp3/rtl/core/`
   - `tp3/rtl/debug/` (acá está `riscv_uart_top.v`, el top)
4. **Importante:** dejar **destildado** "Copy sources into project" —
   así Vivado referencia los archivos donde ya están en el repo en vez
   de duplicarlos (mismo criterio de una sola fuente de verdad que
   vienen usando en TP1/TP2/TP3).
5. Finish. En la ventana **Sources**, `riscv_uart_top` debería aparecer
   en negrita (top module auto-detectado). Si no: click derecho sobre
   `riscv_uart_top` → **Set as Top**.

   No hace falta agregar nada de `tp3/tb/` — son los testbenches, ya
   verificados con Icarus Verilog; Vivado no los necesita para síntesis.

### 3. Agregar las constraints

1. **Add Sources** de nuevo → **"Add or create constraints"** → Next.
2. Add Files → `tp3/constraints/riscv_uart_top.xdc`.
3. Destildar "Copy constraints files into project" (mismo motivo que
   arriba). Finish.

### 4. Sintetizar e implementar

1. Flow Navigator → **SYNTHESIS → Run Synthesis**. Si tira errores,
   pegarlos tal cual aparecen para revisarlos — es normal que la primera
   pasada encuentre algo puntual.
2. Flow Navigator → **IMPLEMENTATION → Run Implementation**.
3. (Opcional, se puede dejar para la Fase 5) **Generate Bitstream**.

> **Ya pasó una vez:** la primera corrida real falló acá con
> `Place Design` (DRC, Register-as-Flip-Flop over-utilized — pedía 43337
> FF contra 41600 disponibles). Causa y fix ya aplicados y reverificados
> en `imem.v`/`dmem.v`/`riscv_core.v`/`debug_unit.v`/`riscv_uart_top.v`
> — ver `tp3/informe.md` §3.6. Si Vivado no re-sintetiza solo al notar
> que las fuentes cambiaron, forzalo con click derecho sobre
> "Synthesis" → **Reset Runs**, y volvé a correr Synthesis →
> Implementation.

### 5. Leer el timing

1. **Reports → Report Timing Summary** (post-implementación, o se abre
   solo si quedó tildado al terminar la implementación). Anotar el
   Worst Negative Slack (WNS):
   - Si es ≥ 0: cierra a 100MHz, no hace falta tocar nada más.
   - Si es negativo: no cierra a 100MHz, y hay que generar un clock
     derivado más lento con el Clock Wizard (ver "Pendiente", abajo).
     **Cambiar sólo el período de `create_clock` en el .xdc NO sirve:**
     eso no cambia la frecuencia real (el oscilador de la placa sigue en
     100MHz), sólo le cambia a Vivado contra qué compara -- el reporte
     daría OK y el hardware fallaría igual.

### 6. Documentar

Completar `tp3/informe.md` §3.8 con los números reales: camino crítico
(qué instancia/señal lo genera, lo dice el Timing Summary), si hay skew
y sus consecuencias, y la frecuencia final aplicada. Actualizar también
la tabla de estado de `tp3/README.md` (Fase 4/5).

## Pendiente

Estado al 2026-10-05: la primera síntesis falló por exceso de flip-flops
(ya corregido en el RTL, informe §3.6) y la implementación midió WNS =
-3.633ns a 100MHz (informe §3.8). Desde entonces cambió el RTL (freeze
del modo paso a paso, pausa de `CMD_RUN`, reset sincronizado,
`parity_en_i` conectado), así que esos números hay que volver a medirlos.

1. **Re-sintetizar.** Click derecho sobre "Synthesis" → **Reset Runs**, y
   correr Synthesis → Implementation. Anotar la utilización
   (**Report Utilization**: LUT, FF, LUTRAM, BRAM) para completar el
   informe §3.6.
2. **Clock Wizard a 50MHz.** IP Catalog → *Clocking Wizard*: entrada
   100MHz, `clk_out1` = 50MHz. Recomendado: instanciarlo en un top nuevo
   sólo para síntesis (p.ej. `rtl/debug/riscv_fpga_top.v`: Clock Wizard
   + `riscv_uart_top`), y dejar `riscv_uart_top` como está -- el IP del
   Clock Wizard no se puede simular con Icarus, y así los testbenches
   siguen andando sin tocarlos. Dos detalles que no hay que olvidar:
   - **`CLK_FREQ` de `riscv_uart_top` tiene que pasar a `50_000_000`.**
     Si queda en 100MHz, el generador de baudios cuenta mal y la UART
     transmite a la mitad del baud rate: la PC no la entiende.
   - Mantener el diseño en reset hasta que el Clock Wizard enganche: usar
     `rst_i | ~locked` como reset de entrada.
   El `create_clock` del .xdc se queda como está (describe el oscilador
   real de 100MHz); Vivado deriva solo el clock de 50MHz de la salida
   del Clock Wizard.
3. **Verificar timing a 50MHz** (Report Timing Summary): WNS ≥ 0, y
   anotar el nuevo camino crítico.
4. **Skew** (la consigna lo pregunta explícitamente: *"¿este camino
   crítico genera skew en mi sistema? ¿qué consecuencias tiene?"*). En el
   detalle del peor path (Report Timing → doble click sobre el path),
   leer la línea **Clock Path Skew**; para una vista general, **Report
   Clock Networks** / **Report Clock Interaction**. Documentar el valor y
   su efecto: el skew se suma o se resta al presupuesto de tiempo de cada
   path (Vivado ya lo incluye en el slack), y en un FPGA, con el clock
   distribuido por buffers globales (BUFG), suele ser de décimas de ns.
5. **Documentar** en el informe §3.6 (utilización) y §3.8 (frecuencia
   final, nuevo camino crítico, skew) y actualizar la tabla de estado de
   `tp3/README.md`.

## Qué se versiona

El `.gitignore` de la raíz ya excluye `*.cache/`, `*.runs/`, `*.sim/`,
`*.Xil/`, `*.jou`, `*.log` — así que la carpeta de trabajo de Vivado
(`tp3_riscv.cache/`, `tp3_riscv.runs/`, etc.) no se va a trackear sola.
Al terminar, decidan explícitamente qué del `.xpr`/reportes/bitstream
final vale la pena commitear (TP2 commiteó el proyecto completo incluido
el `.bit`; para TP3 pueden seguir ese mismo criterio o ser más
selectivos — es decisión de equipo, no hay nada forzado por el
`.gitignore` actual).
