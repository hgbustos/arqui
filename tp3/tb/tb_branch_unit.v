`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_branch_unit
//
// Descripción:
// Verifica branch_unit.v: beq/bne tomados y no tomados, jal/jalr siempre
// tomados con su cálculo de destino propio (PC+imm vs (rs1+imm)&~1,
// incluyendo el caso donde rs1+imm da una dirección impar para confirmar
// que se fuerza el bit 0 a cero), y el caso "ninguna señal de salto activa"
// (una instrucción R/I-type cualquiera pasando por ID).
// =============================================================================
module tb_branch_unit;

    reg  [31:0] tb_pc, tb_rs1, tb_rs2, tb_imm;
    reg  [2:0]  tb_funct3;
    reg         tb_is_branch, tb_is_jal, tb_is_jalr;
    wire        tb_taken;
    wire [31:0] tb_target;

    integer pass_count, fail_count;

    branch_unit uut (
        .pc_i          (tb_pc),
        .rs1_data_i    (tb_rs1),
        .rs2_data_i    (tb_rs2),
        .imm_i         (tb_imm),
        .funct3_i      (tb_funct3),
        .is_branch_i   (tb_is_branch),
        .is_jal_i      (tb_is_jal),
        .is_jalr_i     (tb_is_jalr),
        .branch_taken_o(tb_taken),
        .target_pc_o   (tb_target)
    );

    task check;
        input [511:0] label;
        input         exp_taken;
        input [31:0]  exp_target;
        begin
            #1;
            if (tb_taken === exp_taken && (!exp_taken || tb_target === exp_target)) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: taken=%0b target=0x%08h", label, tb_taken, tb_target);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado taken=%0b target=0x%08h, recibido taken=%0b target=0x%08h",
                       label, exp_taken, exp_target, tb_taken, tb_target);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de branch_unit");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;
        tb_is_branch = 0; tb_is_jal = 0; tb_is_jalr = 0;

        $display("\n--- beq ---");
        tb_pc = 32'h0000_1000; tb_imm = 32'd16; tb_funct3 = 3'b000; // beq
        tb_is_branch = 1; tb_is_jal = 0; tb_is_jalr = 0;
        tb_rs1 = 32'd7; tb_rs2 = 32'd7;
        check("beq iguales -> tomado", 1'b1, 32'h0000_1010);
        tb_rs1 = 32'd7; tb_rs2 = 32'd8;
        check("beq distintos -> no tomado", 1'b0, 32'bx);

        $display("\n--- bne ---");
        tb_funct3 = 3'b001; // bne
        tb_rs1 = 32'd7; tb_rs2 = 32'd8;
        check("bne distintos -> tomado", 1'b1, 32'h0000_1010);
        tb_rs1 = 32'd7; tb_rs2 = 32'd7;
        check("bne iguales -> no tomado", 1'b0, 32'bx);

        $display("\n--- jal ---");
        tb_is_branch = 0; tb_is_jal = 1; tb_is_jalr = 0;
        tb_pc = 32'h0000_2000; tb_imm = -32'd8; // jal hacia atras
        check("jal siempre tomado, target=PC+imm", 1'b1, 32'h0000_1FF8);

        $display("\n--- jalr ---");
        tb_is_branch = 0; tb_is_jal = 0; tb_is_jalr = 1;
        tb_rs1 = 32'h0000_3005; tb_imm = 32'd2; // rs1+imm = 0x3007 (impar)
        check("jalr fuerza bit0 a 0", 1'b1, 32'h0000_3006);

        $display("\n--- Ninguna senial de salto activa (R/I-type generico) ---");
        tb_is_branch = 0; tb_is_jal = 0; tb_is_jalr = 0;
        tb_rs1 = 32'd1; tb_rs2 = 32'd1; // igualdad casual, no deberia importar
        check("sin control de salto -> nunca tomado", 1'b0, 32'bx);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("BRANCH_UNIT: TODOS LOS TESTS PASARON");
        else $display("BRANCH_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
