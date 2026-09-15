`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_control_unit
//
// Descripción:
// Recorre los 9 opcodes que reconoce control_unit.v (R/I/Load/Store/Branch/
// JAL/JALR/LUI/HALT) más un par de opcodes basura, y verifica el bundle de
// señales de control completo contra lo que corresponde según el enunciado
// de TP3 y el mapeo de opcode de RV32I.
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
    wire       tb_reg_write, tb_alu_src_a, tb_alu_src_b;
    wire [1:0] tb_alu_op;
    wire       tb_mem_read, tb_mem_write, tb_mem_to_reg;
    wire       tb_is_jal, tb_is_jalr, tb_is_branch, tb_is_halt;
    wire [2:0] tb_imm_sel;

    integer pass_count, fail_count;

    control_unit uut (
        .opcode_i     (tb_opcode),
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
        .imm_sel_o    (tb_imm_sel)
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

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de control_unit");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

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

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("CONTROL_UNIT: TODOS LOS TESTS PASARON");
        else $display("CONTROL_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
