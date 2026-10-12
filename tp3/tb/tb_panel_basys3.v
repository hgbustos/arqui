`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_panel_basys3
//
// Descripción:
// Testbench del panel de la placa (tp3/rtl/fpga/panel_basys3.v), con los
// tiempos achicados (1 "ms" del panel = 4 ciclos) para simular rápido:
//   1. Display: marquesina inicial, LoAd / rESt según el largo del
//      soft-reset, Step vs. Run, rUn -> viborita -> StOP (pausa), HALt <->
//      ciclos (HALT), y CYCLE_COUNT en decimal con el punto de "más de 4
//      cifras". El display se reconstruye mirando el multiplexado (an_o +
//      seg_o), como lo vería el ojo.
//   2. LEDs: lee la traza real del RTL (tp3/host/testdata/pipeline_trace.hex,
//      la misma que usa la GUI) y verifica, ciclo por ciclo, que los LEDs
//      coincidan con los eventos que riscv_pipeview.py muestra para ese
//      programa (forwarding, stalls, saltos tomados, HALT).
// Correr desde la raíz del repo (lee la traza con ruta relativa):
//   iverilog -g2012 -o tb.vvp tp3/rtl/core/control_unit.v tp3/rtl/fpga/panel_basys3.v \
//     tp3/tb/tb_panel_basys3.v && vvp tb.vvp
// =============================================================================
module tb_panel_basys3;

    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;

    reg        stall = 1'b1, halted = 1'b0, soft_rst = 1'b0, hz = 1'b0, br = 1'b0;
    reg [7:0]  fwd = 8'b0;
    reg [31:0] id_instr = 32'h00000013, ex_instr = 32'h00000013, cycles = 32'd0;
    wire [6:0] seg;
    wire       dp;
    wire [3:0] an;
    wire [15:0] led;

    panel_basys3 #(
        .CLK_FREQ(4000), .TICK_HZ(1000), .MSG_MS(20), .RUN_WORD_MS(20),
        .HALT_ALT_MS(20), .SNAKE_STEP_MS(2), .MARQUEE_STEP_MS(15)
    ) dut (
        .clk_i(clk), .rst_i(rst),
        .core_stall_i(stall), .core_halted_i(halted), .core_soft_reset_i(soft_rst),
        .hazard_stall_i(hz), .branch_taken_i(br), .fwd_sel_i(fwd),
        .if_id_instr_i(id_instr), .id_ex_instr_i(ex_instr), .cycle_count_i(cycles),
        .seg_o(seg), .dp_o(dp), .an_o(an), .led_o(led)
    );

    integer pass_count = 0, fail_count = 0;

    task check;
        input [511:0] label;
        input ok;
        begin
            if (ok) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s", label);
            end
        end
    endtask

    // --- Caracteres <-> patrones a..g (activos en alto) ---
    function [6:0] pat;
        input [7:0] c;
        case (c)
            "0", "O": pat = 7'h3F; "1": pat = 7'h06; "2": pat = 7'h5B; "3": pat = 7'h4F;
            "4": pat = 7'h66; "5", "S": pat = 7'h6D; "6": pat = 7'h7D; "7": pat = 7'h07;
            "8": pat = 7'h7F; "9": pat = 7'h6F; "A": pat = 7'h77; "C": pat = 7'h39;
            "d": pat = 7'h5E; "E": pat = 7'h79; "H": pat = 7'h76; "I": pat = 7'h30;
            "L": pat = 7'h38; "n": pat = 7'h54; "o": pat = 7'h5C; "P": pat = 7'h73;
            "r": pat = 7'h50; "t": pat = 7'h78; "U": pat = 7'h3E; "-": pat = 7'h40;
            default: pat = 7'h00;
        endcase
    endfunction

    function [7:0] chr;   // sólo para imprimir (S y 5, O y 0 se ven igual)
        input [6:0] p;
        case (p)
            7'h3F: chr = "0"; 7'h06: chr = "1"; 7'h5B: chr = "2"; 7'h4F: chr = "3";
            7'h66: chr = "4"; 7'h6D: chr = "5"; 7'h7D: chr = "6"; 7'h07: chr = "7";
            7'h7F: chr = "8"; 7'h6F: chr = "9"; 7'h77: chr = "A"; 7'h39: chr = "C";
            7'h5E: chr = "d"; 7'h79: chr = "E"; 7'h76: chr = "H"; 7'h30: chr = "I";
            7'h38: chr = "L"; 7'h54: chr = "n"; 7'h5C: chr = "o"; 7'h73: chr = "P";
            7'h50: chr = "r"; 7'h78: chr = "t"; 7'h3E: chr = "U"; 7'h40: chr = "-";
            7'h00: chr = " "; default: chr = "?";
        endcase
    endfunction

    // --- Lectura del display multiplexado: un barrido completo ---
    reg [6:0] cap [0:3];   // cap[3] = dígito izquierdo
    reg       cap_dot;
    task capture;
        integer k;
        begin
            cap_dot = 1'b0;
            for (k = 0; k < 24; k = k + 1) begin
                @(posedge clk); #1;
                case (an)
                    4'b1110: cap[0] = ~seg;
                    4'b1101: cap[1] = ~seg;
                    4'b1011: cap[2] = ~seg;
                    4'b0111: begin cap[3] = ~seg; cap_dot = ~dp; end
                    default: ;
                endcase
            end
        end
    endtask

    function frame_is;
        input [31:0] s;    // "abcd": s[31:24] = dígito izquierdo
        frame_is = (cap[3] == pat(s[31:24])) && (cap[2] == pat(s[23:16])) &&
                   (cap[1] == pat(s[15:8]))  && (cap[0] == pat(s[7:0]));
    endfunction

    // Espera hasta que el display muestre 's' (con o sin el punto izquierdo)
    task wait_display;
        input [31:0]  s;
        input         dot;
        input integer max_frames;
        input [511:0] label;
        integer f;
        reg     ok;
        begin
            ok = 1'b0;
            for (f = 0; f < max_frames && !ok; f = f + 1) begin
                capture;
                if (frame_is(s) && cap_dot == dot) ok = 1'b1;
            end
            if (!ok) $display("     display = \"%s%s%s%s\" punto=%b", chr(cap[3]), chr(cap[2]),
                              chr(cap[1]), chr(cap[0]), cap_dot);
            check(label, ok);
        end
    endtask

    // La viborita se mueve más rápido que un barrido completo del display,
    // así que se mira directamente lo que el panel está mostrando (dig[]).
    function integer lit_segments;
        input dummy;
        integer d, b;
        begin
            lit_segments = 0;
            for (d = 0; d < 4; d = d + 1)
                for (b = 0; b < 7; b = b + 1)
                    lit_segments = lit_segments + dut.dig[d][b];
        end
    endfunction

    // --- Traza real del RTL para los LEDs ---
    localparam TRACE_WORDS = 59;   // 55 fijas + 4 de dmem (tb_pipeline_trace.v)
    reg [31:0] w [0:TRACE_WORDS-1];
    reg [15:0] exp_led [0:19];
    integer fd, line, i, r;
    reg [3:0] pos_a;
    integer lit;
    reg [8*40-1:0] lbl;

    initial begin
        $display("========================================");
        $display("Panel de la placa (display + LEDs)");
        $display("========================================");
        repeat (3) @(posedge clk);
        rst = 1'b0;

        // ---------------------------------------------------------------
        $display("\n--- 1. Display ---");
        wait_display("rISC", 1'b0, 60, "saludo: la marquesina pasa por \"rISC\"");
        wait_display("SC-5", 1'b0, 60, "saludo: ... y por \"SC-5\"");
        wait_display("   0", 1'b0, 60, "despues del saludo: ciclo 0 en decimal");

        cycles = 32'd19;
        wait_display("  19", 1'b0, 10, "ciclo 19 (ceros a la izquierda apagados)");
        cycles = 32'd105;
        wait_display(" 105", 1'b0, 10, "ciclo 105");
        cycles = 32'd9999;
        wait_display("9999", 1'b0, 10, "ciclo 9999: entran las 4 cifras, sin punto");
        cycles = 32'd10000;
        wait_display("0000", 1'b1, 10, "ciclo 10000: ultimas 4 cifras + punto izquierdo");
        cycles = 32'hFFFFFFFF;
        wait_display("7295", 1'b1, 10, "ciclo 4294967295: ultimas 4 cifras + punto izquierdo");
        cycles = 32'd0;

        // Carga de programa: soft-reset largo -> LoAd, después vuelve a reposo
        @(negedge clk); soft_rst = 1'b1;
        repeat (50) @(negedge clk);
        soft_rst = 1'b0;
        wait_display("LoAd", 1'b0, 10, "CMD_LOAD_*: \"LoAd\"");
        wait_display("   0", 1'b0, 60, "despues de LoAd: ciclo 0");

        // CMD_RESET: soft-reset de 1 ciclo -> rESt
        @(negedge clk); soft_rst = 1'b1;
        @(negedge clk); soft_rst = 1'b0;
        wait_display("rESt", 1'b0, 10, "CMD_RESET: \"rESt\"");
        wait_display("   0", 1'b0, 60, "despues de rESt: ciclo 0");

        // Step: el núcleo avanza exactamente 1 ciclo -> sigue mostrando ciclos
        @(negedge clk); stall = 1'b0; cycles = 32'd1;
        @(negedge clk); stall = 1'b1;
        wait_display("   1", 1'b0, 10, "CMD_STEP: muestra el ciclo nuevo, no \"rUn\"");

        // Run con pausa: rUn -> viborita -> StOP
        @(negedge clk); stall = 1'b0;
        wait_display(" rUn", 1'b0, 10, "CMD_RUN: primero \"rUn\"");
        repeat (120) @(posedge clk); #1;   // pasa RUN_WORD_MS
        lit = lit_segments(0);
        check("viborita: 3 segmentos encendidos (cabeza + 2 de cola)", lit == 3);
        pos_a = dut.snake_pos;
        repeat (12) @(posedge clk); #1;    // más que SNAKE_STEP_MS
        check("viborita: se mueve", dut.snake_pos != pos_a);
        lit = lit_segments(0);
        check("viborita: sigue con 3 segmentos despues de moverse", lit == 3);
        @(negedge clk); stall = 1'b1;  // pausa: se frena sin HALT
        wait_display("StOP", 1'b0, 10, "pausa (CMD_BREAK): \"StOP\"");
        @(negedge clk); stall = 1'b0; cycles = 32'd2;
        @(negedge clk); stall = 1'b1;
        wait_display("   2", 1'b0, 10, "Step despues de la pausa: ciclo");

        // Run que termina por HALT: HALt <-> ciclos
        @(negedge clk); stall = 1'b0;
        repeat (40) @(negedge clk);
        cycles = 32'd32; halted = 1'b1; stall = 1'b1;   // mismo ciclo, como en RUN_EXEC
        wait_display("HALt", 1'b0, 10, "HALT: \"HALt\"");
        wait_display("  32", 1'b0, 40, "HALT: alterna con los ciclos ejecutados");
        wait_display("HALt", 1'b0, 40, "HALT: y vuelve a \"HALt\"");
        // Un Step/Run sobre un núcleo detenido no lo libera: no cambia nada
        wait_display("  32", 1'b0, 40, "HALT: sigue alternando");

        // Cargar otro programa sale del HALT
        @(negedge clk); soft_rst = 1'b1; halted = 1'b0; cycles = 32'd0;
        repeat (50) @(negedge clk);
        soft_rst = 1'b0;
        wait_display("LoAd", 1'b0, 10, "carga despues de un HALT: \"LoAd\"");
        wait_display("   0", 1'b0, 60, "y vuelve al ciclo 0");

        // Reset físico: vuelve el saludo
        @(negedge clk); rst = 1'b1;
        @(negedge clk); rst = 1'b0;
        wait_display("rISC", 1'b0, 60, "reset fisico: vuelve el saludo");

        // ---------------------------------------------------------------
        $display("\n--- 2. LEDs contra la traza real del RTL ---");
        // Esperado por ciclo, sacado de los eventos de riscv_pipeview.py
        // sobre la misma traza (ver tb_pipeline_trace.v):
        //   led[15] HALT, [14] stall, [13] salto tomado,
        //   [11:9] ID rs1 <- EX/MEM/WB, [8:6] ID rs2 <- EX/MEM/WB,
        //   [4:3] ALU rs1 <- MEM/WB, [2:1] ALU rs2 <- MEM/WB
        for (i = 0; i < 20; i = i + 1) exp_led[i] = 16'h0000;
        exp_led[3]  = 16'h0014;   // x1 desde EX/MEM a rs1 y rs2 de la ALU
        exp_led[4]  = 16'h0004;   // x2 desde EX/MEM al dato del sw (rs2)
        exp_led[5]  = 16'h4000;   // stall load-use
        exp_led[7]  = 16'h0808;   // x4 desde EX al comparador (rs1) + x3 desde MEM/WB a la ALU (rs1)
        exp_led[9]  = 16'h4000;   // stall load-use antes de un salto
        exp_led[10] = 16'h4000;   // stall load antes de salto (2do ciclo)
        exp_led[11] = 16'h0200;   // x5 desde MEM/WB al comparador (rs1)
        exp_led[12] = 16'h2000;   // jal tomado
        exp_led[14] = 16'h2400;   // jalr tomado + x6 desde EX/MEM al comparador (rs1)
        exp_led[19] = 16'h8000;   // HALT en WB

        fd = $fopen("tp3/host/testdata/pipeline_trace.hex", "r");
        if (fd == 0) begin
            check("abrir tp3/host/testdata/pipeline_trace.hex (correr desde la raiz)", 1'b0);
        end
        else begin
            for (line = 0; line < 20; line = line + 1) begin
                for (i = 0; i < TRACE_WORDS; i = i + 1) r = $fscanf(fd, "%h", w[i]);
                @(negedge clk);
                halted   = w[1][0];  br = w[1][1];  hz = w[1][3];  fwd = w[1][15:8];
                id_instr = w[4];     ex_instr = w[6];
                repeat (3) @(posedge clk); #1;
                if (led !== exp_led[line])
                    $display("     ciclo %0d: led=%016b esperado=%016b", w[2], led, exp_led[line]);
                $sformat(lbl, "LEDs del ciclo %0d", w[2]);
                check(lbl, led === exp_led[line]);
            end
            $fclose(fd);
        end

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        $finish;
    end

endmodule
