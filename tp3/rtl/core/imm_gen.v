// =============================================================================
// Módulo:         imm_gen
//
// Descripción:
// Generador de inmediatos de RV32I: extrae y reconstruye el valor inmediato
// embebido en la instrucción según su formato (I/S/B/U/J), con extensión de
// signo a 32 bits (excepto U, que no la necesita: siempre ocupa los bits
// altos). El formato lo indica 'imm_sel_i', que arma control_unit a partir
// del opcode -- imm_gen no vuelve a decodificar el opcode por su cuenta,
// para no tener dos módulos con la misma tabla de decisión (si mañana
// cambia el mapeo de opcodes, se cambia en un solo lugar).
//
// Fórmulas (bits de la instrucción -> imm), una por formato:
//   I: {20{instr[31]}}, instr[31:20]
//   S: {20{instr[31]}}, instr[31:25], instr[11:7]
//   B: {19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0
//   U: instr[31:12], 12'b0
//   J: {11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0
// =============================================================================
module imm_gen (
    input  wire [31:0] instr_i,
    input  wire [2:0]  imm_sel_i,
    output reg  [31:0] imm_o
);

    localparam IMM_I = 3'b000;
    localparam IMM_S = 3'b001;
    localparam IMM_B = 3'b010;
    localparam IMM_U = 3'b011;
    localparam IMM_J = 3'b100;

    always @(*) begin
        case (imm_sel_i)
            IMM_I: imm_o = {{20{instr_i[31]}}, instr_i[31:20]};

            IMM_S: imm_o = {{20{instr_i[31]}}, instr_i[31:25], instr_i[11:7]};

            IMM_B: imm_o = {{19{instr_i[31]}}, instr_i[31], instr_i[7],
                             instr_i[30:25], instr_i[11:8], 1'b0};

            IMM_U: imm_o = {instr_i[31:12], 12'b0};

            IMM_J: imm_o = {{11{instr_i[31]}}, instr_i[31], instr_i[19:12],
                             instr_i[20], instr_i[30:21], 1'b0};

            default: imm_o = 32'b0;
        endcase
    end

endmodule
