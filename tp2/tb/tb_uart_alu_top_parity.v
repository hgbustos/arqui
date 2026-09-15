// =============================================================================
// Módulo:         tb_uart_alu_top_parity (Test Bench end-to-end)
//
// Prueba de integración de la capability de paridad sobre el sistema
// COMPLETO, con 'parity_en_i' como entrada en tiempo real (switch fisico
// en la Basys3 real, ver uart_alu_top.v): arma tramas UART reales (start
// + 8 datos + paridad + stop) sobre 'rx_i' y decodifica 'tx_o' con un par
// baud_rate_generator + uart_rx auxiliar -- mismo patrón que
// tb_uart_alu_top.v (que sigue validando aparte, sin tocar, el camino con
// 'parity_en_i'=0). No repite la batería completa de opcodes ni el
// cambio de baud rate en caliente (ya cubiertos ahí); el foco acá es
// confirmar que la paridad se propaga correctamente de punta a punta a
// través de uart_alu_top, en los dos sentidos:
//   - 'parity_err_o' del propio DUT (paridad de lo que la FPGA recibe)
//   - 'chk_parity_err' del checker (paridad de lo que la FPGA transmite)
// En un canal limpio (sin ruido inyectado), los dos tienen que quedar en 0
// durante todo el test -- si alguno se prende, hay una inconsistencia
// entre cómo uart_tx arma la paridad y cómo uart_rx la verifica dentro del
// mismo sistema integrado (ya probado por separado, a nivel de módulo, en
// tb_uart_rx_parity.v / tb_uart_tx_parity.v).
//
// Al final tambien prueba el cambio de 'parity_en_i' EN CALIENTE (mismo
// criterio que ya usa tb_uart_alu_top.v para baud_sel_i: solo entre
// transacciones completas, nunca a mitad de un envio), confirmando que el
// sistema sigue funcionando de punta a punta de los dos lados del switch.
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_alu_top_parity;

    localparam N          = 8;
    localparam CLK_FREQ   = 8000;
    localparam BAUD_RATE0 = 500;
    localparam BAUD_RATE1 = 125;
    localparam BAUD_RATE2 = 250;
    localparam BAUD_RATE3 = 50;
    localparam CLK_PERIOD = 10;

    localparam [7:0] CMD_LOAD = 8'h01;
    localparam [7:0] CMD_READ = 8'h02;

    reg  tb_clk;
    reg  tb_rst;
    reg  tb_rx;
    wire tb_tx;
    wire tb_dut_parity_err;
    reg  [1:0] tb_baud_sel;
    reg  tb_parity_en; // "switch" fisico simulado, compartido por dut y chk_rx

    integer errors;
    integer ops_ok;
    integer bit_cycles;

    // --- DUT: sistema completo, con paridad activa ---
    uart_alu_top #(
        .N          (N),
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3)
    ) dut (
        .clk_i        (tb_clk),
        .rst_i        (tb_rst),
        .rx_i         (tb_rx),
        .baud_sel_i   (tb_baud_sel),
        .parity_en_i  (tb_parity_en),
        .tx_o         (tb_tx),
        .parity_err_o (tb_dut_parity_err)
    );

    // --- Checker: decodifica tx_o de forma independiente del DUT, tambien con paridad activa ---
    wire chk_tick;
    baud_rate_generator #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3),
        .OVERSAMPLE (16)
    ) chk_baud_gen (
        .clk_i      (tb_clk),
        .rst_i      (tb_rst),
        .baud_sel_i (tb_baud_sel),
        .tick_o     (chk_tick)
    );

    wire [N-1:0] chk_dout;
    wire         chk_rx_done_tick;
    wire         chk_parity_err;

    uart_rx #(
        .DBIT       (N),
        .SB_TICKS   (16)
    ) chk_rx (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_tx),
        .s_tick_i       (chk_tick),
        .parity_en_i    (tb_parity_en),
        .dout_o         (chk_dout),
        .rx_done_tick_o (chk_rx_done_tick),
        .parity_err_o   (chk_parity_err)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Volcado de senales para inspeccionar en GTKWave (ver tp2/README.md,
    // "Ver el trafico en GTKWave"). Con parity_en_i=1 esta es la version que
    // sirve para mostrar en vivo el bit de paridad en la trama.
    initial begin
        $dumpfile("tb_uart_alu_top_parity.vcd");
        $dumpvars(0, tb_uart_alu_top_parity);
    end

    // Arma start + N datos LSB-primero + (si 'tb_parity_en' esta en alto)
    // 1 bit de paridad EVEN + stop, tal como lo haria un emisor externo
    // real que ya sabe en que posicion esta el switch de paridad de la
    // FPGA en este momento (tiene que coincidir en los dos extremos,
    // igual que el baud rate -- ver 2.4 del informe sobre las capas del
    // enlace). Como 'tb_parity_en' tambien alimenta a 'dut' (mismo wire),
    // esta tarea automaticamente arma la trama correcta aunque el
    // testbench cambie el switch entre llamadas.
    task send_byte(input [N-1:0] data);
        integer i;
        reg     parity_bit;
        begin
            parity_bit = ^data; // paridad EVEN, unica opcion soportada

            tb_rx = 1'b0; // start bit
            repeat (bit_cycles) @(posedge tb_clk);
            for (i = 0; i < N; i = i + 1) begin
                tb_rx = data[i];
                repeat (bit_cycles) @(posedge tb_clk);
            end
            if (tb_parity_en) begin
                tb_rx = parity_bit;
                repeat (bit_cycles) @(posedge tb_clk);
            end
            tb_rx = 1'b1; // stop bit
            repeat (bit_cycles) @(posedge tb_clk);
        end
    endtask

    // Espera el proximo byte decodificado por el checker y confirma que
    // llegue con paridad OK (canal limpio, sin ruido inyectado en este
    // test -- eso ya se prueba a nivel de modulo en tb_uart_rx_parity.v).
    task recv_byte(output [N-1:0] data);
        begin
            wait (chk_rx_done_tick === 1'b1);
            data = chk_dout;
            if (chk_parity_err !== 1'b0) begin
                $error("  -> FALLO | El checker detecto parity_err=1 en un byte que la FPGA transmitio limpio");
                errors = errors + 1;
            end
            wait (chk_rx_done_tick === 1'b0);
            @(negedge tb_clk);
        end
    endtask

    task compute_expected(input [5:0] op, input [N-1:0] a, input [N-1:0] b,
                           output [N-1:0] exp_out, output exp_zero, output exp_co);
        reg [N:0] sum_ext;
        begin
            exp_co = 1'b0;
            case (op)
                6'b100000: begin sum_ext = {1'b0, a} + {1'b0, b}; exp_out = sum_ext[N-1:0]; exp_co = sum_ext[N]; end
                6'b100010: {exp_co, exp_out} = a - b;
                6'b100100: exp_out = a & b;
                6'b100101: exp_out = a | b;
                6'b100110: exp_out = a ^ b;
                default:   exp_out = {N{1'b0}};
            endcase
            exp_zero = ~|exp_out;
        end
    endtask

    // Ejecuta una operacion completa (CMD_LOAD+op+A+B, despues CMD_READ)
    // con paridad activa de punta a punta, chequeando ademas que ni el DUT
    // ni el checker hayan visto un error de paridad en el camino.
    task run_op(input [5:0] op, input [N-1:0] a, input [N-1:0] b, input [255:0] label);
        reg [N-1:0] exp_out, got_result, got_status;
        reg         exp_zero, exp_co;
        reg [N-1:0] exp_status;
        begin
            compute_expected(op, a, b, exp_out, exp_zero, exp_co);
            exp_status = {{(N - 2){1'b0}}, exp_co, exp_zero};

            send_byte(CMD_LOAD);
            send_byte({2'b00, op});
            send_byte(a);
            send_byte(b);
            send_byte(CMD_READ);

            recv_byte(got_result);
            recv_byte(got_status);

            if (got_result !== exp_out || got_status !== exp_status || tb_dut_parity_err !== 1'b0) begin
                $error("  -> FALLO | %0s | op=%b A=%0d B=%0d | resultado esp:%02h rec:%02h | estado esp:%02h rec:%02h | dut_parity_err:%b",
                       label, op, a, b, exp_out, got_result, exp_status, got_status, tb_dut_parity_err);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | %0s | op=%b A=%0d B=%0d -> resultado:%02h estado:%02h (co=%b zero=%b), paridad OK en ambos sentidos",
                          label, op, a, b, got_result, got_status, exp_co, exp_zero);
                ops_ok = ops_ok + 1;
            end
        end
    endtask

    // Watchdog de seguridad.
    initial begin
        #2000000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo (posible deadlock) ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion end-to-end de uart_alu_top con parity_en_i=1");
        $display("========================================");

        errors       = 0;
        ops_ok       = 0;
        tb_rx        = 1'b1; // linea en reposo
        tb_baud_sel  = 2'b01;
        tb_parity_en = 1'b1; // "switch" ya arriba antes de la primera operacion
        bit_cycles   = CLK_FREQ / BAUD_RATE1;
        tb_rst = 1'b1;
        repeat (5) @(posedge tb_clk);
        tb_rst = 1'b0;
        repeat (5) @(posedge tb_clk);

        $display("\n--- Una operacion de varios opcodes, con paridad activa de punta a punta ---");
        run_op(6'b100000, 8'd100, 8'd50, "ADD");
        run_op(6'b100010, 8'd10,  8'd50, "SUB (con carry-out)");
        run_op(6'b100100, 8'hF0,  8'h0F, "AND (da zero=1)");
        run_op(6'b100101, 8'hF0,  8'h0F, "OR");
        run_op(6'b100110, 8'hFF,  8'h0F, "XOR");

        $display("\n--- CMD_READ repetido sin recargar, con paridad activa ---");
        begin
            reg [N-1:0] exp_out, got_a, got_b;
            reg         exp_zero, exp_co;
            reg [N-1:0] exp_status;

            compute_expected(6'b100000, 8'd7, 8'd3, exp_out, exp_zero, exp_co);
            exp_status = {{(N - 2){1'b0}}, exp_co, exp_zero};

            send_byte(CMD_LOAD);
            send_byte({2'b00, 6'b100000});
            send_byte(8'd7);
            send_byte(8'd3);

            send_byte(CMD_READ);
            recv_byte(got_a);
            recv_byte(got_b);

            send_byte(CMD_READ); // sin recargar
            recv_byte(got_a);
            recv_byte(got_b);

            if (got_a !== exp_out || got_b !== exp_status) begin
                $error("  -> FALLO | CMD_READ repetido con paridad | esperado result:%02h status:%02h | recibido:%02h %02h",
                       exp_out, exp_status, got_a, got_b);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | CMD_READ repetido con paridad activa devolvio el mismo resultado");
                ops_ok = ops_ok + 1;
            end
        end

        $display("\n--- Cambio de parity_en_i en caliente (mismo criterio que baud_sel_i: solo entre transacciones) ---");
        tb_parity_en = 1'b0;
        repeat (4) @(posedge tb_clk); // margen antes de la proxima trama, mismo patron que switch_baud en tb_uart_alu_top.v
        run_op(6'b100000, 8'd9, 8'd9, "ADD con el switch de paridad recien apagado");

        tb_parity_en = 1'b1;
        repeat (4) @(posedge tb_clk);
        run_op(6'b100110, 8'hAA, 8'h55, "XOR con el switch de paridad prendido de nuevo");

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d operaciones correctas (paridad OK de punta a punta).", ops_ok, ops_ok);
        else
            $display("RESULTADO: %0d de %0d operaciones fallaron.", errors, errors + ops_ok);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
