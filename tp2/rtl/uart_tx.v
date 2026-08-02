// =============================================================================
// Módulo:         uart_tx
//
// Descripción:
// FSM transmisora UART, simétrica al receptor ('uart_rx'). Secuencia de
// estados:
//   idle  -> línea en reposo en '1'. Al recibir 'tx_start_i' carga el byte
//            a transmitir ('din_i') y pasa a 'start'.
//   start -> saca el bit de start ('0') durante 16 ticks (un bit completo).
//   data  -> saca cada bit de 'din_i' (LSB primero) durante 16 ticks cada
//            uno, desplazando el shift register. Se repite DBIT veces.
//   stop  -> saca el/los bit/s de stop ('1') durante SB_TICKS ticks y
//            levanta 'tx_done_tick_o' por un ciclo antes de volver a idle.
//
// La salida 'tx_o' es de tipo Moore: depende únicamente del estado (y del
// bit menos significativo del shift register, que también es parte del
// estado registrado), nunca combinacionalmente de 'din_i' o 'tx_start_i'.
// =============================================================================
module uart_tx #(
    parameter DBIT     = 8,   // cantidad de bits de datos por trama
    parameter SB_TICKS = 16   // ticks (s_tick_i) que dura el/los bit/s de stop
)(
    input  wire            clk_i,
    input  wire            rst_i,
    input  wire            tx_start_i,
    input  wire            s_tick_i,
    input  wire [DBIT-1:0] din_i,

    output reg              tx_done_tick_o,
    output wire              tx_o
);

    localparam integer BIT_CNT_WIDTH  = $clog2(DBIT);
    localparam integer TICK_CNT_MAX   = (SB_TICKS > 16) ? SB_TICKS : 16;
    localparam integer TICK_CNT_WIDTH = $clog2(TICK_CNT_MAX);

    // --- Estados ---
    localparam [1:0] IDLE  = 2'd0,
                      START = 2'd1,
                      DATA  = 2'd2,
                      STOP  = 2'd3;

    reg [1:0]                  state_reg, state_next;
    reg [TICK_CNT_WIDTH-1:0]   tick_cnt_reg, tick_cnt_next; // contador de ticks (0..15)
    reg [BIT_CNT_WIDTH-1:0]    bit_idx_reg, bit_idx_next;   // indice del bit de datos
    reg [DBIT-1:0]             shift_reg, shift_next;       // shift register de datos
    reg                        tx_reg, tx_next;             // salida serie registrada
    reg                        tx_done_next;

    // Registro de estado (memoria). 'tx_done_tick_o' se registra aca (no es
    // una salida puramente combinacional) por la misma razón que dout_o en
    // uart_rx: un consumidor externo (mismo clk, otro módulo) que lo
    // muestree en el propio bloque clocked donde se genera la condición no
    // tiene garantizado ver la versión combinacional resuelta en ese mismo
    // flanco.
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg      <= IDLE;
            tick_cnt_reg   <= {TICK_CNT_WIDTH{1'b0}};
            bit_idx_reg    <= {BIT_CNT_WIDTH{1'b0}};
            shift_reg      <= {DBIT{1'b0}};
            tx_reg         <= 1'b1; // línea en reposo en '1'
            tx_done_tick_o <= 1'b0;
        end
        else begin
            state_reg      <= state_next;
            tick_cnt_reg   <= tick_cnt_next;
            bit_idx_reg    <= bit_idx_next;
            shift_reg      <= shift_next;
            tx_reg         <= tx_next;
            tx_done_tick_o <= tx_done_next;
        end
    end

    // Lógica de próximo estado y de la salida serie
    always @(*) begin
        state_next    = state_reg;
        tick_cnt_next = tick_cnt_reg;
        bit_idx_next  = bit_idx_reg;
        shift_next    = shift_reg;
        tx_next       = tx_reg;
        tx_done_next  = 1'b0;

        case (state_reg)
            IDLE: begin
                tx_next = 1'b1;
                if (tx_start_i) begin
                    state_next    = START;
                    tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
                    shift_next    = din_i;
                end
            end

            START: begin
                tx_next = 1'b0; // bit de start
                if (s_tick_i) begin
                    if (tick_cnt_reg == 4'd15) begin
                        state_next    = DATA;
                        tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
                        bit_idx_next  = {BIT_CNT_WIDTH{1'b0}};
                    end
                    else begin
                        tick_cnt_next = tick_cnt_reg + 1'b1;
                    end
                end
            end

            DATA: begin
                tx_next = shift_reg[0]; // LSB primero
                if (s_tick_i) begin
                    if (tick_cnt_reg == 4'd15) begin
                        tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
                        shift_next    = shift_reg >> 1;
                        if (bit_idx_reg == DBIT - 1) begin
                            state_next = STOP;
                        end
                        else begin
                            bit_idx_next = bit_idx_reg + 1'b1;
                        end
                    end
                    else begin
                        tick_cnt_next = tick_cnt_reg + 1'b1;
                    end
                end
            end

            STOP: begin
                tx_next = 1'b1; // bit(s) de stop
                if (s_tick_i) begin
                    if (tick_cnt_reg == SB_TICKS - 1) begin
                        state_next   = IDLE;
                        tx_done_next = 1'b1;
                    end
                    else begin
                        tick_cnt_next = tick_cnt_reg + 1'b1;
                    end
                end
            end

            default: state_next = IDLE;
        endcase
    end

    assign tx_o = tx_reg;

endmodule
