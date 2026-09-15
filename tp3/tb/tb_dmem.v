`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_dmem
//
// Descripción:
// Verifica dmem.v: carga por el puerto de loader, sw/lw de palabra
// completa, sb en los 4 offsets de byte dentro de una palabra (confirma
// que sólo cambia el byte apuntado, el resto se preserva) con lb/lbu
// releyendo cada uno (con y sin extensión de signo), sh en los 2 offsets
// de media palabra con lh/lhu, y que load_clear_i vacía todo.
// =============================================================================
module tb_dmem;

    parameter CLK_PERIOD = 10;
    reg tb_clk;
    reg  [31:0] tb_addr, tb_wdata;
    reg  [2:0]  tb_funct3;
    reg         tb_mem_write;
    wire [31:0] tb_rdata;
    reg  tb_load_en, tb_load_clear;
    reg  [31:0] tb_load_addr, tb_load_data;
    wire tb_clear_busy;
    reg  [31:0] tb_dbg_addr;
    wire [31:0] tb_dbg_rdata;

    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    dmem #(.DEPTH_WORDS(64)) uut (
        .clk_i(tb_clk),
        .addr_i(tb_addr), .wdata_i(tb_wdata), .funct3_i(tb_funct3),
        .mem_write_i(tb_mem_write), .rdata_o(tb_rdata),
        .load_en_i(tb_load_en), .load_addr_i(tb_load_addr),
        .load_data_i(tb_load_data), .load_clear_i(tb_load_clear),
        .clear_busy_o(tb_clear_busy),
        .dbg_addr_i(tb_dbg_addr), .dbg_rdata_o(tb_dbg_rdata)
    );

    task load_word;
        input [31:0] addr;
        input [31:0] data;
        begin
            tb_load_en = 1; tb_load_addr = addr; tb_load_data = data;
            @(posedge tb_clk);
            #1; // evita la carrera con el always @(posedge) del propio DUT
            tb_load_en = 0;
        end
    endtask

    // store_word: escritura via el puerto normal del pipeline (con
    // enmascarado segun funct3), no via el puerto de loader.
    task store_word;
        input [31:0] addr;
        input [31:0] data;
        input [2:0]  funct3;
        begin
            tb_addr = addr; tb_wdata = data; tb_funct3 = funct3; tb_mem_write = 1;
            @(posedge tb_clk);
            #1;
            tb_mem_write = 0;
        end
    endtask

    // check_read: arma la lectura (addr/funct3) y compara rdata_o. Es un
    // task (no una funcion) a proposito: necesita el '#1' para dejar
    // asentar la logica combinacional de dmem antes de leer 'tb_rdata', y
    // las funciones de Verilog no admiten controles de tiempo.
    task check_read;
        input [511:0] label;
        input [31:0]  addr;
        input [2:0]   funct3;
        input [31:0]  expected;
        begin
            tb_addr = addr; tb_funct3 = funct3;
            #1;
            if (tb_rdata === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: 0x%08h", label, tb_rdata);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, tb_rdata);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de dmem");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_addr=0; tb_wdata=0; tb_funct3=3'b010; tb_mem_write=0;
        tb_load_en=0; tb_load_clear=0; tb_load_addr=0; tb_load_data=0;
        #(CLK_PERIOD*2);

        $display("\n--- Puerto de loader + LW ---");
        load_word(32'h0, 32'h11223344);
        check_read("lw tras loader", 32'h0, 3'b010, 32'h11223344);

        $display("\n--- SW + LW ---");
        store_word(32'h4, 32'hAABBCCDD, 3'b010);
        check_read("lw tras sw", 32'h4, 3'b010, 32'hAABBCCDD);

        $display("\n--- SB en los 4 offsets, no debe pisar el resto de la palabra ---");
        load_word(32'h8, 32'h00000000);
        store_word(32'h8, 32'hFFFFFF7F, 3'b000); // byte_off=0 -> solo mem[8][7:0]=0x7F
        check_read("sb offset0 (lw completo)", 32'h8, 3'b010, 32'h0000007F);
        store_word(32'h9, 32'hFFFFFF55, 3'b000); // byte_off=1 -> mem[8][15:8]=0x55
        check_read("sb offset1 (lw completo)", 32'h8, 3'b010, 32'h0000557F);
        store_word(32'hA, 32'hFFFFFF33, 3'b000); // byte_off=2 -> mem[8][23:16]=0x33
        check_read("sb offset2 (lw completo)", 32'h8, 3'b010, 32'h0033557F);
        store_word(32'hB, 32'hFFFFFF90, 3'b000); // byte_off=3 -> mem[8][31:24]=0x90 (negativo como byte)
        check_read("sb offset3 (lw completo)", 32'h8, 3'b010, 32'h9033557F);

        $display("\n--- LB / LBU sobre lo recien escrito ---");
        check_read("lbu offset0 (0x7F, positivo)", 32'h8, 3'b100, 32'h0000007F);
        check_read("lb  offset0 (0x7F, positivo con signo)", 32'h8, 3'b000, 32'h0000007F);
        check_read("lbu offset3 (0x90, sin signo)", 32'hB, 3'b100, 32'h00000090);
        check_read("lb  offset3 (0x90, con signo -> negativo)", 32'hB, 3'b000, 32'hFFFFFF90);

        $display("\n--- SH en los 2 offsets de media palabra ---");
        load_word(32'hC, 32'h00000000);
        store_word(32'hC, 32'h0000ABCD, 3'b001); // byte_off[1]=0 -> mem[12][15:0]=0xABCD
        check_read("sh offset0 (lw completo)", 32'hC, 3'b010, 32'h0000ABCD);
        store_word(32'hE, 32'h00007E5A, 3'b001); // byte_off[1]=1 -> mem[12][31:16]=0x7E5A
        check_read("sh offset1 (lw completo)", 32'hC, 3'b010, 32'h7E5AABCD);

        $display("\n--- LH / LHU sobre lo recien escrito ---");
        check_read("lhu offset0 (0xABCD, sin signo)", 32'hC, 3'b101, 32'h0000ABCD);
        check_read("lh  offset0 (0xABCD, con signo -> negativo)", 32'hC, 3'b001, 32'hFFFFABCD);
        check_read("lhu offset1 (0x7E5A, positivo)", 32'hE, 3'b101, 32'h00007E5A);
        check_read("lh  offset1 (0x7E5A, positivo con signo)", 32'hE, 3'b001, 32'h00007E5A);

        $display("\n--- Puerto de debug (dbg_addr_i/dbg_rdata_o), independiente del pipeline ---");
        // mem[word 3] (byte addr 0xC) vale 0x7E5AABCD tras el bloque de SH.
        // Se lee por el puerto de debug mientras el puerto del pipeline
        // sigue apuntando a otra direccion (0x0), para confirmar que no
        // contienden entre si.
        tb_addr = 32'h0; tb_funct3 = 3'b010;
        tb_dbg_addr = 32'hC;
        #1;
        check_read("dbg_rdata_o no afecta rdata_o del pipeline (siguen direcciones distintas)", 32'h0, 3'b010, 32'h11223344);
        if (tb_dbg_rdata === 32'h7E5AABCD) begin
            pass_count = pass_count + 1;
            $display("  -> EXITO | dbg_rdata_o lee la misma memoria que el pipeline: 0x%08h", tb_dbg_rdata);
        end else begin
            fail_count = fail_count + 1;
            $error("  -> FALLO | dbg_rdata_o: esperado=0x7E5AABCD, recibido=0x%08h", tb_dbg_rdata);
        end

        $display("\n--- load_clear_i vacia todo (barrido secuencial, 1 direccion/ciclo) ---");
        tb_load_clear = 1;
        @(posedge tb_clk);
        #1;
        tb_load_clear = 0;
        while (tb_clear_busy) @(posedge tb_clk);
        #1;
        check_read("lw en addr=4 tras clear", 32'h4, 3'b010, 32'h0);
        check_read("lw en addr=8 tras clear", 32'h8, 3'b010, 32'h0);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("DMEM: TODOS LOS TESTS PASARON");
        else $display("DMEM: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
