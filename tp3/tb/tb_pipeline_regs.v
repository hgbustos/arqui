`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_pipeline_regs
//
// Descripción:
// Verifica los 4 latches de pipeline en un solo testbench (son simples y
// comparten patrón): if_id_reg (freeze vs. flush-a-NOP), id_ex_reg (bubble
// fuerza TODOS los campos, incluidas las señales de control, a inerte),
// y ex_mem_reg/mem_wb_reg (passthrough síncrono liso, sin stall/flush,
// más reset). El valor de NOP esperado (0x00000013 = addi x0,x0,0) se
// verifica explícitamente porque es la pieza clave que evita que un
// flush/burbuja dispare un halt implícito por accidente (ver comentarios
// en if_id_reg.v / id_ex_reg.v).
// =============================================================================
module tb_pipeline_regs;

    localparam NOP = 32'h00000013;
    parameter CLK_PERIOD = 10;

    reg tb_clk, tb_rst;
    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    task check32;
        input [511:0] label;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: 0x%08h", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, got);
            end
        end
    endtask

    task check1;
        input [511:0] label;
        input got;
        input expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: %0b", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%0b, recibido=%0b", label, expected, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // if_id_reg
    // ------------------------------------------------------------------
    reg  ifid_we, ifid_flush;
    reg  [31:0] ifid_pc_i, ifid_instr_i;
    wire [31:0] ifid_pc_o, ifid_instr_o;

    if_id_reg u_ifid (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .write_en_i(ifid_we), .flush_i(ifid_flush),
        .pc_i(ifid_pc_i), .instr_i(ifid_instr_i),
        .pc_o(ifid_pc_o), .instr_o(ifid_instr_o)
    );

    // ------------------------------------------------------------------
    // id_ex_reg
    // ------------------------------------------------------------------
    reg  idex_bubble;
    reg  [31:0] idex_pc_i, idex_rs1_i, idex_rs2_i, idex_imm_i, idex_instr_i;
    reg  idex_rw_i, idex_asa_i, idex_asb_i, idex_mr_i, idex_mw_i, idex_m2r_i, idex_jal_i, idex_jalr_i, idex_halt_i;
    reg  [1:0] idex_aluop_i;
    wire [31:0] idex_pc_o, idex_rs1_o, idex_rs2_o, idex_imm_o, idex_instr_o;
    wire idex_rw_o, idex_asa_o, idex_asb_o, idex_mr_o, idex_mw_o, idex_m2r_o, idex_jal_o, idex_jalr_o, idex_halt_o;
    wire [1:0] idex_aluop_o;

    id_ex_reg u_idex (
        .clk_i(tb_clk), .rst_i(tb_rst), .bubble_i(idex_bubble),
        .pc_i(idex_pc_i), .rs1_data_i(idex_rs1_i), .rs2_data_i(idex_rs2_i),
        .imm_i(idex_imm_i), .instr_i(idex_instr_i),
        .reg_write_i(idex_rw_i), .alu_src_a_i(idex_asa_i), .alu_src_b_i(idex_asb_i),
        .alu_op_i(idex_aluop_i), .mem_read_i(idex_mr_i), .mem_write_i(idex_mw_i),
        .mem_to_reg_i(idex_m2r_i), .is_jal_i(idex_jal_i), .is_jalr_i(idex_jalr_i), .is_halt_i(idex_halt_i),
        .pc_o(idex_pc_o), .rs1_data_o(idex_rs1_o), .rs2_data_o(idex_rs2_o),
        .imm_o(idex_imm_o), .instr_o(idex_instr_o),
        .reg_write_o(idex_rw_o), .alu_src_a_o(idex_asa_o), .alu_src_b_o(idex_asb_o),
        .alu_op_o(idex_aluop_o), .mem_read_o(idex_mr_o), .mem_write_o(idex_mw_o),
        .mem_to_reg_o(idex_m2r_o), .is_jal_o(idex_jal_o), .is_jalr_o(idex_jalr_o), .is_halt_o(idex_halt_o)
    );

    // ------------------------------------------------------------------
    // ex_mem_reg / mem_wb_reg (passthrough liso)
    // ------------------------------------------------------------------
    reg  [31:0] exmem_pc_i, exmem_res_i, exmem_rs2_i, exmem_instr_i;
    reg  exmem_rw_i, exmem_mr_i, exmem_mw_i, exmem_m2r_i, exmem_halt_i;
    wire [31:0] exmem_pc_o, exmem_res_o, exmem_rs2_o, exmem_instr_o;
    wire exmem_rw_o, exmem_mr_o, exmem_mw_o, exmem_m2r_o, exmem_halt_o;

    ex_mem_reg u_exmem (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .pc_i(exmem_pc_i), .ex_result_i(exmem_res_i), .rs2_data_i(exmem_rs2_i), .instr_i(exmem_instr_i),
        .reg_write_i(exmem_rw_i), .mem_read_i(exmem_mr_i), .mem_write_i(exmem_mw_i),
        .mem_to_reg_i(exmem_m2r_i), .is_halt_i(exmem_halt_i),
        .pc_o(exmem_pc_o), .ex_result_o(exmem_res_o), .rs2_data_o(exmem_rs2_o), .instr_o(exmem_instr_o),
        .reg_write_o(exmem_rw_o), .mem_read_o(exmem_mr_o), .mem_write_o(exmem_mw_o),
        .mem_to_reg_o(exmem_m2r_o), .is_halt_o(exmem_halt_o)
    );

    reg  [31:0] memwb_pc_i, memwb_res_i, memwb_mdata_i, memwb_instr_i;
    reg  memwb_rw_i, memwb_m2r_i, memwb_halt_i;
    wire [31:0] memwb_pc_o, memwb_res_o, memwb_mdata_o, memwb_instr_o;
    wire memwb_rw_o, memwb_m2r_o, memwb_halt_o;

    mem_wb_reg u_memwb (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .pc_i(memwb_pc_i), .result_i(memwb_res_i), .mem_read_data_i(memwb_mdata_i), .instr_i(memwb_instr_i),
        .reg_write_i(memwb_rw_i), .mem_to_reg_i(memwb_m2r_i), .is_halt_i(memwb_halt_i),
        .pc_o(memwb_pc_o), .result_o(memwb_res_o), .mem_read_data_o(memwb_mdata_o), .instr_o(memwb_instr_o),
        .reg_write_o(memwb_rw_o), .mem_to_reg_o(memwb_m2r_o), .is_halt_o(memwb_halt_o)
    );

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de latches de pipeline");
        $display("========================================");
        pass_count = 0; fail_count = 0;

        tb_rst = 1;
        ifid_we = 1; ifid_flush = 0; ifid_pc_i = 0; ifid_instr_i = 0;
        idex_bubble = 0; idex_pc_i=0; idex_rs1_i=0; idex_rs2_i=0; idex_imm_i=0; idex_instr_i=0;
        idex_rw_i=0; idex_asa_i=0; idex_asb_i=0; idex_aluop_i=0; idex_mr_i=0; idex_mw_i=0;
        idex_m2r_i=0; idex_jal_i=0; idex_jalr_i=0; idex_halt_i=0;
        exmem_pc_i=0; exmem_res_i=0; exmem_rs2_i=0; exmem_instr_i=0;
        exmem_rw_i=0; exmem_mr_i=0; exmem_mw_i=0; exmem_m2r_i=0; exmem_halt_i=0;
        memwb_pc_i=0; memwb_res_i=0; memwb_mdata_i=0; memwb_instr_i=0;
        memwb_rw_i=0; memwb_m2r_i=0; memwb_halt_i=0;
        #(CLK_PERIOD*2);
        tb_rst = 0;

        $display("\n--- Reset ---");
        check32("if_id pc post-reset", ifid_pc_o, 32'h0);
        check32("if_id instr post-reset (NOP)", ifid_instr_o, NOP);
        check32("id_ex instr post-reset (NOP)", idex_instr_o, NOP);
        check1 ("id_ex reg_write post-reset", idex_rw_o, 1'b0);
        check32("ex_mem instr post-reset (NOP)", exmem_instr_o, NOP);
        check32("mem_wb instr post-reset (NOP)", memwb_instr_o, NOP);

        $display("\n--- if_id_reg: update normal ---");
        ifid_pc_i = 32'h1000; ifid_instr_i = 32'hAABBCCDD;
        @(posedge tb_clk); #1;
        check32("if_id pc tras update", ifid_pc_o, 32'h1000);
        check32("if_id instr tras update", ifid_instr_o, 32'hAABBCCDD);

        $display("\n--- if_id_reg: freeze mantiene el valor ---");
        ifid_we = 0;
        ifid_pc_i = 32'h9999; ifid_instr_i = 32'hFFFFFFFF; // no deberian verse
        @(posedge tb_clk); #1;
        check32("if_id pc tras freeze (sin cambio)", ifid_pc_o, 32'h1000);
        check32("if_id instr tras freeze (sin cambio)", ifid_instr_o, 32'hAABBCCDD);

        $display("\n--- if_id_reg: flush fuerza NOP ---");
        ifid_we = 1; ifid_flush = 1;
        @(posedge tb_clk); #1;
        check32("if_id pc tras flush", ifid_pc_o, 32'h0);
        check32("if_id instr tras flush (NOP real)", ifid_instr_o, NOP);
        ifid_flush = 0;

        $display("\n--- id_ex_reg: update normal ---");
        idex_pc_i = 32'h2000; idex_rs1_i = 32'h11; idex_rs2_i = 32'h22; idex_imm_i = 32'h33;
        idex_instr_i = 32'hDEADBEEF;
        idex_rw_i = 1; idex_asb_i = 1; idex_aluop_i = 2'b01; idex_mr_i = 1; idex_halt_i = 1;
        @(posedge tb_clk); #1;
        check32("id_ex pc tras update", idex_pc_o, 32'h2000);
        check32("id_ex rs1 tras update", idex_rs1_o, 32'h11);
        check32("id_ex instr tras update", idex_instr_o, 32'hDEADBEEF);
        check1 ("id_ex reg_write tras update", idex_rw_o, 1'b1);
        check1 ("id_ex mem_read tras update", idex_mr_o, 1'b1);
        check1 ("id_ex is_halt tras update", idex_halt_o, 1'b1);

        $display("\n--- id_ex_reg: bubble fuerza TODO a inerte ---");
        idex_bubble = 1;
        // Los datos de entrada siguen "activos" (como pasaria en la
        // realidad: control_unit sigue decodificando algo ese ciclo) pero
        // deben ser ignorados por completo.
        idex_pc_i = 32'h7777; idex_rw_i = 1; idex_mr_i = 1; idex_halt_i = 1; idex_jal_i = 1;
        @(posedge tb_clk); #1;
        check32("id_ex instr tras bubble (NOP real)", idex_instr_o, NOP);
        check1 ("id_ex reg_write tras bubble (0)", idex_rw_o, 1'b0);
        check1 ("id_ex mem_read tras bubble (0)", idex_mr_o, 1'b0);
        check1 ("id_ex is_halt tras bubble (0, no debe verse forzado)", idex_halt_o, 1'b0);
        check1 ("id_ex is_jal tras bubble (0)", idex_jal_o, 1'b0);
        check32("id_ex pc tras bubble (0)", idex_pc_o, 32'h0);
        idex_bubble = 0;

        $display("\n--- ex_mem_reg / mem_wb_reg: passthrough liso ---");
        exmem_pc_i = 32'h3000; exmem_res_i = 32'hCAFE; exmem_rs2_i = 32'hBABE; exmem_instr_i = 32'h12345678;
        exmem_rw_i = 1; exmem_mw_i = 1; exmem_halt_i = 0;
        memwb_pc_i = 32'h4000; memwb_res_i = 32'hF00D; memwb_mdata_i = 32'hFEED; memwb_instr_i = 32'h87654321;
        memwb_rw_i = 1; memwb_halt_i = 1;
        @(posedge tb_clk); #1;
        check32("ex_mem ex_result tras update", exmem_res_o, 32'hCAFE);
        check32("ex_mem instr tras update", exmem_instr_o, 32'h12345678);
        check1 ("ex_mem mem_write tras update", exmem_mw_o, 1'b1);
        check32("mem_wb result tras update", memwb_res_o, 32'hF00D);
        check32("mem_wb mem_read_data tras update", memwb_mdata_o, 32'hFEED);
        check1 ("mem_wb is_halt tras update", memwb_halt_o, 1'b1);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("PIPELINE_REGS: TODOS LOS TESTS PASARON");
        else $display("PIPELINE_REGS: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
