// =============================================================================
// Módulo:         tb_uart_alu_top (Test Bench end-to-end)
//
// Verifica el sistema COMPLETO (uart_alu_top) a nivel de trama serie real:
// arma bytes UART completos sobre 'rx_i' (start + 8 datos LSB-primero +
// stop), a razón de CLK_FREQ/BAUD_RATE ciclos de clock por bit, tal como lo
// haría un emisor externo real (sin depender de ninguna señal interna del
// DUT). Para decodificar 'tx_o' se usa un par baud_rate_generator+uart_rx
// auxiliar, independiente del DUT, que actúa como un receptor externo real.
//
// Los opcodes, el framing y el protocolo de 5 bytes ya fueron verificados
// exhaustivamente en tb_uart_rx.v, tb_uart_tx.v, tb_uart_interface.v y
// tb_alu_link.v; este testbench es la prueba de integración de que todo
// junto, con timing de UART real, funciona de punta a punta.
// =============================================================================
`timescale 1ns / 1ps

module tb_uart_alu_top;

    localparam N          = 8;
    localparam CLK_FREQ   = 8000;  // valores pequeños para simulación rápida,
    // 4 presets de baud rate ficticios (misma idea que en tb_baud_generator.v),
    // todos con MOD_VALUE entero para CLK_FREQ=8000. BAUD_RATE1 es el valor
    // que se usaba antes como único baud rate (BIT_CYCLES=64), y queda como
    // preset por defecto para no alterar el resto de los tests.
    localparam BAUD_RATE0 = 500; // preset 00, MOD=1  -> BIT_CYCLES=16  (el mas rapido)
    localparam BAUD_RATE1 = 125; // preset 01, MOD=4  -> BIT_CYCLES=64  (default, igual que antes)
    localparam BAUD_RATE2 = 250; // preset 10, MOD=2  -> BIT_CYCLES=32
    localparam BAUD_RATE3 = 50;  // preset 11, MOD=10 -> BIT_CYCLES=160 (el mas lento)
    localparam CLK_PERIOD = 10;

    localparam [7:0] CMD_LOAD = 8'h01;
    localparam [7:0] CMD_READ = 8'h02;

    reg  tb_clk;
    reg  tb_rst;
    reg  tb_rx;
    wire tb_tx;
    reg  [1:0] tb_baud_sel; // preset activo, compartido entre el DUT y el checker

    integer errors;
    integer ops_ok;
    integer bit_cycles; // ciclos de clock por bit serie del preset activo (ver switch_baud)

    // --- DUT: sistema completo ---
    uart_alu_top #(
        .N          (N),
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3)
    ) dut (
        .clk_i      (tb_clk),
        .rst_i      (tb_rst),
        .rx_i       (tb_rx),
        .baud_sel_i (tb_baud_sel),
        .tx_o       (tb_tx)
    );

    // --- Checker: decodifica tx_o de forma independiente del DUT ---
    // Comparte 'tb_baud_sel' con el DUT: en la realidad, ambos extremos de
    // un enlace serie tienen que estar de acuerdo en el baud rate activo.
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

    uart_rx #(
        .DBIT     (N),
        .SB_TICKS (16)
    ) chk_rx (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_i           (tb_tx),
        .s_tick_i       (chk_tick),
        .dout_o         (chk_dout),
        .rx_done_tick_o (chk_rx_done_tick)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Envia un byte UART completo sobre rx_i (start + N datos LSB-primero +
    // stop), a razon de 'bit_cycles' ciclos de clock por bit (depende del
    // preset de baud rate activo, ver switch_baud), igual que lo haria un
    // emisor externo real (no depende de ninguna senial interna del DUT).
    task send_byte(input [N-1:0] data);
        integer i;
        begin
            tb_rx = 1'b0; // start bit
            repeat (bit_cycles) @(posedge tb_clk);
            for (i = 0; i < N; i = i + 1) begin
                tb_rx = data[i];
                repeat (bit_cycles) @(posedge tb_clk);
            end
            tb_rx = 1'b1; // stop bit
            repeat (bit_cycles) @(posedge tb_clk);
        end
    endtask

    // Cambia el preset de baud rate activo en ambos extremos (DUT y
    // checker) y actualiza 'bit_cycles' para que send_byte/recv_byte usen
    // el timing correcto. Un margen de reposo antes y despues del cambio
    // evita mandar el proximo byte mientras el generador todavia esta
    // reiniciando su contador.
    task switch_baud(input [1:0] sel, input integer new_bit_cycles, input [255:0] label);
        begin
            $display("\n=== Cambiando de preset de baud rate a %0s (bit_cycles=%0d) ===", label, new_bit_cycles);
            @(negedge tb_clk);
            tb_baud_sel = sel;
            bit_cycles  = new_bit_cycles;
            repeat (4) @(posedge tb_clk);
        end
    endtask

    // Espera a que el checker decodifique el proximo byte de tx_o. Tras
    // capturarlo, espera a que 'chk_rx_done_tick' vuelva a 0 antes de
    // volver: si no se esperara, la proxima llamada a recv_byte podria
    // "recapturar" la cola del MISMO pulso (wait no bloquea si la
    // condicion ya es verdadera en el instante en que se evalua) en vez
    // de esperar genuinamente al siguiente byte.
    task recv_byte(output [N-1:0] data);
        begin
            wait (chk_rx_done_tick === 1'b1);
            data = chk_dout;
            wait (chk_rx_done_tick === 1'b0);
            @(negedge tb_clk);
        end
    endtask

    // Modelo de referencia: misma tabla de opcodes que tp1/ALU.v.
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
                6'b000011: exp_out = $signed(a) >>> b;
                6'b000010: exp_out = a >> b;
                6'b100111: exp_out = ~(a | b);
                default:   exp_out = {N{1'b0}};
            endcase
            exp_zero = ~|exp_out;
        end
    endtask

    // Ejecuta una operacion completa mandando CMD_LOAD+op+A+B y despues
    // CMD_READ por 'rx_i' (5 bytes en total), verificando los 2 bytes que
    // vuelven por 'tx_o'.
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

            if (got_result !== exp_out || got_status !== exp_status) begin
                $error("  -> FALLO | %0s | op=%b A=%0d B=%0d | resultado esp:%02h rec:%02h | estado esp:%02h rec:%02h",
                       label, op, a, b, exp_out, got_result, exp_status, got_status);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | %0s | op=%b A=%0d B=%0d -> resultado:%02h estado:%02h (co=%b zero=%b)",
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
        $display("Inicio de la Verificacion end-to-end de uart_alu_top");
        $display("========================================");

        errors      = 0;
        ops_ok      = 0;
        tb_rx       = 1'b1; // linea en reposo
        tb_baud_sel = 2'b01; // preset por defecto (BAUD_RATE1), estable antes del reset
        bit_cycles  = CLK_FREQ / BAUD_RATE1;
        $display("Preset inicial: bit_cycles=%0d ciclos de clock por bit serie", bit_cycles);
        tb_rst = 1'b1;
        repeat (5) @(posedge tb_clk);
        tb_rst = 1'b0;
        repeat (5) @(posedge tb_clk);

        $display("\n--- Una operacion de cada opcode ---");
        run_op(6'b100000, 8'd100, 8'd50,  "ADD");
        run_op(6'b100010, 8'd10,  8'd50,  "SUB (con carry-out)");
        run_op(6'b100100, 8'hF0,  8'h0F,  "AND (da zero=1)");
        run_op(6'b100101, 8'hF0,  8'h0F,  "OR");
        run_op(6'b100110, 8'hFF,  8'h0F,  "XOR");
        run_op(6'b000011, 8'hF0,  8'd2,   "SRA");
        run_op(6'b000010, 8'hF0,  8'd2,   "SRL");
        run_op(6'b100111, 8'hFF,  8'h00,  "NOR (da zero=1)");
        run_op(6'b111111, 8'd1,   8'd1,   "Opcode invalido (default)");

        $display("\n--- Operaciones consecutivas, sin pausas entre medio ---");
        run_op(6'b100000, 8'd255, 8'd1, "back-to-back #1 (overflow)");
        run_op(6'b100000, 8'd1,   8'd1, "back-to-back #2");

        $display("\n--- Operandos aleatorios ---");
        repeat (5) begin
            run_op(6'b100000, $random, $random, "random ADD");
        end

        $display("\n--- CMD_READ repetido sobre UART real (releer sin recargar) ---");
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
                $error("  -> FALLO | CMD_READ repetido | esperado result:%02h status:%02h | recibido:%02h %02h",
                       exp_out, exp_status, got_a, got_b);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | CMD_READ repetido sobre UART real devolvio el mismo resultado");
                ops_ok = ops_ok + 1;
            end
        end

        $display("\n--- Cambio de baud rate en caliente (mismos dos extremos, distinto preset) ---");
        switch_baud(2'b10, CLK_FREQ / BAUD_RATE2, "BAUD_RATE2");
        run_op(6'b100000, 8'd20, 8'd5, "ADD a BAUD_RATE2");
        run_op(6'b100110, 8'hAA, 8'h55, "XOR a BAUD_RATE2");

        switch_baud(2'b00, CLK_FREQ / BAUD_RATE0, "BAUD_RATE0 (el mas rapido)");
        run_op(6'b100010, 8'd50, 8'd20, "SUB a BAUD_RATE0");

        switch_baud(2'b11, CLK_FREQ / BAUD_RATE3, "BAUD_RATE3 (el mas lento)");
        run_op(6'b100100, 8'hF0, 8'hFF, "AND a BAUD_RATE3");

        $display("\n========================================");
        if (errors == 0)
            $display("RESULTADO: %0d/%0d operaciones correctas.", ops_ok, ops_ok);
        else
            $display("RESULTADO: %0d de %0d operaciones fallaron.", errors, errors + ops_ok);
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
