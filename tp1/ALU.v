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

    reg [N:0] sum_extended;

    always @(*) begin
        // Asignaciones por defecto para evitar la inferencia de latches.
        out = {N{1'b0}};
        co = 1'b0;
        sum_extended = {N+1{1'b0}};

        case (opcode)
            6'b100000: begin // ADD
                sum_extended = {1'b0, in1} + {1'b0, in2};
                out = sum_extended[N-1:0];
                co  = sum_extended[N];
            end

            6'b100010: begin // SUB
                {co, out} = in1 - in2;
            end

            6'b100100: begin // AND
                out = in1 & in2;
            end

            6'b100101: begin // OR
                out = in1 | in2;
            end

            6'b100110: begin // XOR
                out = in1 ^ in2;
            end

            6'b000011: begin // SRA (Shift Right Arithmetic)
                out = $signed(in1) >>> in2;
            end

            6'b000010: begin // SRL (Shift Right Logical)
                out = in1 >> in2;
            end

            6'b100111: begin // NOR
                out = ~(in1 | in2);
            end

            default: begin
                out = {N{1'b0}};
                co = 1'b0;
            end
        endcase
    end

    // El flag 'zero' es '1' solo si todos los bits de salida son cero.
    assign zero = ~|out;

endmodule