// =============================================================================
// Módulo:         riscv_fpga_top
//
// Descripción:
// Top SÓLO para síntesis (Basys 3): el Clock Wizard de Vivado (IP
// 'clk_wiz_0') genera el clock del sistema a partir del oscilador de 100MHz
// de la placa y se lo da a riscv_uart_top, que queda exactamente igual (es
// el top que simulan los testbenches). Acá van las decisiones propias de la
// placa: la frecuencia del clock, el baud rate fijo de la UART y el panel
// (panel_basys3.v), que muestra en el display de 7 segmentos y en los LEDs
// lo que hace el núcleo, sincronizado con la GUI.
//
// Por qué un clock derivado: a 100MHz el diseño no cierra timing (camino
// crítico medido de ~13.6ns, ver tp3/informe.md §3.8). El enunciado pide no
// intervenir el clock, así que no se lo divide con un contador propio ni se
// lo gatea: el Clock Wizard configura un MMCM, el bloque dedicado del FPGA
// para sintetizar frecuencias, y su salida entra a la red global de clock
// (BUFG) igual que el oscilador original.
//
// Por qué 65MHz: se implementó el diseño a 50, 60, 65, 70 y 75MHz. Cierra
// timing sin excepciones hasta 65MHz; a 70MHz sólo falla la captura de
// STATUS en la Dump Unit (que en la práctica toma el valor con el núcleo
// congelado), y a 75MHz ya falla un camino del propio núcleo (IF/ID), así
// que su límite está cerca de 72MHz. 65MHz además deja el baud rate de la
// UART cerca del nominal (+0.76% a 115200; la división del generador de
// baudios es entera).
//
// Dos cosas tienen que acompañar a la frecuencia:
//   - CLK_FREQ de riscv_uart_top tiene que ser la frecuencia REAL del clock
//     que recibe: el generador de baudios calcula su divisor con ella (con
//     el valor de 100MHz la UART transmitiría a la mitad del baud rate y la
//     PC no la entendería). Para cambiar la frecuencia hay que cambiar las
//     dos cosas: el Clock Wizard (clk_wiz_0 en el proyecto de Vivado,
//     tp3/synt/riscv-fpga) y este parámetro.
//   - Mientras el MMCM no engancha ('locked'=0) su salida no es confiable:
//     el diseño se mantiene en reset ('rst_i | ~locked'), y el sincronizador
//     de reset de riscv_uart_top lo libera alineado al clock nuevo.
//
// Baud rate fijo (BAUD_RATE, 115200 por defecto): en TP2 la UART era el
// objeto del trabajo y el baud rate se elegía en runtime con los switches
// SW0/SW1; en TP3 es sólo el canal hacia la PC, así que la placa ya no
// depende de la posición de ningún switch. riscv_uart_top conserva su
// selector de 4 presets (los testbenches lo usan para simular rápido): acá
// se carga BAUD_RATE en el preset 3 y el selector se ata a ese preset, así
// que Vivado elimina el resto de la lógica de selección al propagar la
// constante. Para cambiarlo alcanza con este parámetro (más resintetizar);
// la PC tiene que usar el mismo valor (--baud en la CLI, selector en la GUI).
//
// Vive en rtl/fpga/ (no en rtl/debug/) porque instancia un IP de Vivado que
// Icarus Verilog no conoce: así los comandos de simulación que compilan
// rtl/debug/*.v siguen andando sin cambios. Sus pines están en
// tp3/constraints/riscv_uart_top.xdc.
// =============================================================================
module riscv_fpga_top #(
    // Salida del Clock Wizard, en Hz. TIENE que coincidir con la
    // configuración del IP (clk_out1 = 65 MHz): Vivado no puede verificarlo,
    // y si no coinciden la UART transmite a otro baud rate.
    parameter CLK_FREQ  = 65_000_000,
    // Baud rate de la UART, fijo (ver header). La PC tiene que usar el mismo.
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk_i,        // oscilador de 100MHz de la placa
    input  wire       rst_i,
    input  wire       rx_i,
    output wire       tx_o,
    output wire [6:0]  seg_o,
    output wire        dp_o,
    output wire [3:0]  an_o,
    output wire [15:0] led_o
);

    wire clk_sys;
    wire locked;

    // Señales que riscv_uart_top expone para el panel
    wire        p_rst, p_core_stall, p_core_halted, p_soft_reset;
    wire        p_hazard_stall, p_branch_taken;
    wire [7:0]  p_fwd_sel;
    wire [31:0] p_if_id_instr, p_id_ex_instr, p_cycle_count;

    clk_wiz_0 u_clk_wiz (
        .clk_in1  (clk_i),
        .clk_out1 (clk_sys),
        .locked   (locked)
    );

    // BAUD_RATE va al preset 3 y el selector queda atado a ese preset.
    riscv_uart_top #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE3 (BAUD_RATE)
    ) u_top (
        .clk_i      (clk_sys),
        .rst_i      (rst_i | ~locked),
        .rx_i       (rx_i),
        .baud_sel_i (2'b11),
        .tx_o       (tx_o),
        .panel_rst_o          (p_rst),
        .panel_core_stall_o   (p_core_stall),
        .panel_core_halted_o  (p_core_halted),
        .panel_soft_reset_o   (p_soft_reset),
        .panel_hazard_stall_o (p_hazard_stall),
        .panel_branch_taken_o (p_branch_taken),
        .panel_fwd_sel_o      (p_fwd_sel),
        .panel_if_id_instr_o  (p_if_id_instr),
        .panel_id_ex_instr_o  (p_id_ex_instr),
        .panel_cycle_count_o  (p_cycle_count)
    );

    // Panel de la placa: sólo observa, nunca maneja al núcleo.
    panel_basys3 #(
        .CLK_FREQ (CLK_FREQ)
    ) u_panel (
        .clk_i             (clk_sys),
        .rst_i             (p_rst),
        .core_stall_i      (p_core_stall),
        .core_halted_i     (p_core_halted),
        .core_soft_reset_i (p_soft_reset),
        .hazard_stall_i    (p_hazard_stall),
        .branch_taken_i    (p_branch_taken),
        .fwd_sel_i         (p_fwd_sel),
        .if_id_instr_i     (p_if_id_instr),
        .id_ex_instr_i     (p_id_ex_instr),
        .cycle_count_i     (p_cycle_count),
        .seg_o             (seg_o),
        .dp_o              (dp_o),
        .an_o              (an_o),
        .led_o             (led_o)
    );

endmodule
