// =============================================================================
// Módulo:         tb_uart_interface (Test Bench)
//
// Verifica 'uart_interface' a nivel de byte, simulando directamente los
// pulsos 'rx_done_tick_i' / 'tx_done_tick_i' que en el sistema real vendrían
// de uart_rx/uart_tx. Así se prueba la lógica del buffer/handshake en
// simulaciones muy rápidas, sin bit-banging serie.
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_interface;

    localparam DBIT       = 8;
    localparam CLK_PERIOD = 10;

    reg              tb_clk;
    reg              tb_rst;

    reg  [DBIT-1:0]  tb_rx_dout;
    reg              tb_rx_done_tick;
    reg              tb_tx_done_tick;
    wire             tb_tx_start;
    wire [DBIT-1:0]  tb_din;

    wire [DBIT-1:0]  tb_r_data;
    wire             tb_rx_empty;
    reg              tb_rd;

    reg  [DBIT-1:0]  tb_w_data;
    wire             tb_tx_full;
    reg              tb_wr;

    integer errors;
    integer checks;

    uart_interface #(.DBIT(DBIT)) uut (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_dout_i      (tb_rx_dout),
        .rx_done_tick_i (tb_rx_done_tick),
        .tx_done_tick_i (tb_tx_done_tick),
        .tx_start_o     (tb_tx_start),
        .din_o          (tb_din),
        .r_data_o       (tb_r_data),
        .rx_empty_o     (tb_rx_empty),
        .rd_i           (tb_rd),
        .w_data_i       (tb_w_data),
        .tx_full_o      (tb_tx_full),
        .wr_i           (tb_wr)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    task check(input cond, input [511:0] label);
        begin
            checks = checks + 1;
            if (!cond) begin
                $error("  -> FALLO | %0s", label);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | %0s", label);
            end
        end
    endtask

    // Watchdog de seguridad.
    initial begin
        #50000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de uart_interface");
        $display("========================================");

        errors          = 0;
        checks          = 0;
        tb_rx_dout      = 0;
        tb_rx_done_tick = 0;
        tb_tx_done_tick = 0;
        tb_rd           = 0;
        tb_w_data       = 0;
        tb_wr           = 0;

        tb_rst = 1'b1;
        @(posedge tb_clk); @(posedge tb_clk);
        tb_rst = 1'b0;
        @(negedge tb_clk);

        $display("\n--- Estado inicial ---");
        check(tb_rx_empty === 1'b1, "rx_empty=1 tras reset");
        check(tb_tx_full  === 1'b0, "tx_full=0 tras reset");

        $display("\n--- Recepcion de un byte ---");
        tb_rx_dout      = 8'hA5;
        tb_rx_done_tick = 1'b1;
        @(negedge tb_clk);
        tb_rx_done_tick = 1'b0;
        check(tb_rx_empty === 1'b0,   "rx_empty=0 tras rx_done_tick");
        check(tb_r_data   === 8'hA5,  "r_data=A5 tras rx_done_tick");

        tb_rd = 1'b1;
        @(negedge tb_clk);
        tb_rd = 1'b0;
        check(tb_rx_empty === 1'b1, "rx_empty=1 tras leer con rd");

        $display("\n--- rd sin dato disponible: no debe romper nada ---");
        tb_rd = 1'b1;
        @(negedge tb_clk);
        tb_rd = 1'b0;
        check(tb_rx_empty === 1'b1, "rx_empty sigue en 1 (no habia dato)");

        $display("\n--- Byte nuevo y lectura en el mismo ciclo: gana el byte nuevo ---");
        tb_rx_dout      = 8'h11;
        tb_rx_done_tick = 1'b1;
        @(negedge tb_clk);
        tb_rx_done_tick = 1'b0;
        // Ahora, en el mismo flanco, llega un byte nuevo Y se intenta leer
        tb_rx_dout      = 8'h22;
        tb_rx_done_tick = 1'b1;
        tb_rd           = 1'b1;
        @(negedge tb_clk);
        tb_rx_done_tick = 1'b0;
        tb_rd           = 1'b0;
        check(tb_rx_empty === 1'b0,  "rx_empty=0 (el byte nuevo no se pierde)");
        check(tb_r_data   === 8'h22, "r_data=22 (prioridad al dato entrante)");
        tb_rd = 1'b1;
        @(negedge tb_clk);
        tb_rd = 1'b0;

        $display("\n--- Transmision de un byte ---");
        // 'wr' se levanta recien pasado un negedge (igual que el resto de
        // este testbench) para que ya este estable ANTES del flanco que lo
        // captura. Bajarlo justo en ese mismo flanco (@(posedge);wr=0;)
        // competiria con la propia lectura del DUT en el mismo instante de
        // simulacion (uart_interface lee wr_i directo dentro de un unico
        // bloque @(posedge), a diferencia de uart_rx/uart_tx que separan
        // la logica combinacional del registro) — por eso siempre se
        // sostiene la señal hasta el negedge siguiente antes de soltarla.
        tb_w_data = 8'h5A;
        tb_wr     = 1'b1;
        @(negedge tb_clk); // cruza el flanco donde se acepta el wr, con margen
        // tx_start_reg es un pulso de 1 ciclo: todavia debe estar en 1 aca
        check(tb_tx_start === 1'b1,  "tx_start=1 justo despues de aceptar el wr");
        check(tb_tx_full  === 1'b1,  "tx_full=1 tras wr");
        check(tb_din      === 8'h5A, "din=5A tras wr");
        tb_wr = 1'b0;
        @(negedge tb_clk); // cruza el flanco donde tx_start_reg vuelve a 0
        check(tb_tx_start === 1'b0, "tx_start vuelve a 0 un ciclo despues");

        $display("\n--- wr mientras tx_full=1: se ignora sin corromper el dato ---");
        tb_w_data = 8'hFF;
        tb_wr     = 1'b1;
        @(negedge tb_clk);
        tb_wr     = 1'b0;
        check(tb_din     === 8'h5A, "din sigue siendo 5A (el segundo wr fue ignorado)");
        check(tb_tx_full === 1'b1,  "tx_full sigue en 1");

        tb_tx_done_tick = 1'b1;
        @(negedge tb_clk);
        tb_tx_done_tick = 1'b0;
        check(tb_tx_full === 1'b0, "tx_full=0 tras tx_done_tick");

        $display("\n--- Segunda transmision, inmediatamente despues (back-to-back) ---");
        tb_w_data = 8'h33;
        tb_wr     = 1'b1;
        @(negedge tb_clk);
        tb_wr     = 1'b0;
        check(tb_tx_full === 1'b1,  "tx_full=1 tras el segundo wr");
        check(tb_din     === 8'h33, "din=33 tras el segundo wr");

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d verificaciones OK.", checks, checks);
        else
            $display("RESULTADO: %0d de %0d verificaciones fallaron.", errors, checks);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
