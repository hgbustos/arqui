"""Genera tp3/docs/img/datapath_control.svg: datapath + control completo de
riscv_core.v. Cada cable corresponde a una señal real del RTL (ver
comentarios con la línea de riscv_core.v que la origina).

Con --pdf también genera datapath_control.pdf (A3 apaisado) para imprimir."""
from xml.sax.saxutils import escape

import os
import shutil
import subprocess
import sys
import tempfile
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "datapath_control.svg")
W, H = 2720, 1720

BG = "#ffffff"; BAND = "#f1f3f6"     # fondo claro: se imprime bien y gasta poca tinta
WH = "#2d333b"; BL = "#0e7f86"; OR = "#7c3aed"; PK = "#d1293d"; GR = "#a66a00"; GY = "#6b7280"
# relleno suave de cada módulo según la categoría de su borde
TINT = {WH: "#ffffff", BL: "#e7f5f6", OR: "#f3edfe", PK: "#fdecee", GR: "#fbf3df", GY: "#ffffff"}
SANS = "'Segoe UI', 'Helvetica Neue', Arial, sans-serif"
MONO = "Consolas, 'DejaVu Sans Mono', 'Courier New', monospace"

out = []
def a(s): out.append(s)

def text(x, y, s, c=WH, size=12, anchor="start", bold=False, italic=False, mono=False):
    w = ' font-weight="700"' if bold else ""
    it = ' font-style="italic"' if italic else ""
    f = f' font-family="{MONO}" style="white-space:pre"' if mono else ""
    size = {10: 11.5, 11: 12.5, 12: 13}.get(size, size)   # letra chica más grande: se imprime
    a(f'<text x="{x}" y="{y}" fill="{c}" font-size="{size}" text-anchor="{anchor}"{w}{it}{f}>{escape(s)}</text>')

def wire(pts, c=WH, arrow=True, w=1.6, dash=None):
    d = "M" + " L".join(f"{x},{y}" for x, y in pts)
    m = f' marker-end="url(#m{c[1:]})"' if arrow else ""
    ds = f' stroke-dasharray="{dash}"' if dash else ""
    a(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{w}"{m}{ds}/>')

def dot(x, y, c=WH):
    a(f'<circle cx="{x}" cy="{y}" r="3.2" fill="{c}"/>')

def box(x, y, w, h, title, c=WH, sub=None, fs=14):
    a(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="6" fill="{TINT[c]}" stroke="{c}" stroke-width="1.5"/>')
    if title:
        text(x + w / 2, y + 20, title, c, fs, "middle", True)
    if sub:
        for i, s in enumerate(sub):
            text(x + w / 2, y + 38 + 15 * i, s, GY, 11, "middle")

def mux(x, y, w, h, c=WH, label="MUX"):
    a(f'<polygon points="{x},{y} {x+w},{y+h*0.18} {x+w},{y+h*0.82} {x},{y+h}" fill="{TINT[c]}" stroke="{c}" stroke-width="1.5"/>')

def gate(x, y, s="&", c=WH):
    a(f'<rect x="{x}" y="{y}" width="28" height="24" rx="10" fill="{TINT[c]}" stroke="{c}" stroke-width="1.5"/>')
    text(x + 14, y + 16, s, c, 13, "middle", True)

def latch(x, y0, y1, name, num):
    a(f'<rect x="{x}" y="{y0}" width="28" height="{y1-y0}" rx="4" fill="{WH}" stroke="{WH}" stroke-width="1.8"/>')
    for i, ch in enumerate(name):
        text(x + 14, (y0 + y1) / 2 - 30 + 16 * i, ch, BG, 14, "middle", True)
    text(x + 14, y1 + 18, f"({num})", GY, 11, "middle")

def stub_in(x, y, label, c, side="left", length=24):
    """Etiqueta de red: la señal llega desde 'label' (no se dibuja el cable entero)."""
    if side == "left":
        wire([(x - length, y), (x, y)], c)
        text(x - length - 4, y + 4, label, c, 11, "end")
    elif side == "top":
        wire([(x, y - length), (x, y)], c)
        text(x, y - length - 4, label, c, 11, "middle")
    elif side == "bottom":
        wire([(x, y + length), (x, y)], c)
        text(x, y + length + 13, label, c, 11, "middle")

def stub_out(x, y, label, c, side="right", length=24):
    if side == "right":
        wire([(x, y), (x + length, y)], c)
        text(x + length + 4, y + 4, label, c, 11, "start")
    elif side == "bottom":
        wire([(x, y), (x, y + length)], c)
        text(x, y + length + 13, label, c, 11, "middle")
    elif side == "left":
        wire([(x, y), (x - length, y)], c)
        text(x - length - 4, y + 4, label, c, 11, "end")

# ---------------------------------------------------------------- cabecera
a(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" '
  f'font-family="{SANS}" xml:space="preserve">')
a('<title>RISC-V core del TP3: datapath y control (riscv_core.v)</title>')
a("<defs>")
for c in (WH, BL, OR, PK, GR, GY):
    a(f'<marker id="m{c[1:]}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto">'
      f'<path d="M0,1 L9,5 L0,9 z" fill="{c}"/></marker>')
a("</defs>")
a(f'<rect width="{W}" height="{H}" fill="{BG}"/>')
text(24, 36, "RISC-V CORE (TP3) — DATAPATH Y CONTROL", WH, 24, bold=True)
text(24, 58, "riscv_core.v · cada cable es una señal real del RTL · (n) = parada del plan de estudio (docs/defensa.md)", GY, 12)

# ---------------------------------------------------------------- lanes
Y_EN = 112                      # core_en (Debug Unit)
Y_WB, Y_M, Y_EX = 170, 190, 210  # grupos de control (control_unit -> latches)
Y_PC = 250
Y_RS1, Y_RS2, Y_IMM = 548, 640, 775
Y_EXRES, Y_RES, Y_RD = 650, 580, 700
Y_ST = 1010                     # dato del store
Y_INS = 1140
Y_WBK = 1480                    # escritura en el banco (vuelve de WB)
LAT_Y0, LAT_Y1 = 150, 1180
X_IFID, X_IDEX, X_EXMEM, X_MEMWB = 440, 1250, 1960, 2250

# ---------------------------------------------------------------- etapas
# bandas alternadas: cada etapa va del centro de un latch al del siguiente
bounds = [16, X_IFID + 14, X_IDEX + 14, X_EXMEM + 14, X_MEMWB + 14, W - 16]
for i in range(0, 5, 2):
    a(f'<rect x="{bounds[i]}" y="66" width="{bounds[i+1] - bounds[i]}" height="1430" fill="{BAND}"/>')
for x, s in ((230, "IF · búsqueda"), (870, "ID · decodificación"), (1620, "EX · ejecución"),
             (2110, "MEM · memoria"), (2430, "WB · escritura")):
    pw = 7.6 * len(s) + 28
    a(f'<rect x="{x - pw / 2}" y="68" width="{pw}" height="24" rx="12" fill="{WH}"/>')
    text(x, 85, s, BG, 13, "middle", True)

# ---------------------------------------------------------------- core_en (verde)
text(24, Y_EN + 18, "global_stall_i (Debug Unit)", GR, 11)
wire([(24, Y_EN), (96, Y_EN)], GR, arrow=False)
a(f'<polygon points="96,{Y_EN-9} 96,{Y_EN+9} 114,{Y_EN}" fill="{TINT[GR]}" stroke="{GR}" stroke-width="1.5"/>')
a(f'<circle cx="118" cy="{Y_EN}" r="4" fill="{TINT[GR]}" stroke="{GR}" stroke-width="1.5"/>')
wire([(122, Y_EN), (2690, Y_EN)], GR, arrow=False, w=2.2)
text(600, Y_EN - 6, "core_en = ~global_stall_i   (riscv_core.v:146)", GR, 11)
for x in (195, X_IFID + 14, X_IDEX + 14, X_EXMEM + 14, X_MEMWB + 14, 2094, 2580):
    dot(x, Y_EN, GR)
# contador de ciclos
box(2520, 30, 170, 52, "cycle_count", GR, ["+1 si core_en  (165-170)"], fs=12)
wire([(2540, Y_EN), (2540, 82)], GR)
dot(2540, Y_EN, GR)

# ---------------------------------------------------------------- IF
# mux del PC
mux(88, 390, 30, 90, PK)
text(103, 382, "", PK)
text(95, 409, "0", GY, 10); text(95, 469, "1", GY, 10)
# PC + AND
gate(181, 330, "&", WH)
wire([(195, Y_EN), (195, 330)], GR)
wire([(195, 354), (195, 400)], WH)
text(205, 382, "pc_write_en", WH, 10)
box(160, 400, 70, 70, "PC", WH, ["pc_reg"])
wire([(118, 435), (160, 435)], WH)
wire([(230, 435), (250, 435)], WH, arrow=False)
dot(250, 435)
# +4
box(270, 300, 60, 40, "+4", WH)
wire([(250, 435), (250, 320), (270, 320)], WH)
dot(250, 320)
wire([(300, 300), (300, 280), (60, 280), (60, 405), (88, 405)], WH)
text(160, 274, "pc_plus4", GY, 10)
# imem
box(270, 1060, 140, 140, "imem (7)", WH, ["lectura asíncrona", "1024 × 32"])
wire([(250, 435), (250, 1100), (270, 1100)], WH)
wire([(410, 1140), (X_IFID, 1140)], WH)
text(414, 1134, "instr", GY, 10)
wire([(340, 1226), (340, 1200)], GR)
text(350, 1224, "carga ← debug_unit", GR, 10)
# pc -> IF/ID
wire([(250, 435), (250, Y_PC), (X_IFID, Y_PC)], WH)
text(300, Y_PC - 6, "pc", GY, 10)

# ---------------------------------------------------------------- IF/ID
gate(X_IFID, 120, "&", OR)
wire([(X_IFID + 14, 144), (X_IFID + 14, LAT_Y0)], OR)
latch(X_IFID, LAT_Y0, LAT_Y1, "IF/ID", 9)

# ---------------------------------------------------------------- ID
# bus de instrucción
wire([(X_IFID + 28, 1140), (510, 1140)], WH, arrow=False)
dot(510, 1140)
wire([(510, 1140), (510, 330)], WH, arrow=False, w=2.2)
for y in (330, 580, 620, 770):
    dot(510, y)
wire([(510, 330), (560, 330)], WH); text(516, 324, "op,f3,f7", GY, 10)
wire([(510, 580), (580, 580)], WH); text(516, 574, "[19:15]", GY, 10)
wire([(510, 620), (580, 620)], WH); text(516, 614, "[24:20]", GY, 10)
wire([(510, 770), (580, 770)], WH)
wire([(510, 1140), (X_IDEX, 1140)], WH)
text(600, 1134, "instr (viaja completa: rd, funct3, ...)", GY, 10)
# pc
wire([(X_IFID + 28, Y_PC), (X_IDEX, Y_PC)], WH)

# control_unit
box(560, 300, 240, 170, "control_unit (4)", BL,
    ["decodifica opcode + funct3 + funct7", "no soportada → is_halt", "(HALT implícito)"])
# grupos de control hacia ID/EX
wire([(700, 300), (700, Y_WB), (X_IDEX, Y_WB)], BL)
wire([(720, 300), (720, Y_M), (X_IDEX, Y_M)], BL)
wire([(740, 300), (740, Y_EX), (X_IDEX, Y_EX)], BL)
text(810, Y_WB - 4, "WB: reg_write, mem_to_reg, is_halt", BL, 11)
text(810, Y_M - 4, "M: mem_read, mem_write", BL, 11)
text(810, Y_EX - 4, "EX: alu_src_a, alu_src_b, alu_op, is_jal, is_jalr", BL, 11)
# imm_sel
wire([(570, 470), (570, 795), (580, 795)], BL)
text(574, 490, "imm_sel", BL, 10)
# hacia branch_unit
wire([(800, 440), (1000, 440), (1000, 860)], BL)
text(806, 434, "is_branch, is_jal, is_jalr, funct3", BL, 10)
# hacia hazard_unit (etiqueta)
stub_out(780, 470, "→ hazard_unit", BL, side="bottom", length=14)

# register_file
box(580, 540, 220, 170, "register_file (6)", WH, ["2 lecturas async", "1 escritura (flanco)", "x0 = 0 · bypass WB→ID"])
wire([(800, Y_RS1), (X_IDEX, Y_RS1)], WH); text(850, Y_RS1 - 6, "rs1_data (sin adelantar)", GY, 10)
wire([(800, 640), (X_IDEX, Y_RS2)], WH); text(850, 634, "rs2_data (sin adelantar)", GY, 10)
text(590, 702, "← escritura (WB)", WH, 10)
text(794, 702, "regs_flat → dump", GR, 10, "end")

# imm_gen
box(580, 740, 220, 70, "imm_gen (3)", WH, ["I / S / B / U / J"])
wire([(800, 775), (X_IDEX, Y_IMM)], WH); text(806, 769, "imm", GY, 10)

# muxes de forwarding hacia ID
wire([(830, Y_RS1), (830, 885), (850, 885)], WH); dot(830, Y_RS1)
wire([(840, Y_RS2), (840, 1005), (850, 1005)], WH); dot(840, Y_RS2)
mux(850, 870, 30, 92, OR)
mux(850, 990, 30, 92, OR)
for (yy, lab) in ((905, "ex_result"), (925, "ex_mem_ex_result"), (945, "wb_write_data")):
    stub_in(850, yy, lab, OR, length=14)
for (yy, lab) in ((1025, "ex_result"), (1045, "ex_mem_ex_result"), (1065, "wb_write_data")):
    stub_in(850, yy, lab, OR, length=14)
stub_in(865, 872, "fwd_a_id", OR, side="top", length=14)
stub_in(865, 992, "fwd_b_id", OR, side="top", length=10)
wire([(880, 915), (920, 915)], WH)
wire([(880, 1035), (920, 1035)], WH)

# branch_unit
box(920, 860, 230, 240, "branch_unit (5)", PK,
    ["beq: rs1 == rs2", "bne: rs1 != rs2", "jal: pc + imm", "jalr: (rs1+imm) & ~1", "", "taken = jal | jalr |", "  (is_branch & cond)"])
wire([(1060, Y_IMM), (1060, 860)], WH); dot(1060, Y_IMM); text(1064, 852, "imm", GY, 10)
wire([(1100, Y_PC), (1100, 860)], WH); dot(1100, Y_PC); text(1104, 852, "pc", GY, 10)
# target y taken (rosa) hacia IF
wire([(980, 1100), (980, 1250), (70, 1250), (70, 465), (88, 465)], PK)
text(600, 1245, "branch_target", PK, 11)
wire([(1060, 1100), (1060, 1265), (50, 1265), (50, 370), (103, 370), (103, 397)], PK)
text(300, 1280, "branch_taken", PK, 11)
dot(880, 1265, PK)
wire([(880, 1265), (880, 1300)], PK)
text(884, 1292, "branch_taken", PK, 10)

# hazard_unit
box(560, 1300, 360, 140, "hazard_unit (13)", OR,
    ["load_use, load antes de salto, HALT (ecuaciones abajo)",
     "salidas ← pc_write_en, if_id_write_en, if_id_flush",
     "        → id_ex_bubble"])
stub_in(620, 1300, "rs, uses_rs, is_*", BL, side="top", length=12)
stub_in(790, 1300, "rd, mem_read @EX/@MEM", OR, side="top", length=12)
# salidas
wire([(560, 1375), (140, 1375), (140, 342), (181, 342)], OR)
text(150, 1370, "pc_write_en (hazard)", OR, 10)
wire([(560, 1395), (478, 1395), (478, 132), (X_IFID + 28, 132)], OR)
text(474, 1391, "if_id_write_en", OR, 10, "end")
wire([(560, 1415), (490, 1415), (490, 1160), (X_IFID + 28, 1160)], PK)
text(486, 1411, "if_id_flush", PK, 10, "end")
wire([(920, 1400), (1300, 1400), (1300, 1170), (X_IDEX + 28, 1170)], OR)
text(1294, 1290, "bubble", OR, 10, "end")
text(930, 1394, "id_ex_bubble (= stall)", OR, 10)
# IF/ID: core_en también entra a la AND
wire([(X_IFID + 14, Y_EN), (X_IFID + 14, 120)], GR)

# ---------------------------------------------------------------- ID/EX
wire([(X_IDEX + 14, Y_EN), (X_IDEX + 14, LAT_Y0)], GR)
text(X_IDEX + 20, 146, "en", GR, 10)
latch(X_IDEX, LAT_Y0, LAT_Y1, "ID/EX", 10)

# ---------------------------------------------------------------- EX
XE = X_IDEX + 28
# forwarding EX: fuentes (naranja) dibujadas completas
mux(1330, 515, 30, 90, OR)   # fwd A
mux(1330, 625, 30, 90, OR)   # fwd B
wire([(XE, Y_RS1), (1330, Y_RS1)], WH)
wire([(XE, Y_RS2), (1330, 640)], WH)
stub_in(1345, 517, "fwd_a_ex", OR, side="top", length=14)
wire([(1345, 732), (1345, 712)], OR); text(1340, 746, "fwd_b_ex", OR, 11, "end")
# ex_mem_ex_result -> muxes EX (01)
wire([(2000, Y_RES), (2000, 300), (1295, 300), (1295, 665), (1330, 665)], OR)
wire([(1295, 568), (1330, 568)], OR); dot(1295, 568, OR)
text(1500, 296, "ex_mem_ex_result (desde EX/MEM) → muxes de EX (01)", OR, 11)
# wb_write_data -> muxes EX (10)
wire([(2440, 640), (2440, 280), (1312, 280), (1312, 685), (1330, 685)], OR)
wire([(1312, 588), (1330, 588)], OR); dot(1312, 588, OR)
text(1500, 276, "wb_write_data (desde WB) → muxes de EX (10)", OR, 11)
# alu_src_a
mux(1400, 540, 25, 60, BL)
wire([(1360, 560), (1400, 560)], WH)
text(1396, 594, "0", GY, 11, "end")
wire([(1412, Y_EX), (1412, 545)], BL); dot(1412, Y_EX, BL)
text(1416, 532, "alu_src_a", BL, 10)
wire([(1425, 570), (1580, 570)], WH)
# alu_src_b
mux(1400, 650, 25, 80, BL)
wire([(1360, 670), (1375, 670), (1400, 670)], WH); dot(1375, 670)
wire([(XE, Y_IMM), (1385, Y_IMM), (1385, 710), (1400, 710)], WH)
wire([(1440, Y_EX), (1440, 638), (1412, 638), (1412, 654)], BL); dot(1440, Y_EX, BL)
text(1444, 634, "alu_src_b", BL, 10)
# store data
wire([(1375, 670), (1375, Y_ST), (X_EXMEM, Y_ST)], WH)
text(1500, Y_ST - 6, "rs2 adelantado = dato del store", GY, 10)
# recorte del shift
box(1460, 670, 82, 42, "", WH)
text(1501, 687, "[4:0] si", WH, 10, "middle"); text(1501, 702, "shift", WH, 10, "middle")
wire([(1425, 690), (1460, 690)], WH)
wire([(1542, 690), (1580, 690)], WH)
# ALU
a(f'<polygon points="1580,520 1680,560 1680,720 1580,760 1580,665 1600,640 1580,615" fill="{TINT[WH]}" stroke="{WH}" stroke-width="1.8"/>')
text(1640, 645, "ALU", WH, 15, "middle", True); text(1640, 662, "(1)", GY, 11, "middle")
text(1640, 778, "zero, co: sin usar", GY, 10, "middle")
# alu_control
box(1560, 360, 140, 70, "alu_control (2)", BL, ["alu_op+funct3+[30]"], fs=12)
wire([(1600, Y_EX), (1600, 360)], BL); dot(1600, Y_EX, BL)
wire([(1710, Y_INS), (1710, 395), (1700, 395)], WH); dot(1710, Y_INS)
text(1714, 470, "funct3,", GY, 10); text(1714, 485, "bit 30", GY, 10)
wire([(1630, 430), (1630, 540)], BL)
text(1634, 452, "alu_ctrl", BL, 10)
dot(1630, 470, BL)
wire([(1630, 470), (1501, 470), (1501, 670)], BL)
text(1505, 490, "is_shift", BL, 10)
# pc+4 (link)
box(1740, 800, 70, 40, "pc+4", WH)
wire([(1770, Y_PC), (1770, 800)], WH); dot(1770, Y_PC)
wire([(1810, 820), (1835, 820), (1835, 680), (1850, 680)], WH)
# mux link
mux(1850, 600, 25, 100, BL)
wire([(1680, 640), (1850, 640)], WH)
text(1690, 634, "alu_result", GY, 10)
gate(1849, 560, "≥1", BL)
wire([(1862, Y_EX), (1862, 560)], BL); dot(1862, Y_EX, BL)
text(1866, 548, "is_jal | is_jalr", BL, 10)
wire([(1863, 584), (1863, 605)], BL)
wire([(1875, Y_EXRES), (X_EXMEM, Y_EXRES)], WH)
text(1880, Y_EXRES - 6, "ex_result", WH, 11)
# fin del grupo EX

# forwarding_unit
box(1320, 1300, 420, 140, "forwarding_unit (12)", OR,
    ["compara rs1/rs2 (ID y EX) con el rd de ID/EX, EX/MEM, MEM/WB", "(si reg_write y rd ≠ x0; gana el más reciente)",
     "hacia EX: EX/MEM > MEM/WB · hacia ID: EX > EX/MEM > MEM/WB",
     "salidas → fwd_a_ex, fwd_b_ex (EX) · fwd_a_id, fwd_b_id (ID)"])

# ---------------------------------------------------------------- EX/MEM
wire([(X_IDEX + 28, Y_WB), (X_EXMEM, Y_WB)], BL)
wire([(X_IDEX + 28, Y_M), (X_EXMEM, Y_M)], BL)
wire([(X_IDEX + 28, Y_EX), (1880, Y_EX)], BL, arrow=False)
wire([(X_IDEX + 28, Y_PC), (X_EXMEM, Y_PC)], WH)
wire([(X_IDEX + 28, Y_INS), (X_EXMEM, Y_INS)], WH)
wire([(X_EXMEM + 14, Y_EN), (X_EXMEM + 14, LAT_Y0)], GR)
text(X_EXMEM + 20, 146, "en", GR, 10)
latch(X_EXMEM, LAT_Y0, LAT_Y1, "EX/MEM", 11)

# ---------------------------------------------------------------- MEM
XM = X_EXMEM + 28
wire([(XM, Y_EXRES), (2000, Y_EXRES), (2040, Y_EXRES)], WH); dot(2000, Y_EXRES)
wire([(2000, Y_EXRES), (2000, Y_RES)], WH, arrow=False); dot(2000, Y_RES)
wire([(2000, Y_RES), (X_MEMWB, Y_RES)], WH)
text(2010, Y_RES - 6, "ex_mem_ex_result", WH, 10)
box(2040, 600, 150, 300, "dmem (8)", WH)
for i, t_ in enumerate(["lee siempre (async)", "sb/sh/sw: máscara", "lb/lh/lbu/lhu"]):
    text(2115, 740 + 15 * i, t_, GY, 11, "middle")
text(2046, 664, "addr", GY, 10)
wire([(XM, Y_ST), (2015, Y_ST), (2015, 800), (2040, 800)], WH); text(2046, 804, "wdata", GY, 10)
wire([(2025, Y_INS), (2025, 850), (2040, 850)], WH); dot(2025, Y_INS); text(2046, 854, "funct3", GY, 10)
gate(2066, 520, "&", BL)
wire([(2072, Y_M), (2072, 520)], BL); dot(2072, Y_M, BL)
text(2076, 506, "mem_write", BL, 10)
wire([(2094, Y_EN), (2094, 520)], GR)
wire([(2080, 544), (2080, 600)], BL)
text(2100, 540, "mem_store_en (480)", BL, 10)
wire([(2190, Y_RD), (X_MEMWB, Y_RD)], WH); text(2196, Y_RD - 6, "rdata", GY, 10)
wire([(2075, 926), (2075, 900)], GR); text(2075, 940, "carga ← debug_unit", GR, 10, "middle")
wire([(2165, 900), (2165, 944)], GR); text(2165, 958, "dbg → dump_unit", GR, 10, "middle")
wire([(XM, Y_M), (2140, Y_M)], BL, arrow=False)
text(2105, Y_M + 16, "mem_read → hazard", BL, 10)
# MEM/WB
wire([(XM, Y_WB), (X_MEMWB, Y_WB)], BL)
wire([(XM, Y_PC), (X_MEMWB, Y_PC)], WH)
wire([(XM, Y_INS), (X_MEMWB, Y_INS)], WH)
wire([(X_MEMWB + 14, Y_EN), (X_MEMWB + 14, LAT_Y0)], GR)
text(X_MEMWB + 20, 146, "en", GR, 10)
latch(X_MEMWB, LAT_Y0, LAT_Y1, "MEM/WB", 11)

# ---------------------------------------------------------------- WB
XW = X_MEMWB + 28
mux(2370, 560, 30, 160, BL)
text(2377, 584, "0", GY, 10); text(2377, 704, "1", GY, 10)
wire([(XW, Y_RES), (2370, Y_RES)], WH); text(2284, Y_RES - 6, "result", GY, 10)
wire([(XW, Y_RD), (2370, Y_RD)], WH); text(2284, Y_RD - 6, "mem_read_data", GY, 10)
wire([(2385, Y_WB), (2385, 568)], BL); dot(2385, Y_WB, BL)
text(2389, 556, "mem_to_reg", BL, 10)
wire([(2400, 640), (2440, 640)], WH, arrow=False); dot(2440, 640)
text(2446, 660, "wb_write_data", WH, 11)
# reg_write & core_en
gate(2555, 900, "&", BL)
wire([(2560, Y_WB), (2560, 900)], BL); dot(2560, Y_WB, BL)
wire([(2580, Y_EN), (2580, 900)], GR)
text(2569, 944, "wb_reg_write (537)", BL, 10, "middle")
# escritura en el banco: vuelve hasta ID
wire([(2440, 640), (2440, Y_WBK), (530, Y_WBK), (530, 690), (580, 690)], WH, w=2)
wire([(2569, 924), (2569, Y_WBK), (2440, Y_WBK)], BL, arrow=False); dot(2440, Y_WBK)
wire([(XW, Y_INS), (2300, Y_INS), (2300, Y_WBK)], WH, arrow=False); dot(2300, Y_WBK)
text(2306, Y_INS - 6, "rd = instr[11:7]", GY, 10)
text(1100, Y_WBK - 8, "escritura en el banco: rd, wb_write_data, wb_reg_write  (vuelve de WB a ID)", WH, 12)
# is_halt -> core_halted
wire([(XW, Y_WB), (2610, Y_WB)], BL, arrow=False)
text(2615, Y_WB - 10, "is_halt →", GR, 10)
text(2615, Y_WB + 4, "core_halted_o", GR, 10)
text(2615, Y_WB + 18, "(538)", GR, 10)
stub_out(XW, Y_PC, "pc (debug)", GY, length=16)

# ---------------------------------------------------------------- debug (verde)
box(1790, 1300, 470, 140, "Debug Unit ↔ core", GR,
    ["entra: global_stall_i (→ core_en), carga imem/dmem, soft-reset",
     "sale a la Dump Unit: if_pc/if_instr, 4 latches, regs_flat,",
     "cycle_count, STATUS (halted, taken, pc_we, stall, fwd_sel),",
     "dmem por el puerto dbg"])

# ---------------------------------------------------------------- ecuaciones + leyenda
box(24, 1510, 1150, 180, "ECUACIONES (hazard_unit.v:73-93, riscv_core.v:146-150)", OR, fs=13)
eqs = [
    ("load_use   = mem_read@EX · rd@EX≠0 · ((uses_rs1 · rd@EX=rs1) + (uses_rs2 · rd@EX=rs2))", OR),
    ("load_salto = (is_branch + is_jalr) · (load_use + [mem_read@MEM · rd@MEM≠0 · rd@MEM=rs usado])", OR),
    ("stall      = load_use + load_salto      →  id_ex_bubble = stall", OR),
    ("if_id_flush = branch_taken · ~stall", PK),
    ("pc_write_en = if_id_write_en = ~(stall + is_halt) · core_en", GR),
    ("core_en = ~global_stall_i   (la Debug Unit congela todo el core)", GR),
]
for i, (s, c) in enumerate(eqs):
    text(40, 1556 + 22 * i, s, c, 13, mono=True)

lx = 1220
text(lx, 1530, "LEYENDA", WH, 13, bold=True)
leg = [(WH, "datapath (datos que avanzan, y la escritura que vuelve de WB)"),
       (BL, "señales de control (control_unit → latches → etapa que las usa)"),
       (OR, "riesgos de datos: forwarding y stall/burbuja"),
       (PK, "riesgos de control: salto (destino, taken) y flush"),
       (GR, "Debug Unit: core_en (congelar), carga, salidas de debug")]
for i, (c, s) in enumerate(leg):
    y = 1556 + 22 * i
    wire([(lx, y - 4), (lx + 40, y - 4)], c)
    text(lx + 50, y, s, c, 12)
text(lx, 1700, "etiqueta con flecha corta = la señal llega desde el módulo nombrado (el cable no se dibuja entero) · ● = bifurcación · (n) en latches/módulos = parada", GY, 11)

a("</svg>")
open(OUT, "w", encoding="utf-8").write("\n".join(out))
print("ok", OUT, len(out), "elementos")

# ---------------------------------------------------------------- PDF (--pdf)
# Imprime el SVG a PDF (vectorial, A3 apaisado) con Edge o Chrome headless.
if "--pdf" in sys.argv:
    pdf = OUT[:-4] + ".pdf"
    cands = [shutil.which(n) for n in ("msedge", "chrome", "google-chrome", "chromium")]
    cands += [r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
              r"C:\Program Files\Google\Chrome\Application\chrome.exe"]
    browser = next((c for c in cands if c and os.path.exists(c)), None)
    if browser is None:
        sys.exit("--pdf: no encontré Edge ni Chrome")
    page = ("<!doctype html><html><head><meta charset='utf-8'>"
            "<title>RISC-V core (TP3): datapath y control</title><style>"
            "@page { size: A3 landscape; margin: 8mm; }"
            "html, body { margin: 0; } body { height: 278mm; display: flex; align-items: center; }"
            "svg { display: block; width: 100%; height: auto; }"
            "</style></head><body>" + "\n".join(out) + "</body></html>")
    with tempfile.TemporaryDirectory() as tmp:
        html = os.path.join(tmp, "datapath.html")
        open(html, "w", encoding="utf-8").write(page)
        if os.path.exists(pdf):
            os.remove(pdf)
        subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        f"--user-data-dir={os.path.join(tmp, 'perfil')}",
                        f"--print-to-pdf={pdf}", "file:///" + html.replace(os.sep, "/")],
                       check=True, timeout=120, capture_output=True)
    if not os.path.exists(pdf):
        sys.exit("--pdf: el navegador no generó el PDF")
    print("ok", pdf)
