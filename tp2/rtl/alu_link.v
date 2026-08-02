// =============================================================================
// Módulo:         alu_link
//
// Descripción:
// Protocolo serie de este TP sobre el "Interface Circuit" (uart_interface).
// A diferencia de una primera versión que asumía "el primer byte siempre es
// un opcode de ALU y toda carga dispara una respuesta automática", este
// protocolo usa un byte de COMANDO inicial que decide qué hacer, y separa
// "cargar operandos" de "pedir el resultado" como dos acciones explícitas.
// Se eligió así pensando en que este mismo Interface Circuit va a tener que
// encajar en el pipeline completo del TP final: ahí se va a necesitar cargar
// datos (instrucciones, registros) sin una respuesta por cada byte, y leer
// resultados bajo demanda en un momento distinto al de la carga. El formato
// "opcode+A+B -> respuesta automática" no generaliza a eso; un dispatcher de
// comandos sí (agregar un comando nuevo el día de mañana es un case más, no
// un protocolo nuevo).
//
//   Comandos (primer byte de cada transacción):
//     CMD_LOAD (0x01) -> le siguen 3 bytes: opcode (bits[5:0]), operando A,
//                        operando B. Se cargan los registros; NO se envía
//                        nada por 'tx' todavía.
//     CMD_READ (0x02) -> sin bytes adicionales. Dispara el envío de los 2
//                        bytes de respuesta (resultado + estado) sobre el
//                        último opcode/A/B cargados.
//     cualquier otro   -> se descarta (se consume el byte, no se hace nada),
//                        para no trabarse ante ruido o un comando futuro que
//                        todavía no se implementó.
//
//   Salida (siempre en este orden, tras un CMD_READ):
//     1) resultado -> alu_out[N-1:0]
//     2) estado    -> {{(N-2){1'b0}}, co, zero}  (bit1=co, bit0=zero)
//
// Instancia la ALU combinacional de tp1/ALU.v sin modificarla.
// =============================================================================
module alu_link #(
    parameter N = 8
)(
    input  wire         clk_i,
    input  wire         rst_i,

    // --- Lado Rx del Interface Circuit ---
    input  wire [N-1:0] r_data_i,
    input  wire         rx_empty_i,
    output reg           rd_o,

    // --- Lado Tx del Interface Circuit ---
    output reg [N-1:0]   w_data_o,
    input  wire          tx_full_i,
    output reg            wr_o
);

    localparam [7:0] CMD_LOAD = 8'h01;
    localparam [7:0] CMD_READ = 8'h02;

    // --- Estados ---
    // SEND_RESULT/SEND_STATUS sostienen 'wr_o' hasta VER 'tx_full_i' en
    // alto (confirma que uart_interface aceptó el byte) en vez de asumir
    // que un solo ciclo alcanza. WAIT_RESULT_SENT espera a que 'tx_full_i'
    // vuelva a bajar (byte realmente transmitido, buffer libre) antes de
    // intentar el segundo envío: ver "Lecciones de diseño" en el README.
    localparam [2:0] RECV_CMD        = 3'd0,
                      RECV_OP         = 3'd1,
                      RECV_A          = 3'd2,
                      RECV_B          = 3'd3,
                      SEND_RESULT     = 3'd4,
                      WAIT_RESULT_SENT = 3'd5,
                      SEND_STATUS     = 3'd6;

    reg [2:0]   state_reg, state_next;
    reg [5:0]   reg_opcode, opcode_next;
    reg [N-1:0] reg_A, A_next;
    reg [N-1:0] reg_B, B_next;

    // --- ALU combinacional (reutilizada de tp1, sin modificar) ---
    // Instanciada despues de declarar reg_opcode/reg_A/reg_B (y no antes,
    // como en una version previa): conectar un puerto a un identificador
    // todavia no declarado hace que Icarus lo trate como una wire implicita
    // de 1 bit hasta encontrar la declaracion real mas abajo en el archivo
    // (funciona por tolerancia del parser, pero no es portable a otras
    // herramientas de sintesis).
    wire [N-1:0] alu_out;
    wire         alu_zero;
    wire         alu_co;

    ALU #(.N(N)) u_alu (
        .opcode (reg_opcode),
        .in1    (reg_A),
        .in2    (reg_B),
        .out    (alu_out),
        .zero   (alu_zero),
        .co     (alu_co)
    );

    // Registro de estado (memoria)
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg  <= RECV_CMD;
            reg_opcode <= 6'b0;
            reg_A      <= {N{1'b0}};
            reg_B      <= {N{1'b0}};
        end
        else begin
            state_reg  <= state_next;
            reg_opcode <= opcode_next;
            reg_A      <= A_next;
            reg_B      <= B_next;
        end
    end

    // Lógica de próximo estado y de las salidas hacia el Interface Circuit
    always @(*) begin
        state_next  = state_reg;
        opcode_next = reg_opcode;
        A_next      = reg_A;
        B_next      = reg_B;
        rd_o        = 1'b0;
        wr_o        = 1'b0;
        w_data_o    = {N{1'b0}};

        case (state_reg)
            // Dispatcher de comandos: el primer byte decide qué sigue.
            RECV_CMD: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    case (r_data_i)
                        CMD_LOAD: state_next = RECV_OP;
                        CMD_READ: state_next = SEND_RESULT;
                        default:  state_next = RECV_CMD; // comando desconocido: se descarta
                    endcase
                end
            end

            RECV_OP: begin
                if (~rx_empty_i) begin
                    rd_o        = 1'b1;
                    opcode_next = r_data_i[5:0];
                    state_next  = RECV_A;
                end
            end

            RECV_A: begin
                if (~rx_empty_i) begin
                    rd_o       = 1'b1;
                    A_next     = r_data_i;
                    state_next = RECV_B;
                end
            end

            RECV_B: begin
                if (~rx_empty_i) begin
                    rd_o       = 1'b1;
                    B_next     = r_data_i;
                    state_next = RECV_CMD; // carga completa; espera un CMD_READ para responder
                end
            end

            // Al llegar aca, reg_opcode/reg_A/reg_B ya están estables desde
            // el último CMD_LOAD, así que alu_out/alu_zero/alu_co (puramente
            // combinacionales) ya son válidos.
            SEND_RESULT: begin
                w_data_o = alu_out;
                wr_o     = 1'b1; // sostenido hasta confirmar aceptacion
                if (tx_full_i) begin
                    state_next = WAIT_RESULT_SENT;
                end
            end

            // Esperar a que el primer byte termine de transmitirse (buffer
            // libre otra vez) antes de intentar escribir el segundo.
            WAIT_RESULT_SENT: begin
                if (~tx_full_i) begin
                    state_next = SEND_STATUS;
                end
            end

            SEND_STATUS: begin
                w_data_o = {{(N - 2){1'b0}}, alu_co, alu_zero};
                wr_o     = 1'b1; // sostenido hasta confirmar aceptacion
                if (tx_full_i) begin
                    state_next = RECV_CMD;
                end
            end

            default: state_next = RECV_CMD;
        endcase
    end

endmodule
