// =============================================================================
// Módulo:         tb_uart_rx_parity (Test Bench)
//
// Verifica la capability de paridad de 'uart_rx' con 'parity_en_i'=1
// sostenido en alto (entrada en tiempo real, pensada para switch fisico,
// ver uart_rx.v). No reemplaza a tb_uart_rx.v: ese sigue validando el
// camino por defecto ('parity_en_i'=0) sin tocar. Este agrega:
//   - Tramas con paridad EVEN correcta (unica variante soportada):
//     'parity_err_o' tiene que quedar en 0 y el byte recibido tiene que
//     coincidir con el enviado.
//   - Tramas con el bit de paridad deliberadamente invertido (simula
//     ruido real en la línea), para probar la detección de error en sí.
//   - En todos los casos, 'dout_o' tiene que seguir entregando el byte
//     correcto y 'rx_done_tick_o' tiene que seguir pulsando igual: un
//     error de paridad NUNCA descarta el byte (ver justificación en
//     uart_rx.v).
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_rx_parity;

    localparam DBIT         = 8;
    localparam SB_TICKS     = 16;
    localparam CLK_PERIOD   = 10;
    localparam TICK_DIVIDER = 4;

    reg  tb_clk;
    reg  tb_rst;
    reg  tb_rx;
    reg  tb_parity_en; // "switch" compartido por las dos instancias, sostenido en 1 en todo este testbench

    wire [DBIT-1:0] even_dout;
    wire            even_rx_done;
    wire            even_perr;

    reg  [3:0] tick_div;
    reg        tb_s_tick;

    integer errors;
    integer checks;

    uart_rx #(.DBIT(DBIT), .SB_TICKS(SB_TICKS)) uut_even (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_rx),
        .s_tick_i       (tb_s_tick),
        .parity_en_i    (tb_parity_en),
        .dout_o         (even_dout),
        .rx_done_tick_o (even_rx_done),
        .parity_err_o   (even_perr)
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

    // 'data' y 'what' se imprimen por separado (no concatenados) a
    // propósito: concatenar regs de ancho fijo con literales de largo
    // distinto en cada call site hace que '%0s' trunclinks de forma
    // inconsistente en Icarus (el padding de ceros de 'label' terminaba
    // en el medio del string resultante). Pasando cada pieza por su
    // propio '%02h'/'%0s' se evita el problema de raíz.
    task check(input cond, input [DBIT-1:0] data, input [511:0] what);
        begin
            checks = checks + 1;
            if (!cond) begin
                $error("  -> FALLO | dato=%02h | %0s", data, what);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | dato=%02h | %0s", data, what);
            end
        end
    endtask

    // Arma y envía una trama completa: start + DBIT datos LSB-primero + 1
    // bit de paridad EXPLICITO (lo decide quien llama, no se recalcula
    // acá) + stop. Permite tanto paridad correcta como corrompida a
    // propósito, según lo que pase el que llama.
    task send_frame(input [DBIT-1:0] data, input parity_bit);
        integer idx;
        begin
            tb_rx = 1'b0; // start
            wait_ticks(16);
            for (idx = 0; idx < DBIT; idx = idx + 1) begin
                tb_rx = data[idx]; // LSB primero
                wait_ticks(16);
            end
            tb_rx = parity_bit;
            wait_ticks(16);
            tb_rx = 1'b1; // stop
            wait_ticks(SB_TICKS);
        end
    endtask

    // Envía 'data' con paridad EVEN correcta (^data) y verifica que se
    // reciba sin marcar error.
    task check_valid_parity(input [DBIT-1:0] data);
        reg computed_even;
        begin
            computed_even = ^data;
            fork
                send_frame(data, computed_even);
                begin : wait_done
                    wait (even_rx_done === 1'b1);
                end
            join

            check(even_dout === data,  data, "dato correcto");
            check(even_perr === 1'b0,  data, "parity_err=0 (paridad EVEN correcta)");
        end
    endtask

    // Envía 'data' a la instancia EVEN con el bit de paridad
    // deliberadamente invertido (simula ruido en la línea) y verifica que
    // se detecte el error SIN perder el byte.
    task check_corrupted_parity(input [DBIT-1:0] data);
        reg correct_parity;
        begin
            correct_parity = ^data;
            fork
                send_frame(data, ~correct_parity); // bit de paridad invertido a propósito
                begin : wait_done2
                    wait (even_rx_done === 1'b1);
                end
            join

            check(even_dout === data, data, "dato entregado igual pese al error (paridad corrompida)");
            check(even_perr === 1'b1, data, "parity_err=1 (paridad corrompida detectada)");
        end
    endtask

    // Watchdog de seguridad.
    initial begin
        #500000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de uart_rx con parity_en_i=1");
        $display("========================================");

        errors      = 0;
        checks      = 0;
        tb_rx       = 1'b1;
        tb_parity_en = 1'b1; // "switch" ya arriba antes de la primera trama
        tb_rst      = 1'b1;
        #(CLK_PERIOD * 5);
        tb_rst      = 1'b0;
        #(CLK_PERIOD * 5);

        $display("\n--- Paridad EVEN correcta: se acepta sin error ---");
        check_valid_parity(8'h00);
        check_valid_parity(8'hFF);
        check_valid_parity(8'hA5);
        check_valid_parity(8'h5A);
        check_valid_parity(8'h01); // un solo bit en 1

        $display("\n--- Bit de paridad corrompido (ruido simulado): se detecta sin perder el byte ---");
        check_corrupted_parity(8'h00);
        check_corrupted_parity(8'hFF);
        check_corrupted_parity(8'h3C);
        check_corrupted_parity(8'hC3);

        $display("\n--- Aleatorios, paridad EVEN correcta ---");
        repeat (8) begin
            wait_ticks(8);
            check_valid_parity($random);
        end

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
