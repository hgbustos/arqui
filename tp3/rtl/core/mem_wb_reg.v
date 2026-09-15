// =============================================================================
// Módulo:         mem_wb_reg
//
// Descripción:
// Latch MEM/WB, el último del pipeline. Sin stall ni flush, por el mismo
// motivo que ex_mem_reg.v. Transporta 'result' (pasante desde EX/MEM:
// resultado de ALU o valor de enlace de jal/jalr), 'mem_read_data' (lo
// leído de dmem este ciclo, ya alineado/extendido en signo por dmem.v) e
// 'instr' para que WB -- y, sobre todo, la Debug Unit -- pueda mostrar qué
// instrucción está terminando en cada ciclo.
// =============================================================================
module mem_wb_reg (
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire [31:0] pc_i,
    input  wire [31:0] result_i,
    input  wire [31:0] mem_read_data_i,
    input  wire [31:0] instr_i,

    input  wire        reg_write_i,
    input  wire        mem_to_reg_i,
    input  wire        is_halt_i,

    output reg  [31:0] pc_o,
    output reg  [31:0] result_o,
    output reg  [31:0] mem_read_data_o,
    output reg  [31:0] instr_o,

    output reg          reg_write_o,
    output reg           mem_to_reg_o,
    output reg           is_halt_o
);

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            pc_o            <= 32'b0;
            result_o        <= 32'b0;
            mem_read_data_o <= 32'b0;
            instr_o         <= 32'h00000013;
            reg_write_o     <= 1'b0;
            mem_to_reg_o    <= 1'b0;
            is_halt_o       <= 1'b0;
        end
        else begin
            pc_o            <= pc_i;
            result_o        <= result_i;
            mem_read_data_o <= mem_read_data_i;
            instr_o         <= instr_i;
            reg_write_o     <= reg_write_i;
            mem_to_reg_o    <= mem_to_reg_i;
            is_halt_o       <= is_halt_i;
        end
    end

endmodule
