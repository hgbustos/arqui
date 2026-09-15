// =============================================================================
// Módulo:         uart_alu_top
//
// Descripción:
// Módulo top de TP2: equivalente a tp1/ALU_top.v pero con la UART como
// interfaz en lugar de switches/botones/leds. Integra:
//
//   Baud Rate Generator -> genera 's_tick' (16x el baud rate) para Rx y Tx.
//   uart_rx  -> deserializa la línea 'rx_i'.
//   uart_tx  -> serializa hacia la línea 'tx_o'.
//   uart_interface -> adapta Rx/Tx a una interfaz de 1 byte por sentido
//                     (r_data/rd/rx_empty, w_data/wr/tx_full).
//   alu_link -> protocolo de comando+trigger de este TP (CMD_LOAD/CMD_READ,
//               ver README) e instancia la ALU combinacional de tp1/ALU.v
//               sin modificarla.
//
// Único punto de entrada/salida hacia el exterior: 'rx_i' (dato serie desde
// la PC) y 'tx_o' (dato serie hacia la PC), además de clock, reset y
// 'baud_sel_i'. CLK_FREQ=100MHz por defecto porque es la frecuencia real
// del oscilador de la Basys3 (ver tp2/constraints/uart_alu_top.xdc); si se
// instancia para simulación con otro CLK_FREQ, hay que pasarlo explícito.
//
// Paridad (opcional, 'parity_en_i' en bajo por defecto, siempre EVEN
// cuando está activa -- única variante soportada, ver uart_rx.v/
// uart_tx.v): 'parity_en_i' se reenvía tal cual a uart_rx y uart_tx --
// los dos lados de un mismo enlace tienen que coincidir en la trama que
// usan, así que no tendría sentido que difirieran entre sí dentro de
// esta misma instancia. Es una entrada en tiempo real, no un parámetro:
// pensada para un switch físico de la Basys3 (mismo patrón que
// 'baud_sel_i'), así se puede probar con y sin paridad sin resintetizar.
// Con el switch en bajo el comportamiento es bit a bit idéntico al ya
// verificado en simulación y en la Basys 3 real; 'parity_err_o' queda
// expuesto al tope como señal informativa (no se propaga a alu_link, que
// no tiene mecanismo de reintento -- ver uart_rx.v), mapeada a una LED en
// el .xdc.
// =============================================================================
module uart_alu_top #(
    parameter N           = 8,           // ancho de datos de la ALU / bytes UART
    parameter CLK_FREQ    = 100_000_000, // clock de la placa (Basys 3)
    parameter BAUD_RATE0  = 9_600,      // baud_sel_i = 2'b00
    parameter BAUD_RATE1  = 19_200,     // baud_sel_i = 2'b01 (default equivalente al anterior)
    parameter BAUD_RATE2  = 57_600,     // baud_sel_i = 2'b10
    parameter BAUD_RATE3  = 115_200,    // baud_sel_i = 2'b11
    parameter SB_TICKS    = 16          // ticks de stop bit (16 = 1 bit de stop)
)(
    input  wire       clk_i,
    input  wire       rst_i,
    input  wire       rx_i,
    input  wire [1:0] baud_sel_i,  // selector de baud rate en runtime (p.ej. switches de la Basys3)
    input  wire       parity_en_i, // 0 = sin paridad (comportamiento original); 1 = con paridad (p.ej. otro switch)
    output wire       tx_o,
    output wire       parity_err_o, // informativo; sin sentido si esta trama no tenia paridad. Ver nota arriba.

    // Display de 7 segmentos: este TP no lo usa, pero la Basys3 lo comparte
    // el mismo banco de pines con otras señales, así que hay que manejarlo
    // explícitamente. Dejarlo sin conectar en el XDC lo deja flotando (se ve
    // como "medio prendido"); acá se apaga a propósito (activo en bajo:
    // todo en '1' = apagado).
    output wire [6:0] seg_o,
    output wire       dp_o,
    output wire [3:0] an_o
);

    assign seg_o = 7'b1111111;
    assign dp_o  = 1'b1;
    assign an_o  = 4'b1111;

    // --- Base de tiempos ---
    wire s_tick;

    baud_rate_generator #(
        .CLK_FREQ   (CLK_FREQ),
        .BAUD_RATE0 (BAUD_RATE0),
        .BAUD_RATE1 (BAUD_RATE1),
        .BAUD_RATE2 (BAUD_RATE2),
        .BAUD_RATE3 (BAUD_RATE3),
        .OVERSAMPLE (16)
    ) u_baud_gen (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .baud_sel_i (baud_sel_i),
        .tick_o     (s_tick)
    );

    // --- Receptor UART ---
    wire [N-1:0] rx_dout;
    wire         rx_done_tick;

    uart_rx #(
        .DBIT       (N),
        .SB_TICKS   (SB_TICKS)
    ) u_uart_rx (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .rx_i           (rx_i),
        .s_tick_i       (s_tick),
        .parity_en_i    (parity_en_i),
        .dout_o         (rx_dout),
        .rx_done_tick_o (rx_done_tick),
        .parity_err_o   (parity_err_o)
    );

    // --- Transmisor UART ---
    wire         tx_start;
    wire [N-1:0] tx_din;
    wire         tx_done_tick;

    uart_tx #(
        .DBIT       (N),
        .SB_TICKS   (SB_TICKS)
    ) u_uart_tx (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .tx_start_i     (tx_start),
        .s_tick_i       (s_tick),
        .din_i          (tx_din),
        .parity_en_i    (parity_en_i),
        .tx_done_tick_o (tx_done_tick),
        .tx_o           (tx_o)
    );

    // --- Interface Circuit (adaptador de bytes) ---
    wire [N-1:0] r_data;
    wire         rx_empty;
    wire         rd;
    wire [N-1:0] w_data;
    wire         tx_full;
    wire         wr;

    uart_interface #(
        .DBIT (N)
    ) u_interface (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .rx_dout_i      (rx_dout),
        .rx_done_tick_i (rx_done_tick),
        .tx_done_tick_i (tx_done_tick),
        .tx_start_o     (tx_start),
        .din_o          (tx_din),
        .r_data_o       (r_data),
        .rx_empty_o     (rx_empty),
        .rd_i           (rd),
        .w_data_i       (w_data),
        .tx_full_o      (tx_full),
        .wr_i           (wr)
    );

    // --- Protocolo (opcode+A+B -> resultado+estado) + ALU de TP1 ---
    alu_link #(
        .N (N)
    ) u_alu_link (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .r_data_i   (r_data),
        .rx_empty_i (rx_empty),
        .rd_o       (rd),
        .w_data_o   (w_data),
        .tx_full_i  (tx_full),
        .wr_o       (wr)
    );

endmodule
