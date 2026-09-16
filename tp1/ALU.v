// =============================================================================
// Módulo:         ALU (Unidad Aritmético-Lógica)
//
// Descripción:
// Implementa una ALU parametrizable de N bits que realiza operaciones
// aritméticas y lógicas basadas en un 'opcode'. Este módulo es puramente
// combinacional.
//
// Extensión TP3: se agregaron SLL/SLT/SLTU (aditivo, no se tocó ninguno de
// los 8 opcodes ni comportamientos originales de TP1/TP2) para que esta
// misma ALU, validada en TP1 standalone y operada por UART en TP2, sea
// también la ALU de la etapa EX del pipeline RISC-V de TP3 (instanciada con
// N=32, decodificada por tp3/rtl/core/alu_control.v). Los OP_* son
// etiquetas de control internas (nunca forman parte de una instrucción,
// solo tienen que coincidir bit a bit con alu_control.v): SLL no usa
// 6'b000000 porque tp1/tb_alu.v ya lo reserva como probe de "opcode
// inválido" (ver ese testbench); se usa el próximo código libre de la
// familia de shifts. El enmascarado del shift amount a los bits bajos que
// exige RV32I (in2[4:0] para N=32) es responsabilidad de quien instancia
// la ALU (tp3/rtl/core/riscv_core.v), no de este módulo genérico: igual
// que SRA/SRL ya hacían, el shift acá usa 'in2' crudo tal cual llega.
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
    // --- Opcodes (TP3, RV32I) ---
    localparam OP_SLL  = 6'b000001; // no usa 000000: ver nota arriba (reservado por tb_alu.v)
    localparam OP_SLT  = 6'b101010;
    localparam OP_SLTU = 6'b101011;

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

            OP_SLL: begin
                out = in1 << in2;
            end

            OP_SLT: begin
                out = {{(N-1){1'b0}}, $signed(in1) < $signed(in2)};
            end

            OP_SLTU: begin
                out = {{(N-1){1'b0}}, in1 < in2};
            end

            default: begin
                out = {N{1'b0}};
                co = 1'b0;
            end
        endcase
    end

    assign zero = ~|out;

endmodule