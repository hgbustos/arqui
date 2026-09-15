// =============================================================================
// Módulo:         tb_uart_tx (Test Bench)
//
// Verifica 'uart_tx' en loopback: la línea 'tx_o' se conecta a un
// 'uart_rx' auxiliar (ya verificado en tb_uart_rx.v) que actúa como
// decodificador de referencia. Si lo que arma uart_tx es una trama UART
// válida, el uart_rx auxiliar debe recuperar exactamente el mismo byte.
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_tx;

    localparam DBIT         = 8;
    localparam SB_TICKS     = 16;
    localparam CLK_PERIOD   = 10;
    localparam TICK_DIVIDER = 4;   // clks por cada s_tick (valor arbitrario)

    reg               tb_clk;
    reg               tb_rst;
    reg               tb_tx_start;
    reg  [DBIT-1:0]   tb_din;
    wire              tb_tx_done_tick;
    wire              tb_tx_line;

    wire [DBIT-1:0]   chk_dout;
    wire              chk_rx_done_tick;

    reg  [3:0]        tick_div;
    reg               tb_s_tick;

    integer errors;
    integer bytes_ok;

    // --- DUT: transmisor bajo prueba ---
    uart_tx #(
        .DBIT     (DBIT),
        .SB_TICKS (SB_TICKS)
    ) uut (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .tx_start_i     (tb_tx_start),
        .s_tick_i       (tb_s_tick),
        .din_i          (tb_din),
        .parity_en_i    (1'b0), // este testbench valida el camino sin paridad; ver tb_uart_tx_parity.v para parity_en_i=1
        .tx_done_tick_o (tb_tx_done_tick),
        .tx_o           (tb_tx_line)
    );

    // --- Checker: receptor auxiliar en loopback, ya verificado aparte ---
    uart_rx #(
        .DBIT     (DBIT),
        .SB_TICKS (SB_TICKS)
    ) rx_checker (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_tx_line),
        .s_tick_i       (tb_s_tick),
        .parity_en_i    (1'b0),
        .dout_o         (chk_dout),
        .rx_done_tick_o (chk_rx_done_tick)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

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

    // Dispara una transmision y sostiene tx_start hasta ver que el DUT la
    // reconoce (tx_o cae a 0 al entrar en 'start'). Soltarla despues de un
    // solo ciclo fijo no alcanza en el caso back-to-back: la transicion
    // STOP->IDLE del DUT puede completarse en el mismo flanco en el que
    // nosotros bajariamos tx_start, y esa carrera puede hacer que el pulso
    // se pierda.
    task check_byte(input [DBIT-1:0] data);
        begin
            $display("  -> INFO  | Iniciando transmision de %02h", data);
            tb_din      = data;
            tb_tx_start = 1'b1;
            @(negedge tb_tx_line);
            tb_tx_start = 1'b0;

            fork
                begin : wait_tx_done
                    wait (tb_tx_done_tick === 1'b1);
                end
                begin : wait_rx_done
                    wait (chk_rx_done_tick === 1'b1);
                end
            join

            // Margen de sincronizacion: deja que state_reg de ambos modulos
            // se asiente en IDLE antes de que la proxima llamada pueda
            // volver a levantar tx_start_i (evita una carrera del propio
            // testbench en el caso "back-to-back", sin hueco en idle).
            @(negedge tb_clk);

            if (chk_dout !== data) begin
                $error("  -> FALLO | Enviado: %02h, Decodificado por el rx_checker: %02h", data, chk_dout);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | Byte:%02h transmitido y decodificado correctamente", data);
                bytes_ok = bytes_ok + 1;
            end
        end
    endtask

    // Watchdog: si algo se traba (p.ej. un 'wait' que nunca se cumple),
    // forzar el fin de la simulacion en vez de colgar el proceso.
    initial begin
        #500000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo (posible deadlock) ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de uart_tx (loopback con uart_rx)");
        $display("========================================");

        errors      = 0;
        bytes_ok    = 0;
        tb_din      = {DBIT{1'b0}};
        tb_tx_start = 1'b0;
        tb_rst      = 1'b1;
        #(CLK_PERIOD * 5);
        tb_rst      = 1'b0;
        #(CLK_PERIOD * 5);

        $display("\n--- Bytes fijos ---");
        check_byte(8'h00);
        wait_ticks(8);
        check_byte(8'hFF);
        wait_ticks(8);
        check_byte(8'hA5);
        wait_ticks(8);
        check_byte(8'h5A);

        $display("\n--- Bytes aleatorios (con hueco en idle) ---");
        repeat (10) begin
            wait_ticks(8);
            check_byte($random);
        end

        $display("\n--- Transmisiones consecutivas (tx_start apenas termina la anterior) ---");
        check_byte(8'h3C);
        check_byte(8'hC3);

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d bytes transmitidos y decodificados correctamente.", bytes_ok, bytes_ok);
        else
            $display("RESULTADO: %0d byte(s) con error de %0d enviados.", errors, errors + bytes_ok);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
