// =============================================================================
// Módulo:         tb_uart_tx_parity (Test Bench)
//
// Verifica la generación de paridad de 'uart_tx' con 'parity_en_i'=1
// sostenido en alto, en loopback contra un 'uart_rx' auxiliar con el
// mismo 'parity_en_i' compartido (mismo patrón que tb_uart_tx.v, que
// sigue validando aparte, sin tocar, el camino sin paridad). Si uart_tx arma el bit de paridad correctamente,
// el checker tiene que decodificar el mismo byte Y reportar
// parity_err_o=0 siempre -- cualquier fallo acá sería una inconsistencia
// entre cómo uart_tx calcula el bit y cómo uart_rx lo verifica (cada uno
// ya probado por separado, a nivel de módulo, en tb_uart_rx_parity.v).
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_tx_parity;

    localparam DBIT          = 8;
    localparam SB_TICKS      = 16;
    localparam CLK_PERIOD    = 10;
    localparam TICK_DIVIDER  = 4;

    reg               tb_clk;
    reg               tb_rst;
    reg               tb_tx_start;
    reg  [DBIT-1:0]   tb_din;
    reg               tb_parity_en; // "switch" compartido entre uut y rx_checker, sostenido en 1
    wire              tb_tx_done_tick;
    wire              tb_tx_line;

    wire [DBIT-1:0]   chk_dout;
    wire              chk_rx_done_tick;
    wire              chk_parity_err;

    reg  [3:0]        tick_div;
    reg               tb_s_tick;

    integer errors;
    integer bytes_ok;

    // --- DUT: transmisor bajo prueba, con paridad activa ---
    uart_tx #(
        .DBIT       (DBIT),
        .SB_TICKS   (SB_TICKS)
    ) uut (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .tx_start_i     (tb_tx_start),
        .s_tick_i       (tb_s_tick),
        .din_i          (tb_din),
        .parity_en_i    (tb_parity_en),
        .tx_done_tick_o (tb_tx_done_tick),
        .tx_o           (tb_tx_line)
    );

    // --- Checker: receptor auxiliar en loopback, tambien con paridad activa ---
    uart_rx #(
        .DBIT       (DBIT),
        .SB_TICKS   (SB_TICKS)
    ) rx_checker (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_tx_line),
        .s_tick_i       (tb_s_tick),
        .parity_en_i    (tb_parity_en),
        .dout_o         (chk_dout),
        .rx_done_tick_o (chk_rx_done_tick),
        .parity_err_o   (chk_parity_err)
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

    // Dispara una transmisión y sostiene tx_start hasta ver que el DUT la
    // reconoce (misma lógica que tb_uart_tx.v -- ver ese archivo para el
    // detalle de por qué hace falta esperar el flanco de tx_o en vez de
    // soltar tx_start después de un ciclo fijo).
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

            @(negedge tb_clk);

            if (chk_dout !== data || chk_parity_err !== 1'b0) begin
                $error("  -> FALLO | Enviado: %02h, Decodificado: %02h, parity_err del checker: %b",
                       data, chk_dout, chk_parity_err);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | Byte:%02h transmitido, decodificado y con paridad OK", data);
                bytes_ok = bytes_ok + 1;
            end
        end
    endtask

    // Watchdog de seguridad.
    initial begin
        #500000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo (posible deadlock) ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de uart_tx con parity_en_i=1 (loopback con uart_rx)");
        $display("========================================");

        errors       = 0;
        bytes_ok     = 0;
        tb_din       = {DBIT{1'b0}};
        tb_tx_start  = 1'b0;
        tb_parity_en = 1'b1; // "switch" ya arriba antes de la primera transmision
        tb_rst       = 1'b1;
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
        wait_ticks(8);
        check_byte(8'h01);

        $display("\n--- Bytes aleatorios ---");
        repeat (10) begin
            wait_ticks(8);
            check_byte($random);
        end

        $display("\n--- Transmisiones consecutivas, sin pausas entre medio ---");
        check_byte(8'h3C);
        check_byte(8'hC3);

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d bytes OK (dato + paridad).", bytes_ok, bytes_ok);
        else
            $display("RESULTADO: %0d byte(s) con error de %0d enviados.", errors, errors + bytes_ok);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
