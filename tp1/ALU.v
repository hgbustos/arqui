// =============================================================================
// Módulo:         ALU (Unidad Aritmético-Lógica)
//
// Descripción:
// Implementa una ALU parametrizable de N bits que realiza operaciones
// aritméticas y lógicas basadas en un 'opcode'. Este módulo es puramente
// combinacional.
// =============================================================================
module ALU #(
    parameter N = 8
)(
    input wire [5:0]     opcode,
    input wire [N-1:0]   in1,
    input wire [N-1:0]   in2,

    output reg [N-1:0]   out,
    output wire          zero,
    output reg           co
);

    // --- Definición de Opcodes ---
    // El uso de 'localparam' mejora la legibilidad y mantenibilidad del código.
    localparam OP_ADD = 6'b100000;
    localparam OP_SUB = 6'b100010;
    localparam OP_AND = 6'b100100;
    localparam OP_OR  = 6'b100101;
    localparam OP_XOR = 6'b100110;
    localparam OP_SRA = 6'b000011;
    localparam OP_SRL = 6'b000010;
    localparam OP_NOR = 6'b100111;

    reg [N:0] sum_extended;

    always @(*) begin
        // Asignaciones por defecto para evitar la inferencia de latches.
        out = {N{1'b0}};
        co = 1'b0;
        sum_extended = {N+1{1'b0}};

        case (opcode)
            OP_ADD: begin
                sum_extended = {1'b0, in1} + {1'b0, in2};
                out = sum_extended[N-1:0];
                co  = sum_extended[N];
            end

            OP_SUB: begin
                {co, out} = in1 - in2;
            end

            OP_AND: begin
                out = in1 & in2;
            end

            OP_OR: begin
                out = in1 | in2;
            end

            OP_XOR: begin
                out = in1 ^ in2;
            end

            OP_SRA: begin
                out = $signed(in1) >>> in2;
            end

            OP_SRL: begin
                out = in1 >> in2;
            end

            OP_NOR: begin
                out = ~(in1 | in2);
            end

            default: begin
                out = {N{1'b0}};
                co = 1'b0;
            end
        endcase
    end

    assign zero = ~|out;

endmodule