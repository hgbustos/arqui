// =============================================================================
// Módulo:         tb_alu_link (Test Bench)
//
// Verifica el protocolo completo (CMD_LOAD + opcode + operando A + operando
// B, luego CMD_READ -> byte de resultado + byte de estado) instanciando
// 'alu_link' junto con 'uart_interface'. Los pulsos 'rx_done_tick'/
// 'tx_done_tick' que en el sistema real vendrían de uart_rx/uart_tx se
// simulan directamente, para poder validar muchos casos de la ALU a alta
// velocidad sin bit-banging serie (eso ya se prueba aparte, a nivel de
// sistema completo).
// =============================================================================
`timescale 1ns / 1ps

module tb_alu_link;

    localparam N          = 8;
    localparam CLK_PERIOD = 10;

    localparam [7:0] CMD_LOAD = 8'h01;
    localparam [7:0] CMD_READ = 8'h02;

    reg              tb_clk;
    reg              tb_rst;

    // Lado "Rx" simulado hacia uart_interface
    reg  [N-1:0]     tb_rx_dout;
    reg              tb_rx_done_tick;

    // Lado "Tx" simulado hacia uart_interface
    reg              tb_tx_done_tick;
    wire             tb_tx_start;
    wire [N-1:0]     tb_din;

    // Interconexion interface <-> alu_link
    wire [N-1:0]     w_r_data;
    wire             w_rx_empty;
    wire             w_rd;
    wire [N-1:0]     w_w_data;
    wire             w_tx_full;
    wire             w_wr;

    integer errors;
    integer ops_ok;

    uart_interface #(.DBIT(N)) intf (
        .clk_i          (tb_clk),
        .rst_i          (tb_rst),
        .rx_dout_i      (tb_rx_dout),
        .rx_done_tick_i (tb_rx_done_tick),
        .tx_done_tick_i (tb_tx_done_tick),
        .tx_start_o     (tb_tx_start),
        .din_o          (tb_din),
        .r_data_o       (w_r_data),
        .rx_empty_o     (w_rx_empty),
        .rd_i           (w_rd),
        .w_data_i       (w_w_data),
        .tx_full_o      (w_tx_full),
        .wr_i           (w_wr)
    );

    alu_link #(.N(N)) uut (
        .clk_i      (tb_clk),
        .rst_i      (tb_rst),
        .r_data_i   (w_r_data),
        .rx_empty_i (w_rx_empty),
        .rd_o       (w_rd),
        .w_data_o   (w_w_data),
        .tx_full_i  (w_tx_full),
        .wr_o       (w_wr)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Simula la llegada de un byte por 'rx' (lo que en el sistema real
    // entregaria uart_rx via rx_done_tick_i).
    task send_byte(input [N-1:0] data);
        begin
            wait (w_rx_empty === 1'b1); // no pisar un byte que el link todavia no leyo
            @(negedge tb_clk);
            tb_rx_dout      = data;
            tb_rx_done_tick = 1'b1;
            @(negedge tb_clk);
            tb_rx_done_tick = 1'b0;
        end
    endtask

    // Espera a que alu_link escriba un byte (tx_full sube), lo captura, y
    // simula que uart_tx ya lo transmitio (lo que libera tx_full para el
    // proximo byte).
    task recv_byte(output [N-1:0] data);
        begin
            wait (w_tx_full === 1'b1);
            data = tb_din;
            @(negedge tb_clk);
            tb_tx_done_tick = 1'b1;
            @(negedge tb_clk);
            tb_tx_done_tick = 1'b0;
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

    // Ejecuta una operacion completa a traves del protocolo (CMD_LOAD +
    // opcode + A + B, despues CMD_READ) y la compara contra el modelo de
    // referencia.
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
        #200000;
        $display("\n*** TIMEOUT: la simulacion no termino a tiempo ***");
        $finish;
    end

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de alu_link (protocolo completo)");
        $display("========================================");

        errors          = 0;
        ops_ok          = 0;
        tb_rx_dout      = 0;
        tb_rx_done_tick = 0;
        tb_tx_done_tick = 0;

        tb_rst = 1'b1;
        @(posedge tb_clk); @(posedge tb_clk);
        tb_rst = 1'b0;
        @(negedge tb_clk);

        $display("\n--- Una operacion de cada tipo ---");
        run_op(6'b100000, 8'd100, 8'd50,  "ADD");
        run_op(6'b100000, 8'd200, 8'd100, "ADD con carry-out");
        run_op(6'b100010, 8'd10,  8'd50,  "SUB con carry-out (resta negativa)");
        run_op(6'b100100, 8'hF0,  8'h0F,  "AND");
        run_op(6'b100101, 8'hF0,  8'h0F,  "OR");
        run_op(6'b100110, 8'hFF,  8'h0F,  "XOR");
        run_op(6'b000011, 8'hF0,  8'd2,   "SRA");
        run_op(6'b000010, 8'hF0,  8'd2,   "SRL");
        run_op(6'b100111, 8'hFF,  8'h00,  "NOR (tambien ejercita zero=1)");
        run_op(6'b111111, 8'd1,   8'd1,   "Opcode invalido (default)");

        $display("\n--- Varias operaciones consecutivas, sin pausas entre medio ---");
        run_op(6'b100000, 8'd1, 8'd1, "back-to-back #1");
        run_op(6'b100110, 8'd1, 8'd1, "back-to-back #2 (da zero=1)");
        run_op(6'b100000, 8'd255, 8'd1, "back-to-back #3 (overflow 8 bits)");

        $display("\n--- Operandos aleatorios ---");
        repeat (15) begin
            run_op(6'b100000, $random, $random, "random ADD");
        end

        // --- Casos que solo el protocolo CMD_LOAD/CMD_READ permite probar ---
        $display("\n--- CMD_READ repetido sin volver a cargar (releer el mismo resultado) ---");
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
            recv_byte(got_b); // descarta el estado de esta primera lectura

            send_byte(CMD_READ); // releer sin cargar de nuevo
            recv_byte(got_a);
            recv_byte(got_b);

            if (got_a !== exp_out || got_b !== exp_status) begin
                $error("  -> FALLO | CMD_READ repetido | esperado result:%02h status:%02h | recibido:%02h %02h",
                       exp_out, exp_status, got_a, got_b);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | CMD_READ repetido devolvio el mismo resultado ambas veces");
                ops_ok = ops_ok + 1;
            end
        end

        $display("\n--- Comando desconocido intercalado: se descarta y no rompe lo que sigue ---");
        begin
            send_byte(8'hFF); // comando invalido, se debe descartar sin efecto
        end
        run_op(6'b100101, 8'hAA, 8'h55, "OR justo despues de un comando invalido");

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
