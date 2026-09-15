# ============================================================================
# riscv_uart_top - Constraints para Digilent Basys 3
#
# Pines tomados del "Basys 3 Reference Manual" / Master XDC de Digilent,
# mapeados a los nombres de puerto de riscv_uart_top.v. Misma placa y
# mismos pines físicos que tp2/constraints/uart_alu_top.xdc (el conector
# UART-USB, el botón de reset y los switches de baud rate no cambiaron
# entre TP2 y TP3) porque riscv_uart_top.v expone exactamente la misma
# interfaz externa que uart_alu_top.v: clk_i, rst_i, rx_i, baud_sel_i,
# tx_o, seg_o/dp_o/an_o.
#
# baud_sel_i[0] -> SW0 (V17, bit menos significativo)
# baud_sel_i[1] -> SW1 (V16)
# Tabla de presets (igual que TP2):
#   00 (todo abajo)       -> BAUD_RATE0 = 9600
#   01 (SW0 arriba)       -> BAUD_RATE1 = 19200
#   10 (SW1 arriba)       -> BAUD_RATE2 = 57600
#   11 (SW0 y SW1 arriba) -> BAUD_RATE3 = 115200
# ============================================================================

# 0. Voltaje de la bank de configuracion (bank 0) -- sin esto Vivado tira
# el warning CFGBVS-1 en cada implementacion. Basys3 alimenta bank 0 a
# 3.3V desde VCCO de la placa.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# 1. Clock del sistema: 100 MHz (coincide con CLK_FREQ=100_000_000 por
#    default en riscv_uart_top.v)
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

# 5. Display de 7 segmentos: sin uso en este TP, apagado explícitamente
# desde riscv_uart_top.v (assign seg_o=7'b1111111, dp_o=1'b1, an_o=4'b1111)
# para que no quede flotando a media intensidad.
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
