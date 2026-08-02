// =============================================================================
// Módulo:         uart_rx
//
// Descripción:
// FSM receptora UART. Sigue la secuencia de estados del enunciado:
//   idle  -> espera a que 'rx_i' sea '0' (comienzo del bit de start).
//   start -> cuando el contador de ticks llega a 7, la entrada está en el
//            punto medio del bit de start.
//   data  -> cada vez que el contador llega a 15 (mitad del bit actual), se
//            muestrea 'rx_i' hacia un shift register. Se repite DBIT veces.
//   stop  -> se repite el muestreo SB_TICKS/16 veces (bits de stop) y se
//            levanta 'rx_done_tick_o' por un ciclo.
//
// La entrada serie 'rx_i' es asincrona respecto de 'clk_i', por lo que se
// sincroniza con un doble flip-flop antes de usarla en la FSM (evita
// metaestabilidad).
// =============================================================================
module uart_rx #(
    parameter DBIT     = 8,   // cantidad de bits de datos por trama
    parameter SB_TICKS = 16   // ticks (s_tick_i) que dura el/los bit/s de stop
)(
    input  wire            clk_i,
    input  wire            rst_i,
    input  wire            rx_i,
    input  wire            s_tick_i,

    output reg [DBIT-1:0]  dout_o,
    output reg             rx_done_tick_o
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
    localparam [1:0] IDLE  = 2'd0,
                      START = 2'd1,
                      DATA  = 2'd2,
                      STOP  = 2'd3;

    reg [1:0]                  state_reg, state_next;
    reg [TICK_CNT_WIDTH-1:0]   tick_cnt_reg, tick_cnt_next; // contador de ticks (0..15)
    reg [BIT_CNT_WIDTH-1:0]    bit_idx_reg, bit_idx_next;   // indice del bit de datos
    reg [DBIT-1:0]             shift_reg, shift_next;       // shift register de datos
    reg [DBIT-1:0]             dout_next;
    reg                        rx_done_next;

    // Registro de estado (memoria). 'dout_o' y 'rx_done_tick_o' se registran
    // aca, junto con el resto, en lugar de en un bloque separado o como
    // salida puramente combinacional: un consumidor externo (otro módulo,
    // mismo clk) que muestree una señal puramente combinacional derivada de
    // estos mismos registros en el MISMO flanco en que cambian puede leerla
    // todavía con el valor viejo (nada garantiza que la propagación
    // combinacional entre módulos se resuelva antes de que el bloque
    // clocked del consumidor evalúe su condición ese mismo flanco). Al
    // registrar ambas salidas juntas, quedan estables un ciclo completo
    // antes de que cualquier consumidor síncrono las necesite leer.
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg      <= IDLE;
            tick_cnt_reg   <= {TICK_CNT_WIDTH{1'b0}};
            bit_idx_reg    <= {BIT_CNT_WIDTH{1'b0}};
            shift_reg      <= {DBIT{1'b0}};
            dout_o         <= {DBIT{1'b0}};
            rx_done_tick_o <= 1'b0;
        end
        else begin
            state_reg      <= state_next;
            tick_cnt_reg   <= tick_cnt_next;
            bit_idx_reg    <= bit_idx_next;
            shift_reg      <= shift_next;
            dout_o         <= dout_next;
            rx_done_tick_o <= rx_done_next;
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

        case (state_reg)
            IDLE: begin
                if (~rx_sync2) begin
                    state_next    = START;
                    tick_cnt_next = {TICK_CNT_WIDTH{1'b0}};
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
