`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_control_unit
//
// Descripción:
// Recorre los 9 opcodes que reconoce control_unit.v (R/I/Load/Store/Branch/
// JAL/JALR/LUI/HALT) más un par de opcodes basura, y verifica el bundle de
// señales de control completo contra lo que corresponde según el enunciado
// de TP3 y el mapeo de opcode de RV32I. Después verifica uses_rs1/uses_rs2
// por tipo, y que las codificaciones con opcode conocido pero funct3/funct7
// fuera del subset (blt, mul, ld, sd, ...) caigan en HALT implícito sin
// arrastrar a las válidas que comparten opcode (sub, sra, srai, lhu, ...).
// =============================================================================
module tb_control_unit;

    localparam OP_R      = 7'b0110011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_LUI    = 7'b0110111;
    localparam OP_HALT   = 7'b0001011;

    localparam IMM_I = 3'b000;
    localparam IMM_S = 3'b001;
    localparam IMM_B = 3'b010;
    localparam IMM_U = 3'b011;
    localparam IMM_J = 3'b100;

    localparam ALUOP_ADD   = 2'b00;
    localparam ALUOP_RTYPE = 2'b01;
    localparam ALUOP_ITYPE = 2'b10;

    reg  [6:0] tb_opcode;
    reg  [2:0] tb_funct3;
    reg  [6:0] tb_funct7;
    wire       tb_uses_rs1, tb_uses_rs2;
    wire       tb_reg_write, tb_alu_src_a, tb_alu_src_b;
    wire [1:0] tb_alu_op;
    wire       tb_mem_read, tb_mem_write, tb_mem_to_reg;
    wire       tb_is_jal, tb_is_jalr, tb_is_branch, tb_is_halt;
    wire [2:0] tb_imm_sel;

    integer pass_count, fail_count;

    control_unit uut (
        .opcode_i     (tb_opcode),
        .funct3_i     (tb_funct3),
        .funct7_i     (tb_funct7),
        .reg_write_o  (tb_reg_write),
        .alu_src_a_o  (tb_alu_src_a),
        .alu_src_b_o  (tb_alu_src_b),
        .alu_op_o     (tb_alu_op),
        .mem_read_o   (tb_mem_read),
        .mem_write_o  (tb_mem_write),
        .mem_to_reg_o (tb_mem_to_reg),
        .is_jal_o     (tb_is_jal),
        .is_jalr_o    (tb_is_jalr),
        .is_branch_o  (tb_is_branch),
        .is_halt_o    (tb_is_halt),
        .imm_sel_o    (tb_imm_sel),
        .uses_rs1_o   (tb_uses_rs1),
        .uses_rs2_o   (tb_uses_rs2)
    );

    task check;
        input [511:0] label;
        input [12:0]  got;      // {reg_write,alu_src_a,alu_src_b,alu_op[1:0],mem_read,mem_write,mem_to_reg,is_jal,is_jalr,is_branch,is_halt}
        input [12:0]  expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%013b, recibido=%013b", label, expected, got);
            end
        end
    endtask

    // Empaqueta el bundle actual de salidas en el mismo orden que 'check'.
    function [12:0] pack_actual;
        input dummy;
        begin
            pack_actual = {tb_reg_write, tb_alu_src_a, tb_alu_src_b, tb_alu_op,
                           tb_mem_read, tb_mem_write, tb_mem_to_reg,
                           tb_is_jal, tb_is_jalr, tb_is_branch, tb_is_halt};
        end
    endfunction

    // Bundle de un HALT (explícito o implícito): todo inerte salvo is_halt.
    localparam [12:0] HALT_BUNDLE = {1'b0,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b1};

    task check_uses;
        input [511:0] label;
        input         exp_rs1, exp_rs2;
        begin
            if (tb_uses_rs1 === exp_rs1 && tb_uses_rs2 === exp_rs2) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: uses_rs1=%0b uses_rs2=%0b", label, exp_rs1, exp_rs2);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado uses_rs1/2=%0b%0b, recibido=%0b%0b",
                       label, exp_rs1, exp_rs2, tb_uses_rs1, tb_uses_rs2);
            end
        end
    endtask

    // Codificación fuera del subset: bundle de HALT y sin leer registros
    // (un halt nunca tiene que generar un stall de hazard).
    task check_illegal;
        input [511:0] label;
        input [6:0]   op; input [2:0] f3; input [6:0] f7;
        begin
            tb_opcode = op; tb_funct3 = f3; tb_funct7 = f7; #1;
            check(label, pack_actual(0), HALT_BUNDLE);
            check_uses(label, 1'b0, 1'b0);
        end
    endtask

    // Codificación válida que comparte opcode con alguna ilegal: no
    // tiene que haber quedado atrapada por el chequeo de funct3/funct7.
    task check_legal;
        input [511:0] label;
        input [6:0]   op; input [2:0] f3; input [6:0] f7;
        begin
            tb_opcode = op; tb_funct3 = f3; tb_funct7 = f7; #1;
            if (tb_is_halt === 1'b0) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: no es halt", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: se decodifico como halt", label);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de control_unit");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        // funct3=funct7=0 en esta primera parte: add/addi/lb/sb/beq/jalr,
        // todas dentro del subset.
        tb_funct3 = 3'b000; tb_funct7 = 7'b0000000;

        tb_opcode = OP_R; #1;
        check("OP_R", pack_actual(0), {1'b1,1'b0,1'b0, ALUOP_RTYPE, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_I) begin fail_count=fail_count+1; $error("FALLO | OP_R imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_R imm_sel=I"); end

        tb_opcode = OP_IMM; #1;
        check("OP_IMM", pack_actual(0), {1'b1,1'b0,1'b1, ALUOP_ITYPE, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_I) begin fail_count=fail_count+1; $error("FALLO | OP_IMM imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_IMM imm_sel=I"); end

        tb_opcode = OP_LOAD; #1;
        check("OP_LOAD", pack_actual(0), {1'b1,1'b0,1'b1, ALUOP_ADD, 1'b1,1'b0,1'b1, 1'b0,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_I) begin fail_count=fail_count+1; $error("FALLO | OP_LOAD imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_LOAD imm_sel=I"); end

        tb_opcode = OP_STORE; #1;
        check("OP_STORE", pack_actual(0), {1'b0,1'b0,1'b1, ALUOP_ADD, 1'b0,1'b1,1'b0, 1'b0,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_S) begin fail_count=fail_count+1; $error("FALLO | OP_STORE imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_STORE imm_sel=S"); end

        tb_opcode = OP_BRANCH; #1;
        check("OP_BRANCH", pack_actual(0), {1'b0,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b1,1'b0});
        if (tb_imm_sel !== IMM_B) begin fail_count=fail_count+1; $error("FALLO | OP_BRANCH imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_BRANCH imm_sel=B"); end

        tb_opcode = OP_JAL; #1;
        check("OP_JAL", pack_actual(0), {1'b1,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b1,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_J) begin fail_count=fail_count+1; $error("FALLO | OP_JAL imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_JAL imm_sel=J"); end

        tb_opcode = OP_JALR; #1;
        check("OP_JALR", pack_actual(0), {1'b1,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b1,1'b0,1'b0});
        if (tb_imm_sel !== IMM_I) begin fail_count=fail_count+1; $error("FALLO | OP_JALR imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_JALR imm_sel=I"); end

        tb_opcode = OP_LUI; #1;
        check("OP_LUI", pack_actual(0), {1'b1,1'b1,1'b1, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b0});
        if (tb_imm_sel !== IMM_U) begin fail_count=fail_count+1; $error("FALLO | OP_LUI imm_sel"); end
        else begin pass_count=pass_count+1; $display("  -> EXITO | OP_LUI imm_sel=U"); end

        tb_opcode = OP_HALT; #1;
        check("OP_HALT explicito", pack_actual(0), {1'b0,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b1});

        // --- Halt implicito: cualquier opcode no reconocido, incluido
        // el caso critico 0000000 (lo que se lee de imem sin programar) ---
        tb_opcode = 7'b0000000; #1;
        check("Opcode 0000000 (imem vacia) -> halt implicito", pack_actual(0), {1'b0,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b1});

        tb_opcode = 7'b1111111; #1;
        check("Opcode 1111111 (basura) -> halt implicito", pack_actual(0), {1'b0,1'b0,1'b0, ALUOP_ADD, 1'b0,1'b0,1'b0, 1'b0,1'b0,1'b0,1'b1});

        $display("\n--- uses_rs1/uses_rs2: que registros lee de verdad cada tipo ---");
        tb_funct3 = 3'b000; tb_funct7 = 7'b0000000;
        tb_opcode = OP_R;      #1; check_uses("R-type",  1'b1, 1'b1);
        tb_opcode = OP_IMM;    #1; check_uses("I-type (rs2 es inmediato)", 1'b1, 1'b0);
        tb_opcode = OP_LOAD;   #1; check_uses("Load",    1'b1, 1'b0);
        tb_opcode = OP_STORE;  #1; check_uses("Store (base + dato)", 1'b1, 1'b1);
        tb_opcode = OP_BRANCH; #1; check_uses("Branch",  1'b1, 1'b1);
        tb_opcode = OP_JAL;    #1; check_uses("JAL (todo inmediato)", 1'b0, 1'b0);
        tb_opcode = OP_JALR;   #1; check_uses("JALR",    1'b1, 1'b0);
        tb_opcode = OP_LUI;    #1; check_uses("LUI (todo inmediato)", 1'b0, 1'b0);
        tb_opcode = OP_HALT;   #1; check_uses("HALT",    1'b0, 1'b0);

        $display("\n--- Opcode conocido, funct3/funct7 fuera del subset -> halt implicito ---");
        check_illegal("blt  (branch funct3=100)",  OP_BRANCH, 3'b100, 7'b0000000);
        check_illegal("bge  (branch funct3=101)",  OP_BRANCH, 3'b101, 7'b0000000);
        check_illegal("bltu (branch funct3=110)",  OP_BRANCH, 3'b110, 7'b0000000);
        check_illegal("bgeu (branch funct3=111)",  OP_BRANCH, 3'b111, 7'b0000000);
        check_illegal("mul  (R funct7=0000001)",   OP_R,      3'b000, 7'b0000001);
        check_illegal("R funct7=0100000 con funct3=111 (no existe)", OP_R, 3'b111, 7'b0100000);
        check_illegal("slli con funct7=0100000",   OP_IMM,    3'b001, 7'b0100000);
        check_illegal("srli/srai con funct7=0000001", OP_IMM, 3'b101, 7'b0000001);
        check_illegal("ld   (load funct3=011)",    OP_LOAD,   3'b011, 7'b0000000);
        check_illegal("lwu  (load funct3=110)",    OP_LOAD,   3'b110, 7'b0000000);
        check_illegal("sd   (store funct3=011)",   OP_STORE,  3'b011, 7'b0000000);
        check_illegal("jalr con funct3=001",       OP_JALR,   3'b001, 7'b0000000);

        $display("\n--- Las validas que comparten opcode siguen andando ---");
        check_legal("sub  (R funct7=0100000, funct3=000)", OP_R,   3'b000, 7'b0100000);
        check_legal("sra  (R funct7=0100000, funct3=101)", OP_R,   3'b101, 7'b0100000);
        check_legal("srai (I funct7=0100000, funct3=101)", OP_IMM, 3'b101, 7'b0100000);
        check_legal("addi con imm negativo (instr[31:25]=1111111)", OP_IMM, 3'b000, 7'b1111111);
        check_legal("lhu  (load funct3=101)",  OP_LOAD,   3'b101, 7'b0000000);
        check_legal("sw   (store funct3=010)", OP_STORE,  3'b010, 7'b0000000);
        check_legal("bne  (branch funct3=001)", OP_BRANCH, 3'b001, 7'b0000000);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("CONTROL_UNIT: TODOS LOS TESTS PASARON");
        else $display("CONTROL_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
