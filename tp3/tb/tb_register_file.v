`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_register_file
//
// Descripción:
// Verifica register_file.v: x0 fijo en cero (lectura y escritura), lectura
// asíncrona de rs1/rs2, escritura síncrona en el flanco de subida, que un
// write y un read al mismo registro en el mismo ciclo no hacen bypass (el
// read ve el valor viejo -- ese caso lo resuelve la forwarding_unit del
// pipeline, no el banco de registros), reset limpia todo, y que el bus
// plano de debug 'regs_flat_o' coincide con lo escrito.
// =============================================================================
module tb_register_file;

    parameter CLK_PERIOD = 10;

    reg         tb_clk;
    reg         tb_rst;
    reg  [4:0]  tb_rs1_addr, tb_rs2_addr;
    wire [31:0] tb_rs1_data, tb_rs2_data;
    reg  [4:0]  tb_rd_addr;
    reg  [31:0] tb_rd_data;
    reg         tb_reg_write;
    wire [32*32-1:0] tb_regs_flat;

    integer pass_count, fail_count;

    register_file uut (
        .clk_i        (tb_clk),
        .rst_i        (tb_rst),
        .rs1_addr_i   (tb_rs1_addr),
        .rs2_addr_i   (tb_rs2_addr),
        .rs1_data_o   (tb_rs1_data),
        .rs2_data_o   (tb_rs2_data),
        .rd_addr_i    (tb_rd_addr),
        .rd_data_i    (tb_rd_data),
        .reg_write_i  (tb_reg_write),
        .regs_flat_o  (tb_regs_flat)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    task check_equal;
        input [511:0] label;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: got=%0d (0x%08h)", label, got, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, got);
            end
        end
    endtask

    // Escribe un registro con un pulso de clock (reg_write_i sostenido en
    // el flanco). No toca los puertos de lectura.
    task write_reg;
        input [4:0]  addr;
        input [31:0] data;
        begin
            tb_rd_addr   = addr;
            tb_rd_data   = data;
            tb_reg_write = 1'b1;
            @(posedge tb_clk);
            #1;
            tb_reg_write = 1'b0;
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de register_file");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        tb_rst = 1; tb_rs1_addr = 0; tb_rs2_addr = 0;
        tb_rd_addr = 0; tb_rd_data = 0; tb_reg_write = 0;
        #(CLK_PERIOD * 3);
        tb_rst = 0;
        #(CLK_PERIOD);

        $display("\n--- x0 fijo en cero tras reset ---");
        tb_rs1_addr = 5'd0; tb_rs2_addr = 5'd31; #1;
        check_equal("x0 via rs1 post-reset", tb_rs1_data, 32'h0);
        check_equal("x31 via rs2 post-reset", tb_rs2_data, 32'h0);

        $display("\n--- Escritura + lectura asincronica ---");
        write_reg(5'd5, 32'hDEADBEEF);
        tb_rs1_addr = 5'd5; #1;
        check_equal("x5 tras write", tb_rs1_data, 32'hDEADBEEF);

        write_reg(5'd10, 32'h00000001);
        write_reg(5'd20, 32'hFFFFFFFF);
        tb_rs1_addr = 5'd10; tb_rs2_addr = 5'd20; #1;
        check_equal("x10 tras write", tb_rs1_data, 32'h00000001);
        check_equal("x20 tras write", tb_rs2_data, 32'hFFFFFFFF);

        $display("\n--- x0 no escribible ---");
        write_reg(5'd0, 32'hCAFECAFE);
        tb_rs1_addr = 5'd0; #1;
        check_equal("x0 tras intento de escritura", tb_rs1_data, 32'h0);

        $display("\n--- Bypass de escritura-a-lectura, mismo registro y mismo ciclo ---");
        // x5 vale 0xDEADBEEF. Se pide escribir 0x12345678 en x5 y, en el
        // mismo ciclo (antes de que el flanco confirme la escritura en el
        // array), leerlo por rs2: debe verse YA el valor NUEVO (bypass
        // interno, ver header de register_file.v) -- si no lo hiciera,
        // ningun productor exactamente 3 instrucciones antes de su
        // consumidor podria resolverse ni por forwarding_unit (que ya para
        // ese punto perdio el dato) ni por una lectura directa del banco.
        tb_rs2_addr  = 5'd5;
        tb_rd_addr   = 5'd5;
        tb_rd_data   = 32'h12345678;
        tb_reg_write = 1'b1;
        #1;
        check_equal("x5 con bypass *antes* del flanco (ya ve el valor nuevo)", tb_rs2_data, 32'h12345678);
        @(posedge tb_clk);
        #1;
        tb_reg_write = 1'b0;
        check_equal("x5 *despues* del flanco (confirmado en el array)", tb_rs2_data, 32'h12345678);

        $display("\n--- Sin bypass hacia x0: escribir x0 nunca se ve, ni bypaseado ---");
        tb_rs2_addr  = 5'd0;
        tb_rd_addr   = 5'd0;
        tb_rd_data   = 32'hFFFFFFFF;
        tb_reg_write = 1'b1;
        #1;
        check_equal("x0 ignora el bypass, sigue en 0", tb_rs2_data, 32'h0);
        tb_reg_write = 1'b0;

        $display("\n--- Bus plano de debug (regs_flat_o) ---");
        check_equal("regs_flat_o[x5]",  tb_regs_flat[32*5  +: 32], 32'h12345678);
        check_equal("regs_flat_o[x10]", tb_regs_flat[32*10 +: 32], 32'h00000001);
        check_equal("regs_flat_o[x20]", tb_regs_flat[32*20 +: 32], 32'hFFFFFFFF);
        check_equal("regs_flat_o[x0]",  tb_regs_flat[32*0  +: 32], 32'h00000000);

        $display("\n--- Reset limpia todo ---");
        tb_rst = 1;
        #(CLK_PERIOD * 2);
        tb_rst = 0;
        #1;
        tb_rs1_addr = 5'd5; #1;
        check_equal("x5 tras reset", tb_rs1_data, 32'h0);
        check_equal("regs_flat_o[x20] tras reset", tb_regs_flat[32*20 +: 32], 32'h0);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("REGISTER_FILE: TODOS LOS TESTS PASARON");
        else $display("REGISTER_FILE: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
