// =============================================================================
// Módulo:         control_unit
//
// Descripción:
// Decodificador principal (etapa ID): traduce el opcode de 7 bits en las
// señales de control que gobiernan el resto del datapath. Qué operación
// hace la ALU lo elige alu_control, aguas abajo, con su propia tabla de 2
// niveles, y si un salto se toma lo decide branch_unit -- esa separación
// es deliberada, la misma que describe el Patterson para el "ALU control"
// de 2 niveles.
//
// Cubre exactamente el subset de RV32I que pide el enunciado de TP3
// (R/I/S/B/U/J) más una instrucción HALT propia en el opcode reservado
// "custom-0" (0001011) de la especificación RISC-V -- el enunciado no
// incluye ninguna instrucción de parada en su lista, así que hace falta
// definir una. Cualquier instrucción fuera de ese subset levanta
// is_halt_o (HALT implícito): es la respuesta a "¿qué pasa si no hay HALT
// en memoria?" que pide documentar el enunciado (la memoria de
// instrucciones sin programar lee 0x00000000, ver tp3/informe.md §3.2).
//
// "Fuera del subset" se decide con la codificación COMPLETA, no sólo con
// el opcode: funct3/funct7 también se validan ('supported', abajo). Un
// opcode conocido no alcanza -- p.ej. blt/bge comparten opcode con
// beq/bne y branch_unit sólo mira funct3[0], así que sin este chequeo un
// blt se ejecutaría en silencio como si fuera un beq; lo mismo un mul
// (funct7=0000001) como add, o un ld (funct3=011) como lw. Con el
// chequeo, todas esas codificaciones caen en el mismo HALT implícito.
//
// 'uses_rs1_o'/'uses_rs2_o' indican si la instrucción LEE de verdad cada
// registro fuente. Los campos rs1/rs2 están siempre en las mismas
// posiciones de la instrucción, pero en un I-type esos bits de rs2 son el
// inmediato, y en lui/jal son parte del inmediato los dos: hazard_unit
// los usa para no frenar por una "dependencia" que en realidad es un
// inmediato que casualmente coincide con el rd de un load.
// =============================================================================
module control_unit (
    input  wire [6:0] opcode_i,
    input  wire [2:0] funct3_i,      // instr[14:12]
    input  wire [6:0] funct7_i,      // instr[31:25]

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
    output reg        is_halt_o,     // HALT explicito (custom-0) o implicito (instrucción fuera del subset)
    output reg  [2:0] imm_sel_o,
    output reg        uses_rs1_o,    // la instrucción lee rs1 (para hazard_unit)
    output reg        uses_rs2_o     // la instrucción lee rs2 (para hazard_unit)
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

    localparam F7_BASE = 7'b0000000;
    localparam F7_ALT  = 7'b0100000; // sub / sra / srai

    // --- ¿La codificación completa está dentro del subset del enunciado? ---
    reg supported;
    always @(*) begin
        case (opcode_i)
            // add/sll/slt/sltu/xor/srl/or/and con funct7=0; sub y sra con 0100000
            OP_R:      supported = (funct7_i == F7_BASE) ||
                                   (funct7_i == F7_ALT && (funct3_i == 3'b000 || funct3_i == 3'b101));
            // addi/slti/sltiu/xori/ori/andi: todo el campo alto es inmediato.
            // slli/srli/srai: instr[31:25] sí es funct7.
            OP_IMM:    supported = (funct3_i == 3'b001) ? (funct7_i == F7_BASE) :
                                   (funct3_i == 3'b101) ? (funct7_i == F7_BASE || funct7_i == F7_ALT) :
                                   1'b1;
            // lb/lh/lw/lbu/lhu
            OP_LOAD:   supported = (funct3_i == 3'b000) || (funct3_i == 3'b001) || (funct3_i == 3'b010) ||
                                   (funct3_i == 3'b100) || (funct3_i == 3'b101);
            // sb/sh/sw
            OP_STORE:  supported = (funct3_i == 3'b000) || (funct3_i == 3'b001) || (funct3_i == 3'b010);
            // beq/bne (blt/bge/bltu/bgeu no están en el enunciado)
            OP_BRANCH: supported = (funct3_i == 3'b000) || (funct3_i == 3'b001);
            OP_JALR:   supported = (funct3_i == 3'b000);
            OP_JAL, OP_LUI, OP_HALT: supported = 1'b1;
            default:   supported = 1'b0;
        endcase
    end

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
        uses_rs1_o   = 1'b0;
        uses_rs2_o   = 1'b0;

        if (!supported) begin
            // Fuera del subset (opcode desconocido, o opcode conocido con
            // funct3/funct7 que no corresponde a ninguna instrucción
            // pedida): halt implícito, ver header.
            is_halt_o = 1'b1;
        end
        else begin
            case (opcode_i)
                OP_R: begin
                    reg_write_o = 1'b1;
                    alu_src_b_o = 1'b0; // rs2
                    alu_op_o    = ALUOP_RTYPE;
                    uses_rs1_o  = 1'b1;
                    uses_rs2_o  = 1'b1;
                end

                OP_IMM: begin
                    reg_write_o = 1'b1;
                    alu_src_b_o = 1'b1; // inmediato
                    alu_op_o    = ALUOP_ITYPE;
                    imm_sel_o   = IMM_I;
                    uses_rs1_o  = 1'b1;
                end

                OP_LOAD: begin
                    reg_write_o  = 1'b1;
                    alu_src_b_o  = 1'b1; // rs1 + imm = dirección efectiva
                    alu_op_o     = ALUOP_ADD;
                    mem_read_o   = 1'b1;
                    mem_to_reg_o = 1'b1;
                    imm_sel_o    = IMM_I;
                    uses_rs1_o   = 1'b1;
                end

                OP_STORE: begin
                    alu_src_b_o = 1'b1; // rs1 + imm = dirección efectiva
                    alu_op_o    = ALUOP_ADD;
                    mem_write_o = 1'b1;
                    imm_sel_o   = IMM_S;
                    uses_rs1_o  = 1'b1;  // base de la dirección
                    uses_rs2_o  = 1'b1;  // dato a escribir
                end

                OP_BRANCH: begin
                    // beq/bne se resuelven enteramente en ID (branch_unit); la
                    // ALU de EX no participa. imm_sel sigue haciendo falta acá
                    // porque branch_unit consume la salida de imm_gen.
                    is_branch_o = 1'b1;
                    imm_sel_o   = IMM_B;
                    uses_rs1_o  = 1'b1;
                    uses_rs2_o  = 1'b1;
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
                    uses_rs1_o  = 1'b1;
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
                    // Inalcanzable ('supported' ya filtró los opcodes
                    // desconocidos); se deja por seguridad.
                    is_halt_o = 1'b1;
                end
            endcase
        end
    end

endmodule
