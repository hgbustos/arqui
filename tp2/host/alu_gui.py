#!/usr/bin/env python3
"""
alu_gui.py — GUI de escritorio (tkinter, sin dependencias extra) para hablar
con uart_alu_top (TP2) por puerto serie real, pensada para la defensa: setear
puerto/baudios, armar y enviar un CMD_LOAD, pedir CMD_READ (y releerlo N
veces sin recargar) y ver en un log el detalle byte a byte de lo que se
manda y se recibe.

No reimplementa el protocolo: reutiliza el armado/parseo de paquetes de
alu_client.py (mismo modulo, un solo lugar si el protocolo cambia el dia de
manana). Solo agrega la parte de UI y el manejo de threads.

Uso:
    python alu_gui.py
"""
import queue
import threading
import time
import tkinter as tk
from tkinter import ttk

import serial
import serial.tools.list_ports

from alu_client import (BAUD_TO_SEL, CMD_LOAD, CMD_READ, OpCode,
                         build_load_packet, build_read_packet, parse_response, pyserial_parity)

POLL_MS = 50  # frecuencia con la que la GUI drena la cola de eventos del worker


class AluGui(tk.Tk):
    # La comunicacion serie (ser.write/ser.read, este ultimo bloqueante hasta
    # el timeout) corre siempre en un thread aparte para no congelar el
    # mainloop de tkinter. El thread nunca toca widgets directamente: solo
    # empuja eventos a 'self.events' (thread-safe) y el mainloop los aplica
    # a la UI via 'after()', que es el unico patron seguro para mezclar
    # threads con tkinter.
    def __init__(self):
        super().__init__()
        self.title("TP2 - Cliente ALU por UART")
        self.geometry("760x620")
        self.minsize(680, 560)

        self.ser = None
        self.ser_lock = threading.Lock()
        self.events = queue.Queue()
        self.last_load = None  # (op_name, a, b), para el resumen en pantalla

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
        self.baud_var = tk.StringVar(value="19200")
        baud_combo = ttk.Combobox(conn, textvariable=self.baud_var, width=8, state="readonly",
                                   values=[str(b) for b in sorted(BAUD_TO_SEL)])
        baud_combo.grid(row=0, column=4, **pad)
        baud_combo.bind("<<ComboboxSelected>>", lambda e: self._update_switch_hint())

        self.switch_hint_var = tk.StringVar()
        ttk.Label(conn, textvariable=self.switch_hint_var, foreground="#555").grid(
            row=1, column=0, columnspan=5, sticky="w", padx=6)
        self._update_switch_hint()

        self.parity_var = tk.BooleanVar(value=False)  # False = switch en bajo, el default probado en hardware
        parity_check = ttk.Checkbutton(conn, text="Paridad EVEN activa", variable=self.parity_var)
        parity_check.grid(row=2, column=0, columnspan=2, sticky="w", padx=6, pady=4)
        ttk.Label(conn, text="(tiene que coincidir con SW2 de la FPGA -- parity_en_i, sin feedback automatico)",
                  foreground="#555").grid(row=2, column=2, columnspan=4, sticky="w", padx=6)

        self.connect_btn = ttk.Button(conn, text="Conectar", command=self._toggle_connect)
        self.connect_btn.grid(row=0, column=5, rowspan=2, padx=10)

        self.status_var = tk.StringVar()
        self.status_label = ttk.Label(conn, textvariable=self.status_var, font=("", 10, "bold"))
        self.status_label.grid(row=0, column=6, rowspan=2, sticky="w", padx=6)

        load = ttk.LabelFrame(self, text="Cargar operacion (CMD_LOAD)")
        load.pack(fill="x", **pad)

        ttk.Label(load, text="Opcode:").grid(row=0, column=0, sticky="w", **pad)
        self.op_var = tk.StringVar(value=OpCode.ADD.name)
        op_combo = ttk.Combobox(load, textvariable=self.op_var, width=8, state="readonly",
                                 values=[o.name for o in OpCode])
        op_combo.grid(row=0, column=1, **pad)
        op_combo.bind("<<ComboboxSelected>>", lambda e: self._update_opcode_hint())
        self.opcode_hint_var = tk.StringVar()
        ttk.Label(load, textvariable=self.opcode_hint_var, foreground="#555").grid(row=0, column=2, sticky="w")
        self._update_opcode_hint()

        ttk.Label(load, text="A (0-255):").grid(row=0, column=3, sticky="w", **pad)
        self.a_var = tk.StringVar(value="100")
        ttk.Entry(load, textvariable=self.a_var, width=8).grid(row=0, column=4, **pad)

        ttk.Label(load, text="B (0-255):").grid(row=0, column=5, sticky="w", **pad)
        self.b_var = tk.StringVar(value="50")
        ttk.Entry(load, textvariable=self.b_var, width=8).grid(row=0, column=6, **pad)

        self.load_btn = ttk.Button(load, text="Enviar CMD_LOAD", command=self._do_load)
        self.load_btn.grid(row=0, column=7, padx=10)

        self.last_load_var = tk.StringVar(value="Todavia no se cargo ninguna operacion.")
        ttk.Label(load, textvariable=self.last_load_var, foreground="#555").grid(
            row=1, column=0, columnspan=8, sticky="w", padx=6)

        read = ttk.LabelFrame(self, text="Leer resultado (CMD_READ)")
        read.pack(fill="x", **pad)

        self.read_btn = ttk.Button(read, text="Leer (CMD_READ)", command=self._do_read)
        self.read_btn.grid(row=0, column=0, **pad)

        ttk.Label(read, text="Releer x").grid(row=0, column=1, sticky="e")
        self.reread_var = tk.StringVar(value="3")
        ttk.Spinbox(read, from_=1, to=20, textvariable=self.reread_var, width=4).grid(row=0, column=2)
        self.reread_btn = ttk.Button(read, text="Releer sin recargar", command=self._do_reread)
        self.reread_btn.grid(row=0, column=3, padx=6)

        result = ttk.Frame(read)
        result.grid(row=0, column=4, padx=20)
        self.result_var = tk.StringVar(value="resultado: -")
        ttk.Label(result, textvariable=self.result_var, font=("", 10, "bold")).grid(row=0, column=0, columnspan=4)

        self.co_canvas = tk.Canvas(result, width=16, height=16, highlightthickness=0)
        self.co_dot = self.co_canvas.create_oval(2, 2, 14, 14, fill="#bbb")
        self.co_canvas.grid(row=1, column=0)
        ttk.Label(result, text="co").grid(row=1, column=1, sticky="w")

        self.zero_canvas = tk.Canvas(result, width=16, height=16, highlightthickness=0)
        self.zero_dot = self.zero_canvas.create_oval(2, 2, 14, 14, fill="#bbb")
        self.zero_canvas.grid(row=1, column=2)
        ttk.Label(result, text="zero").grid(row=1, column=3, sticky="w")

        log_frame = ttk.LabelFrame(self, text="Log (paquetes enviados / recibidos)")
        log_frame.pack(fill="both", expand=True, **pad)

        log_scroll = ttk.Scrollbar(log_frame)
        log_scroll.pack(side="right", fill="y")
        self.log_text = tk.Text(log_frame, height=14, wrap="none", yscrollcommand=log_scroll.set,
                                 font=("Consolas", 9), state="disabled")
        self.log_text.pack(fill="both", expand=True, side="left")
        log_scroll.config(command=self.log_text.yview)

        ttk.Button(self, text="Limpiar log", command=self._clear_log).pack(anchor="e", padx=8, pady=(0, 6))

        self._refresh_ports()

    def _update_switch_hint(self):
        baud = int(self.baud_var.get())
        sel = BAUD_TO_SEL[baud]
        sw0 = "arriba" if sel & 0b01 else "abajo"
        sw1 = "arriba" if sel & 0b10 else "abajo"
        self.switch_hint_var.set(f"baud_sel_i={sel:02b} -> SW0 {sw0}, SW1 {sw1}")

    def _update_opcode_hint(self):
        op = OpCode[self.op_var.get()]
        self.opcode_hint_var.set(f"opcode = {op.value:06b}b")

    def _refresh_ports(self):
        ports = [p.device for p in serial.tools.list_ports.comports()]
        self.port_combo["values"] = ports
        if ports and not self.port_var.get():
            self.port_var.set(ports[0])

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
        self.load_btn.configure(state=state)
        self.read_btn.configure(state=state)
        self.reread_btn.configure(state=state)

    def _parse_operand(self, raw, label):
        try:
            value = int(raw, 0)
        except ValueError:
            raise ValueError(f"Operando {label}='{raw}' no es un numero valido (decimal o 0x..)")
        if not (0 <= value <= 255):
            raise ValueError(f"Operando {label}={value} no entra en un byte (0-255)")
        return value

    def _set_leds(self, co, zero):
        self.co_canvas.itemconfig(self.co_dot, fill="#1a7f37" if co else "#bbb")
        self.zero_canvas.itemconfig(self.zero_dot, fill="#1a7f37" if zero else "#bbb")

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
        parity = self.parity_var.get()
        self.connect_btn.configure(state="disabled")

        def worker():
            try:
                ser = serial.Serial(port, baud, parity=pyserial_parity(parity), timeout=1.0)
            except serial.SerialException as e:
                self.events.put(("connect_failed", str(e)))
                return
            self.events.put(("connected", ser, port, baud, parity))

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
            a = self._parse_operand(self.a_var.get(), "A")
            b = self._parse_operand(self.b_var.get(), "B")
        except ValueError as e:
            self._log(f"Error: {e}")
            return
        op = OpCode[self.op_var.get()]
        packet = build_load_packet(op, a, b)
        self._set_busy(True)

        def worker():
            try:
                with self.ser_lock:
                    self.ser.write(packet)
                    self.ser.flush()
            except serial.SerialException as e:
                self.events.put(("error", f"Error escribiendo CMD_LOAD: {e}"))
                self.events.put(("busy_done", None))
                return
            self.events.put(("log", f"TX CMD_LOAD | bytes: {packet.hex(' ').upper()} "
                                     f"| cmd=01 op={op.name}({op.value:06b}b) A={a}(0x{a:02X}) B={b}(0x{b:02X})"))
            self.events.put(("loaded", op.name, a, b))
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _do_read(self):
        self._send_read(label="CMD_READ")

    def _do_reread(self):
        try:
            n = int(self.reread_var.get())
        except ValueError:
            n = 1
        self._set_busy(True)

        def worker():
            for i in range(max(n, 1)):
                self._read_once(f"releer #{i + 1}/{n}")
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _send_read(self, label):
        self._set_busy(True)

        def worker():
            self._read_once(label)
            self.events.put(("busy_done", None))

        threading.Thread(target=worker, daemon=True).start()

    def _read_once(self, label):
        packet = build_read_packet()
        try:
            with self.ser_lock:
                self.ser.write(packet)
                self.ser.flush()
                self.events.put(("log", f"TX {label} | bytes: {packet.hex(' ').upper()} | cmd=02 (sin datos)"))
                raw = self.ser.read(2)
        except serial.SerialException as e:
            self.events.put(("error", f"Error en {label}: {e}"))
            return

        try:
            parsed = parse_response(raw)
        except ValueError as e:
            self.events.put(("log", f"RX {label} | bytes: {raw.hex(' ').upper() or '(nada, timeout)'} "
                                     f"| Error: {e}"))
            self.events.put(("error", str(e)))
            return

        self.events.put(("log", f"RX {label} | bytes: {raw.hex(' ').upper()} | "
                                 f"resultado={parsed['result_unsigned']}(0x{parsed['result_unsigned']:02X}, "
                                 f"signed {parsed['result_signed']}) co={int(parsed['co'])} zero={int(parsed['zero'])}"))
        self.events.put(("result", parsed))

    def _set_busy(self, busy):
        # 'connect_btn' tambien se deshabilita: si el usuario desconecta
        # mientras hay una transaccion en curso, '_disconnect' (que corre en
        # el thread de la GUI) esperaria el mismo lock que sostiene el
        # worker durante el 'ser.read()' con timeout, congelando el
        # mainloop hasta 1 segundo.
        state = "disabled" if busy else "normal"
        self.load_btn.configure(state=state)
        self.read_btn.configure(state=state)
        self.reread_btn.configure(state=state)
        self.connect_btn.configure(state=state)

    # -------------------------------------------------------- cola de eventos

    def _poll_events(self):
        try:
            while True:
                event = self.events.get_nowait()
                kind = event[0]

                if kind == "connected":
                    _, ser, port, baud, parity = event
                    self.ser = ser
                    self._set_connected(True)
                    self.connect_btn.configure(state="normal")
                    paridad_str = "EVEN" if parity else "ninguna"
                    self._log(f"Conectado a {port} @ {baud} bps, paridad={paridad_str}.")
                elif kind == "connect_failed":
                    self._log(f"Error abriendo puerto: {event[1]}")
                    self.connect_btn.configure(state="normal")
                elif kind == "log":
                    self._log(event[1])
                elif kind == "error":
                    self._log(f"Error: {event[1]}")
                elif kind == "loaded":
                    _, op_name, a, b = event
                    self.last_load = (op_name, a, b)
                    self.last_load_var.set(f"Ultima carga: {op_name}({a}, {b})")
                elif kind == "result":
                    parsed = event[1]
                    self.result_var.set(
                        f"resultado: {parsed['result_unsigned']} "
                        f"(0x{parsed['result_unsigned']:02X}, signed {parsed['result_signed']})")
                    self._set_leds(parsed["co"], parsed["zero"])
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
    AluGui().mainloop()
