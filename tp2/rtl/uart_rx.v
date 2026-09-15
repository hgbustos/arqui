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
// Paridad (opcional, 'parity_en_i' en bajo por defecto):
// El enunciado la marca como opcional en la trama. A diferencia de la
// primera version, 'PARITY_EN' ya no es un parametro de compilacion sino
// una ENTRADA en tiempo real ('parity_en_i'), pensada para un switch
// fisico de la Basys3 -- mismo criterio que 'baud_sel_i' en
// baud_generator.v: se puede prender/apagar sin resintetizar. Se
// muestrea una sola vez por trama, al detectar el bit de start (ver
// IDLE), y esa copia registrada ('parity_en_reg') es la que decide el
// resto de la trama: si alguien mueve el switch a mitad de una
// recepcion, no afecta al byte que ya esta en curso, solo al proximo.
//
// Ante un error de paridad, el byte NO se descarta: se sigue entregando
// por 'dout_o'/'rx_done_tick_o' igual que siempre, y 'parity_err_o' se
// levanta aparte como flag informativo. Se eligió así porque este
// receptor no tiene forma de pedir un reenvío (no hay ACK/NACK en el
// protocolo de este TP): descartar el byte en silencio ante un error de
// paridad desincronizaría la FSM de comandos de 'alu_link' de una forma
// peor que la que se intenta evitar (ver README, "Lecciones de diseño").
// =============================================================================
module uart_rx #(
    parameter DBIT       = 8, // cantidad de bits de datos por trama
    parameter SB_TICKS   = 16 // ticks (s_tick_i) que dura el/los bit/s de stop
)(
    input  wire            clk_i,
    input  wire            rst_i,
    input  wire            rx_i,
    input  wire            s_tick_i,
    input  wire            parity_en_i,    // 0 = sin bit de paridad (comportamiento original); 1 = con paridad

    output reg [DBIT-1:0]  dout_o,
    output reg             rx_done_tick_o,
    output reg             parity_err_o    // valido junto con rx_done_tick_o; sin sentido si esta trama no tenia paridad
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
    // 3 bits para 5 estados (antes 2 bits para 4 sin paridad): el estado
    // PARITY se agrega siempre en el RTL, aunque con parity_en_i en bajo nunca se
    // alcanza (DATA salta directo a STOP, ver más abajo) -- así se evita
    // duplicar la FSM entera por parámetro, al costo de 1 bit más de
    // registro de estado. Mismo trade-off "binaria, sin presión de
    // área/frecuencia" ya justificado en el informe para los 4 estados
    // originales. Deja 3 códigos sin usar (3'b101, 3'b110, 3'b111),
    // cubiertos por el 'default' de FSM segura, igual que en alu_link.
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
                    // Se latchea 'parity_en_i' justo al detectar el start
                    // bit: esta trama usa el valor del switch en ESTE
                    // instante, sin importar si cambia despues (mientras
                    // se recibe) o antes de la proxima trama.
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

            // Solo se alcanza si parity_en_reg=1 (ver DATA). 'shift_reg' ya
            // tiene los DBIT bits de datos completos -- el ultimo se
            // termina de armar en 'shift_next' al salir de DATA, y para
            // cuando la FSM llega aca ya quedo registrado. Se compara el
            // bit muestreado en el punto medio (tick 15) contra la
            // paridad esperada de esos DBIT bits.
            PARITY: begin
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
