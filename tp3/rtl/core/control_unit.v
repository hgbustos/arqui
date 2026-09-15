// =============================================================================
// Módulo:         control_unit
//
// Descripción:
// Decodificador principal (etapa ID): traduce el opcode de 7 bits en las
// señales de control que gobiernan el resto del datapath. No mira
// funct3/funct7 (eso lo hace alu_control, aguas abajo, con su propia tabla
// de 2 niveles) ni decide si un salto se toma (eso lo hace branch_unit) --
// esa separación es deliberada, la misma que describe el Patterson para el
// "ALU control" de 2 niveles.
//
// Cubre exactamente el subset de RV32I que pide el enunciado de TP3
// (R/I/S/B/U/J) más una instrucción HALT propia en el opcode reservado
// "custom-0" (0001011) de la especificación RISC-V -- el enunciado no
// incluye ninguna instrucción de parada en su lista, así que hace falta
// definir una. Cualquier opcode no reconocido (incluida la memoria de
// instrucciones sin programar, que lee 0x00000000) también levanta
// is_halt_o: es la respuesta a "¿qué pasa si no hay HALT en memoria?" que
// pide documentar el enunciado (ver tp3/informe.md).
// =============================================================================
module control_unit (
    input  wire [6:0] opcode_i,

    output reg        reg_write_o,
    output reg        alu_src_a_o,   // 0 = rs1, 1 = fuerza 0 (LUI)
    output reg        alu_src_b_o,   // 0 = rs2, 1 = inmediato
    output reg  [1:0] alu_op_o,      // 00=ADD forzado, 01=R-type (funct), 10=I-type aritmético (funct)
    output reg        mem_read_o,
    output reg        mem_write_o,
    output reg        mem_to_reg_o,  // 0 = resultado (ALU o link), 1 = dato de memoria
    output reg        is_jal_o,
    output reg        is_jalr_o,
    output reg        is_branch_o,   // beq/bne; funct3 los distingue en branch_unit
    output reg        is_halt_o,     // HALT explicito (custom-0) o implicito (opcode no reconocido)
    output reg  [2:0] imm_sel_o
);

    localparam OP_R      = 7'b0110011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_LUI    = 7'b0110111;
    localparam OP_HALT   = 7'b0001011; // custom-0

    localparam IMM_I = 3'b000;
    localparam IMM_S = 3'b001;
    localparam IMM_B = 3'b010;
    localparam IMM_U = 3'b011;
    localparam IMM_J = 3'b100;

    localparam ALUOP_ADD   = 2'b00;
    localparam ALUOP_RTYPE = 2'b01;
    localparam ALUOP_ITYPE = 2'b10;

    always @(*) begin
        // Default: instrucción inerte y segura (equivale a HALT implícito).
        // Cubre tanto la rama 'default' del case como el punto de partida
        // de cada rama, para no repetir cada campo en cada caso.
        reg_write_o  = 1'b0;
        alu_src_a_o  = 1'b0;
        alu_src_b_o  = 1'b0;
        alu_op_o     = ALUOP_ADD;
        mem_read_o   = 1'b0;
        mem_write_o  = 1'b0;
        mem_to_reg_o = 1'b0;
        is_jal_o     = 1'b0;
        is_jalr_o    = 1'b0;
        is_branch_o  = 1'b0;
        is_halt_o    = 1'b0;
        imm_sel_o    = IMM_I;

        case (opcode_i)
            OP_R: begin
                reg_write_o = 1'b1;
                alu_src_b_o = 1'b0; // rs2
                alu_op_o    = ALUOP_RTYPE;
            end

            OP_IMM: begin
                reg_write_o = 1'b1;
                alu_src_b_o = 1'b1; // inmediato
                alu_op_o    = ALUOP_ITYPE;
                imm_sel_o   = IMM_I;
            end

            OP_LOAD: begin
                reg_write_o  = 1'b1;
                alu_src_b_o  = 1'b1; // rs1 + imm = dirección efectiva
                alu_op_o     = ALUOP_ADD;
                mem_read_o   = 1'b1;
                mem_to_reg_o = 1'b1;
                imm_sel_o    = IMM_I;
            end

            OP_STORE: begin
                alu_src_b_o = 1'b1; // rs1 + imm = dirección efectiva
                alu_op_o    = ALUOP_ADD;
                mem_write_o = 1'b1;
                imm_sel_o   = IMM_S;
            end

            OP_BRANCH: begin
                // beq/bne se resuelven enteramente en ID (branch_unit); la
                // ALU de EX no participa. imm_sel sigue haciendo falta acá
                // porque branch_unit consume la salida de imm_gen.
                is_branch_o = 1'b1;
                imm_sel_o   = IMM_B;
            end

            OP_JAL: begin
                reg_write_o = 1'b1; // rd <= PC+4 (mux en EX, ver riscv_core)
                is_jal_o    = 1'b1;
                imm_sel_o   = IMM_J;
            end

            OP_JALR: begin
                reg_write_o = 1'b1; // rd <= PC+4
                is_jalr_o   = 1'b1;
                imm_sel_o   = IMM_I; // jalr es I-type
            end

            OP_LUI: begin
                reg_write_o = 1'b1;
                alu_src_a_o = 1'b1;      // fuerza operando A = 0
                alu_src_b_o = 1'b1;      // operando B = inmediato
                alu_op_o    = ALUOP_ADD; // 0 + imm = imm
                imm_sel_o   = IMM_U;
            end

            OP_HALT: begin
                is_halt_o = 1'b1;
            end

            default: begin
                // Opcode no reconocido: halt implícito (ver header).
                is_halt_o = 1'b1;
            end
        endcase
    end

endmodule
