`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_pipeline_trace
//
// Descripción:
// Genera la traza que usa tp3/host/test_riscv_pipeview.py: corre un
// programa chico en modo paso a paso con el riscv_core y la dump_unit
// REALES, haciendo lo mismo que la Debug Unit con un CMD_STEP (liberar
// global_stall_i exactamente un ciclo y disparar el volcado), y escribe
// cada volcado completo -- los mismos bytes que recibiría el host por
// UART -- como una línea de palabras hex en
// tp3/host/testdata/pipeline_trace.hex (el primero es el estado recién
// cargado, ciclo 0, como un CMD_DUMP). Así la vista de pipeline de la GUI
// se prueba contra el comportamiento real del RTL, no contra datos
// armados a mano. Correrlo desde la raíz del repo regenera ese archivo:
// si cambia el RTL y el archivo cambia, git lo muestra.
//
// El programa está armado para pasar, en pocos ciclos, por cada evento
// que la GUI dibuja: forwarding EX/MEM -> EX (operandos A y B, y el dato
// de un store), stall de load-use, forwarding EX -> ID, stall de load
// antes de un salto (2 ciclos) y forwarding MEM/WB -> ID, salto no
// tomado, jal tomado (flush), jalr con forwarding EX/MEM -> ID, HALT
// drenando hasta WB y una instrucción vacía (HALT implícito) en IF que
// el flush descarta sin efecto.
// =============================================================================
module tb_pipeline_trace;

    `include "riscv_isa_encode.vh"

    localparam DMEM_WORDS  = 4;
    localparam FIXED_WORDS = 55;
    localparam TOTAL_WORDS = FIXED_WORDS + DMEM_WORDS;
    localparam MAX_STEPS   = 64;

    parameter CLK_PERIOD = 10;
    reg tb_clk, tb_rst, tb_stall, tb_trigger;
    reg tb_imem_load_en, tb_imem_load_clear;
    reg [31:0] tb_imem_load_addr, tb_imem_load_data;
    wire tb_imem_busy, tb_dmem_busy;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    // --- Núcleo + Dump Unit, cableados como en riscv_uart_top.v ---
    wire [32*32-1:0] regs_flat;
    wire core_halted, branch_taken, pc_write_en, hazard_stall;
    wire [7:0] fwd_sel;
    wire [31:0] cycle_count, if_pc, if_instr;
    wire [31:0] if_id_pc, if_id_instr;
    wire [31:0] id_ex_pc, id_ex_instr, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm;
    wire id_ex_reg_write, id_ex_mem_read, id_ex_mem_write, id_ex_mem_to_reg,
         id_ex_is_jal, id_ex_is_jalr, id_ex_is_halt;
    wire [31:0] ex_mem_pc, ex_mem_instr, ex_mem_ex_result, ex_mem_rs2_data;
    wire ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write, ex_mem_mem_to_reg, ex_mem_is_halt;
    wire [31:0] mem_wb_pc, mem_wb_instr, mem_wb_result, mem_wb_mem_read_data;
    wire mem_wb_reg_write, mem_wb_mem_to_reg, mem_wb_is_halt;
    wire [31:0] dmem_dbg_addr, dmem_dbg_rdata;
    wire dump_done, wr;
    wire [7:0] w_data;
    reg tx_full;

    riscv_core #(.IMEM_DEPTH_WORDS(64), .DMEM_DEPTH_WORDS(DMEM_WORDS)) u_core (
        .clk_i(tb_clk), .rst_i(tb_rst), .global_stall_i(tb_stall),
        .imem_load_en_i(tb_imem_load_en), .imem_load_addr_i(tb_imem_load_addr),
        .imem_load_data_i(tb_imem_load_data), .imem_load_clear_i(tb_imem_load_clear),
        .imem_load_clear_busy_o(tb_imem_busy),
        .dmem_load_en_i(1'b0), .dmem_load_addr_i(32'b0), .dmem_load_data_i(32'b0),
        .dmem_load_clear_i(tb_imem_load_clear), .dmem_load_clear_busy_o(tb_dmem_busy),
        .dmem_dbg_addr_i(dmem_dbg_addr), .dmem_dbg_rdata_o(dmem_dbg_rdata),
        .regs_flat_o(regs_flat), .core_halted_o(core_halted),
        .branch_taken_o(branch_taken), .pc_write_en_o(pc_write_en),
        .hazard_stall_o(hazard_stall), .fwd_sel_o(fwd_sel),
        .cycle_count_o(cycle_count),
        .if_pc_o(if_pc), .if_instr_o(if_instr),
        .if_id_pc_o(if_id_pc), .if_id_instr_o(if_id_instr),
        .id_ex_pc_o(id_ex_pc), .id_ex_instr_o(id_ex_instr),
        .id_ex_rs1_data_o(id_ex_rs1_data), .id_ex_rs2_data_o(id_ex_rs2_data), .id_ex_imm_o(id_ex_imm),
        .id_ex_reg_write_o(id_ex_reg_write), .id_ex_mem_read_o(id_ex_mem_read),
        .id_ex_mem_write_o(id_ex_mem_write), .id_ex_mem_to_reg_o(id_ex_mem_to_reg),
        .id_ex_is_jal_o(id_ex_is_jal), .id_ex_is_jalr_o(id_ex_is_jalr), .id_ex_is_halt_o(id_ex_is_halt),
        .ex_mem_pc_o(ex_mem_pc), .ex_mem_instr_o(ex_mem_instr),
        .ex_mem_ex_result_o(ex_mem_ex_result), .ex_mem_rs2_data_o(ex_mem_rs2_data),
        .ex_mem_reg_write_o(ex_mem_reg_write), .ex_mem_mem_read_o(ex_mem_mem_read),
        .ex_mem_mem_write_o(ex_mem_mem_write), .ex_mem_mem_to_reg_o(ex_mem_mem_to_reg),
        .ex_mem_is_halt_o(ex_mem_is_halt),
        .mem_wb_pc_o(mem_wb_pc), .mem_wb_instr_o(mem_wb_instr),
        .mem_wb_result_o(mem_wb_result), .mem_wb_mem_read_data_o(mem_wb_mem_read_data),
        .mem_wb_reg_write_o(mem_wb_reg_write), .mem_wb_mem_to_reg_o(mem_wb_mem_to_reg),
        .mem_wb_is_halt_o(mem_wb_is_halt)
    );

    dump_unit #(.DMEM_DEPTH_WORDS(DMEM_WORDS)) u_dump (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .dump_trigger_i(tb_trigger), .dump_done_o(dump_done),
        .core_halted_i(core_halted), .branch_taken_i(branch_taken), .pc_write_en_i(pc_write_en),
        .hazard_stall_i(hazard_stall), .fwd_sel_i(fwd_sel),
        .cycle_count_i(cycle_count),
        .if_pc_i(if_pc), .if_instr_i(if_instr),
        .if_id_pc_i(if_id_pc), .if_id_instr_i(if_id_instr),
        .id_ex_pc_i(id_ex_pc), .id_ex_instr_i(id_ex_instr),
        .id_ex_rs1_data_i(id_ex_rs1_data), .id_ex_rs2_data_i(id_ex_rs2_data), .id_ex_imm_i(id_ex_imm),
        .id_ex_reg_write_i(id_ex_reg_write), .id_ex_mem_read_i(id_ex_mem_read),
        .id_ex_mem_write_i(id_ex_mem_write), .id_ex_mem_to_reg_i(id_ex_mem_to_reg),
        .id_ex_is_jal_i(id_ex_is_jal), .id_ex_is_jalr_i(id_ex_is_jalr), .id_ex_is_halt_i(id_ex_is_halt),
        .ex_mem_pc_i(ex_mem_pc), .ex_mem_instr_i(ex_mem_instr),
        .ex_mem_ex_result_i(ex_mem_ex_result), .ex_mem_rs2_data_i(ex_mem_rs2_data),
        .ex_mem_reg_write_i(ex_mem_reg_write), .ex_mem_mem_read_i(ex_mem_mem_read),
        .ex_mem_mem_write_i(ex_mem_mem_write), .ex_mem_mem_to_reg_i(ex_mem_mem_to_reg),
        .ex_mem_is_halt_i(ex_mem_is_halt),
        .mem_wb_pc_i(mem_wb_pc), .mem_wb_instr_i(mem_wb_instr),
        .mem_wb_result_i(mem_wb_result), .mem_wb_mem_read_data_i(mem_wb_mem_read_data),
        .mem_wb_reg_write_i(mem_wb_reg_write), .mem_wb_mem_to_reg_i(mem_wb_mem_to_reg),
        .mem_wb_is_halt_i(mem_wb_is_halt),
        .regs_flat_i(regs_flat),
        .dmem_dbg_addr_o(dmem_dbg_addr), .dmem_dbg_rdata_i(dmem_dbg_rdata),
        .w_data_o(w_data), .tx_full_i(tx_full), .wr_o(wr)
    );

    // Lado Tx mínimo (mismo modelo que tb_dump_unit.v): acepta el byte y lo
    // libera un ciclo después.
    reg [7:0] captured [0:TOTAL_WORDS*4-1];
    integer   capture_idx;
    always @(posedge tb_clk) begin
        if (tb_rst) begin
            tx_full <= 1'b0;
        end
        else if (wr && !tx_full) begin
            captured[capture_idx] <= w_data;
            capture_idx <= capture_idx + 1;
            tx_full <= 1'b1;
        end
        else if (tx_full) begin
            tx_full <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    reg [31:0] prog [0:15];
    integer prog_len, i, fd, n_dumps, pass_count, fail_count;

    task check;
        input [511:0] label;
        input [31:0] got, expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: %0d", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%0d, recibido=%0d", label, expected, got);
            end
        end
    endtask

    // Un volcado completo con el núcleo congelado, escrito como una línea.
    task dump_line;
        integer w;
        begin
            capture_idx = 0;
            @(negedge tb_clk); tb_trigger = 1;
            @(negedge tb_clk); tb_trigger = 0;
            while (!dump_done) @(negedge tb_clk);
            for (w = 0; w < TOTAL_WORDS; w = w + 1)
                $fwrite(fd, "%08x%s", {captured[4*w+3], captured[4*w+2], captured[4*w+1], captured[4*w]},
                        (w == TOTAL_WORDS-1) ? "\n" : " ");
            n_dumps = n_dumps + 1;
        end
    endtask

    initial begin
        $display("========================================");
        $display("Traza paso a paso para test_riscv_pipeview.py");
        $display("========================================");
        pass_count = 0; fail_count = 0; n_dumps = 0;
        tb_rst = 1; tb_stall = 1; tb_trigger = 0;
        tb_imem_load_en = 0; tb_imem_load_clear = 0; tb_imem_load_addr = 0; tb_imem_load_data = 0;

        prog[0]  = i_addi(1, 0, 5);          // 0x00
        prog[1]  = i_add (2, 1, 1);          // 0x04  x2 = 10   (A y B desde EX/MEM)
        prog[2]  = i_sw  (0, 2, 12'd0);      // 0x08  mem[0] = 10 (dato desde EX/MEM)
        prog[3]  = i_lw  (3, 0, 12'd0);      // 0x0C  x3 = 10
        prog[4]  = i_add (4, 3, 2);          // 0x10  x4 = 20   (load-use)
        prog[5]  = i_beq (4, 2, 13'd8);      // 0x14  no tomado (x4 desde EX)
        prog[6]  = i_lw  (5, 0, 12'd0);      // 0x18  x5 = 10
        prog[7]  = i_bne (5, 2, 13'd8);      // 0x1C  load antes de salto; no tomado
        prog[8]  = i_jal (6, 21'd12);        // 0x20  -> 0x2C, x6 = 0x24
        prog[9]  = i_addi(9, 0, 1);          // 0x24  descartada (flush del jal)
        prog[10] = i_halt(0);                // 0x28
        prog[11] = i_jalr(0, 6, 12'd4);      // 0x2C  -> x6+4 = 0x28 (x6 desde EX/MEM)
        prog_len = 12;

        // Carga con el núcleo en reset (igual que CMD_LOAD_PROG)
        @(negedge tb_clk); tb_imem_load_clear = 1;
        @(negedge tb_clk); tb_imem_load_clear = 0;
        while (tb_imem_busy || tb_dmem_busy) @(negedge tb_clk);
        for (i = 0; i < prog_len; i = i + 1) begin
            tb_imem_load_en = 1; tb_imem_load_addr = 4*i; tb_imem_load_data = prog[i];
            @(negedge tb_clk);
        end
        tb_imem_load_en = 0;
        @(negedge tb_clk); tb_rst = 0;

        fd = $fopen("tp3/host/testdata/pipeline_trace.hex", "w");
        if (fd == 0) begin
            $display("No se pudo abrir tp3/host/testdata/pipeline_trace.hex (correr desde la raiz del repo)");
            $finish;
        end

        dump_line; // ciclo 0, como un CMD_DUMP recién cargado
        while (!core_halted && n_dumps < MAX_STEPS) begin
            // CMD_STEP: exactamente un ciclo libre
            @(negedge tb_clk); tb_stall = 0;
            @(negedge tb_clk); tb_stall = 1;
            dump_line;
        end
        $fclose(fd);

        check("llego a HALT", core_halted, 1);
        check("volcados escritos (ciclos 0..HALT en WB)", n_dumps, cycle_count + 1);
        check("x6 = 0x24 (enlace del jal)", regs_flat[32*6 +: 32], 32'h24);
        check("x9 = 0 (instruccion descartada)", regs_flat[32*9 +: 32], 0);
        check("x4 = 20", regs_flat[32*4 +: 32], 20);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        $finish;
    end

endmodule
