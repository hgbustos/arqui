#!/usr/bin/env python3
"""
riscv_gui.py — GUI de escritorio (tkinter, sin dependencias extra alla de
pyserial) para hablar con riscv_uart_top (TP3) por puerto serie real,
pensada para la defensa: editar/cargar un programa .asm, ensamblarlo y
mandarlo por CMD_LOAD_PROG, correrlo (CMD_RUN) o pasearlo paso a paso
(CMD_STEP), y ver en vivo los 32 registros, los 4 latches de pipeline
(con la instruccion de cada uno ya desensamblada) y la memoria de datos,
ademas de un log byte a byte de lo que se manda y se recibe.

No reimplementa el protocolo ni el ensamblador: reutiliza riscv_asm.py y
riscv_protocol.py (mismos modulos que riscv_client.py), y sigue el mismo
patron de threads que tp2/host/alu_gui.py -- la comunicacion serie corre
siempre en un worker aparte, nunca toca widgets directamente, y empuja
eventos a una cola que el mainloop drena via 'after()'.

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

from riscv_asm import AsmError, REG_NAMES, assemble, disassemble_word
from riscv_protocol import (
    DumpState, ProtocolError,
    build_dump_packet, build_load_prog_packet, build_reset_packet,
    build_run_packet, build_step_packet,
    expected_dump_size, parse_dump, to_signed32,
)

POLL_MS = 50

EXAMPLE_PROGRAM = """\
# Programa de ejemplo: x3 = x1 + x2, guardado en mem[0]
addi x1, x0, 10
addi x2, x0, 32
add  x3, x1, x2
sw   x3, 0(x0)
halt
"""

BAUD_CHOICES = [9600, 19200, 57600, 115200]


class RiscvGui(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("TP3 - Debug Unit RISC-V por UART")
        self.geometry("1040x760")
        self.minsize(900, 640)

        self.ser = None
        self.ser_lock = threading.Lock()
        self.events = queue.Queue()
        self.n_loaded_words = None

        self._build_widgets()
        self._set_connected(False)
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(POLL_MS, self._poll_events)

    # ------------------------------------------------------------------ UI

    def _build_widgets(self):
        pad = {"padx": 6, "pady": 4}

        conn = ttk.LabelFrame(self, text="Conexion")
        conn.pack(fill="x", **pad)

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
        self.dmem_words_var = tk.StringVar(value="256")
        ttk.Spinbox(conn, from_=1, to=4096, textvariable=self.dmem_words_var, width=6).grid(
            row=0, column=6, **pad)
        ttk.Label(conn, text="(debe coincidir con DMEM_DEPTH_WORDS de riscv_uart_top.v)",
                  foreground="#555").grid(row=1, column=0, columnspan=5, sticky="w", padx=6)

        self.connect_btn = ttk.Button(conn, text="Conectar", command=self._toggle_connect)
        self.connect_btn.grid(row=0, column=7, rowspan=2, padx=10)

        self.status_var = tk.StringVar()
        self.status_label = ttk.Label(conn, textvariable=self.status_var, font=("", 10, "bold"))
        self.status_label.grid(row=0, column=8, rowspan=2, sticky="w", padx=6)

        notebook = ttk.Notebook(self)
        notebook.pack(fill="both", expand=True, **pad)
        self._build_tab_programa(notebook)
        self._build_tab_ejecucion(notebook)
        self._build_tab_memoria(notebook)

        log_frame = ttk.LabelFrame(self, text="Log (paquetes enviados / recibidos)")
        log_frame.pack(fill="both", **pad)
        log_scroll = ttk.Scrollbar(log_frame)
        log_scroll.pack(side="right", fill="y")
        self.log_text = tk.Text(log_frame, height=8, wrap="none", yscrollcommand=log_scroll.set,
                                 font=("Consolas", 9), state="disabled")
        self.log_text.pack(fill="both", expand=True, side="left")
        log_scroll.config(command=self.log_text.yview)
        ttk.Button(self, text="Limpiar log", command=self._clear_log).pack(anchor="e", padx=8, pady=(0, 6))

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
        self.step_btn = ttk.Button(ctrl, text="Step (CMD_STEP)", command=self._do_step)
        self.step_btn.pack(side="left", padx=4)
        self.reset_btn = ttk.Button(ctrl, text="Reset (CMD_RESET)", command=self._do_reset)
        self.reset_btn.pack(side="left", padx=4)
        self.dump_btn = ttk.Button(ctrl, text="Ver estado (CMD_DUMP)", command=self._do_dump)
        self.dump_btn.pack(side="left", padx=4)

        status = ttk.Frame(tab)
        status.pack(fill="x", padx=6, pady=4)
        self.halted_dot, _ = self._make_indicator(status, "Halted", 0)
        self.stalled_dot, _ = self._make_indicator(status, "Stalled", 1)
        self.branch_dot, _ = self._make_indicator(status, "Branch taken", 2)
        self.cycle_var = tk.StringVar(value="Ciclos: -")
        ttk.Label(status, textvariable=self.cycle_var, font=("", 10, "bold")).grid(
            row=0, column=6, padx=20)

        body = ttk.Frame(tab)
        body.pack(fill="both", expand=True, padx=6, pady=4)

        regs_frame = ttk.LabelFrame(body, text="Registros")
        regs_frame.pack(side="left", fill="y", padx=(0, 6))
        self.reg_vars = []
        for i in range(32):
            var = tk.StringVar(value=f"{REG_NAMES[i]:>4} = 0x00000000")
            ttk.Label(regs_frame, textvariable=var, font=("Consolas", 9)).grid(
                row=i % 16, column=i // 16, sticky="w", padx=8, pady=1)
            self.reg_vars.append(var)

        pipe_frame = ttk.Frame(body)
        pipe_frame.pack(side="left", fill="both", expand=True)
        self.stage_vars = {}
        for stage in ("IF/ID", "ID/EX", "EX/MEM", "MEM/WB"):
            f = ttk.LabelFrame(pipe_frame, text=stage)
            f.pack(fill="x", pady=4)
            pc_var = tk.StringVar(value="pc = -")
            instr_var = tk.StringVar(value="(sin datos)")
            extra_var = tk.StringVar(value="")
            ttk.Label(f, textvariable=pc_var, font=("Consolas", 9)).pack(anchor="w", padx=6)
            ttk.Label(f, textvariable=instr_var, font=("Consolas", 10, "bold")).pack(anchor="w", padx=6)
            ttk.Label(f, textvariable=extra_var, font=("Consolas", 9), foreground="#555").pack(
                anchor="w", padx=6)
            self.stage_vars[stage] = (pc_var, instr_var, extra_var)

    def _build_tab_memoria(self, notebook):
        tab = ttk.Frame(notebook)
        notebook.add(tab, text="Memoria de datos")

        tree_frame = ttk.Frame(tab)
        tree_frame.pack(fill="both", expand=True, padx=6, pady=6)
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
        tree_scroll.config(command=self.mem_tree.yview)

    def _make_indicator(self, parent, label, col):
        canvas = tk.Canvas(parent, width=16, height=16, highlightthickness=0)
        dot = canvas.create_oval(2, 2, 14, 14, fill="#bbb")
        canvas.grid(row=0, column=col * 2, padx=(12, 2))
        ttk.Label(parent, text=label).grid(row=0, column=col * 2 + 1, sticky="w")
        return (canvas, dot), None

    # ------------------------------------------------------------- helpers

    def _log(self, text):
        self.log_text.configure(state="normal")
        self.log_text.insert("end", f"[{time.strftime('%H:%M:%S')}] {text}\n")
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
        for w in (self.load_btn, self.run_btn, self.step_btn, self.reset_btn, self.dump_btn):
            w.configure(state=state)

    def _set_busy(self, busy):
        state = "disabled" if busy else "normal"
        for w in (self.load_btn, self.run_btn, self.step_btn, self.reset_btn,
                   self.dump_btn, self.connect_btn):
            w.configure(state=state)

    def _set_dot(self, dot_pair, on):
        canvas, dot = dot_pair
        canvas.itemconfig(dot, fill="#1a7f37" if on else "#bbb")

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

    def _dmem_words(self) -> int:
        try:
            return int(self.dmem_words_var.get())
        except ValueError:
            return 256

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
                ser = serial.Serial(port, baud, timeout=5.0)
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
        packet = build_load_prog_packet(words)
        self._set_busy(True)

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(packet)
                    self.ser.flush()
            except serial.SerialException as e:
                self.events.put(("error", f"Error escribiendo CMD_LOAD_PROG: {e}"))
                self.events.put(("busy_done", None))
                return
            self.events.put(("log", f"TX CMD_LOAD_PROG | {len(words)} palabras | "
                                     f"{packet[:12].hex(' ').upper()}{'...' if len(packet) > 12 else ''}"))
            self.events.put(("loaded", len(words)))
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _do_run(self):
        self._send_simple_command(build_run_packet(), "CMD_RUN")

    def _do_step(self):
        self._send_simple_command(build_step_packet(), "CMD_STEP")

    def _do_dump(self):
        self._send_simple_command(build_dump_packet(), "CMD_DUMP")

    def _do_reset(self):
        if self.ser is None:
            return
        packet = build_reset_packet()
        self._set_busy(True)

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(packet)
                    self.ser.flush()
            except serial.SerialException as e:
                self.events.put(("error", f"Error escribiendo CMD_RESET: {e}"))
            else:
                self.events.put(("log", "TX CMD_RESET"))
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

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
        self._set_dot(self.halted_dot, state.core_halted)
        self._set_dot(self.stalled_dot, state.stalled)
        self._set_dot(self.branch_dot, state.branch_taken)
        self.cycle_var.set(f"Ciclos: {state.cycle_count}")

        for i in range(32):
            self.reg_vars[i].set(f"{REG_NAMES[i]:>4} = 0x{state.registers[i]:08x}")

        latches = {
            "IF/ID": (state.if_id.pc, state.if_id.instr, ""),
            "ID/EX": (state.id_ex.pc, state.id_ex.instr,
                      f"rs1=0x{state.id_ex.rs1_data:08x}  rs2=0x{state.id_ex.rs2_data:08x}  "
                      f"imm={to_signed32(state.id_ex.imm)}  "
                      f"{self._control_flags(state.id_ex)}"),
            "EX/MEM": (state.ex_mem.pc, state.ex_mem.instr,
                       f"result=0x{state.ex_mem.ex_result:08x}  rs2=0x{state.ex_mem.rs2_data:08x}  "
                       f"{self._control_flags(state.ex_mem)}"),
            "MEM/WB": (state.mem_wb.pc, state.mem_wb.instr,
                       f"result=0x{state.mem_wb.result:08x}  mem_data=0x{state.mem_wb.mem_read_data:08x}  "
                       f"{self._control_flags(state.mem_wb)}"),
        }
        for stage, (pc, instr, extra) in latches.items():
            pc_var, instr_var, extra_var = self.stage_vars[stage]
            pc_var.set(f"pc = 0x{pc:08x}")
            instr_var.set(disassemble_word(instr, pc))
            extra_var.set(extra)

        self.mem_tree.delete(*self.mem_tree.get_children())
        for addr, value in enumerate(state.dmem):
            self.mem_tree.insert("", "end", values=(
                f"0x{addr * 4:04x}", f"0x{value:08x}", str(to_signed32(value))))

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
                elif kind == "dump":
                    self._update_dump_display(event[1])
                elif kind == "busy_done":
                    self._set_busy(False)
        except queue.Empty:
            pass
        self.after(POLL_MS, self._poll_events)

    def _on_close(self):
        with self.ser_lock:
            if self.ser is not None:
                self.ser.close()
        self.destroy()


if __name__ == "__main__":
    RiscvGui().mainloop()
