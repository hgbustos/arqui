# TP3 — Procesador Pipeline RISC-V + Debug Unit

Guía práctica: estado actual, cómo correr todo lo que ya existe, y qué
sigue. Para la justificación de cada decisión de diseño (por qué se
resuelven los saltos en ID, por qué HALT es un opcode custom, etc.) ver
**`tp3/informe.md`** — este README no la repite.

## Estado (actualizado 2026-08-18)

| Fase | Contenido | Estado |
|---|---|---|
| 1 | Datapath del pipeline (`rtl/core/`) | ✅ 201 tests |
| 2 | Debug Unit + Dump Unit + top UART (`rtl/debug/`) | ✅ 260 tests |
| 3 | Ensamblador + protocolo + CLI + GUI (`host/`) | ✅ 61 tests |
| 4 | Proyecto Vivado, síntesis, timing closure | 🟡 constraints listos (`constraints/riscv_uart_top.xdc`) — falta crear el proyecto y correr síntesis, ver `synt/README.md` |
| 5 | Validación en una Basys 3 real | ⬜ pendiente — necesita la placa |

**522/522 tests pasando** (461 Verilog + 61 Python), 0 fallos —
re-verificado en vivo el 2026-08-18, no solo recordado de una corrida
anterior. Todo lo de las Fases 1-3 está verificado en **simulación**
(Icarus Verilog) y con **tests unitarios** de Python — nada se corrió
todavía en un FPGA real.

## Estructura de archivos

```
tp3/
├── docs/
│   ├── TRABAJO FINAL 2025.pptx.pdf         consigna original
│   ├── Computer Organization...pdf          Patterson & Hennessy (RISC-V ed.)
│   └── debug_protocol.md                    protocolo exacto de la Debug Unit
├── rtl/
│   ├── core/      12 módulos: el datapath del pipeline (Fase 1)
│   └── debug/     debug_unit.v, dump_unit.v, riscv_uart_top.v (Fase 2)
├── tb/            14 testbenches (uno por módulo + 2 de integración) + riscv_isa_encode.vh
├── host/          riscv_asm.py, riscv_protocol.py, riscv_client.py, riscv_gui.py + tests (Fase 3)
├── constraints/   riscv_uart_top.xdc (Fase 4, ver abajo)
├── synt/          README.md con el checklist de Vivado -- el proyecto en sí se crea ahí
├── informe.md     reporte completo, decisiones de diseño justificadas
└── README.md      este archivo
```

`tp1/ALU.v` se extendió in-place (aditivo) con `sll`/`slt`/`sltu`. Nada
más fuera de `tp3/` se tocó. `tp2/rtl/{baud_generator,uart_rx,uart_tx,
uart_interface}.v` se referencian directo desde `tp3/rtl/debug/
riscv_uart_top.v`, sin copiarlos.

## Cómo correr las verificaciones

### Verilog (Icarus Verilog 12.0)

```bash
# Regresion de TP1 (confirma que extender la ALU no rompio nada)
iverilog -g2012 -o /tmp/tb.vvp tp1/ALU.v tp1/ALU_top.v tp1/tb_alu.v && vvp /tmp/tb.vvp

# Cualquier testbench de rtl/core/ (probar cada uno de esta lista)
iverilog -g2012 -I tp3/tb -o /tmp/tb.vvp tp1/ALU.v tp3/rtl/core/*.v tp3/tb/<nombre>.v && vvp /tmp/tb.vvp
# <nombre>: tb_register_file, tb_imm_gen, tb_control_unit, tb_alu_control,
#           tb_branch_unit, tb_forwarding_unit, tb_hazard_unit,
#           tb_pipeline_regs, tb_imem, tb_dmem, tb_riscv_core

# Debug Unit / Dump Unit (no necesitan el core ni tp1/ALU.v)
iverilog -g2012 -o /tmp/tb.vvp tp3/rtl/debug/debug_unit.v tp3/rtl/debug/dump_unit.v tp3/tb/tb_debug_unit.v && vvp /tmp/tb.vvp
iverilog -g2012 -o /tmp/tb.vvp tp3/rtl/debug/debug_unit.v tp3/rtl/debug/dump_unit.v tp3/tb/tb_dump_unit.v && vvp /tmp/tb.vvp

# Integracion de punta a punta (banguea UART real bit a bit, tarda unos segundos)
iverilog -g2012 -I tp3/tb -o /tmp/tb.vvp tp1/ALU.v tp2/rtl/baud_generator.v tp2/rtl/uart_rx.v \
  tp2/rtl/uart_tx.v tp2/rtl/uart_interface.v tp3/rtl/core/*.v tp3/rtl/debug/*.v \
  tp3/tb/tb_riscv_uart_top.v && vvp /tmp/tb.vvp
```

Cada corrida termina con una línea `Resultado: N EXITO / 0 FALLO`.

### Python (3.x + pyserial)

```bash
cd tp3/host
pip install -r requirements.txt   # solo pyserial

py test_riscv_asm.py -v        # 41 tests: ensamblador + desensamblador
py test_riscv_protocol.py -v   # 19 tests: framing del protocolo
py test_riscv_client.py -v     # 1 test: CLI de punta a punta con un puerto serie simulado
```

Probar el ensamblador a mano:

```bash
py -c "from riscv_asm import assemble; print([hex(w) for w in assemble('addi x1, x0, 10')])"
```

Abrir la GUI (sin hardware conectado, sólo para ver que levanta):

```bash
py riscv_gui.py
```

## Qué sigue

### Fase 4 — Vivado (necesita instalación local)

`tp3/constraints/riscv_uart_top.xdc` ya está listo (mismos pines físicos
que TP2 usó en la Basys3 — el port list de `riscv_uart_top.v` es
idéntico al de `uart_alu_top.v`). Falta crear el proyecto y correr
síntesis/implementación: checklist completo paso a paso en
**`tp3/synt/README.md`** (crear proyecto, agregar fuentes, sintetizar,
leer Worst Negative Slack, qué hacer si no cierra a 100MHz).

### Fase 5 — Hardware real

1. `write_bitstream`, programar la Basys 3.
2. Repetir en hardware los mismos programas que ya corrieron en
   `tb_riscv_core.v` (buen punto de partida: ya se sabe cuál es el
   resultado esperado de cada uno).
3. Usar `riscv_client.py --port COMx programa.asm` o `riscv_gui.py` con
   el puerto real.
4. Registrar los resultados en el informe (tabla de casos, igual que
   hizo TP2 en su momento).

## Cosas a tener en cuenta

- **`DMEM_DEPTH_WORDS` tiene que coincidir** entre el bitstream (parámetro
  de `riscv_uart_top.v`, default 256) y la herramienta de host
  (`--dmem-words` en la CLI / spinbox en la GUI, default 256). Si no
  coinciden, `parse_dump` tira `ProtocolError` por tamaño de paquete
  incorrecto.
- **`register_file.v` tiene un bypass de escritura-lectura** interno
  (mismo ciclo). Es necesario para que un productor exactamente 3
  instrucciones antes de su consumidor funcione — ver informe §3.5 antes
  de tocar ese archivo.
- **`debug_unit.v`/`dump_unit.v` usan el reset FÍSICO** (`rst_i`), nunca
  `core_soft_reset_o` (que ellos mismos generan para resetear el core) —
  si se resetearan a sí mismos con esa señal, perderían su propio estado
  de FSM a mitad de una carga.
- **`tp2/rtl/baud_generator.v` tiene un bug latente** (no de TP3, no se
  tocó el archivo): si `CLK_FREQ/(BAUD×16)` da una potencia de 2 exacta,
  el generador de baudios deja de tickear (`$clog2` no deja margen para
  representar ese valor límite). No afecta al hardware real, pero
  importa si en algún momento se simula con parámetros de clock/baud
  distintos a los que ya usa `tb_riscv_uart_top.v` — ver el comentario en
  ese testbench antes de cambiarlos.
