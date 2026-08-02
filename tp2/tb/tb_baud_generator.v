// =============================================================================
// Módulo:         tb_baud_generator (Test Bench)
//
// Verifica que 'tick_o' se genere exactamente cada MOD_VALUE ciclos de clock
// para CADA uno de los 4 presets de baud rate, y que cambiar 'baud_sel_i' en
// caliente reinicia el contador en vez de arrastrar la cuenta vieja (lo que
// daría un primer tick con período incorrecto, mezcla de dos bases de
// tiempo).
// =============================================================================
`timescale 1ns / 1ps

module tb_baud_generator;

    // Parámetros pequeños para que la simulación sea corta, eligiendo 4
    // "baud rates" ficticios que dan MOD_VALUE entero y distinto cada uno.
    localparam CLK_FREQ   = 3840;
    localparam BAUD_RATE0 = 10; // MOD_VALUE0 = 24
    localparam BAUD_RATE1 = 20; // MOD_VALUE1 = 12
    localparam BAUD_RATE2 = 40; // MOD_VALUE2 = 6
    localparam BAUD_RATE3 = 80; // MOD_VALUE3 = 3
    localparam OVERSAMPLE = 16;
    localparam CLK_PERIOD = 10;

    reg        tb_clk;
    reg        tb_rst;
    reg  [1:0] tb_sel;
    wire       tb_tick;

    integer cycles_since_tick;
    integer ticks_seen;
    integer errors;
    reg     skip_next_tick; // discontinuidad pendiente (reset o cambio de preset)
    integer expected_mod;   // período esperado para el preset actualmente activo

    baud_rate_generator #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3),
        .OVERSAMPLE (OVERSAMPLE)
    ) uut (
        .clk_i      (tb_clk),
        .rst_i      (tb_rst),
        .baud_sel_i (tb_sel),
        .tick_o     (tb_tick)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // Cuenta ciclos entre ticks y verifica que coincida con 'expected_mod'.
    // El primer tick tras cualquier discontinuidad (reset o cambio de
    // 'tb_sel') no se valida, igual que el primer tick tras el reset en la
    // versión anterior de este testbench: su distancia depende de la fase
    // exacta en la que ocurrió la discontinuidad, no del período estacionario.
    always @(posedge tb_clk) begin
        if (tb_rst) begin
            cycles_since_tick <= 0;
        end
        else if (tb_tick) begin
            if (skip_next_tick) begin
                $display("  -> INFO  | Tick post-discontinuidad detectado, usado como referencia (%0d ciclos)",
                          cycles_since_tick + 1);
                skip_next_tick <= 1'b0;
            end
            else if (cycles_since_tick != expected_mod - 1) begin
                $error("  -> FALLO | Periodo entre ticks incorrecto. Esperado:%0d ciclos, Medido:%0d ciclos",
                       expected_mod, cycles_since_tick + 1);
                errors = errors + 1;
            end
            else begin
                $display("  -> EXITO | Tick #%0d detectado con periodo correcto (%0d ciclos)",
                          ticks_seen + 1, cycles_since_tick + 1);
            end
            ticks_seen <= ticks_seen + 1;
            cycles_since_tick <= 0;
        end
        else begin
            cycles_since_tick <= cycles_since_tick + 1;
        end
    end

    // Cambia el preset activo, marca la discontinuidad esperada y espera a
    // que se observen 'n' ticks correctos con el nuevo período.
    task run_preset(input [1:0] sel, input integer mod_value, input integer n_ticks, input [255:0] label);
        integer target;
        begin
            $display("\n--- Preset %0d (%0s), MOD_VALUE esperado = %0d ---", sel, label, mod_value);
            @(negedge tb_clk); // margen de un flanco antes de cambiar el selector
            tb_sel         = sel;
            expected_mod   = mod_value;
            skip_next_tick = 1'b1;
            target = ticks_seen + n_ticks + 1; // +1 por el tick de descarte
            wait (ticks_seen >= target);
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion del Baud Rate Generator (4 presets + cambio en caliente)");
        $display("========================================");

        ticks_seen        = 0;
        cycles_since_tick = 0;
        errors            = 0;
        skip_next_tick    = 1'b0;
        expected_mod      = CLK_FREQ / (BAUD_RATE1 * OVERSAMPLE);
        tb_sel            = 2'b01; // arranca en el preset "por defecto" (equivalente a 19200 real)

        tb_rst = 1;
        #(CLK_PERIOD * 3);
        tb_rst = 0;
        skip_next_tick = 1'b1; // el primer tick tras el reset tampoco se valida

        run_preset(2'b01, CLK_FREQ / (BAUD_RATE1 * OVERSAMPLE), 4, "BAUD_RATE1");
        run_preset(2'b00, CLK_FREQ / (BAUD_RATE0 * OVERSAMPLE), 4, "BAUD_RATE0, mas lento");
        run_preset(2'b11, CLK_FREQ / (BAUD_RATE3 * OVERSAMPLE), 4, "BAUD_RATE3, mas rapido");
        run_preset(2'b10, CLK_FREQ / (BAUD_RATE2 * OVERSAMPLE), 4, "BAUD_RATE2");
        run_preset(2'b01, CLK_FREQ / (BAUD_RATE1 * OVERSAMPLE), 4, "de vuelta a BAUD_RATE1");

        if (errors == 0)
            $display("\nRESULTADO: TODOS LOS TICKS TUVIERON EL PERIODO ESPERADO (%0d ticks, 4 presets).", ticks_seen);
        else
            $display("\nRESULTADO: %0d TICK(S) CON PERIODO INCORRECTO.", errors);

        $display("========================================");
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule
