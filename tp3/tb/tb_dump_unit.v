`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_dump_unit
//
// Descripción:
// Verifica dump_unit.v de punta a punta: arma valores de prueba
// reconocibles para cada entrada (registros, los 4 latches, status,
// ciclos, y una dmem chica simulada localmente), dispara un volcado,
// captura los bytes que salen por el lado Tx (con un modelo simple de
// tx_full_i, no timing real de UART -- eso lo cubre tb_riscv_uart_top.v)
// y decodifica cada palabra de 32 bits (little-endian) para compararla
// contra el mapa de palabras de tp3/docs/debug_protocol.md.
// =============================================================================
module tb_dump_unit;

    localparam DMEM_WORDS = 4;
    localparam FIXED_WORDS = 53;
    localparam TOTAL_WORDS = FIXED_WORDS + DMEM_WORDS;

    parameter CLK_PERIOD = 10;
    reg tb_clk, tb_rst;
    reg tb_trigger;
    wire tb_done;

    reg tb_core_halted, tb_branch_taken, tb_pc_we;
    reg [31:0] tb_cycle_count;

    reg [31:0] tb_ifid_pc, tb_ifid_instr;
    reg [31:0] tb_idex_pc, tb_idex_instr, tb_idex_rs1, tb_idex_rs2, tb_idex_imm;
    reg tb_idex_rw, tb_idex_mr, tb_idex_mw, tb_idex_m2r, tb_idex_jal, tb_idex_jalr, tb_idex_halt;
    reg [31:0] tb_exmem_pc, tb_exmem_instr, tb_exmem_res, tb_exmem_rs2;
    reg tb_exmem_rw, tb_exmem_mr, tb_exmem_mw, tb_exmem_m2r, tb_exmem_halt;
    reg [31:0] tb_memwb_pc, tb_memwb_instr, tb_memwb_res, tb_memwb_mdata;
    reg tb_memwb_rw, tb_memwb_m2r, tb_memwb_halt;

    reg [32*32-1:0] tb_regs_flat;

    wire [31:0] tb_dbg_addr;
    reg  [31:0] tb_dbg_rdata;
    reg  [31:0] dmem_model [0:DMEM_WORDS-1];

    wire [7:0] tb_w_data;
    reg        tb_tx_full;
    wire       tb_wr;

    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    dump_unit #(.DMEM_DEPTH_WORDS(DMEM_WORDS)) uut (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .dump_trigger_i(tb_trigger), .dump_done_o(tb_done),
        .core_halted_i(tb_core_halted), .branch_taken_i(tb_branch_taken), .pc_write_en_i(tb_pc_we),
        .cycle_count_i(tb_cycle_count),
        .if_id_pc_i(tb_ifid_pc), .if_id_instr_i(tb_ifid_instr),
        .id_ex_pc_i(tb_idex_pc), .id_ex_instr_i(tb_idex_instr),
        .id_ex_rs1_data_i(tb_idex_rs1), .id_ex_rs2_data_i(tb_idex_rs2), .id_ex_imm_i(tb_idex_imm),
        .id_ex_reg_write_i(tb_idex_rw), .id_ex_mem_read_i(tb_idex_mr), .id_ex_mem_write_i(tb_idex_mw),
        .id_ex_mem_to_reg_i(tb_idex_m2r), .id_ex_is_jal_i(tb_idex_jal), .id_ex_is_jalr_i(tb_idex_jalr),
        .id_ex_is_halt_i(tb_idex_halt),
        .ex_mem_pc_i(tb_exmem_pc), .ex_mem_instr_i(tb_exmem_instr),
        .ex_mem_ex_result_i(tb_exmem_res), .ex_mem_rs2_data_i(tb_exmem_rs2),
        .ex_mem_reg_write_i(tb_exmem_rw), .ex_mem_mem_read_i(tb_exmem_mr), .ex_mem_mem_write_i(tb_exmem_mw),
        .ex_mem_mem_to_reg_i(tb_exmem_m2r), .ex_mem_is_halt_i(tb_exmem_halt),
        .mem_wb_pc_i(tb_memwb_pc), .mem_wb_instr_i(tb_memwb_instr),
        .mem_wb_result_i(tb_memwb_res), .mem_wb_mem_read_data_i(tb_memwb_mdata),
        .mem_wb_reg_write_i(tb_memwb_rw), .mem_wb_mem_to_reg_i(tb_memwb_m2r), .mem_wb_is_halt_i(tb_memwb_halt),
        .regs_flat_i(tb_regs_flat),
        .dmem_dbg_addr_o(tb_dbg_addr), .dmem_dbg_rdata_i(tb_dbg_rdata),
        .w_data_o(tb_w_data), .tx_full_i(tb_tx_full), .wr_o(tb_wr)
    );

    // Modelo minimo de dmem: lectura combinacional segun la direccion que
    // pide dump_unit (byte, palabra-alineada).
    always @(*) begin
        tb_dbg_rdata = dmem_model[tb_dbg_addr[31:2]];
    end

    // Modelo minimo del lado Tx de uart_interface.v: acepta el byte
    // (tx_full sube) apenas ve wr_o con tx_full en bajo, y lo libera 1
    // ciclo despues. No es timing real de UART (eso es tb_riscv_uart_top.v);
    // alcanza para ejercitar el handshake de dos pasos de dump_unit.v.
    reg [7:0] captured [0:1023];
    integer   capture_idx;
    always @(posedge tb_clk, posedge tb_rst) begin
        if (tb_rst) begin
            tb_tx_full  <= 1'b0;
            capture_idx <= 0;
        end
        else if (tb_wr && !tb_tx_full) begin
            captured[capture_idx] <= tb_w_data;
            capture_idx <= capture_idx + 1;
            tb_tx_full <= 1'b1;
        end
        else if (tb_tx_full) begin
            tb_tx_full <= 1'b0;
        end
    end

    reg [31:0] expected [0:TOTAL_WORDS-1];
    integer i;

    task check_word;
        input [511:0] label;
        input [31:0]  idx;
        input [31:0]  expected_val;
        reg [31:0] got;
        begin
            got = {captured[idx*4+3], captured[idx*4+2], captured[idx*4+1], captured[idx*4+0]};
            if (got === expected_val) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s (palabra %0d): 0x%08h", label, idx, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s (palabra %0d): esperado=0x%08h, recibido=0x%08h", label, idx, expected_val, got);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de dump_unit");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_rst = 1; tb_trigger = 0;

        // --- Valores de prueba, todos reconocibles ---
        tb_core_halted = 1; tb_branch_taken = 0; tb_pc_we = 0; // stalled = ~pc_we = 1
        tb_cycle_count = 32'd12345;

        tb_ifid_pc = 32'h00000010; tb_ifid_instr = 32'h00000013;

        tb_idex_pc = 32'h00000014; tb_idex_instr = 32'h002081B3;
        tb_idex_rs1 = 32'hAAAA0001; tb_idex_rs2 = 32'hAAAA0002; tb_idex_imm = 32'hAAAA0003;
        tb_idex_rw = 1; tb_idex_mr = 0; tb_idex_mw = 0; tb_idex_m2r = 0;
        tb_idex_jal = 1; tb_idex_jalr = 0; tb_idex_halt = 0;
        // control = {is_halt,is_jalr,is_jal,mem_to_reg,mem_write,mem_read,reg_write}
        //         = {0,0,1,0,0,0,1} = 0b0010001 = 0x11

        tb_exmem_pc = 32'h00000018; tb_exmem_instr = 32'h00302023;
        tb_exmem_res = 32'hBBBB0001; tb_exmem_rs2 = 32'hBBBB0002;
        tb_exmem_rw = 0; tb_exmem_mr = 0; tb_exmem_mw = 1; tb_exmem_m2r = 0; tb_exmem_halt = 0;
        // control = {is_halt,mem_to_reg,mem_write,mem_read,reg_write} = {0,0,1,0,0} = 0b00100 = 0x4

        tb_memwb_pc = 32'h0000001C; tb_memwb_instr = 32'h0000006F;
        tb_memwb_res = 32'hCCCC0001; tb_memwb_mdata = 32'hCCCC0002;
        tb_memwb_rw = 1; tb_memwb_m2r = 1; tb_memwb_halt = 0;
        // control = {is_halt,mem_to_reg,reg_write} = {0,1,1} = 0b011 = 0x3

        for (i = 0; i < 32; i = i + 1) begin
            tb_regs_flat[32*i +: 32] = 32'h00000100 + i;
        end

        for (i = 0; i < DMEM_WORDS; i = i + 1) begin
            dmem_model[i] = 32'hDDDD0000 + i;
        end

        #(CLK_PERIOD*2);
        tb_rst = 0;
        #1;

        // --- Palabras esperadas (mismo orden que debug_protocol.md) ---
        expected[0]  = 32'hAA55AA55;
        expected[1]  = {29'b0, 1'b1, 1'b0, 1'b1}; // stalled=1, branch_taken=0, core_halted=1
        expected[2]  = 32'd12345;
        expected[3]  = tb_ifid_pc;
        expected[4]  = tb_ifid_instr;
        expected[5]  = tb_idex_pc;
        expected[6]  = tb_idex_instr;
        expected[7]  = tb_idex_rs1;
        expected[8]  = tb_idex_rs2;
        expected[9]  = tb_idex_imm;
        expected[10] = 32'h00000011;
        expected[11] = tb_exmem_pc;
        expected[12] = tb_exmem_instr;
        expected[13] = tb_exmem_res;
        expected[14] = tb_exmem_rs2;
        expected[15] = 32'h00000004;
        expected[16] = tb_memwb_pc;
        expected[17] = tb_memwb_instr;
        expected[18] = tb_memwb_res;
        expected[19] = tb_memwb_mdata;
        expected[20] = 32'h00000003;
        for (i = 0; i < 32; i = i + 1) begin
            expected[21+i] = 32'h00000100 + i;
        end
        for (i = 0; i < DMEM_WORDS; i = i + 1) begin
            expected[FIXED_WORDS+i] = 32'hDDDD0000 + i;
        end

        // --- Dispara el volcado y espera a que termine ---
        tb_trigger = 1;
        @(posedge tb_clk); #1;
        tb_trigger = 0;

        while (!tb_done) begin
            @(posedge tb_clk);
        end
        #1;

        check("cantidad de bytes capturados", capture_idx, TOTAL_WORDS*4);

        check_word("SYNC",          0,  expected[0]);
        check_word("STATUS",        1,  expected[1]);
        check_word("CYCLE_COUNT",   2,  expected[2]);
        check_word("IF/ID.pc",      3,  expected[3]);
        check_word("IF/ID.instr",   4,  expected[4]);
        check_word("ID/EX.pc",      5,  expected[5]);
        check_word("ID/EX.instr",   6,  expected[6]);
        check_word("ID/EX.rs1",     7,  expected[7]);
        check_word("ID/EX.rs2",     8,  expected[8]);
        check_word("ID/EX.imm",     9,  expected[9]);
        check_word("ID/EX.control", 10, expected[10]);
        check_word("EX/MEM.pc",     11, expected[11]);
        check_word("EX/MEM.instr",  12, expected[12]);
        check_word("EX/MEM.result", 13, expected[13]);
        check_word("EX/MEM.rs2",    14, expected[14]);
        check_word("EX/MEM.control",15, expected[15]);
        check_word("MEM/WB.pc",     16, expected[16]);
        check_word("MEM/WB.instr",  17, expected[17]);
        check_word("MEM/WB.result", 18, expected[18]);
        check_word("MEM/WB.mdata",  19, expected[19]);
        check_word("MEM/WB.control",20, expected[20]);

        for (i = 0; i < 32; i = i + 1) begin
            check_word("registro", 21+i, expected[21+i]);
        end
        for (i = 0; i < DMEM_WORDS; i = i + 1) begin
            check_word("dmem", FIXED_WORDS+i, expected[FIXED_WORDS+i]);
        end

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("DUMP_UNIT: TODOS LOS TESTS PASARON");
        else $display("DUMP_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

    task check;
        input [511:0] label;
        input integer got;
        input integer expected_val;
        begin
            if (got === expected_val) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: %0d", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%0d, recibido=%0d", label, expected_val, got);
            end
        end
    endtask

endmodule
