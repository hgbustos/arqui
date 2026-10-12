# ============================================================================
# riscv_uart_top - Constraints para Digilent Basys 3
#
# Pines tomados del "Basys 3 Reference Manual" / Master XDC de Digilent,
# mapeados a los nombres de puerto del top de síntesis, riscv_fpga_top.v
# (tp3/rtl/fpga/): clk_i, rst_i, rx_i, tx_o, seg_o/dp_o/an_o. Mismos pines
# físicos que tp2/constraints/uart_alu_top.xdc para el clock, el botón de
# reset y el conector UART-USB. A diferencia de TP2, los switches SW0/SW1
# ya no se usan: el baud rate está fijo en 115200 (parámetro BAUD_RATE de
# riscv_fpga_top.v).
# ============================================================================

# 0. Voltaje de la bank de configuracion (bank 0) -- sin esto Vivado tira
# el warning CFGBVS-1 en cada implementacion. Basys3 alimenta bank 0 a
# 3.3V desde VCCO de la placa.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# 1. Clock: oscilador de 100 MHz de la placa, que entra al Clock Wizard
#    (clk_wiz_0, en riscv_fpga_top.v). Acá sólo va el pin: el período del
#    clock de entrada lo declara el propio IP en su .xdc (100 MHz, más el
#    jitter del oscilador), y a partir de él Vivado deriva solo el clock de
#    salida que usa todo el diseño (clk_out1_clk_wiz_0). Declararlo también
#    acá con create_clock pisaba el del IP: Vivado avisaba con critical
#    warnings (Constraints 18-1055/18-1056, XDCC-7) y descartaba las
#    constraints del IP que se refieren a ese clock, como el jitter.
set_property PACKAGE_PIN W5 [get_ports clk_i]
set_property IOSTANDARD LVCMOS33 [get_ports clk_i]

# 2. Reset (BTN_CENTER, activo en alto)
set_property PACKAGE_PIN U18 [get_ports rst_i]
set_property IOSTANDARD LVCMOS33 [get_ports rst_i]

# 3. Interfaz UART (puente USB-Serial FTDI ya integrado en la placa)
set_property PACKAGE_PIN B18 [get_ports rx_i]
set_property PACKAGE_PIN A18 [get_ports tx_o]
set_property IOSTANDARD LVCMOS33 [get_ports {rx_i tx_o}]

# 4. Display de 7 segmentos (ánodo común, todo activo en bajo): lo maneja
# el panel de la placa (tp3/rtl/fpga/panel_basys3.v). an_o[0] es el dígito
# de la derecha.
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

# 5. LEDs LD0..LD15 (led_o[0] = LD0, el de la derecha): espejo de los
# riesgos del ciclo actual, ver panel_basys3.v. Mismos pines que usó TP1
# (constraints.xdc de la raíz) para LD0..LD9.
set_property PACKAGE_PIN U16 [get_ports {led_o[0]}]
set_property PACKAGE_PIN E19 [get_ports {led_o[1]}]
set_property PACKAGE_PIN U19 [get_ports {led_o[2]}]
set_property PACKAGE_PIN V19 [get_ports {led_o[3]}]
set_property PACKAGE_PIN W18 [get_ports {led_o[4]}]
set_property PACKAGE_PIN U15 [get_ports {led_o[5]}]
set_property PACKAGE_PIN U14 [get_ports {led_o[6]}]
set_property PACKAGE_PIN V14 [get_ports {led_o[7]}]
set_property PACKAGE_PIN V13 [get_ports {led_o[8]}]
set_property PACKAGE_PIN V3  [get_ports {led_o[9]}]
set_property PACKAGE_PIN W3  [get_ports {led_o[10]}]
set_property PACKAGE_PIN U3  [get_ports {led_o[11]}]
set_property PACKAGE_PIN P3  [get_ports {led_o[12]}]
set_property PACKAGE_PIN N3  [get_ports {led_o[13]}]
set_property PACKAGE_PIN P1  [get_ports {led_o[14]}]
set_property PACKAGE_PIN L1  [get_ports {led_o[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led_o[*]}]

# 6. Entradas y salidas asíncronas: ninguna tiene relación de fase con el
# clock del diseño, así que no hay un requisito de timing que verificar
# (set_input_delay/set_output_delay no tienen sentido acá). Lo que las hace
# seguras es el diseño, no el análisis de timing:
#   - rx_i pasa por un sincronizador de 2 flip-flops en uart_rx.v.
#   - rst_i se activa asíncrono y se libera sincronizado (riscv_uart_top.v).
#   - tx_o es una línea serie que la PC muestrea a su propio ritmo.
#   - El display y los LEDs los mira una persona: cambian a lo sumo una vez
#     por milisegundo (el refresco del display) o por cada Step.
# Sin esto, Vivado las reporta como entradas/salidas sin constraint
# (aviso TIMING-18 del reporte de metodología).
set_false_path -from [get_ports {rst_i rx_i}]
set_false_path -to [get_ports {tx_o seg_o[*] dp_o an_o[*] led_o[*]}]
