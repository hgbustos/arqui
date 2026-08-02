// =============================================================================
// Módulo:         uart_interface
//
// Descripción:
// "Interface Circuit" del diagrama del enunciado: adapta el Rx/Tx (que
// trabajan a nivel de bit/trama) a una interfaz de 1 palabra por sentido,
// tipo FIFO, para que un controlador aguas abajo pueda leer y escribir
// bytes sin conocer nada de UART:
//
//   Lado Rx: rx_dout_i / rx_done_tick_i (de uart_rx)  -> r_data_o / rx_empty_o,
//            consumido con un pulso de 1 ciclo en 'rd_i'.
//   Lado Tx: w_data_i / wr_i (pulso de 1 ciclo)        -> din_o / tx_start_o
//            (hacia uart_tx), con tx_full_o indicando "ocupado" hasta que
//            'tx_done_tick_i' confirma que se transmitió.
//
// Es un buffer de una sola palabra en cada sentido (no una FIFO profunda):
// alcanza porque el protocolo de este TP consume/produce un byte por vez.
// =============================================================================
module uart_interface #(
    parameter DBIT = 8
)(
    input  wire             clk_i,
    input  wire             rst_i,

    // --- Lado Rx (uart_rx) ---
    input  wire [DBIT-1:0]  rx_dout_i,
    input  wire             rx_done_tick_i,

    // --- Lado Tx (uart_tx) ---
    input  wire             tx_done_tick_i,
    output wire              tx_start_o,
    output wire [DBIT-1:0]   din_o,

    // --- Lado controlador (p.ej. alu_link) ---
    output wire [DBIT-1:0]  r_data_o,
    output wire             rx_empty_o,
    input  wire             rd_i,

    input  wire [DBIT-1:0]  w_data_i,
    output wire             tx_full_o,
    input  wire             wr_i
);

    // --- Buffer de recepción ---
    reg [DBIT-1:0] rx_data_reg;
    reg            rx_valid_reg;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            rx_data_reg  <= {DBIT{1'b0}};
            rx_valid_reg <= 1'b0;
        end
        else if (rx_done_tick_i) begin
            // Un byte nuevo tiene prioridad sobre una lectura simultánea:
            // en este protocolo nunca deberían coincidir (se lee apenas
            // hay dato disponible), pero de coincidir no se pierde el dato
            // entrante.
            rx_data_reg  <= rx_dout_i;
            rx_valid_reg <= 1'b1;
        end
        else if (rd_i && rx_valid_reg) begin
            rx_valid_reg <= 1'b0;
        end
    end

    assign r_data_o   = rx_data_reg;
    assign rx_empty_o = ~rx_valid_reg;

    // --- Buffer de transmisión ---
    reg [DBIT-1:0] tx_data_reg;
    reg            tx_full_reg;
    reg            tx_start_reg;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            tx_data_reg  <= {DBIT{1'b0}};
            tx_full_reg  <= 1'b0;
            tx_start_reg <= 1'b0;
        end
        else begin
            tx_start_reg <= 1'b0; // pulso de 1 ciclo por defecto

            if (wr_i && !tx_full_reg) begin
                tx_data_reg  <= w_data_i;
                tx_full_reg  <= 1'b1;
                tx_start_reg <= 1'b1; // dispara la transmisión del byte recién cargado
            end
            else if (tx_done_tick_i) begin
                tx_full_reg <= 1'b0;
            end
        end
    end

    assign din_o      = tx_data_reg;
    assign tx_start_o = tx_start_reg;
    assign tx_full_o  = tx_full_reg;

endmodule
