`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_alu_control
//
// Descripción:
// Recorre las 10 combinaciones R-type y las 9 combinaciones I-type
// aritmético de {funct3, funct7[5]} y verifica que alu_control.v elige el
// opcode de tp1/ALU.v esperado en cada caso, más el caso ALUOP_ADD forzado
// (loads/stores/lui).
// =============================================================================
module tb_alu_control;

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

    reg  [1:0] tb_alu_op;
    reg  [2:0] tb_funct3;
    reg        tb_funct7b5;
    wire [5:0] tb_alu_ctrl;

    integer pass_count, fail_count;

    alu_control uut (
        .alu_op_i      (tb_alu_op),
        .funct3_i      (tb_funct3),
        .funct7_bit5_i (tb_funct7b5),
        .alu_ctrl_o    (tb_alu_ctrl)
    );

    task check;
        input [511:0] label;
        input [5:0]   expected;
        begin
            #1;
            if (tb_alu_ctrl === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s -> %06b", label, tb_alu_ctrl);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%06b, recibido=%06b", label, expected, tb_alu_ctrl);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de alu_control");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        $display("\n--- ALUOP_ADD forzado (loads/stores/lui) ---");
        tb_alu_op = ALUOP_ADD; tb_funct3 = 3'b111; tb_funct7b5 = 1'b1; // deben ignorarse
        check("ALUOP_ADD ignora funct3/funct7", OP_ADD);

        $display("\n--- R-type (ALUOP_RTYPE) ---");
        tb_alu_op = ALUOP_RTYPE;
        tb_funct3 = 3'b000; tb_funct7b5 = 1'b0; check("add",  OP_ADD);
        tb_funct3 = 3'b000; tb_funct7b5 = 1'b1; check("sub",  OP_SUB);
        tb_funct3 = 3'b001; tb_funct7b5 = 1'b0; check("sll",  OP_SLL);
        tb_funct3 = 3'b010; tb_funct7b5 = 1'b0; check("slt",  OP_SLT);
        tb_funct3 = 3'b011; tb_funct7b5 = 1'b0; check("sltu", OP_SLTU);
        tb_funct3 = 3'b100; tb_funct7b5 = 1'b0; check("xor",  OP_XOR);
        tb_funct3 = 3'b101; tb_funct7b5 = 1'b0; check("srl",  OP_SRL);
        tb_funct3 = 3'b101; tb_funct7b5 = 1'b1; check("sra",  OP_SRA);
        tb_funct3 = 3'b110; tb_funct7b5 = 1'b0; check("or",   OP_OR);
        tb_funct3 = 3'b111; tb_funct7b5 = 1'b0; check("and",  OP_AND);

        $display("\n--- I-type aritmetico (ALUOP_ITYPE) ---");
        tb_alu_op = ALUOP_ITYPE;
        tb_funct3 = 3'b000; tb_funct7b5 = 1'b0; check("addi",  OP_ADD);
        tb_funct3 = 3'b010; tb_funct7b5 = 1'b0; check("slti",  OP_SLT);
        tb_funct3 = 3'b011; tb_funct7b5 = 1'b0; check("sltiu", OP_SLTU);
        tb_funct3 = 3'b100; tb_funct7b5 = 1'b0; check("xori",  OP_XOR);
        tb_funct3 = 3'b110; tb_funct7b5 = 1'b0; check("ori",   OP_OR);
        tb_funct3 = 3'b111; tb_funct7b5 = 1'b0; check("andi",  OP_AND);
        tb_funct3 = 3'b001; tb_funct7b5 = 1'b0; check("slli",  OP_SLL);
        tb_funct3 = 3'b101; tb_funct7b5 = 1'b0; check("srli",  OP_SRL);
        tb_funct3 = 3'b101; tb_funct7b5 = 1'b1; check("srai",  OP_SRA);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("ALU_CONTROL: TODOS LOS TESTS PASARON");
        else $display("ALU_CONTROL: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
