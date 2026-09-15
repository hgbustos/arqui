`timescale 1ns / 1ps
`include "riscv_isa_encode.vh"
// =============================================================================
// Módulo:         tb_riscv_uart_top
//
// Descripción:
// Testbench de integración de punta a punta (Fase 2): a diferencia de
// tb_debug_unit.v/tb_dump_unit.v (que manejan la interfaz Rx/Tx tipo
// registro directamente), acá se banguea la línea 'rx_i' bit a bit como lo
// haría una PC real (start bit, 8 datos LSB-primero, stop bit) y se
// decodifica 'tx_o' de la misma forma, atravesando la cadena completa:
// baud_rate_generator + uart_rx/uart_tx + uart_interface (las tres, de
// TP2, sin modificar) + debug_unit + dump_unit + riscv_core. El objetivo
// es validar el cableado de riscv_uart_top.v y el protocolo de extremo a
// extremo -- la lógica interna de cada pieza ya se verificó por separado
// (201 tests de riscv_core.v en Fase 1, 29 de debug_unit.v y 58 de
// dump_unit.v en Fase 2).
//
// Usa una base de tiempos artificialmente rápida (CLK_FREQ/BAUD_RATE1
// chicos, MOD_VALUE=4) y una dmem chica (4 palabras) sólo para que la
// simulación corra en segundos -- no cambia nada del protocolo, sólo la
// velocidad y el tamaño del volcado.
// =============================================================================
module tb_riscv_uart_top;

    localparam [7:0] CMD_LOAD_PROG = 8'h10;
    localparam [7:0] CMD_RUN       = 8'h20;
    localparam [7:0] CMD_STEP      = 8'h21;

    localparam DMEM_WORDS  = 4;
    localparam FIXED_WORDS = 53;
    localparam TOTAL_WORDS = FIXED_WORDS + DMEM_WORDS;

    // Base de tiempos de simulación: MOD_VALUE = CLK_FREQ/(BAUD*16) = 5.
    // Deliberadamente NO una potencia de 2: baud_generator.v dimensiona su
    // contador con $clog2(MOD_MAX), que da la cantidad de bits que
    // necesita para contar valores 0..MOD_MAX-1, no para representar el
    // literal MOD_MAX en sí. Si MOD_MAX es una potencia de 2 exacta (4, 8,
    // 16...), $clog2 no deja el bit de margen que hace falta para guardar
    // ese literal completo, y el contador de baudios nunca genera 'tick_o'
    // (se comprobó en simulación con MOD_VALUE=4: 'tick_o' quedaba en 0
    // para siempre). No es un bug que afecte al hardware real -- ninguno
    // de los 4 MOD_VALUE de la Basys3 a 100MHz cae en una potencia de 2
    // exacta -- así que no se toca baud_generator.v (TP2, reutilizado sin
    // modificar); alcanza con elegir acá un CLK_FREQ/BAUD que no la
    // dispare.
    localparam CLK_PERIOD = 10;      // ns por ciclo de reloj
    localparam SIM_CLK_FREQ  = 80_000;
    localparam SIM_BAUD_RATE = 1_000;
    localparam real BIT_TIME = 16.0 * 5 * CLK_PERIOD; // 16 ticks * MOD_VALUE ciclos * periodo

    reg tb_clk, tb_rst;
    reg tb_rx;
    wire tb_tx;
    reg [1:0] tb_baud_sel;

    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    riscv_uart_top #(
        .IMEM_DEPTH_WORDS(64),
        .DMEM_DEPTH_WORDS(DMEM_WORDS),
        .CLK_FREQ  (SIM_CLK_FREQ),
        .BAUD_RATE0(SIM_BAUD_RATE), .BAUD_RATE1(SIM_BAUD_RATE),
        .BAUD_RATE2(SIM_BAUD_RATE), .BAUD_RATE3(SIM_BAUD_RATE)
    ) uut (
        .clk_i(tb_clk), .rst_i(tb_rst), .rx_i(tb_rx), .baud_sel_i(tb_baud_sel), .tx_o(tb_tx),
        .seg_o(), .dp_o(), .an_o()
    );

    // ------------------------------------------------------------------
    // UART banguada a mano (host <-> FPGA), 8N1
    // ------------------------------------------------------------------
    task send_uart_byte;
        input [7:0] data;
        integer i;
        begin
            tb_rx = 1'b0; // start
            #(BIT_TIME);
            for (i = 0; i < 8; i = i + 1) begin
                tb_rx = data[i];
                #(BIT_TIME);
            end
            tb_rx = 1'b1; // stop
            #(BIT_TIME);
        end
    endtask

    task send_word_le;
        input [31:0] word;
        begin
            send_uart_byte(word[7:0]);
            send_uart_byte(word[15:8]);
            send_uart_byte(word[23:16]);
            send_uart_byte(word[31:24]);
        end
    endtask

    // Nota de diseño: no hay espera fija para el bit de stop al final.
    // Alcanza con haber muestreado bit7 a mitad de su propia ventana; el
    // resto de esa ventana, el bit de stop completo, y cualquier hueco
    // entre bytes que agregue el hardware (PREP_WORD + el handshake
    // wr/tx_full de dump_unit.v) lo absorbe el '@(negedge tb_tx)' de la
    // PROXIMA llamada, que espera lo que haga falta sin asumir una
    // duración fija. La primera versión sí tenía una espera fija ahí (una
    // mitad de bit extra) que asumía "bit de stop + arranque del próximo
    // byte" con una duración exacta -- como esa duración real es un poco
    // más larga (el handshake agrega algo de por medio), cada byte se
    // desincronizaba un poco más que el anterior, un bit entero por byte,
    // hasta perder la trama por completo a partir del segundo byte.
    task recv_uart_byte;
        output [7:0] data;
        integer i;
        begin
            @(negedge tb_tx);
            #(BIT_TIME/2.0);
            for (i = 0; i < 8; i = i + 1) begin
                #(BIT_TIME);
                data[i] = tb_tx;
            end
        end
    endtask

    reg [31:0] dump_words [0:TOTAL_WORDS-1];
    task recv_dump;
        integer w;
        reg [7:0] b0, b1, b2, b3;
        begin
            for (w = 0; w < TOTAL_WORDS; w = w + 1) begin
                recv_uart_byte(b0);
                recv_uart_byte(b1);
                recv_uart_byte(b2);
                recv_uart_byte(b3);
                dump_words[w] = {b3, b2, b1, b0};
            end
        end
    endtask

    task check32;
        input [511:0] label;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: 0x%08h", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Programa de prueba
    // ------------------------------------------------------------------
    reg [31:0] prog [0:4];

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion end-to-end de riscv_uart_top");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_rst = 1; tb_rx = 1'b1; tb_baud_sel = 2'b01;
        #(CLK_PERIOD*4);
        tb_rst = 0;
        #(CLK_PERIOD*4);

        // addi x1,x0,10 / addi x2,x0,32 / add x3,x1,x2 / sw x3,0(x0) / halt
        prog[0] = i_addi(1, 0, 10);
        prog[1] = i_addi(2, 0, 32);
        prog[2] = i_add (3, 1, 2);
        prog[3] = i_sw  (0, 3, 12'd0);
        prog[4] = i_halt(0);

        $display("\n===== CMD_LOAD_PROG por UART real (bit a bit) =====");
        send_uart_byte(CMD_LOAD_PROG);
        send_uart_byte(8'd5); send_uart_byte(8'd0); // N=5, little-endian
        send_word_le(prog[0]);
        send_word_le(prog[1]);
        send_word_le(prog[2]);
        send_word_le(prog[3]);
        send_word_le(prog[4]);
        $display("  -> programa enviado (5 palabras)");

        $display("\n===== CMD_RUN + recepcion del volcado completo =====");
        // fork/join, NO secuencial: el programa de prueba es tan chico
        // (5 instrucciones) que el core llega a HALT y dump_unit ya
        // empieza a mandar el primer byte de la respuesta mientras
        // send_uart_byte(CMD_RUN) todavia esta terminando de sostener su
        // propio bit de stop -- si recv_dump arranca recien DESPUES de
        // que send_uart_byte retorne, el primer '@(negedge tb_tx)' llega
        // tarde y cae en medio de la trama en vez de al principio.
        fork
            send_uart_byte(CMD_RUN);
            recv_dump;
        join
        $display("  -> volcado recibido (%0d palabras)", TOTAL_WORDS);

        check32("SYNC",                       dump_words[0], 32'hAA55AA55);
        check32("STATUS: core_halted=1",      dump_words[1] & 32'h1, 32'h1);
        check32("x1 = 10",                    dump_words[21+1], 32'd10);
        check32("x2 = 32",                    dump_words[21+2], 32'd32);
        check32("x3 = 42 (10+32)",            dump_words[21+3], 32'd42);
        check32("dmem[0] = 42 (sw x3,0(x0))", dump_words[FIXED_WORDS+0], 32'd42);
        if (dump_words[2] !== 32'd0) begin
            pass_count = pass_count + 1;
            $display("  -> EXITO | CYCLE_COUNT > 0: %0d ciclos", dump_words[2]);
        end else begin
            fail_count = fail_count + 1;
            $error("  -> FALLO | CYCLE_COUNT deberia ser mayor a 0");
        end

        $display("\n===== CMD_STEP por UART real (no debe cambiar nada, core ya detenido) =====");
        fork
            send_uart_byte(CMD_STEP);
            recv_dump;
        join
        check32("STATUS sigue en halted tras CMD_STEP sobre core detenido", dump_words[1] & 32'h1, 32'h1);
        check32("x3 sigue en 42 (nada avanzo)", dump_words[21+3], 32'd42);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("RISCV_UART_TOP: TODOS LOS TESTS PASARON");
        else $display("RISCV_UART_TOP: HAY TESTS FALLADOS");
        $finish;
    end

    // Salvavidas de simulacion: si algo se traba, cortar en vez de colgar.
    initial begin
        #(BIT_TIME * 10 * (TOTAL_WORDS*4 + 30) * 3);
        $display("TIMEOUT: la simulacion no termino a tiempo");
        $finish;
    end

endmodule
