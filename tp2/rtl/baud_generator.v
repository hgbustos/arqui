// =============================================================================
// Módulo:         baud_rate_generator
//
// Descripción:
// Genera un pulso 'tick_o' de un ciclo de clock de duración, 16 veces por
// cada período de baud rate (sobremuestreo x16). Es un contador módulo
// CLK_FREQ / (BAUD_RATE * OVERSAMPLE). Soporta 4 baud rates preseteados
// (parametrizables) elegibles en runtime vía 'baud_sel_i', pensando en
// probarlo en la placa real con switches sin tener que resintetizar para
// cambiar de velocidad. Con los valores por defecto (50 MHz, preset 01 =
// 19200 baudios) el módulo resulta ~163, tal como en el enunciado.
// =============================================================================
module baud_rate_generator #(
    parameter CLK_FREQ   = 50_000_000,
    parameter BAUD_RATE0 = 9_600,   // baud_sel_i = 2'b00
    parameter BAUD_RATE1 = 19_200,  // baud_sel_i = 2'b01
    parameter BAUD_RATE2 = 57_600,  // baud_sel_i = 2'b10
    parameter BAUD_RATE3 = 115_200, // baud_sel_i = 2'b11
    parameter OVERSAMPLE = 16
)(
    input wire        clk_i,
    input wire        rst_i,
    input wire [1:0]  baud_sel_i,

    output reg  tick_o
);

    localparam integer MOD_VALUE0 = CLK_FREQ / (BAUD_RATE0 * OVERSAMPLE);
    localparam integer MOD_VALUE1 = CLK_FREQ / (BAUD_RATE1 * OVERSAMPLE);
    localparam integer MOD_VALUE2 = CLK_FREQ / (BAUD_RATE2 * OVERSAMPLE);
    localparam integer MOD_VALUE3 = CLK_FREQ / (BAUD_RATE3 * OVERSAMPLE);

    // El contador se dimensiona para el divisor más grande de los 4 (el
    // baud rate más lento, BAUD_RATE0 por defecto).
    localparam integer MOD_MAX_01 = (MOD_VALUE0 > MOD_VALUE1) ? MOD_VALUE0 : MOD_VALUE1;
    localparam integer MOD_MAX_23 = (MOD_VALUE2 > MOD_VALUE3) ? MOD_VALUE2 : MOD_VALUE3;
    localparam integer MOD_MAX    = (MOD_MAX_01 > MOD_MAX_23) ? MOD_MAX_01 : MOD_MAX_23;
    localparam integer CNT_WIDTH  = $clog2(MOD_MAX);

    reg [CNT_WIDTH-1:0] count;
    reg [CNT_WIDTH-1:0] mod_value;
    reg [1:0]           baud_sel_reg; // valor de 'baud_sel_i' del ciclo anterior, para detectar cambios

    // Selección combinacional del divisor activo.
    always @(*) begin
        case (baud_sel_i)
            2'b00:   mod_value = MOD_VALUE0[CNT_WIDTH-1:0];
            2'b01:   mod_value = MOD_VALUE1[CNT_WIDTH-1:0];
            2'b10:   mod_value = MOD_VALUE2[CNT_WIDTH-1:0];
            default: mod_value = MOD_VALUE3[CNT_WIDTH-1:0];
        endcase
    end

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            count        <= {CNT_WIDTH{1'b0}};
            tick_o       <= 1'b0;
            baud_sel_reg <= baud_sel_i; // asume el selector ya estable antes del reset
        end
        else begin
            baud_sel_reg <= baud_sel_i;
            // Si cambió el preset, reiniciar el contador limpio: seguir
            // contando con el divisor viejo generaría un tick con período
            // incorrecto (mezcla de dos bases de tiempo distintas).
            if (baud_sel_i != baud_sel_reg) begin
                count  <= {CNT_WIDTH{1'b0}};
                tick_o <= 1'b0;
            end
            else if (count == mod_value - 1) begin
                count  <= {CNT_WIDTH{1'b0}};
                tick_o <= 1'b1;
            end
            else begin
                count  <= count + 1'b1;
                tick_o <= 1'b0;
            end
        end
    end

endmodule
