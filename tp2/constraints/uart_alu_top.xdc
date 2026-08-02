# ============================================================================
# uart_alu_top - Constraints para Digilent Basys 3
#
# Pines tomados del "Basys 3 Reference Manual" / Master XDC de Digilent,
# mapeados a los nombres de puerto de nuestro uart_alu_top.v.
#
# baud_sel_i[0] -> SW0 (V17, bit menos significativo)
# baud_sel_i[1] -> SW1 (V16)
# Para reproducir el baud rate que se usaba antes como unico valor fijo
# (BAUD_RATE1=19200, baud_sel_i=2'b01): SW0 en alto, SW1 (y el resto) en
# bajo. Ir cambiando switches despues para probar los otros presets:
#   00 (todo abajo)      -> BAUD_RATE0 = 9600
#   01 (SW0 arriba)      -> BAUD_RATE1 = 19200
#   10 (SW1 arriba)      -> BAUD_RATE2 = 57600
#   11 (SW0 y SW1 arriba) -> BAUD_RATE3 = 115200
# ============================================================================

# 1. Clock del sistema: 100 MHz
set_property PACKAGE_PIN W5 [get_ports clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_i]
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports clk_i]

# 2. Reset (BTN_CENTER, activo en alto)
set_property PACKAGE_PIN U18 [get_ports rst_i]
set_property IOSTANDARD LVCMOS33 [get_ports rst_i]

# 3. Interfaz UART (puente USB-Serial FTDI ya integrado en la placa)
set_property PACKAGE_PIN B18 [get_ports rx_i]
set_property PACKAGE_PIN A18 [get_ports tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports {rx_i tx_o}]

# 4. Selector de baud rate en runtime (SW0, SW1)
set_property PACKAGE_PIN V17 [get_ports {baud_sel_i[0]}]
set_property PACKAGE_PIN V16 [get_ports {baud_sel_i[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {baud_sel_i[*]}]

# 5. Display de 7 segmentos: no lo usa este TP, se apaga explicitamente
# desde uart_alu_top.v (ver assign de seg_o/dp_o/an_o) para que no quede
# flotando a media intensidad.
set_property PACKAGE_PIN W7 [get_ports {seg_o[0]}]
set_property PACKAGE_PIN W6 [get_ports {seg_o[1]}]
set_property PACKAGE_PIN U8 [get_ports {seg_o[2]}]
set_property PACKAGE_PIN V8 [get_ports {seg_o[3]}]
set_property PACKAGE_PIN U5 [get_ports {seg_o[4]}]
set_property PACKAGE_PIN V5 [get_ports {seg_o[5]}]
set_property PACKAGE_PIN U7 [get_ports {seg_o[6]}]
set_property PACKAGE_PIN V7 [get_ports dp_o]
set_property PACKAGE_PIN U2 [get_ports {an_o[0]}]
set_property PACKAGE_PIN U4 [get_ports {an_o[1]}]
set_property PACKAGE_PIN V4 [get_ports {an_o[2]}]
set_property PACKAGE_PIN W4 [get_ports {an_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {seg_o[*] dp_o an_o[*]}]
