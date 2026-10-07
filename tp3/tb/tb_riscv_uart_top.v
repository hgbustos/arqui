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
// (testbenches de rtl/core/, tb_debug_unit.v y tb_dump_unit.v). Cubre la
// carga de un programa, CMD_RUN hasta HALT, CMD_STEP sobre un core
// detenido, y un loop infinito: CMD_RUN no termina solo, CMD_BREAK lo
// pausa, un CMD_STEP posterior avanza exactamente 1 ciclo y otro CMD_RUN
// continúa desde donde quedó.
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
    localparam [7:0] CMD_BREAK     = 8'h24;

    localparam DMEM_WORDS  = 4;
    localparam FIXED_WORDS = 55;
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

    task check_true;
        input [511:0] label;
        input         cond;
        begin
            if (cond === 1'b1) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s", label);
            end
        end
    endtask

    // Detecta cualquier actividad en 'tx_o' (un bit de start = flanco de
    // bajada): sirve para confirmar que NO empezó un volcado.
    reg tx_activity;
    always @(negedge tb_tx) tx_activity = 1'b1;

    // ------------------------------------------------------------------
    // Programa de prueba
    // ------------------------------------------------------------------
    reg [31:0] prog [0:4];
    reg [31:0] x5_paused, cycles_paused;

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
        // 5 instrucciones sin stalls: el HALT (indice 4) entra a IF/ID en el
        // ciclo 5 y llega a WB 3 ciclos despues. La Debug Unit congela el
        // core en ese mismo ciclo, sin dejarlo avanzar uno de mas.
        check32("CYCLE_COUNT exacto: HALT en WB en el ciclo 8", dump_words[2], 32'd8);
        // Etapa IF y bits nuevos de STATUS: con el HALT retenido en IF/ID
        // el PC quedo congelado en HALT+4, que imem lee como 0 (vacia).
        check32("IF.pc = HALT+4 (palabra 53)",            dump_words[53], 32'h14);
        check32("IF.instr = imem vacia (palabra 54)",     dump_words[54], 32'h0);
        check32("STATUS: stalled por HALT, no por datos", dump_words[1] & 32'hC, 32'h4);
        check32("STATUS: sin forwarding (todo el pipeline es HALT)", (dump_words[1] >> 8) & 32'hFF, 32'h0);

        $display("\n===== CMD_STEP por UART real (no debe cambiar nada, core ya detenido) =====");
        fork
            send_uart_byte(CMD_STEP);
            recv_dump;
        join
        check32("STATUS sigue en halted tras CMD_STEP sobre core detenido", dump_words[1] & 32'h1, 32'h1);
        check32("x3 sigue en 42 (nada avanzo)", dump_words[21+3], 32'd42);
        check32("CYCLE_COUNT no cambia (STEP sobre un core detenido es un no-op)", dump_words[2], 32'd8);

        $display("\n===== Loop infinito: CMD_RUN no termina solo, CMD_BREAK lo pausa =====");
        // addi x5,x0,0 / loop: addi x5,x5,1 / jal x0,loop. Nunca llega a un
        // HALT: ni siquiera al implicito de la addr 12, porque el jal tomado
        // descarta (flush) esa instruccion cada vez que se la busca.
        prog[0] = i_addi(5, 0, 0);
        prog[1] = i_addi(5, 5, 1);
        prog[2] = i_jal (0, -21'sd4);
        send_uart_byte(CMD_LOAD_PROG);
        send_uart_byte(8'd3); send_uart_byte(8'd0); // N=3
        send_word_le(prog[0]);
        send_word_le(prog[1]);
        send_word_le(prog[2]);
        send_uart_byte(CMD_RUN);
        tx_activity = 1'b0;
        #(BIT_TIME * 40);
        check_true("RUN sobre un loop: no hay volcado espontaneo", tx_activity === 1'b0);
        fork
            send_uart_byte(CMD_BREAK);
            recv_dump;
        join
        check32("pausa: STATUS core_halted=0 (fue pausa, no HALT)", dump_words[1] & 32'h1, 32'h0);
        check_true("pausa: el loop corrio (x5 > 0)", dump_words[21+5] > 0);
        x5_paused     = dump_words[21+5];
        cycles_paused = dump_words[2];

        $display("\n===== Tras la pausa: STEP avanza 1 ciclo, RUN continua =====");
        fork
            send_uart_byte(CMD_STEP);
            recv_dump;
        join
        check32("STEP tras la pausa: CYCLE_COUNT avanza exactamente 1", dump_words[2], cycles_paused + 1);
        send_uart_byte(CMD_RUN);
        #(BIT_TIME * 20);
        fork
            send_uart_byte(CMD_BREAK);
            recv_dump;
        join
        check_true("RUN tras la pausa continua (x5 sigue creciendo)",
                   dump_words[21+5] > x5_paused);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("RISCV_UART_TOP: TODOS LOS TESTS PASARON");
        else $display("RISCV_UART_TOP: HAY TESTS FALLADOS");
        $finish;
    end

    // Salvavidas de simulacion: si algo se traba, cortar en vez de colgar.
    initial begin
        #(BIT_TIME * 10 * (TOTAL_WORDS*4 + 30) * 8); // ~5 volcados + cargas + esperas
        $display("TIMEOUT: la simulacion no termino a tiempo");
        $finish;
    end

endmodule
