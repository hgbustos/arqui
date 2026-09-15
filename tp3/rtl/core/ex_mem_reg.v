// =============================================================================
// Módulo:         ex_mem_reg
//
// Descripción:
// Latch EX/MEM. Sin stall ni flush: una vez que una instrucción entró a
// EX de forma válida, siempre sigue de largo (los únicos descartes del
// pipeline pasan en el límite IF/ID -- flush por salto tomado -- o en el
// límite ID/EX -- burbuja por hazard --, nunca más adelante). Transporta
// 'ex_result' (la salida de la ALU, o PC+4 si la instrucción es jal/jalr:
// ese mux ya se resolvió en EX, ver riscv_core.v) como dirección efectiva
// para MEM si es load/store, 'rs2_data' ya adelantado (dato a escribir en
// un store) e 'instr' para que MEM extraiga rd/funct3 con un slice, igual
// que las etapas anteriores.
// =============================================================================
module ex_mem_reg (
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire [31:0] pc_i,
    input  wire [31:0] ex_result_i,
    input  wire [31:0] rs2_data_i,
    input  wire [31:0] instr_i,

    input  wire        reg_write_i,
    input  wire        mem_read_i,
    input  wire        mem_write_i,
    input  wire        mem_to_reg_i,
    input  wire        is_halt_i,

    output reg  [31:0] pc_o,
    output reg  [31:0] ex_result_o,
    output reg  [31:0] rs2_data_o,
    output reg  [31:0] instr_o,

    output reg          reg_write_o,
    output reg           mem_read_o,
    output reg           mem_write_o,
    output reg           mem_to_reg_o,
    output reg           is_halt_o
);

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            pc_o         <= 32'b0;
            ex_result_o  <= 32'b0;
            rs2_data_o   <= 32'b0;
            instr_o      <= 32'h00000013;
            reg_write_o  <= 1'b0;
            mem_read_o   <= 1'b0;
            mem_write_o  <= 1'b0;
            mem_to_reg_o <= 1'b0;
            is_halt_o    <= 1'b0;
        end
        else begin
            pc_o         <= pc_i;
            ex_result_o  <= ex_result_i;
            rs2_data_o   <= rs2_data_i;
            instr_o      <= instr_i;
            reg_write_o  <= reg_write_i;
            mem_read_o   <= mem_read_i;
            mem_write_o  <= mem_write_i;
            mem_to_reg_o <= mem_to_reg_i;
            is_halt_o    <= is_halt_i;
        end
    end

endmodule
