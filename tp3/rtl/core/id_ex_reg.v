// =============================================================================
// Módulo:         id_ex_reg
//
// Descripción:
// Latch ID/EX. Transporta los VALORES que ID ya calculó (pc, rs1_data,
// rs2_data sin adelantar todavía, imm, y 'instr' completa para debug y
// para que EX extraiga rs1/rs2/rd/funct3/funct7 con un slice, igual que
// hace ID con IF/ID) más las señales de control que armó control_unit --
// esas sí hay que latchearlas, porque no hay un control_unit corriendo de
// nuevo en EX que las pueda re-derivar de 'instr'.
//
// Una sola entrada de control: 'bubble_i'. A diferencia de IF/ID, acá NO
// hay un "freeze": cuando hazard_unit pide burbujear (load-use o load
// antes de un branch/jalr), este latch SIEMPRE actualiza, pero fuerza
// TODOS los campos -- incluida 'instr', a 0x00000013 (NOP real, mismo
// motivo que en if_id_reg.v) y todas las señales de control a 0 -- en vez
// de dejar pasar lo que sea que control_unit esté decodificando ese ciclo
// (que todavía no debe entrar a EX). Si sólo se pisara 'instr' y no las
// señales de control, quedarían viajando señales de control viejas o
// incorrectas: por eso se fuerzan las dos cosas juntas, siempre.
// =============================================================================
module id_ex_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        bubble_i,

    input  wire [31:0] pc_i,
    input  wire [31:0] rs1_data_i,
    input  wire [31:0] rs2_data_i,
    input  wire [31:0] imm_i,
    input  wire [31:0] instr_i,

    input  wire        reg_write_i,
    input  wire        alu_src_a_i,
    input  wire        alu_src_b_i,
    input  wire [1:0]  alu_op_i,
    input  wire        mem_read_i,
    input  wire        mem_write_i,
    input  wire        mem_to_reg_i,
    input  wire        is_jal_i,
    input  wire        is_jalr_i,
    input  wire        is_halt_i,

    output reg  [31:0] pc_o,
    output reg  [31:0] rs1_data_o,
    output reg  [31:0] rs2_data_o,
    output reg  [31:0] imm_o,
    output reg  [31:0] instr_o,

    output reg          reg_write_o,
    output reg          alu_src_a_o,
    output reg          alu_src_b_o,
    output reg  [1:0]   alu_op_o,
    output reg           mem_read_o,
    output reg           mem_write_o,
    output reg           mem_to_reg_o,
    output reg           is_jal_o,
    output reg           is_jalr_o,
    output reg           is_halt_o
);

    localparam NOP = 32'h00000013; // addi x0, x0, 0

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i || bubble_i) begin
            pc_o         <= 32'b0;
            rs1_data_o   <= 32'b0;
            rs2_data_o   <= 32'b0;
            imm_o        <= 32'b0;
            instr_o      <= NOP;
            reg_write_o  <= 1'b0;
            alu_src_a_o  <= 1'b0;
            alu_src_b_o  <= 1'b0;
            alu_op_o     <= 2'b00;
            mem_read_o   <= 1'b0;
            mem_write_o  <= 1'b0;
            mem_to_reg_o <= 1'b0;
            is_jal_o     <= 1'b0;
            is_jalr_o    <= 1'b0;
            is_halt_o    <= 1'b0;
        end
        else begin
            pc_o         <= pc_i;
            rs1_data_o   <= rs1_data_i;
            rs2_data_o   <= rs2_data_i;
            imm_o        <= imm_i;
            instr_o      <= instr_i;
            reg_write_o  <= reg_write_i;
            alu_src_a_o  <= alu_src_a_i;
            alu_src_b_o  <= alu_src_b_i;
            alu_op_o     <= alu_op_i;
            mem_read_o   <= mem_read_i;
            mem_write_o  <= mem_write_i;
            mem_to_reg_o <= mem_to_reg_i;
            is_jal_o     <= is_jal_i;
            is_jalr_o    <= is_jalr_i;
            is_halt_o    <= is_halt_i;
        end
    end

endmodule
