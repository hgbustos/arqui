#!/usr/bin/env python3
"""
riscv_gui.py — GUI de escritorio (tkinter, sin dependencias extra alla de
pyserial) para hablar con riscv_uart_top (TP3) por puerto serie real,
pensada para la defensa: editar/cargar un programa .asm, ensamblarlo y
mandarlo por CMD_LOAD_PROG, cargar datos iniciales en la memoria de datos
(CMD_LOAD_DATA), correrlo (CMD_RUN) o pasearlo paso a paso (CMD_STEP), y
ver en vivo el estado del procesador, ademas de un log byte a byte de lo
que se manda y se recibe.

La pestaña "Ejecucion" dibuja el pipeline como en las figuras del
Patterson: las 5 etapas con la instruccion que hay en cada una (cada
instruccion conserva su color mientras avanza), los latches entre ellas,
las flechas de forwarding que el hardware eligio en ese ciclo, y marcas de
stall / burbuja / salto tomado / instruccion descartada / HALT, con una
explicacion en castellano de lo que pasa. Abajo, los registros (resaltados
los que cambiaron desde el volcado anterior), el contenido crudo de los
latches, y el diagrama multiciclo (filas = instrucciones, columnas =
ciclos) que se va armando con cada CMD_STEP. Toda esa interpretacion vive
en riscv_pipeview.py (sin tkinter, probada contra trazas reales del RTL);
este archivo solo la dibuja.

No reimplementa el protocolo ni el ensamblador: reutiliza riscv_asm.py y
riscv_protocol.py (mismos modulos que riscv_client.py), y sigue el mismo
patron de threads que tp2/host/alu_gui.py -- la comunicacion serie corre
siempre en un worker aparte, nunca toca widgets directamente, y empuja
eventos a una cola que el mainloop drena via 'after()'.

Mientras corre un CMD_RUN se habilita el boton "Pausa": un programa sin
HALT alcanzable (p.ej. un loop infinito) no termina nunca, y la pausa
(CMD_BREAK) lo detiene y trae el estado en que quedo. La espera del
volcado la resuelve riscv_client.read_run_dump(), la misma que usa la CLI.

Uso:
    python riscv_gui.py
"""
import queue
import threading
import time
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

import serial
import serial.tools.list_ports

from riscv_asm import AsmError, REG_NAMES, REGISTERS, assemble, parse_word_list
from riscv_client import read_run_dump
from riscv_pipeview import STAGES, PipelineHistory, analyze
from riscv_protocol import (
    DMEM_WORDS_DEFAULT, IMEM_WORDS_DEFAULT, DumpState, ProtocolError,
    build_dump_packet, build_load_data_packet, build_load_prog_packet, build_reset_packet,
    build_run_packet, build_step_packet,
    expected_dump_size, parse_dump, to_signed32,
)

POLL_MS = 50
SERIAL_TIMEOUT_S = 5.0

EXAMPLE_PROGRAM = """\
# Programa de ejemplo: x3 = x1 + x2, guardado en mem[0]
addi x1, x0, 10
addi x2, x0, 32
add  x3, x1, x2
sw   x3, 0(x0)
halt
"""

EXAMPLE_DATA = """\
# dmem[0], dmem[1], ...
5
7
0x10
-1
"""

BAUD_CHOICES = [9600, 19200, 57600, 115200]

# Nombre ABI de cada registro (el primero que aparece: s0 antes que fp)
ABI = {}
for _name, _idx in REGISTERS.items():
    if not _name.startswith("x") and _idx not in ABI:
        ABI[_idx] = _name

MONO = ("Consolas", 9)
MONO_S = ("Consolas", 8)
MONO_B = ("Consolas", 10, "bold")
# Cada instruccion se pinta con un color fijo segun su PC, asi se la ve
# "viajar" de etapa en etapa (y en el diagrama multiciclo).
PALETTE = ["#dbeafe", "#dcfce7", "#fef3c7", "#fde2e4", "#ede9fe", "#ccfbf1", "#ffedd5", "#e0e7ff"]
BUBBLE_FILL = "#f3f4f6"
HALT_FILL = "#ead7f7"
C_STALL, C_FLUSH, C_TAKEN, C_HALT = "#cf222e", "#bc4c00", "#1a7f37", "#8250df"
C_FWD_EX, C_FWD_ID = "#0969da", "#bf3989"
CHANGED_BG = "#fff1a8"
LATCH_NAMES = ("IF/ID", "ID/EX", "EX/MEM", "MEM/WB")
TAG_BADGE = {"stall": ("STALL", C_STALL), "flush": ("SE DESCARTA", C_FLUSH),
             "taken": ("SALTO TOMADO", C_TAKEN), "halt_wait": ("HALT", C_HALT)}
# Geometria del datapath: cajas de las etapas + lugar para 2 flechas de forwarding
PIPE_TOP, PIPE_BOX_H, PIPE_ARROW_H = 24, 134, 19
PIPE_H_BASE = PIPE_TOP + PIPE_BOX_H + 16 + 2 * PIPE_ARROW_H + 4
MARK_CHAR = {"stall": "*", "flush": "\u2717", "taken": "!", "halt": "h"}


def instr_color(pc: int) -> str:
    return PALETTE[(pc >> 2) % len(PALETTE)]


class RiscvGui(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("TP3 - Debug Unit RISC-V por UART")
        # Pensada para entrar en una pantalla de 1280x720 logicos (1080p al
        # 150%): arranca maximizada, y si no se puede, en 1280x680.
        self.geometry("1280x680")
        self.minsize(1000, 600)
        try:
            self.state("zoomed")
        except tk.TclError:
            pass

        self.ser = None
        self.ser_lock = threading.Lock()
        self.events = queue.Queue()
        self.n_loaded_words = None
        self.pause_event = threading.Event()  # lo setea el boton Pausa; lo lee el worker de CMD_RUN
        self.cur_state = None        # ultimo volcado
        self.prev_state = None   # el de un ciclo anterior (para resaltar lo que cambio)
        self.view = None         # analyze(self.cur_state)
        self.history = PipelineHistory()
        self._redraw_pending = False

        self._build_widgets()
        self._set_connected(False)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(POLL_MS, self._poll_events)

    # ------------------------------------------------------------------ UI

    def _build_widgets(self):
        pad = {"padx": 6, "pady": 4}

        conn = ttk.LabelFrame(self, text="Conexion")
        conn.pack(fill="x", padx=6, pady=(2, 0))

        ttk.Label(conn, text="Puerto:").grid(row=0, column=0, sticky="w", **pad)
        self.port_var = tk.StringVar()
        self.port_combo = ttk.Combobox(conn, textvariable=self.port_var, width=14)
        self.port_combo.grid(row=0, column=1, **pad)
        ttk.Button(conn, text="Refrescar", command=self._refresh_ports).grid(row=0, column=2, **pad)

        ttk.Label(conn, text="Baud rate:").grid(row=0, column=3, sticky="w", **pad)
        self.baud_var = tk.StringVar(value="115200")
        ttk.Combobox(conn, textvariable=self.baud_var, width=8, state="readonly",
                     values=[str(b) for b in BAUD_CHOICES]).grid(row=0, column=4, **pad)

        ttk.Label(conn, text="Palabras de dmem:").grid(row=0, column=5, sticky="w", **pad)
        self.dmem_words_var = tk.StringVar(value=str(DMEM_WORDS_DEFAULT))
        ttk.Spinbox(conn, from_=1, to=4096, textvariable=self.dmem_words_var, width=6).grid(
            row=0, column=6, **pad)
        ttk.Label(conn, text="(= DMEM_DEPTH_WORDS de riscv_uart_top.v)",
                  foreground="#555").grid(row=0, column=7, sticky="w")

        self.connect_btn = ttk.Button(conn, text="Conectar", command=self._toggle_connect)
        self.connect_btn.grid(row=0, column=8, padx=10)

        self.status_var = tk.StringVar()
        self.status_label = ttk.Label(conn, textvariable=self.status_var, font=("", 10, "bold"))
        self.status_label.grid(row=0, column=9, sticky="w", padx=6)

        # Barra de estado: la ultima linea del log siempre a la vista (el log
        # completo tiene su propia pestaña, para dejarle lugar al pipeline).
        self.last_log_var = tk.StringVar(value="")
        ttk.Label(self, textvariable=self.last_log_var, font=("Consolas", 9), foreground="#444",
                  anchor="w").pack(side="bottom", fill="x", padx=8, pady=(0, 4))

        notebook = ttk.Notebook(self)
        notebook.pack(fill="both", expand=True, padx=6, pady=(0, 2))
        self._build_tab_programa(notebook)
        self._build_tab_ejecucion(notebook)
        self._build_tab_memoria(notebook)

        log_tab = ttk.Frame(notebook)
        notebook.add(log_tab, text="Log UART")
        log_btns = ttk.Frame(log_tab)
        log_btns.pack(fill="x", padx=6, pady=4)
        ttk.Label(log_btns, text="Paquetes enviados (TX) y recibidos (RX)").pack(side="left")
        ttk.Button(log_btns, text="Limpiar log", command=self._clear_log).pack(side="right")
        log_scroll = ttk.Scrollbar(log_tab)
        log_scroll.pack(side="right", fill="y")
        self.log_text = tk.Text(log_tab, wrap="none", yscrollcommand=log_scroll.set,
                                 font=("Consolas", 9), state="disabled")
        self.log_text.pack(fill="both", expand=True, side="left")
        log_scroll.config(command=self.log_text.yview)

        self._refresh_ports()

    def _build_tab_programa(self, notebook):
        tab = ttk.Frame(notebook)
        notebook.add(tab, text="Programa")

        btns = ttk.Frame(tab)
        btns.pack(fill="x", padx=6, pady=4)
        ttk.Button(btns, text="Abrir archivo .asm...", command=self._open_program_file).pack(side="left")
        self.load_btn = ttk.Button(btns, text="Ensamblar y cargar (CMD_LOAD_PROG)",
                                    command=self._do_load)
        self.load_btn.pack(side="left", padx=10)
        self.loaded_var = tk.StringVar(value="Todavia no se cargo ningun programa.")
        ttk.Label(btns, textvariable=self.loaded_var, foreground="#555").pack(side="left", padx=10)

        editor_frame = ttk.LabelFrame(tab, text="Fuente en ensamblador")
        editor_frame.pack(fill="both", expand=True, padx=6, pady=4)
        editor_scroll = ttk.Scrollbar(editor_frame)
        editor_scroll.pack(side="right", fill="y")
        self.program_text = tk.Text(editor_frame, wrap="none", yscrollcommand=editor_scroll.set,
                                     font=("Consolas", 10))
        self.program_text.pack(fill="both", expand=True, side="left")
        editor_scroll.config(command=self.program_text.yview)
        self.program_text.insert("1.0", EXAMPLE_PROGRAM)

    def _build_tab_ejecucion(self, notebook):
        tab = ttk.Frame(notebook)
        notebook.add(tab, text="Ejecucion")

        ctrl = ttk.Frame(tab)
        ctrl.pack(fill="x", padx=6, pady=4)
        self.run_btn = ttk.Button(ctrl, text="Run (CMD_RUN)", command=self._do_run)
        self.run_btn.pack(side="left", padx=4)
        self.pause_btn = ttk.Button(ctrl, text="Pausa (CMD_BREAK)", command=self._do_pause,
                                    state="disabled")
        self.pause_btn.pack(side="left", padx=4)
        self.step_btn = ttk.Button(ctrl, text="Step (CMD_STEP)", command=self._do_step)
        self.step_btn.pack(side="left", padx=4)
        self.reset_btn = ttk.Button(ctrl, text="Reset (CMD_RESET)", command=self._do_reset)
        self.reset_btn.pack(side="left", padx=4)
        self.dump_btn = ttk.Button(ctrl, text="Ver estado (CMD_DUMP)", command=self._do_dump)
        self.dump_btn.pack(side="left", padx=4)
        self.cycle_var = tk.StringVar(value="Ciclo: -")
        ttk.Label(ctrl, textvariable=self.cycle_var, font=("", 12, "bold")).pack(side="left", padx=(24, 8))
        self.chips = ttk.Frame(ctrl)  # etiquetas de color con los eventos del ciclo
        self.chips.pack(side="left")

        # Datapath: las 5 etapas, los latches y las flechas de forwarding
        self.pipe_canvas = tk.Canvas(tab, height=PIPE_H_BASE, background="white", highlightthickness=1,
                                     highlightbackground="#d0d7de")
        self.pipe_canvas.pack(fill="x", padx=6, pady=(2, 4))
        self.pipe_canvas.bind("<Configure>", lambda e: self._schedule_redraw())

        self.events_text = tk.Text(tab, height=3, wrap="word", font=("", 9), relief="flat",
                                   background="#f6f8fa", state="disabled")
        self.events_text.pack(fill="x", padx=6, pady=(0, 4))

        body = ttk.PanedWindow(tab, orient="horizontal")
        body.pack(fill="both", expand=True, padx=6, pady=4)

        left = ttk.Notebook(body)
        body.add(left, weight=0)
        regs_tab = ttk.Frame(left)
        left.add(regs_tab, text="Registros (amarillo = cambio)")
        self.reg_labels = []
        for i in range(32):
            lbl = tk.Label(regs_tab, text=f"{REG_NAMES[i]:>3} {ABI[i]:<4} 0x00000000",
                           font=MONO_S, anchor="w", padx=3, pady=0, background="white")
            lbl.grid(row=i % 11, column=i // 11, sticky="we", padx=1, pady=0)
            self.reg_labels.append(lbl)
        latch_tab = ttk.Frame(left)
        left.add(latch_tab, text="Latches (crudo)")
        self.latch_text = tk.Text(latch_tab, width=60, height=18, wrap="none", font=MONO,
                                  state="disabled")
        self.latch_text.pack(fill="both", expand=True)

        hist_frame = ttk.LabelFrame(body, text="Diagrama multiciclo (se arma con cada Step)")
        body.add(hist_frame, weight=1)
        hist_scroll = ttk.Scrollbar(hist_frame, orient="vertical")
        hist_scroll.pack(side="right", fill="y")
        self.hist_canvas = tk.Canvas(hist_frame, width=200, background="white", highlightthickness=0,
                                     yscrollcommand=hist_scroll.set)
        self.hist_canvas.pack(fill="both", expand=True, side="left")
        hist_scroll.config(command=self.hist_canvas.yview)
        self.hist_canvas.bind("<Configure>", lambda e: self._schedule_redraw())
        # El divisor arranca justo donde terminan los registros (si no, el
        # PanedWindow reparte a ojo y la tercera columna queda cortada).
        self.after(200, lambda: body.sashpos(0, regs_tab.winfo_reqwidth() + 8))

    def _build_tab_memoria(self, notebook):
        tab = ttk.Frame(notebook)
        notebook.add(tab, text="Memoria de datos")

        # Izquierda: los datos iniciales que se van a cargar. Derecha: lo
        # que realmente hay en dmem segun el ultimo volcado.
        init_frame = ttk.LabelFrame(tab, text="Datos iniciales (CMD_LOAD_DATA)")
        init_frame.pack(side="left", fill="y", padx=6, pady=6)
        btns = ttk.Frame(init_frame)
        btns.pack(fill="x", padx=4, pady=4)
        ttk.Button(btns, text="Abrir archivo...", command=self._open_data_file).pack(side="left")
        self.load_data_btn = ttk.Button(btns, text="Cargar en dmem", command=self._do_load_data)
        self.load_data_btn.pack(side="left", padx=6)
        ttk.Label(init_frame, foreground="#555", justify="left",
                  text="Desde la direccion 0x0, decimal o 0x...\n"
                       "Cargar datos reinicia el core (PC,\n"
                       "registros y latches) pero no borra\n"
                       "el programa ya cargado.").pack(anchor="w", padx=4)
        data_scroll = ttk.Scrollbar(init_frame)
        data_scroll.pack(side="right", fill="y", pady=4)
        self.data_text = tk.Text(init_frame, width=30, wrap="none", yscrollcommand=data_scroll.set,
                                 font=("Consolas", 10))
        self.data_text.pack(fill="both", expand=True, side="left", padx=(4, 0), pady=4)
        data_scroll.config(command=self.data_text.yview)
        self.data_text.insert("1.0", EXAMPLE_DATA)

        tree_frame = ttk.LabelFrame(tab, text="Contenido actual (ultimo volcado)")
        tree_frame.pack(side="left", fill="both", expand=True, padx=6, pady=6)
        opts = ttk.Frame(tree_frame)
        opts.pack(fill="x", side="top")
        self.mem_only_used = tk.BooleanVar(value=True)
        ttk.Checkbutton(opts, text="Solo la memoria usada (palabras distintas de 0 o que cambiaron)",
                        variable=self.mem_only_used, command=self._fill_mem_tree).pack(side="left", padx=4)
        ttk.Label(opts, text="amarillo = cambio desde el volcado anterior",
                  foreground="#555").pack(side="left", padx=12)
        tree_scroll = ttk.Scrollbar(tree_frame)
        tree_scroll.pack(side="right", fill="y")
        self.mem_tree = ttk.Treeview(
            tree_frame, columns=("addr", "hex", "dec"), show="headings",
            yscrollcommand=tree_scroll.set, height=25)
        self.mem_tree.heading("addr", text="Direccion")
        self.mem_tree.heading("hex", text="Valor (hex)")
        self.mem_tree.heading("dec", text="Valor (signed)")
        self.mem_tree.column("addr", width=100, anchor="e")
        self.mem_tree.column("hex", width=140, anchor="center")
        self.mem_tree.column("dec", width=140, anchor="center")
        self.mem_tree.pack(fill="both", expand=True, side="left")
        self.mem_tree.tag_configure("changed", background=CHANGED_BG)
        tree_scroll.config(command=self.mem_tree.yview)

    # ------------------------------------------------------------- helpers

    def _log(self, text):
        line = f"[{time.strftime('%H:%M:%S')}] {text}"
        self.last_log_var.set(line)
        self.log_text.configure(state="normal")
        self.log_text.insert("end", line + "\n")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _clear_log(self):
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")

    def _set_connected(self, connected):
        self.status_var.set("Conectado" if connected else "Desconectado")
        self.status_label.configure(foreground="#1a7f37" if connected else "#a00")
        self.connect_btn.configure(text="Desconectar" if connected else "Conectar")
        state = "normal" if connected else "disabled"
        for w in (self.load_btn, self.load_data_btn, self.run_btn, self.step_btn,
                  self.reset_btn, self.dump_btn):
            w.configure(state=state)
        self.pause_btn.configure(state="disabled")  # sólo se habilita durante un CMD_RUN

    def _set_busy(self, busy):
        state = "disabled" if busy else "normal"
        for w in (self.load_btn, self.load_data_btn, self.run_btn, self.step_btn,
                  self.reset_btn, self.dump_btn, self.connect_btn):
            w.configure(state=state)

    def _refresh_ports(self):
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.port_combo["values"] = ports
        if ports and not self.port_var.get():
            self.port_var.set(ports[0])

    def _open_program_file(self):
        path = filedialog.askopenfilename(filetypes=[("Ensamblador RISC-V", "*.asm"), ("Todos", "*.*")])
        if not path:
            return
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        self.program_text.delete("1.0", "end")
        self.program_text.insert("1.0", text)

    def _open_data_file(self):
        path = filedialog.askopenfilename(filetypes=[("Datos (una palabra por linea)", "*.txt"),
                                                     ("Todos", "*.*")])
        if not path:
            return
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        self.data_text.delete("1.0", "end")
        self.data_text.insert("1.0", text)

    def _dmem_words(self) -> int:
        try:
            return int(self.dmem_words_var.get())
        except ValueError:
            return DMEM_WORDS_DEFAULT

    @staticmethod
    def _packet_summary(n_words, packet) -> str:
        head = packet[:12].hex(" ").upper()
        return f" | {n_words} palabras | {head}{'...' if len(packet) > 12 else ''}"

    # ------------------------------------------------------- accion: conectar

    def _toggle_connect(self):
        if self.ser is not None:
            self._disconnect()
        else:
            self._connect()

    def _connect(self):
        port = self.port_var.get().strip()
        if not port:
            self._log("Error: elegi un puerto antes de conectar.")
            return
        baud = int(self.baud_var.get())
        self.connect_btn.configure(state="disabled")

        def worker():
            try:
                ser = serial.Serial(port, baud, timeout=SERIAL_TIMEOUT_S)
            except serial.SerialException as e:
                self.events.put(("connect_failed", str(e)))
                return
            self.events.put(("connected", ser, port, baud))

        threading.Thread(target=worker, daemon=True).start()

    def _disconnect(self):
        with self.ser_lock:
            if self.ser is not None:
                self.ser.close()
                self.ser = None
        self._set_connected(False)
        self._log("Desconectado.")
        self.connect_btn.configure(state="normal")

    # ------------------------------------------------------------ acciones

    def _do_load(self):
        if self.ser is None:
            return
        try:
            words = assemble(self.program_text.get("1.0", "end"))
        except AsmError as e:
            messagebox.showerror("Error de ensamblado", str(e))
            return
        if not words:
            messagebox.showwarning("Programa vacio", "No hay instrucciones para cargar.")
            return
        try:
            packet = build_load_prog_packet(words, IMEM_WORDS_DEFAULT)
        except ProtocolError as e:
            messagebox.showerror("Programa demasiado grande", str(e))
            return
        self._send_without_reply(packet, "CMD_LOAD_PROG", self._packet_summary(len(words), packet),
                                 after=[("loaded", len(words))])

    def _do_load_data(self):
        if self.ser is None:
            return
        try:
            words = parse_word_list(self.data_text.get("1.0", "end"))
        except AsmError as e:
            messagebox.showerror("Error en los datos", str(e))
            return
        if not words and not messagebox.askyesno(
                "Sin datos", "No hay ninguna palabra para cargar.\n"
                             "¿Limpiar la memoria de datos completa (todo en 0)?"):
            return
        try:
            packet = build_load_data_packet(words, self._dmem_words())
        except ProtocolError as e:
            messagebox.showerror("Datos demasiado grandes", str(e))
            return
        self._send_without_reply(
            packet, "CMD_LOAD_DATA", self._packet_summary(len(words), packet),
            after=[("log", "  (soft-reset del core: PC, registros y latches en 0; "
                           "el programa sigue cargado)"), ("core_reset", None)])

    def _send_without_reply(self, packet, label, detail="", after=()):
        """Manda, en un worker, un comando al que la FPGA no responde
        (CMD_LOAD_PROG / CMD_LOAD_DATA / CMD_RESET, ver debug_protocol.md),
        y si salio bien encola el log y los eventos de 'after'."""
        self._set_busy(True)

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(packet)
                    self.ser.flush()
            except serial.SerialException as e:
                self.events.put(("error", f"Error escribiendo {label}: {e}"))
            else:
                self.events.put(("log", f"TX {label}{detail}"))
                for event in after:
                    self.events.put(event)
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _do_run(self):
        # No usa _send_simple_command: un programa sin HALT (loop infinito)
        # nunca manda el volcado, así que acá no hay timeout fijo -- se
        # espera hasta el HALT o hasta que el usuario pida una pausa.
        if self.ser is None:
            return
        dmem_words = self._dmem_words()
        self.pause_event.clear()
        self._set_busy(True)
        self.pause_btn.configure(state="normal")

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(build_run_packet())
                    self.ser.flush()
                    self.events.put(("log", "TX CMD_RUN (corriendo... 'Pausa' lo detiene)"))
                    state, _ = read_run_dump(self.ser, dmem_words,
                                             should_pause=self.pause_event.is_set,
                                             response_timeout=SERIAL_TIMEOUT_S)
            except (serial.SerialException, ProtocolError) as e:
                self.events.put(("error", f"Error en CMD_RUN: {e}"))
                self.events.put(("busy_done", None))
                return

            motivo = "HALT" if state.core_halted else "pausa"
            self.events.put(("log", f"RX CMD_RUN | {expected_dump_size(dmem_words)} bytes | "
                                     f"termino por {motivo} | ciclo={state.cycle_count}"))
            self.events.put(("dump", state))
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _do_pause(self):
        self.pause_event.set()
        self.pause_btn.configure(state="disabled")
        self._log("TX CMD_BREAK (pausa pedida)")

    def _do_step(self):
        self._send_simple_command(build_step_packet(), "CMD_STEP")

    def _do_dump(self):
        self._send_simple_command(build_dump_packet(), "CMD_DUMP")

    def _do_reset(self):
        if self.ser is None:
            return
        self._send_without_reply(build_reset_packet(), "CMD_RESET", after=[("core_reset", None)])

    def _send_simple_command(self, packet, label):
        if self.ser is None:
            return
        dmem_words = self._dmem_words()
        expected = expected_dump_size(dmem_words)
        self._set_busy(True)

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(packet)
                    self.ser.flush()
                    self.events.put(("log", f"TX {label}"))
                    raw = self.ser.read(expected)
            except serial.SerialException as e:
                self.events.put(("error", f"Error en {label}: {e}"))
                self.events.put(("busy_done", None))
                return

            if len(raw) != expected:
                self.events.put(("error", f"{label}: se esperaban {expected} bytes de volcado, "
                                           f"llegaron {len(raw)} (timeout? dmem_words incorrecto?)"))
                self.events.put(("busy_done", None))
                return
            try:
                state = parse_dump(raw, dmem_words)
            except ProtocolError as e:
                self.events.put(("error", f"{label}: {e}"))
                self.events.put(("busy_done", None))
                return

            self.events.put(("log", f"RX {label} | {len(raw)} bytes | "
                                     f"halted={int(state.core_halted)} ciclo={state.cycle_count}"))
            self.events.put(("dump", state))
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    # --------------------------------------------------------- actualizar UI

    def _update_dump_display(self, state: DumpState):
        if self.cur_state is None or state.cycle_count != self.cur_state.cycle_count:
            self.prev_state = self.cur_state
        self.cur_state = state
        self.view = analyze(state)
        self.history.push(state)
        self.cycle_var.set(f"Ciclo: {state.cycle_count}")

        for w in self.chips.winfo_children():
            w.destroy()
        chips = []
        if state.core_halted:
            chips.append(("HALT en WB: terminado", C_HALT))
        elif state.stalled and not state.hazard_stall:
            chips.append(("HALT en ID: drenando", C_HALT))
        if state.hazard_stall:
            chips.append(("STALL de datos", C_STALL))
        if state.branch_taken and not state.hazard_stall:
            chips.append(("Salto tomado: flush", C_FLUSH))
        if self.view.arrows:
            chips.append((f"Forwarding x{len(self.view.arrows)}", C_FWD_EX))
        for text, color in chips:
            tk.Label(self.chips, text=f" {text} ", background=color, foreground="white",
                     font=("", 9, "bold")).pack(side="left", padx=3)

        self.events_text.configure(state="normal")
        self.events_text.delete("1.0", "end")
        self.events_text.insert("1.0", "\n".join(self.view.events) if self.view.events
                                else "Ciclo sin eventos especiales: todas las etapas avanzan.")
        self.events_text.configure(state="disabled")

        prev = self.prev_state
        for i in range(32):
            value = state.registers[i]
            changed = prev is not None and prev.registers[i] != value
            self.reg_labels[i].configure(
                text=f"{REG_NAMES[i]:>3} {ABI[i]:<4} 0x{value:08x} {to_signed32(value):>11}",
                background=CHANGED_BG if changed else "white")

        self._fill_latch_text(state)
        self._fill_mem_tree()
        self._schedule_redraw()

    def _fill_latch_text(self, s: DumpState):
        f = s.forwarding
        lines = [
            f"STATUS  halted={int(s.core_halted)} stalled={int(s.stalled)} "
            f"hazard_stall={int(s.hazard_stall)} branch_taken={int(s.branch_taken)}",
            f"        fwd a_ex={f.a_ex} b_ex={f.b_ex} a_id={f.a_id} b_id={f.b_id}   ciclos={s.cycle_count}",
            "",
            f"IF      pc=0x{s.if_stage.pc:08x} instr=0x{s.if_stage.instr:08x}",
            f"IF/ID   pc=0x{s.if_id.pc:08x} instr=0x{s.if_id.instr:08x}",
            f"ID/EX   pc=0x{s.id_ex.pc:08x} instr=0x{s.id_ex.instr:08x}",
            f"        rs1=0x{s.id_ex.rs1_data:08x} rs2=0x{s.id_ex.rs2_data:08x} imm=0x{s.id_ex.imm:08x}",
            f"        {self._control_flags(s.id_ex)}",
            f"EX/MEM  pc=0x{s.ex_mem.pc:08x} instr=0x{s.ex_mem.instr:08x}",
            f"        result=0x{s.ex_mem.ex_result:08x} rs2=0x{s.ex_mem.rs2_data:08x}",
            f"        {self._control_flags(s.ex_mem)}",
            f"MEM/WB  pc=0x{s.mem_wb.pc:08x} instr=0x{s.mem_wb.instr:08x}",
            f"        result=0x{s.mem_wb.result:08x} mem_data=0x{s.mem_wb.mem_read_data:08x}",
            f"        {self._control_flags(s.mem_wb)}",
        ]
        self.latch_text.configure(state="normal")
        self.latch_text.delete("1.0", "end")
        self.latch_text.insert("1.0", "\n".join(lines))
        self.latch_text.configure(state="disabled")

    def _fill_mem_tree(self):
        self.mem_tree.delete(*self.mem_tree.get_children())
        if self.cur_state is None:
            return
        prev = self.prev_state
        only_used = self.mem_only_used.get()
        for addr, value in enumerate(self.cur_state.dmem):
            changed = prev is not None and addr < len(prev.dmem) and prev.dmem[addr] != value
            if only_used and value == 0 and not changed:
                continue
            self.mem_tree.insert("", "end", tags=("changed",) if changed else (), values=(
                f"0x{addr * 4:04x}", f"0x{value:08x}", str(to_signed32(value))))

    # ------------------------------------------------------------ dibujo

    def _schedule_redraw(self):
        if not self._redraw_pending:
            self._redraw_pending = True
            self.after_idle(self._redraw)

    def _redraw(self):
        self._redraw_pending = False
        self._draw_pipeline()
        self._draw_history()

    def _draw_pipeline(self):
        c = self.pipe_canvas
        c.delete("all")
        width = max(c.winfo_width(), 700)
        if self.view is None:
            c.create_text(width / 2, 120, fill="#666", font=("", 11),
                          text="Sin datos todavia: conectate y usa 'Ver estado' o 'Step'.")
            return
        margin, bar, gap, top, box_h = 8, 12, 6, PIPE_TOP, PIPE_BOX_H
        # Lugar para 2 flechas siempre (el caso comun); con mas, el canvas crece
        needed = PIPE_H_BASE + PIPE_ARROW_H * max(0, len(self.view.arrows) - 2)
        if int(c.cget("height")) != needed:
            c.configure(height=needed)
        box_w = (width - 2 * margin - 4 * (bar + 2 * gap)) / 5
        centers = {}
        x = margin
        for k, st in enumerate(STAGES):
            self._draw_stage_box(c, self.view.stages[st], x, top, box_w, box_h)
            centers[st] = x + box_w / 2
            x += box_w
            if k < 4:
                bx = x + gap
                c.create_rectangle(bx, top - 4, bx + bar, top + box_h + 4, fill="#57606a", outline="")
                c.create_text(bx + bar / 2, top - 14, text=LATCH_NAMES[k], font=("", 8, "bold"),
                              fill="#57606a")
                x = bx + bar + gap

        # Flechas de forwarding, por debajo de las cajas: del productor
        # (EX, o el latch EX/MEM / MEM/WB) al operando que lo consume.
        bottom = top + box_h
        for k, a in enumerate(self.view.arrows):
            y = bottom + 16 + PIPE_ARROW_H * k
            sx = centers[a.src] + 10 * k - 10
            dx = centers[a.dst] + (-box_w * 0.25 if a.operand == "rs1" else box_w * 0.25)
            color = C_FWD_EX if a.dst == "EX" else C_FWD_ID
            c.create_line(sx, bottom, sx, y, dx, y, dx, bottom + 2, arrow="last", width=2,
                          fill=color, arrowshape=(9, 11, 4))
            src_txt = {"EX": "salida ALU", "MEM": "EX/MEM", "WB": "MEM/WB"}[a.src]
            value = "?" if a.value is None else f"0x{a.value:x}"
            label = f"{REG_NAMES[a.regnum]} = {value}  ({src_txt} \u2192 {a.operand})"
            t = c.create_text((sx + dx) / 2, y - 2, text=label, anchor="s", font=("", 8, "bold"),
                              fill=color)
            bb = c.bbox(t)
            r = c.create_rectangle(bb[0] - 2, bb[1], bb[2] + 2, bb[3], fill="white", outline="")
            c.tag_lower(r, t)

    def _draw_stage_box(self, c, sv, x, y, w, h):
        dash = ()
        if sv.kind == "bubble":
            fill, dash = BUBBLE_FILL, (4, 3)
        elif sv.kind == "halt":
            fill = HALT_FILL
        else:
            fill = instr_color(sv.pc)
        outline, lw = "#8c959f", 1
        badge = None
        for tag in ("stall", "flush", "taken", "halt_wait"):
            if tag in sv.tags:
                badge = TAG_BADGE[tag]
                outline, lw = badge[1], 3
                break
        c.create_rectangle(x, y, x + w, y + h, fill=fill, outline=outline, width=lw, dash=dash)
        c.create_text(x + 8, y + 5, anchor="nw", text=sv.stage, font=("Segoe UI", 13, "bold"),
                      fill="#24292f")
        if sv.kind == "bubble":
            c.create_text(x + w / 2, y + h / 2, text="burbuja\n(NOP)", font=("Segoe UI", 11, "italic"),
                          fill="#8c959f", justify="center")
            return
        c.create_text(x + w - 6, y + 8, anchor="ne", text=f"pc 0x{sv.pc:04x}", font=MONO,
                      fill="#57606a")
        if badge is not None:
            t = c.create_text(x + 8, y + 28, anchor="nw", text=f" {badge[0]} ", fill="white",
                              font=("", 8, "bold"))
            bb = c.bbox(t)
            r = c.create_rectangle(bb[0] - 1, bb[1] - 1, bb[2] + 1, bb[3] + 1, fill=badge[1],
                                   outline="")
            c.tag_lower(r, t)
            ty = y + 46
        else:
            ty = y + 30
        text = sv.text.replace("  ; -> ", "  -> ")
        t = c.create_text(x + 8, ty, anchor="nw", text=text, width=w - 14, font=MONO_B, fill="#24292f")
        ty = c.bbox(t)[3] + 4
        for line in sv.details:
            t = c.create_text(x + 8, ty, anchor="nw", text=line, width=w - 14, font=MONO, fill="#24292f")
            ty = c.bbox(t)[3] + 1

    def _draw_history(self):
        c = self.hist_canvas
        c.delete("all")
        cycles = self.history.cycles()
        width = max(c.winfo_width(), 300)
        if not cycles:
            c.create_text(12, 12, anchor="nw", fill="#666", font=("", 9),
                          text="Se arma con volcados de ciclos consecutivos (Step). Un Run o un\n"
                               "Reset lo vuelve a empezar desde el estado actual.")
            return
        label_w, cell_w, cell_h, head_h = 210, 44, 20, 22
        n_fit = max(1, int((width - label_w - 6) // cell_w))
        window = cycles[-n_fit:]
        rows = [r for r in self.history.rows if any(cy in r.cells for cy in window)]
        # Columna del ciclo actual resaltada
        cur_x = label_w + (len(window) - 1) * cell_w
        c.create_rectangle(cur_x, 0, cur_x + cell_w, head_h + len(rows) * cell_h, fill="#fff8c5",
                           outline="")
        for j, cy in enumerate(window):
            c.create_text(label_w + j * cell_w + cell_w / 2, head_h / 2, text=str(cy), font=MONO,
                          fill="#57606a")
        for i, row in enumerate(rows):
            y = head_h + i * cell_h
            if row.kind == "bubble":
                c.create_text(6, y + cell_h / 2, anchor="w", text="(burbuja)", fill="#8c959f",
                              font=("Consolas", 9, "italic"))
            else:
                c.create_text(6, y + cell_h / 2, anchor="w", text=row.label[:28], font=MONO,
                              fill="#24292f")
            for j, cy in enumerate(window):
                if cy not in row.cells:
                    continue
                stage, mark = row.cells[cy]
                x0 = label_w + j * cell_w
                if row.kind == "bubble":
                    fill = BUBBLE_FILL
                elif row.kind == "halt":
                    fill = HALT_FILL
                else:
                    fill = instr_color(row.pc)
                outline = {"stall": C_STALL, "flush": C_FLUSH, "taken": C_TAKEN,
                           "halt": C_HALT}.get(mark, "#8c959f")
                c.create_rectangle(x0 + 1, y + 1, x0 + cell_w - 1, y + cell_h - 1, fill=fill,
                                   outline=outline, width=2 if mark in MARK_CHAR else 1,
                                   dash=(3, 2) if row.kind == "bubble" else ())
                c.create_text(x0 + cell_w / 2, y + cell_h / 2, text=stage + MARK_CHAR.get(mark, ""),
                              font=("Consolas", 8, "bold"),
                              fill="#8c959f" if row.kind == "bubble" else "#24292f")
        legend_y = head_h + len(rows) * cell_h + 8
        c.create_text(6, legend_y, anchor="nw", fill="#555", font=("", 8),
                      text="*  stall     ✗  descartada por un salto     !  salto tomado     "
                           "h  HALT retenido en ID")
        c.configure(scrollregion=(0, 0, width, legend_y + 20))
        c.yview_moveto(1.0)

    @staticmethod
    def _control_flags(latch) -> str:
        flags = []
        for name in ("reg_write", "mem_read", "mem_write", "mem_to_reg", "is_jal", "is_jalr", "is_halt"):
            if getattr(latch, name, False):
                flags.append(name)
        return "[" + ", ".join(flags) + "]" if flags else ""

    # -------------------------------------------------------- cola de eventos

    def _poll_events(self):
        try:
            while True:
                event = self.events.get_nowait()
                kind = event[0]

                if kind == "connected":
                    _, ser, port, baud = event
                    self.ser = ser
                    self._set_connected(True)
                    self.connect_btn.configure(state="normal")
                    self._log(f"Conectado a {port} @ {baud} bps.")
                elif kind == "connect_failed":
                    self._log(f"Error abriendo puerto: {event[1]}")
                    self.connect_btn.configure(state="normal")
                elif kind == "log":
                    self._log(event[1])
                elif kind == "error":
                    self._log(f"Error: {event[1]}")
                    messagebox.showerror("Error", event[1])
                elif kind == "loaded":
                    self.n_loaded_words = event[1]
                    self.loaded_var.set(f"Ultimo programa cargado: {event[1]} instrucciones.")
                    self._reset_history()
                elif kind == "core_reset":
                    self._reset_history()
                elif kind == "dump":
                    self._update_dump_display(event[1])
                elif kind == "busy_done":
                    self._set_busy(False)
                    self.pause_btn.configure(state="disabled")
        except queue.Empty:
            pass
        self.after(POLL_MS, self._poll_events)

    def _reset_history(self):
        """Carga/Reset: el core vuelve al ciclo 0, el diagrama arranca de nuevo."""
        self.history.reset()
        self.prev_state = None
        self._schedule_redraw()

    def _on_close(self):
        # Si hay un CMD_RUN esperando (posible loop infinito), la pausa hace
        # que su worker reciba el volcado y suelte el puerto antes de cerrar.
        self.pause_event.set()
        with self.ser_lock:
            if self.ser is not None:
                self.ser.close()
        self.destroy()


if __name__ == "__main__":
    RiscvGui().mainloop()
