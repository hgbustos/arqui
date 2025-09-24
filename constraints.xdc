# =============================================================================
# Archivo de Constraints (XDC) para el proyecto ALU en la placa Basys 3
#
# Descripción:
# Este archivo mapea los puertos del módulo Verilog 'ALU_top' a los pines
# físicos del chip Artix-7 en la placa Basys 3. También define el estándar
# de voltaje y la temporización del reloj principal.
# =============================================================================

# --- Reloj del Sistema ---
# Conecta el puerto 'clk_i' al oscilador de 100MHz de la placa.
set_property PACKAGE_PIN W5 [get_ports clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_i]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports clk_i]

# --- Switches (sw_i[7:0]) ---
# Se utilizan los 8 switches del lado derecho (SW0 a SW7).
set_property PACKAGE_PIN V17 [get_ports {sw_i[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[0]}]
set_property PACKAGE_PIN V16 [get_ports {sw_i[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[1]}]
set_property PACKAGE_PIN W16 [get_ports {sw_i[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[2]}]
set_property PACKAGE_PIN W17 [get_ports {sw_i[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[3]}]
set_property PACKAGE_PIN W15 [get_ports {sw_i[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[4]}]
set_property PACKAGE_PIN V15 [get_ports {sw_i[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[5]}]
set_property PACKAGE_PIN W14 [get_ports {sw_i[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[6]}]
set_property PACKAGE_PIN W13 [get_ports {sw_i[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {sw_i[7]}]

# --- Botones ---
# Mapeo de funciones a los botones físicos de la placa.
# BTNC (Centro)      -> Reset
# BTNL (Izquierda)   -> Cargar Operando A
# BTNR (Derecha)     -> Cargar Operando B
# BTNU (Arriba)      -> Cargar Opcode
set_property PACKAGE_PIN U18 [get_ports rst_i]
set_property IOSTANDARD LVCMOS33 [get_ports rst_i]
set_property PACKAGE_PIN T17 [get_ports btn_load_b_i]
set_property IOSTANDARD LVCMOS33 [get_ports btn_load_b_i]
set_property PACKAGE_PIN W19 [get_ports btn_load_a_i]
set_property IOSTANDARD LVCMOS33 [get_ports btn_load_a_i]
set_property PACKAGE_PIN T18 [get_ports btn_load_op_i]
set_property IOSTANDARD LVCMOS33 [get_ports btn_load_op_i]

# --- LEDs (led_o[9:0]) ---
# Mapeo de las salidas de la ALU a los LEDs.
# led_o[7:0] -> Resultado de 8 bits
# led_o[8]   -> Flag Zero
# led_o[9]   -> Flag Carry
set_property PACKAGE_PIN U16 [get_ports {led_o[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[0]}]
set_property PACKAGE_PIN E19 [get_ports {led_o[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[1]}]
set_property PACKAGE_PIN U19 [get_ports {led_o[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[2]}]
set_property PACKAGE_PIN V19 [get_ports {led_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[3]}]
set_property PACKAGE_PIN W18 [get_ports {led_o[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[4]}]
set_property PACKAGE_PIN U15 [get_ports {led_o[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[5]}]
set_property PACKAGE_PIN U14 [get_ports {led_o[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[6]}]
set_property PACKAGE_PIN V14 [get_ports {led_o[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[7]}]
set_property PACKAGE_PIN V13 [get_ports {led_o[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[8]}]
set_property PACKAGE_PIN V3 [get_ports {led_o[9]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[9]}]