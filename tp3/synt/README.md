# Fase 4 — Proyecto Vivado (Basys 3)

Acá va a vivir el proyecto de síntesis una vez que lo crees en Vivado
(carpeta `tp3_riscv/`, la genera Vivado solo — no hace falta armarla a
mano). Mismo patrón que `tp2/synt/tp2_uart/`.

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
   - Si es negativo: no cierra a 100MHz. Dos caminos — bajar la
     frecuencia directamente en `create_clock` del .xdc, o generar un
     clock derivado más lento con el Clock Wizard (IP Catalog) e
     instanciarlo entre `clk_i` y el resto del diseño. Cualquiera de los
     dos es válido; documentar cuál se eligió y por qué en el informe.

### 6. Documentar

Completar `tp3/informe.md` §3.8 con los números reales: camino crítico
(qué instancia/señal lo genera, lo dice el Timing Summary), si hay skew
y sus consecuencias, y la frecuencia final aplicada. Actualizar también
la tabla de estado de `tp3/README.md` (Fase 4/5).

## Qué se versiona

El `.gitignore` de la raíz ya excluye `*.cache/`, `*.runs/`, `*.sim/`,
`*.Xil/`, `*.jou`, `*.log` — así que la carpeta de trabajo de Vivado
(`tp3_riscv.cache/`, `tp3_riscv.runs/`, etc.) no se va a trackear sola.
Al terminar, decidan explícitamente qué del `.xpr`/reportes/bitstream
final vale la pena commitear (TP2 commiteó el proyecto completo incluido
el `.bit`; para TP3 pueden seguir ese mismo criterio o ser más
selectivos — es decisión de equipo, no hay nada forzado por el
`.gitignore` actual).
