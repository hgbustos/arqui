// =============================================================================
// Módulo:         riscv_uart_top
//
// Descripción:
// Top de TP3: equivalente a tp2/rtl/uart_alu_top.v pero con el pipeline
// RISC-V completo (riscv_core.v) y su Debug Unit en vez de la ALU y
// alu_link.v. Integra:
//
//   Baud Rate Generator + uart_rx + uart_tx + uart_interface -> reutilizados
//   SIN MODIFICAR de tp2/rtl/ (referenciados directo, no copiados: un solo
//   source of truth, mismo criterio que ya usa TP2 con tp1/ALU.v).
//   debug_unit.v  -> lado Rx del Interface Circuit (comandos + carga).
//   dump_unit.v   -> lado Tx del Interface Circuit (volcado de estado).
//   riscv_core.v  -> el pipeline en sí.
//
// Reset: 'rst_i' (físico, botón de la placa) resetea la UART, debug_unit y
// dump_unit directamente. riscv_core.v en cambio recibe 'core_rst' = 'rst_i'
// OR 'core_soft_reset' (generado por debug_unit en cada CMD_LOAD_*/
// CMD_RESET) -- debug_unit/dump_unit NUNCA deben resetearse a sí mismos
// con la señal que ellos mismos generan para resetear al core (si no,
// debug_unit perdería su propio estado de FSM a mitad de una carga). Ni
// acá ni en ningún lado de este árbol se gatea el clock: todo control de
// flujo es reset síncrono o enable, tal como pide el enunciado.
//
// Único punto de entrada/salida físico: 'rx_i'/'tx_o' (además de clock,
// reset y 'baud_sel_i', igual que uart_alu_top.v). CLK_FREQ=100MHz por
// default (frecuencia real del oscilador de la Basys3). 'DMEM_DEPTH_WORDS'
// default en 256 (no el 1024 de riscv_core.v) a propósito: mantiene cada
// volcado completo en ~100ms a 115200 baudios en vez de ~375ms -- ver
// tp3/docs/debug_protocol.md, sección de ancho de banda.
// =============================================================================
module riscv_uart_top #(
    parameter IMEM_DEPTH_WORDS = 1024,
    parameter DMEM_DEPTH_WORDS = 256,
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD_RATE0 = 9_600,
    parameter BAUD_RATE1 = 19_200,
    parameter BAUD_RATE2 = 57_600,
    parameter BAUD_RATE3 = 115_200,
    parameter SB_TICKS   = 16
)(
    input  wire       clk_i,
    input  wire       rst_i,
    input  wire       rx_i,
    input  wire [1:0] baud_sel_i,
    output wire       tx_o,

    // Display de 7 segmentos: sin uso en este TP, apagado explícitamente
    // (mismo motivo que uart_alu_top.v: comparte banco de pines en la
    // Basys3 con otras señales, dejarlo flotante se ve "medio prendido").
    output wire [6:0] seg_o,
    output wire       dp_o,
    output wire [3:0] an_o
);

    assign seg_o = 7'b1111111;
    assign dp_o  = 1'b1;
    assign an_o  = 4'b1111;

    // --- Base de tiempos ---
    wire s_tick;
    baud_rate_generator #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3),
        .OVERSAMPLE (16)
    ) u_baud_gen (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .baud_sel_i (baud_sel_i),
        .tick_o     (s_tick)
    );

    // --- Receptor UART ---
    wire [7:0] rx_dout;
    wire       rx_done_tick;
    uart_rx #(
        .DBIT     (8),
        .SB_TICKS (SB_TICKS)
    ) u_uart_rx (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .rx_i           (rx_i),
        .s_tick_i       (s_tick),
        .dout_o         (rx_dout),
        .rx_done_tick_o (rx_done_tick)
    );

    // --- Transmisor UART ---
    wire       tx_start;
    wire [7:0] tx_din;
    wire       tx_done_tick;
    uart_tx #(
        .DBIT     (8),
        .SB_TICKS (SB_TICKS)
    ) u_uart_tx (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .tx_start_i     (tx_start),
        .s_tick_i       (s_tick),
        .din_i          (tx_din),
        .tx_done_tick_o (tx_done_tick),
        .tx_o           (tx_o)
    );

    // --- Interface Circuit ---
    wire [7:0] r_data;
    wire       rx_empty;
    wire       rd;
    wire [7:0] w_data;
    wire       tx_full;
    wire       wr;
    uart_interface #(
        .DBIT (8)
    ) u_interface (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .rx_dout_i      (rx_dout),
        .rx_done_tick_i (rx_done_tick),
        .tx_done_tick_i (tx_done_tick),
        .tx_start_o     (tx_start),
        .din_o          (tx_din),
        .r_data_o       (r_data),
        .rx_empty_o     (rx_empty),
        .rd_i           (rd),
        .w_data_i       (w_data),
        .tx_full_o      (tx_full),
        .wr_i           (wr)
    );

    // --- Reset combinado hacia el core (nunca hacia debug_unit/dump_unit) ---
    wire core_soft_reset;
    wire core_rst = rst_i | core_soft_reset;

    // --- Señales de carga (Debug Unit -> riscv_core) ---
    wire         imem_load_en, imem_load_clear, imem_load_clear_busy;
    wire [31:0]  imem_load_addr, imem_load_data;
    wire         dmem_load_en, dmem_load_clear, dmem_load_clear_busy;
    wire [31:0]  dmem_load_addr, dmem_load_data;

    // --- Control de ejecución (Debug Unit -> riscv_core) ---
    wire core_stall;
    wire core_halted;

    // --- Debug: latches + registros (riscv_core -> Dump Unit) ---
    wire [32*32-1:0] regs_flat;
    wire             branch_taken;
    wire             pc_write_en;
    wire [31:0]      cycle_count;

    wire [31:0] if_id_pc, if_id_instr;

    wire [31:0] id_ex_pc, id_ex_instr, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    wire id_ex_reg_write, id_ex_mem_read, id_ex_mem_write, id_ex_mem_to_reg,
         id_ex_is_jal, id_ex_is_jalr, id_ex_is_halt;

    wire [31:0] ex_mem_pc, ex_mem_instr, ex_mem_ex_result, ex_mem_rs2_data;
    wire ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write, ex_mem_mem_to_reg, ex_mem_is_halt;

    wire [31:0] mem_wb_pc, mem_wb_instr, mem_wb_result, mem_wb_mem_read_data;
    wire mem_wb_reg_write, mem_wb_mem_to_reg, mem_wb_is_halt;

    // --- Lectura de debug de dmem (riscv_core <-> Dump Unit) ---
    wire [31:0] dmem_dbg_addr;
    wire [31:0] dmem_dbg_rdata;

    // --- Trigger/done del volcado (Debug Unit <-> Dump Unit) ---
    wire dump_trigger, dump_done;

    debug_unit u_debug (
        .clk_i(clk_i), .rst_i(rst_i), // reset FISICO: ver header
        .r_data_i(r_data), .rx_empty_i(rx_empty), .rd_o(rd),
        .imem_load_en_o(imem_load_en), .imem_load_addr_o(imem_load_addr),
        .imem_load_data_o(imem_load_data), .imem_load_clear_o(imem_load_clear),
        .imem_clear_busy_i(imem_load_clear_busy),
        .dmem_load_en_o(dmem_load_en), .dmem_load_addr_o(dmem_load_addr),
        .dmem_load_data_o(dmem_load_data), .dmem_load_clear_o(dmem_load_clear),
        .dmem_clear_busy_i(dmem_load_clear_busy),
        .core_soft_reset_o(core_soft_reset), .core_stall_o(core_stall),
        .core_halted_i(core_halted),
        .dump_trigger_o(dump_trigger), .dump_done_i(dump_done)
    );

    riscv_core #(
        .IMEM_DEPTH_WORDS(IMEM_DEPTH_WORDS),
        .DMEM_DEPTH_WORDS(DMEM_DEPTH_WORDS)
    ) u_core (
        .clk_i(clk_i), .rst_i(core_rst), .global_stall_i(core_stall),
        .imem_load_en_i(imem_load_en), .imem_load_addr_i(imem_load_addr),
        .imem_load_data_i(imem_load_data), .imem_load_clear_i(imem_load_clear),
        .imem_load_clear_busy_o(imem_load_clear_busy),
        .dmem_load_en_i(dmem_load_en), .dmem_load_addr_i(dmem_load_addr),
        .dmem_load_data_i(dmem_load_data), .dmem_load_clear_i(dmem_load_clear),
        .dmem_load_clear_busy_o(dmem_load_clear_busy),
        .dmem_dbg_addr_i(dmem_dbg_addr), .dmem_dbg_rdata_o(dmem_dbg_rdata),
        .regs_flat_o(regs_flat), .core_halted_o(core_halted),
        .branch_taken_o(branch_taken), .pc_write_en_o(pc_write_en),
        .cycle_count_o(cycle_count),
        .if_id_pc_o(if_id_pc), .if_id_instr_o(if_id_instr),
        .id_ex_pc_o(id_ex_pc), .id_ex_instr_o(id_ex_instr),
        .id_ex_rs1_data_o(id_ex_rs1_data), .id_ex_rs2_data_o(id_ex_rs2_data), .id_ex_imm_o(id_ex_imm),
        .id_ex_reg_write_o(id_ex_reg_write), .id_ex_mem_read_o(id_ex_mem_read),
        .id_ex_mem_write_o(id_ex_mem_write), .id_ex_mem_to_reg_o(id_ex_mem_to_reg),
        .id_ex_is_jal_o(id_ex_is_jal), .id_ex_is_jalr_o(id_ex_is_jalr), .id_ex_is_halt_o(id_ex_is_halt),
        .ex_mem_pc_o(ex_mem_pc), .ex_mem_instr_o(ex_mem_instr),
        .ex_mem_ex_result_o(ex_mem_ex_result), .ex_mem_rs2_data_o(ex_mem_rs2_data),
        .ex_mem_reg_write_o(ex_mem_reg_write), .ex_mem_mem_read_o(ex_mem_mem_read),
        .ex_mem_mem_write_o(ex_mem_mem_write), .ex_mem_mem_to_reg_o(ex_mem_mem_to_reg),
        .ex_mem_is_halt_o(ex_mem_is_halt),
        .mem_wb_pc_o(mem_wb_pc), .mem_wb_instr_o(mem_wb_instr),
        .mem_wb_result_o(mem_wb_result), .mem_wb_mem_read_data_o(mem_wb_mem_read_data),
        .mem_wb_reg_write_o(mem_wb_reg_write), .mem_wb_mem_to_reg_o(mem_wb_mem_to_reg),
        .mem_wb_is_halt_o(mem_wb_is_halt)
    );

    dump_unit #(
        .DMEM_DEPTH_WORDS(DMEM_DEPTH_WORDS)
    ) u_dump (
        .clk_i(clk_i), .rst_i(rst_i), // reset FISICO: ver header
        .dump_trigger_i(dump_trigger), .dump_done_o(dump_done),
        .core_halted_i(core_halted), .branch_taken_i(branch_taken), .pc_write_en_i(pc_write_en),
        .cycle_count_i(cycle_count),
        .if_id_pc_i(if_id_pc), .if_id_instr_i(if_id_instr),
        .id_ex_pc_i(id_ex_pc), .id_ex_instr_i(id_ex_instr),
        .id_ex_rs1_data_i(id_ex_rs1_data), .id_ex_rs2_data_i(id_ex_rs2_data), .id_ex_imm_i(id_ex_imm),
        .id_ex_reg_write_i(id_ex_reg_write), .id_ex_mem_read_i(id_ex_mem_read),
        .id_ex_mem_write_i(id_ex_mem_write), .id_ex_mem_to_reg_i(id_ex_mem_to_reg),
        .id_ex_is_jal_i(id_ex_is_jal), .id_ex_is_jalr_i(id_ex_is_jalr), .id_ex_is_halt_i(id_ex_is_halt),
        .ex_mem_pc_i(ex_mem_pc), .ex_mem_instr_i(ex_mem_instr),
        .ex_mem_ex_result_i(ex_mem_ex_result), .ex_mem_rs2_data_i(ex_mem_rs2_data),
        .ex_mem_reg_write_i(ex_mem_reg_write), .ex_mem_mem_read_i(ex_mem_mem_read),
        .ex_mem_mem_write_i(ex_mem_mem_write), .ex_mem_mem_to_reg_i(ex_mem_mem_to_reg),
        .ex_mem_is_halt_i(ex_mem_is_halt),
        .mem_wb_pc_i(mem_wb_pc), .mem_wb_instr_i(mem_wb_instr),
        .mem_wb_result_i(mem_wb_result), .mem_wb_mem_read_data_i(mem_wb_mem_read_data),
        .mem_wb_reg_write_i(mem_wb_reg_write), .mem_wb_mem_to_reg_i(mem_wb_mem_to_reg),
        .mem_wb_is_halt_i(mem_wb_is_halt),
        .regs_flat_i(regs_flat),
        .dmem_dbg_addr_o(dmem_dbg_addr), .dmem_dbg_rdata_i(dmem_dbg_rdata),
        .w_data_o(w_data), .tx_full_i(tx_full), .wr_o(wr)
    );

endmodule
