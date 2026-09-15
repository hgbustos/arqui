// =============================================================================
// Módulo:         if_id_reg
//
// Descripción:
// Latch IF/ID. Solo transporta 'pc' e 'instr' -- el resto de los campos
// que necesita ID (rs1/rs2/rd, funct3/funct7, opcode) son posiciones fijas
// dentro de 'instr' en RV32I, así que riscv_core.v los extrae con un
// simple slice combinacional en vez de duplicarlos acá como flip-flops
// aparte.
//
// Dos entradas de control, con esta prioridad (igual que decide
// hazard_unit, acá se refuerza en el propio latch por robustez):
//   1) write_en_i=0 (freeze, por un stall de hazard_unit o por halt):
//      mantiene el valor actual, no se pierde la instrucción que está
//      esperando.
//   2) flush_i=1 (con write_en_i=1): la instrucción que se acaba de
//      buscar quedó mal encaminada (un salto tomado la invalidó) -- se
//      reemplaza por un NOP real de RV32I ('addi x0,x0,0' = 0x00000013),
//      no por instr=0. Importante: 0x00000000 decodifica como opcode
//      inválido, que control_unit trata como HALT implícito -- si se
//      usara como valor de burbuja, cada flush disparadaría un halt
//      espurio. 0x00000013 en cambio decodifica como OP_IMM con rd=x0:
//      un no-op genuino, sin ningún efecto.
// =============================================================================
module if_id_reg (
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        write_en_i,
    input  wire        flush_i,

    input  wire [31:0] pc_i,
    input  wire [31:0] instr_i,

    output reg  [31:0] pc_o,
    output reg  [31:0] instr_o
);

    localparam NOP = 32'h00000013; // addi x0, x0, 0

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            pc_o    <= 32'b0;
            instr_o <= NOP;
        end
        else if (!write_en_i) begin
            // freeze: no se actualiza nada.
        end
        else if (flush_i) begin
            pc_o    <= 32'b0;
            instr_o <= NOP;
        end
        else begin
            pc_o    <= pc_i;
            instr_o <= instr_i;
        end
    end

endmodule
