`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_imm_gen
//
// Descripción:
// Verifica imm_gen.v contra instrucciones armadas a partir de sus campos
// nombrados (nunca un literal de 32 bits "a ojo"): cada caso arma 'instr'
// concatenando opcode/rd/rs1/rs2/funct3/imm tal como los define el
// encoding de RV32I, y el valor esperado se calcula por separado a mano
// (aritmética de complemento a 2), para poder revisar cada uno de forma
// independiente. Cubre los 5 formatos (I/S/B/U/J) con casos positivos,
// negativos y el caso 0.
// =============================================================================
module tb_imm_gen;

    localparam IMM_I = 3'b000;
    localparam IMM_S = 3'b001;
    localparam IMM_B = 3'b010;
    localparam IMM_U = 3'b011;
    localparam IMM_J = 3'b100;

    reg  [31:0] tb_instr;
    reg  [2:0]  tb_imm_sel;
    wire [31:0] tb_imm;

    integer pass_count, fail_count;

    imm_gen uut (
        .instr_i   (tb_instr),
        .imm_sel_i (tb_imm_sel),
        .imm_o     (tb_imm)
    );

    task check_equal;
        input [511:0] label;
        input [31:0]  expected;
        begin
            #1;
            if (tb_imm === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: imm_o=0x%08h", label, tb_imm);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, tb_imm);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de imm_gen");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        // --- I-type: addi x1, x2, 100 (positivo) ---
        tb_imm_sel = IMM_I;
        tb_instr = {12'd100, 5'd2, 3'b000, 5'd1, 7'b0010011};
        check_equal("I-type addi imm=+100", 32'd100);

        // --- I-type: addi x1, x2, -5 ---
        tb_imm_sel = IMM_I;
        tb_instr = {12'hFFB, 5'd2, 3'b000, 5'd1, 7'b0010011}; // FFB = -5 en 12 bits
        check_equal("I-type addi imm=-5", 32'hFFFFFFFB);

        // --- I-type: imm=0 ---
        tb_imm_sel = IMM_I;
        tb_instr = {12'd0, 5'd2, 3'b000, 5'd1, 7'b0010011};
        check_equal("I-type addi imm=0", 32'd0);

        // --- S-type: sw x2, -4(x3)  -> imm[11:5]=1111111, imm[4:0]=11100 (-4 en 12 bits = FFC) ---
        tb_imm_sel = IMM_S;
        tb_instr = {7'b1111111, 5'd2, 5'd3, 3'b010, 5'b11100, 7'b0100011};
        check_equal("S-type sw imm=-4", 32'hFFFFFFFC);

        // --- S-type: sw x2, 20(x3) -> 20 = 12'h014 = imm[11:5]=0000000, imm[4:0]=10100 ---
        tb_imm_sel = IMM_S;
        tb_instr = {7'b0000000, 5'd2, 5'd3, 3'b010, 5'b10100, 7'b0100011};
        check_equal("S-type sw imm=+20", 32'd20);

        // --- B-type: beq x1,x2,+8 -> imm[12]=0,imm[10:5]=000000,imm[4:1]=0100,imm[11]=0 ---
        tb_imm_sel = IMM_B;
        tb_instr = {1'b0, 6'b000000, 5'd2, 5'd1, 3'b000, 4'b0100, 1'b0, 7'b1100011};
        check_equal("B-type beq imm=+8", 32'd8);

        // --- B-type: beq x1,x2,-8 -> imm[12]=1,imm[10:5]=111111,imm[4:1]=1100,imm[11]=1 ---
        tb_imm_sel = IMM_B;
        tb_instr = {1'b1, 6'b111111, 5'd2, 5'd1, 3'b000, 4'b1100, 1'b1, 7'b1100011};
        check_equal("B-type beq imm=-8", 32'hFFFFFFF8);

        // --- U-type: lui x5, 0xABCDE ---
        tb_imm_sel = IMM_U;
        tb_instr = {20'hABCDE, 5'd5, 7'b0110111};
        check_equal("U-type lui imm=0xABCDE000", 32'hABCDE000);

        // --- J-type: jal x1, +2 -> imm[20]=0,imm[10:1]=0000000001,imm[11]=0,imm[19:12]=0 ---
        tb_imm_sel = IMM_J;
        tb_instr = {1'b0, 10'b0000000001, 1'b0, 8'b0, 5'd1, 7'b1101111};
        check_equal("J-type jal imm=+2", 32'd2);

        // --- J-type: jal x1, -2 -> imm[20]=1,imm[10:1]=1111111111,imm[11]=1,imm[19:12]=11111111 ---
        tb_imm_sel = IMM_J;
        tb_instr = {1'b1, 10'b1111111111, 1'b1, 8'b11111111, 5'd1, 7'b1101111};
        check_equal("J-type jal imm=-2", 32'hFFFFFFFE);

        // --- J-type: jal x1, +4096 -> bit12 set: imm[19:12]=00000001, resto 0 ---
        tb_imm_sel = IMM_J;
        tb_instr = {1'b0, 10'b0, 1'b0, 8'b00000001, 5'd1, 7'b1101111};
        check_equal("J-type jal imm=+4096", 32'd4096);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("IMM_GEN: TODOS LOS TESTS PASARON");
        else $display("IMM_GEN: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
