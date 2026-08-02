// =============================================================================
// Módulo:         tb_uart_rx (Test Bench)
//
// Genera tramas UART completas (start + DBIT datos LSB-primero + stop) sobre
// 'rx' a razón de 16 ticks por bit, y verifica que 'uart_rx' entregue el
// byte correcto junto con el pulso 'rx_done_tick_o'.
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_rx;

    localparam DBIT           = 8;
    localparam SB_TICKS       = 16;
    localparam CLK_PERIOD     = 10;
    localparam TICK_DIVIDER   = 4;   // clks por cada s_tick (valor arbitrario)

    reg               tb_clk;
    reg               tb_rst;
    reg               tb_rx;
    wire [DBIT-1:0]   tb_dout;
    wire              tb_rx_done_tick;

    reg  [3:0]        tick_div;
    reg               tb_s_tick;

    integer errors;
    integer bytes_ok;

    uart_rx #(
        .DBIT     (DBIT),
        .SB_TICKS (SB_TICKS)
    ) uut (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_rx),
        .s_tick_i       (tb_s_tick),
        .dout_o         (tb_dout),
        .rx_done_tick_o (tb_rx_done_tick)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Generador de tick simple (independiente del baud_rate_generator real,
    // solo interesa que 's_tick' pulse periodicamente cada TICK_DIVIDER clks).
    always @(posedge tb_clk, posedge tb_rst) begin
        if (tb_rst) begin
            tick_div  <= 4'd0;
            tb_s_tick <= 1'b0;
        end
        else if (tick_div == TICK_DIVIDER - 1) begin
            tick_div  <= 4'd0;
            tb_s_tick <= 1'b1;
        end
        else begin
            tick_div  <= tick_div + 1'b1;
            tb_s_tick <= 1'b0;
        end
    end

    // Espera al proximo pulso de tick, muestreado en negedge para evitar
    // condiciones de carrera con la actualizacion sincrona de tb_s_tick.
    task wait_tick;
        begin
            @(negedge tb_clk);
            while (tb_s_tick !== 1'b1) @(negedge tb_clk);
        end
    endtask

    task wait_ticks(input integer n);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) wait_tick;
        end
    endtask

    // Transmite un byte completo (start + DBIT datos LSB-primero + stop)
    // sobre 'tb_rx', a razon de 16 ticks por bit.
    task send_byte(input [DBIT-1:0] data);
        integer idx;
        begin
            tb_rx = 1'b0;                 // start bit
            wait_ticks(16);
            for (idx = 0; idx < DBIT; idx = idx + 1) begin
                tb_rx = data[idx];        // LSB primero
                wait_ticks(16);
            end
            tb_rx = 1'b1;                  // stop bit(s)
            wait_ticks(SB_TICKS);
        end
    endtask

    // Envia un byte y verifica que 'uut' lo reciba correctamente.
    task check_byte(input [DBIT-1:0] data, input [127:0] label);
        begin
            fork
                send_byte(data);
                begin : wait_done
                    wait (tb_rx_done_tick === 1'b1);
                end
            join

            if (tb_dout !== data) begin
                $error("  -> FALLO | %0s | Enviado: %02h, Recibido: %02h", label, data, tb_dout);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | %0s | Byte:%02h recibido correctamente", label, data);
                bytes_ok = bytes_ok + 1;
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de uart_rx");
        $display("========================================");

        errors   = 0;
        bytes_ok = 0;
        tb_rx    = 1'b1; // linea en reposo
        tb_rst   = 1'b1;
        #(CLK_PERIOD * 5);
        tb_rst   = 1'b0;
        #(CLK_PERIOD * 5);

        $display("\n--- Bytes fijos ---");
        check_byte(8'h00, "0x00");
        wait_ticks(8); // pequenio hueco en idle entre tramas
        check_byte(8'hFF, "0xFF");
        wait_ticks(8);
        check_byte(8'hA5, "0xA5 (10100101)");
        wait_ticks(8);
        check_byte(8'h5A, "0x5A (01011010)");

        $display("\n--- Bytes aleatorios (con hueco en idle) ---");
        repeat (10) begin
            wait_ticks(8);
            check_byte($random, "random");
        end

        $display("\n--- Tramas consecutivas (back-to-back, sin hueco en idle) ---");
        check_byte(8'h3C, "0x3C back-to-back #1");
        check_byte(8'hC3, "0xC3 back-to-back #2");

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d bytes recibidos correctamente.", bytes_ok, bytes_ok);
        else
            $display("RESULTADO: %0d byte(s) con error de %0d enviados.", errors, errors + bytes_ok);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
