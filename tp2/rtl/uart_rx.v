// =============================================================================
// Módulo:         uart_rx
//
// Descripción:
// FSM receptora UART. Sigue la secuencia de estados del enunciado:
//   idle   -> espera a que 'rx_i' sea '0' (comienzo del bit de start).
//   start  -> cuando el contador de ticks llega a 7, la entrada está en el
//             punto medio del bit de start.
//   data   -> cada vez que el contador llega a 15 (mitad del bit actual), se
//             muestrea 'rx_i' hacia un shift register. Se repite DBIT veces.
//   parity -> solo si 'parity_en_i' estaba en alto al detectar el start
//             bit de esta trama (ver más abajo). Se repite el mismo
//             muestreo una vez más para el bit de paridad, y se compara
//             contra la paridad calculada sobre los DBIT bits de datos ya
//             recibidos.
//   stop   -> se repite el muestreo SB_TICKS/16 veces (bits de stop) y se
//             levanta 'rx_done_tick_o' por un ciclo.
//
// La entrada serie 'rx_i' es asincrona respecto de 'clk_i', por lo que se
// sincroniza con un doble flip-flop antes de usarla en la FSM (evita
// metaestabilidad).
//
// Ante un error de paridad, el byte NO se descarta: se sigue entregando
// por 'dout_o'/'rx_done_tick_o' igual que siempre, y 'parity_err_o' se
// levanta aparte como flag informativo.
// =============================================================================
module uart_rx #(
    parameter DBIT       = 8, // cantidad de bits de datos por trama
    parameter SB_TICKS   = 16 // ticks (s_tick_i) que dura el bit de stop
)(
    input  wire            clk_i,
    input  wire            rst_i,
    input  wire            rx_i,
    input  wire            s_tick_i,
    input  wire            parity_en_i,    // 0 = sin bit de paridad; 1 = con paridad

    output reg [DBIT-1:0]  dout_o,
    output reg             rx_done_tick_o,
    output reg             parity_err_o    // valido junto con rx_done_tick_o;
);

    localparam integer BIT_CNT_WIDTH  = $clog2(DBIT);
    localparam integer TICK_CNT_MAX   = (SB_TICKS > 16) ? SB_TICKS : 16;
    localparam integer TICK_CNT_WIDTH = $clog2(TICK_CNT_MAX);

    // --- Sincronizador de entrada asincrona ---
    reg rx_sync1, rx_sync2;
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            rx_sync1 <= 1'b1;
            rx_sync2 <= 1'b1;
        end
        else begin
            rx_sync1 <= rx_i;
            rx_sync2 <= rx_sync1;
        end
    end

    // --- Estados ---
    // 3 bits para 5 estados
    localparam [2:0] IDLE   = 3'd0,
                      START  = 3'd1,
                      DATA   = 3'd2,
                      PARITY = 3'd3,
                      STOP   = 3'd4;

    reg [2:0]                  state_reg, state_next;
    reg [TICK_CNT_WIDTH-1:0]   tick_cnt_reg, tick_cnt_next; // contador de ticks (0..15)
    reg [BIT_CNT_WIDTH-1:0]    bit_idx_reg, bit_idx_next;   // indice del bit de datos
    reg [DBIT-1:0]             shift_reg, shift_next;       // shift register de datos
    reg [DBIT-1:0]             dout_next;
    reg                        rx_done_next;
    reg                        parity_err_next;
    reg                        parity_en_reg, parity_en_next; // copia de 'parity_en_i' latcheada al detectar el start bit

    // --- Registro de estado ---
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg      <= IDLE;
            tick_cnt_reg   <= {TICK_CNT_WIDTH{1'b0}};
            bit_idx_reg    <= {BIT_CNT_WIDTH{1'b0}};
            shift_reg      <= {DBIT{1'b0}};
            dout_o         <= {DBIT{1'b0}};
            rx_done_tick_o <= 1'b0;
            parity_err_o   <= 1'b0;
            parity_en_reg  <= 1'b0;
        end
        else begin
            state_reg      <= state_next;
            tick_cnt_reg   <= tick_cnt_next;
            bit_idx_reg    <= bit_idx_next;
            shift_reg      <= shift_next;
            dout_o         <= dout_next;
            rx_done_tick_o <= rx_done_next;
            parity_err_o   <= parity_err_next;
            parity_en_reg  <= parity_en_next;
        end
    end

    // Lógica de próximo estado
    always @(*) begin
        state_next     = state_reg;
        tick_cnt_next  = tick_cnt_reg;
        bit_idx_next   = bit_idx_reg;
        shift_next     = shift_reg;
        dout_next      = dout_o;
        rx_done_next   = 1'b0;
        parity_err_next = parity_err_o; // se mantiene hasta el proximo chequeo (ver estado PARITY)
        parity_en_next  = parity_en_reg; // se mantiene hasta la proxima trama (ver IDLE)

        case (state_reg)
            IDLE: begin
                if (~rx_sync2) begin
                    state_next    = START;
                    tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
                    parity_en_next = parity_en_i;
                end
            end

            START: begin
                if (s_tick_i) begin
                    if (tick_cnt_reg == 4'd7) begin
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
                if (s_tick_i) begin
                    if (tick_cnt_reg == 4'd15) begin
                        tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
                        shift_next    = {rx_sync2, shift_reg[DBIT-1:1]};
                        if (bit_idx_reg == DBIT-1) begin
                            state_next = parity_en_reg ? PARITY : STOP;
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

            // Solo se alcanza si parity_en_reg=1
                if (s_tick_i) begin
                    if (tick_cnt_reg == 4'd15) begin
                        tick_cnt_next   = {TICK_CNT_WIDTH{1'b0}};
                        state_next      = STOP;
                        parity_err_next = (rx_sync2 != (^shift_reg)); // paridad EVEN, unica opcion soportada
                    end
                    else begin
                        tick_cnt_next = tick_cnt_reg + 1'b1;
                    end
                end
            end

            STOP: begin
                if (s_tick_i) begin
                    if (tick_cnt_reg == SB_TICKS - 1) begin
                        state_next   = IDLE;
                        rx_done_next = 1'b1;
                        dout_next    = shift_reg; // se oficializa el byte recien recibido
                    end
                    else begin
                        tick_cnt_next = tick_cnt_reg + 1'b1;
                    end
                end
            end

            default: state_next = IDLE;
        endcase
    end

endmodule
