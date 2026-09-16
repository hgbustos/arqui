// =============================================================================
// Módulo:         tb_demo (Testbench de demostración para la defensa)
//
// A diferencia de los 9 testbenches de regresión (tb_uart_rx.v, tb_uart_tx.v,
// tb_uart_interface.v, tb_alu_link.v, tb_baud_generator.v, tb_uart_alu_top.v
// y los 3 de paridad), que verifican exhaustivamente cada módulo por
// separado, este testbench corre UNA sola operación de punta a punta sobre
// el sistema completo (uart_alu_top), narrada paso a paso por consola y
// pensada para mostrarse en vivo junto con GTKWave durante la defensa.
//
// Flujo: CMD_LOAD (opcode=ADD, A=100, B=50) -> CMD_READ -> verifica
// resultado=150, co=0, zero=0 (el mismo caso ya validado en hardware real,
// ver informe.md 4.3). Reutiliza las mismas tareas de envío/recepción UART
// (timing real, bit a bit) y el mismo checker independiente de tx_o que
// tb_uart_alu_top.v, ya probados.
//
// Cómo correrlo (desde la raíz del repo):
//   iverilog -g2012 -o sim_demo tp2/tb/tb_demo.v tp2/rtl/uart_alu_top.v \
//     tp2/rtl/baud_generator.v tp2/rtl/uart_rx.v tp2/rtl/uart_tx.v \
//     tp2/rtl/uart_interface.v tp2/rtl/alu_link.v tp1/ALU.v
//   vvp sim_demo
//   gtkwave tb_demo.vcd
// =============================================================================
`timescale 1ns / 1ps

module tb_demo;

    localparam N = 8;
    localparam CLK_FREQ   = 8000; // valores chicos para simular rápido, misma idea que tb_uart_alu_top.v
    localparam BAUD_RATE0 = 500;
    localparam BAUD_RATE1 = 125;  // preset fijo usado en esta demo -> BIT_CYCLES=64
    localparam BAUD_RATE2 = 250;
    localparam BAUD_RATE3 = 50;
    localparam CLK_PERIOD = 10;
    localparam integer BIT_CYCLES = CLK_FREQ / BAUD_RATE1;

    localparam [7:0] CMD_LOAD = 8'h01;
    localparam [7:0] CMD_READ = 8'h02;
    localparam [5:0] OP_ADD   = 6'b100000;

    reg  tb_clk;
    reg  tb_rst;
    reg  tb_rx;
    wire tb_tx;

    // --- DUT: sistema completo ---
    uart_alu_top #(
        .N          (N),
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3)
    ) dut (
        .clk_i       (tb_clk),
        .rst_i       (tb_rst),
        .rx_i        (tb_rx),
        .baud_sel_i  (2'b01), // preset por defecto (BAUD_RATE1), fijo en esta demo
        .parity_en_i (1'b0),  // sin paridad: el camino por defecto ya probado en hardware
        .tx_o        (tb_tx)
    );

    // --- Checker: decodifica tx_o de forma independiente del DUT, como lo
    // haría un receptor externo real (mismo patrón que tb_uart_alu_top.v) ---
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
        .baud_sel_i (2'b01),
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
        .parity_en_i    (1'b0),
        .dout_o         (chk_dout),
        .rx_done_tick_o (chk_rx_done_tick)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Volcado recursivo para GTKWave: incluye los registros de estado
    // internos de cada FSM (baud_generator, uart_rx, uart_tx,
    // uart_interface, alu_link, ALU), no solo los puertos del top.
    initial begin
        $dumpfile("tb_demo.vcd");
        $dumpvars(0, tb_demo);
    end

    // Envía un byte UART completo sobre rx_i (start + 8 datos LSB-primero +
    // stop), a razón de BIT_CYCLES ciclos de clock por bit, igual que lo
    // haría un emisor externo real.
    task send_byte(input [N-1:0] data, input [255:0] label);
        integer i;
        begin
            $display("[%0t ns] PC  -> FPGA   %0s = 0x%02h (%0d)", $time, label, data, data);
            tb_rx = 1'b0; // start bit
            repeat (BIT_CYCLES) @(posedge tb_clk);
            for (i = 0; i < N; i = i + 1) begin
                tb_rx = data[i];
                repeat (BIT_CYCLES) @(posedge tb_clk);
            end
            tb_rx = 1'b1; // stop bit
            repeat (BIT_CYCLES) @(posedge tb_clk);
        end
    endtask

    // Espera a que el checker decodifique el próximo byte de tx_o (ver
    // tb_uart_alu_top.v: el segundo wait evita "recapturar" la cola del
    // mismo pulso en la próxima llamada).
    task recv_byte(output [N-1:0] data, input [255:0] label);
        begin
            wait (chk_rx_done_tick === 1'b1);
            data = chk_dout;
            $display("[%0t ns] FPGA -> PC    %0s = 0x%02h (%0d)", $time, label, data, data);
            wait (chk_rx_done_tick === 1'b0);
            @(negedge tb_clk);
        end
    endtask

    reg [N-1:0] got_result, got_status;
    reg [N-1:0] exp_result;
    reg         exp_co, exp_zero;
    integer     errors;

    initial begin
        $display("========================================================");
        $display(" DEMO TP2 -- ALU operada por UART (uart_alu_top)");
        $display(" Operacion: ADD(100, 50) -- mismo caso validado en Basys3 real (informe 4.3)");
        $display("========================================================");

        errors     = 0;
        tb_rx      = 1'b1; // línea en reposo
        exp_result = 8'd150;
        exp_co     = 1'b0;
        exp_zero   = 1'b0;

        tb_rst = 1'b1;
        repeat (5) @(posedge tb_clk);
        tb_rst = 1'b0;
        repeat (5) @(posedge tb_clk);

        $display("\n--- Fase 1: CMD_LOAD (carga opcode=ADD, A=100, B=50; no responde nada) ---");
        send_byte(CMD_LOAD,        "CMD_LOAD  ");
        send_byte({2'b00, OP_ADD}, "opcode    ");
        send_byte(8'd100,          "operando A");
        send_byte(8'd50,           "operando B");

        $display("\n--- Fase 2: CMD_READ (pide el resultado de lo recien cargado) ---");
        send_byte(CMD_READ, "CMD_READ  ");
        recv_byte(got_result, "resultado ");
        recv_byte(got_status, "estado    ");

        $display("\n--- Verificacion ---");
        if (got_result !== exp_result || got_status[0] !== exp_zero || got_status[1] !== exp_co) begin
            $error("FALLO: resultado esp=%0d rec=%0d | co esp=%b rec=%b | zero esp=%b rec=%b",
                   exp_result, got_result, exp_co, got_status[1], exp_zero, got_status[0]);
            errors = errors + 1;
        end
        else begin
            $display("EXITO: 100 + 50 = %0d (co=%b, zero=%b) -- coincide con lo esperado y con hardware real",
                      got_result, got_status[1], got_status[0]);
        end

        $display("\n========================================================");
        if (errors == 0)
            $display(" DEMO OK. Abrir tb_demo.vcd en GTKWave para ver las formas de onda.");
        else
            $display(" DEMO FALLO (%0d error/es).", errors);
        $display("========================================================");
        $finish;
    end

endmodule
