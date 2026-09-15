// =============================================================================
// Módulo:         alu_control
//
// Descripción:
// Segundo nivel del decodificador de 2 niveles que describe el Patterson
// para la ALU: control_unit ya redujo el opcode a un 'alu_op_i' de 2 bits
// (00=sumar siempre, 01=R-type, 10=I-type aritmético) y acá se combina con
// funct3/funct7[5] (bit 30 de la instrucción) para elegir el opcode exacto
// de 6 bits que espera tp1/ALU.v (extendida en TP3 con SLL/SLT/SLTU, ver
// ese archivo). Los valores de OP_* de acá tienen que coincidir bit a bit
// con los localparam de tp1/ALU.v -- están duplicados (no hay un mecanismo
// de import de constantes entre módulos en el subset de Verilog que usa
// este proyecto) y documentados con esa dependencia explícita.
//
// slli/srli/srai (I-type aritmético con funct3=101/001) también necesitan
// el bit 30 para distinguir shift lógico de aritmético, igual que sus
// versiones R-type -- por eso alu_op=10 también consume funct7_bit5_i, no
// solo funct3_i.
// =============================================================================
module alu_control (
    input  wire [1:0] alu_op_i,       // de control_unit: 00=ADD, 01=R-type, 10=I-type aritmético
    input  wire [2:0] funct3_i,       // instr[14:12]
    input  wire       funct7_bit5_i,  // instr[30]: distingue add/sub y srl/sra

    output reg  [5:0] alu_ctrl_o
);

    // --- Deben coincidir con tp1/ALU.v ---
    localparam OP_ADD  = 6'b100000;
    localparam OP_SUB  = 6'b100010;
    localparam OP_AND  = 6'b100100;
    localparam OP_OR   = 6'b100101;
    localparam OP_XOR  = 6'b100110;
    localparam OP_SRA  = 6'b000011;
    localparam OP_SRL  = 6'b000010;
    localparam OP_SLL  = 6'b000001;
    localparam OP_SLT  = 6'b101010;
    localparam OP_SLTU = 6'b101011;

    localparam ALUOP_ADD   = 2'b00;
    localparam ALUOP_RTYPE = 2'b01;
    localparam ALUOP_ITYPE = 2'b10;

    always @(*) begin
        case (alu_op_i)
            ALUOP_ADD: alu_ctrl_o = OP_ADD;

            ALUOP_RTYPE: begin
                case (funct3_i)
                    3'b000:  alu_ctrl_o = funct7_bit5_i ? OP_SUB : OP_ADD;
                    3'b001:  alu_ctrl_o = OP_SLL;
                    3'b010:  alu_ctrl_o = OP_SLT;
                    3'b011:  alu_ctrl_o = OP_SLTU;
                    3'b100:  alu_ctrl_o = OP_XOR;
                    3'b101:  alu_ctrl_o = funct7_bit5_i ? OP_SRA : OP_SRL;
                    3'b110:  alu_ctrl_o = OP_OR;
                    3'b111:  alu_ctrl_o = OP_AND;
                    default: alu_ctrl_o = OP_ADD;
                endcase
            end

            ALUOP_ITYPE: begin
                case (funct3_i)
                    3'b000:  alu_ctrl_o = OP_ADD;  // addi (no existe "subi")
                    3'b010:  alu_ctrl_o = OP_SLT;  // slti
                    3'b011:  alu_ctrl_o = OP_SLTU; // sltiu
                    3'b100:  alu_ctrl_o = OP_XOR;  // xori
                    3'b110:  alu_ctrl_o = OP_OR;   // ori
                    3'b111:  alu_ctrl_o = OP_AND;  // andi
                    3'b001:  alu_ctrl_o = OP_SLL;  // slli
                    3'b101:  alu_ctrl_o = funct7_bit5_i ? OP_SRA : OP_SRL; // srai / srli
                    default: alu_ctrl_o = OP_ADD;
                endcase
            end

            default: alu_ctrl_o = OP_ADD;
        endcase
    end

endmodule
