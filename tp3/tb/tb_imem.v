`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_imem
//
// Descripción:
// Verifica imem.v: carga por el puerto de loader, lectura combinacional
// del pipeline con direcciones de BYTE (confirma que se descartan los 2
// bits bajos correctamente), y que load_clear_i vacía toda la memoria.
// =============================================================================
module tb_imem;

    parameter CLK_PERIOD = 10;
    reg tb_clk;
    reg [31:0] tb_addr;
    wire [31:0] tb_instr;
    reg tb_load_en, tb_load_clear;
    reg [31:0] tb_load_addr, tb_load_data;
    wire tb_clear_busy;

    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    imem #(.DEPTH_WORDS(64)) uut (
        .clk_i(tb_clk),
        .addr_i(tb_addr), .instr_o(tb_instr),
        .load_en_i(tb_load_en), .load_addr_i(tb_load_addr),
        .load_data_i(tb_load_data), .load_clear_i(tb_load_clear),
        .clear_busy_o(tb_clear_busy)
    );

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

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de imem");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_addr = 0; tb_load_en = 0; tb_load_clear = 0; tb_load_addr = 0; tb_load_data = 0;
        #(CLK_PERIOD*2);

        load_word(32'h0, 32'h00000013); // NOP en addr 0
        load_word(32'h4, 32'hDEADBEEF); // addr 4  -> word index 1
        load_word(32'h8, 32'hCAFEF00D); // addr 8  -> word index 2

        tb_addr = 32'h0; #1;
        check32("instr en addr=0", tb_instr, 32'h00000013);
        tb_addr = 32'h4; #1;
        check32("instr en addr=4", tb_instr, 32'hDEADBEEF);
        tb_addr = 32'h8; #1;
        check32("instr en addr=8", tb_instr, 32'hCAFEF00D);

        $display("\n--- load_clear_i vacia todo (barrido secuencial, 1 direccion/ciclo) ---");
        tb_load_clear = 1;
        @(posedge tb_clk);
        #1; // evita la misma carrera que load_word
        tb_load_clear = 0;
        while (tb_clear_busy) @(posedge tb_clk);
        #1;
        tb_addr = 32'h4; #1;
        check32("instr en addr=4 tras clear", tb_instr, 32'h0);
        tb_addr = 32'h8; #1;
        check32("instr en addr=8 tras clear", tb_instr, 32'h0);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("IMEM: TODOS LOS TESTS PASARON");
        else $display("IMEM: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
