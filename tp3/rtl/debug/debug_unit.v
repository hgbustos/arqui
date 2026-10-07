// =============================================================================
// Módulo:         debug_unit
//
// Descripción:
// FSM de comando + trigger sobre el lado Rx del Interface Circuit
// (uart_interface.v de TP2, sin modificar), mismo patrón que
// tp2/rtl/alu_link.v: un byte de comando decide qué sigue. Protocolo
// completo documentado en tp3/docs/debug_protocol.md -- este archivo es la
// implementación fiel de esa spec, no la repite en comentarios.
//
// Sólo necesita el lado Rx (r_data_i/rx_empty_i/rd_o): nunca escribe por
// la UART directamente, eso es trabajo exclusivo de dump_unit.v (a quien
// dispara con 'dump_trigger_o'). Como cada uno usa una mitad distinta del
// Interface Circuit, no hace falta arbitrar nada entre los dos.
//
// Dueño de dos señales de control hacia riscv_core.v que nunca tocan el
// clock (enunciado): 'core_soft_reset_o' (se OR-ea con el reset físico de
// la placa en riscv_uart_top.v) y 'core_stall_o' (-> global_stall_i). Por
// default 'core_stall_o' vale 1 (el core arranca y queda frenado entre
// comandos): sólo se libera durante CMD_RUN (hasta halt o hasta una
// pausa) y CMD_STEP (exactamente 1 ciclo), y nunca con el core ya
// detenido (HALT en WB): una vez terminado el programa, ni RUN ni STEP
// lo hacen avanzar, así el volcado y CYCLE_COUNT quedan fijos.
//
// 'core_soft_reset_o' sale de un FLIP-FLOP, no de la lógica combinacional
// de la FSM: maneja el reset ASÍNCRONO de todo el core, y una salida
// combinacional decodificada de 'state_reg' puede tener glitches mientras
// los bits de estado cambian (p.ej. DUMP_WAIT=1100 -> RECV_CMD=0000 puede
// pasar un instante por 0100 o 1000, que son estados de carga). Un glitch
// sobre un reset asíncrono resetea el core de verdad. Se registra a partir
// de 'state_next', así que el pulso queda alineado exactamente con los
// mismos ciclos que antes. Las demás salidas hacia el core sí pueden ser
// combinacionales: son enables síncronos, sólo importa su valor en el
// flanco (y eso lo verifica el análisis de timing).
//
// Pausa de CMD_RUN: un programa sin HALT alcanzable (p.ej. un loop
// infinito) nunca terminaría el modo continuo. Por eso, en RUN_EXEC,
// cualquier byte que llegue por la UART detiene la ejecución: se consume,
// se descarta y se dispara el volcado (con core_halted=0, así el host sabe
// que fue una pausa). El host usa CMD_BREAK por convención, que en
// cualquier otro estado es un comando desconocido y se descarta.
//
// CMD_LOAD_PROG y CMD_LOAD_DATA comparten los mismos estados de recepción
// (LOAD_*): 'load_target_reg' (0=imem, 1=dmem), fijado al decodificar el
// comando, decide a cuál de los dos puertos de carga de riscv_core.v se
// dirige cada escritura -- evita duplicar 8 estados idénticos por cada
// memoria.
// =============================================================================
module debug_unit (
    input  wire        clk_i,
    input  wire        rst_i,

    // --- Lado Rx del Interface Circuit ---
    input  wire [7:0]  r_data_i,
    input  wire        rx_empty_i,
    output reg          rd_o,

    // --- Puerto de carga de imem (riscv_core.v) ---
    output reg          imem_load_en_o,
    output reg  [31:0]  imem_load_addr_o,
    output reg  [31:0]  imem_load_data_o,
    output reg          imem_load_clear_o,
    input  wire          imem_clear_busy_i,

    // --- Puerto de carga de dmem (riscv_core.v) ---
    output reg          dmem_load_en_o,
    output reg  [31:0]  dmem_load_addr_o,
    output reg  [31:0]  dmem_load_data_o,
    output reg          dmem_load_clear_o,
    input  wire          dmem_clear_busy_i,

    // --- Control del core ---
    output reg          core_soft_reset_o,
    output reg          core_stall_o,
    input  wire          core_halted_i,

    // --- Dump Unit ---
    output reg          dump_trigger_o,
    input  wire          dump_done_i
);

    localparam [7:0] CMD_LOAD_PROG = 8'h10;
    localparam [7:0] CMD_LOAD_DATA = 8'h11;
    localparam [7:0] CMD_RUN       = 8'h20;
    localparam [7:0] CMD_STEP      = 8'h21;
    localparam [7:0] CMD_DUMP      = 8'h22;
    localparam [7:0] CMD_RESET     = 8'h23;
    // CMD_BREAK (8'h24) no se decodifica en RECV_CMD a propósito: durante
    // RUN_EXEC cualquier byte pausa, y fuera de RUN_EXEC cae en 'default'.

    localparam [3:0]
        RECV_CMD       = 4'd0,
        LOAD_CLEAR     = 4'd1,
        LOAD_SZ_LO     = 4'd2,
        LOAD_SZ_HI     = 4'd3,
        LOAD_B0        = 4'd4,
        LOAD_B1        = 4'd5,
        LOAD_B2        = 4'd6,
        LOAD_B3        = 4'd7,
        LOAD_WRITE     = 4'd8,
        RUN_EXEC       = 4'd9,
        STEP_EXEC      = 4'd10,
        DUMP_TRIG      = 4'd11,
        DUMP_WAIT      = 4'd12,
        RST_PULSE      = 4'd13,
        LOAD_CLEAR_WAIT= 4'd14;

    reg [3:0]  state_reg, state_next;
    reg        load_target_reg, load_target_next;   // 0=imem, 1=dmem
    reg [15:0] word_count_reg, word_count_next;
    reg [31:0] load_addr_reg, load_addr_next;
    reg [31:0] word_acc_reg, word_acc_next;          // acumulador del word actual, byte a byte (LE)

    // Estados en los que el core se mantiene en soft-reset: toda la carga
    // de un programa/datos, y el pulso de CMD_RESET.
    function soft_reset_state;
        input [3:0] s;
        begin
            case (s)
                LOAD_CLEAR, LOAD_CLEAR_WAIT, LOAD_SZ_LO, LOAD_SZ_HI,
                LOAD_B0, LOAD_B1, LOAD_B2, LOAD_B3, LOAD_WRITE,
                RST_PULSE: soft_reset_state = 1'b1;
                default:   soft_reset_state = 1'b0;
            endcase
        end
    endfunction

    // Registro de estado (memoria). 'rst_i' acá es el reset FISICO de la
    // placa (o el testbench), nunca 'core_soft_reset_o' -- la FSM de la
    // Debug Unit tiene que seguir sabiendo en qué estado de carga está
    // incluso mientras ella misma sostiene el soft-reset del core.
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg         <= RECV_CMD;
            load_target_reg   <= 1'b0;
            word_count_reg    <= 16'b0;
            load_addr_reg     <= 32'b0;
            word_acc_reg      <= 32'b0;
            core_soft_reset_o <= 1'b0;
        end
        else begin
            state_reg         <= state_next;
            load_target_reg   <= load_target_next;
            word_count_reg    <= word_count_next;
            load_addr_reg     <= load_addr_next;
            word_acc_reg      <= word_acc_next;
            // Registrado (ver header): vale 1 exactamente mientras
            // state_reg está en un estado de soft-reset, sin glitches.
            core_soft_reset_o <= soft_reset_state(state_next);
        end
    end

    // Lógica de próximo estado y de salidas
    always @(*) begin
        // Defaults (FSM segura, sin latches)
        state_next        = state_reg;
        load_target_next  = load_target_reg;
        word_count_next   = word_count_reg;
        load_addr_next    = load_addr_reg;
        word_acc_next      = word_acc_reg;

        rd_o               = 1'b0;
        imem_load_en_o     = 1'b0;
        imem_load_addr_o   = load_addr_reg;
        imem_load_data_o   = word_acc_reg;
        imem_load_clear_o  = 1'b0;
        dmem_load_en_o     = 1'b0;
        dmem_load_addr_o   = load_addr_reg;
        dmem_load_data_o   = word_acc_reg;
        dmem_load_clear_o  = 1'b0;
        core_stall_o       = 1'b1; // por defecto frenado; sólo se libera en RUN_EXEC/STEP_EXEC
        dump_trigger_o     = 1'b0;

        case (state_reg)
            RECV_CMD: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    case (r_data_i)
                        CMD_LOAD_PROG: begin
                            load_target_next = 1'b0;
                            state_next        = LOAD_CLEAR;
                        end
                        CMD_LOAD_DATA: begin
                            load_target_next = 1'b1;
                            state_next        = LOAD_CLEAR;
                        end
                        CMD_RUN:   state_next = RUN_EXEC;
                        CMD_STEP:  state_next = STEP_EXEC;
                        CMD_DUMP:  state_next = DUMP_TRIG;
                        CMD_RESET: state_next = RST_PULSE;
                        default:   state_next = RECV_CMD; // comando desconocido: se descarta
                    endcase
                end
            end

            // Limpia la memoria destino completa (no sólo lo que se va a
            // escribir) y sostiene el soft-reset del core mientras dure
            // toda la carga (soft_reset_state() incluye todos los LOAD_*)
            // -- ver tp3/docs/debug_protocol.md. El pulso de
            // clear dispara un barrido de varios ciclos dentro de
            // imem.v/dmem.v (una dirección por ciclo, ver esos archivos);
            // LOAD_CLEAR_WAIT espera a que termine antes de recibir el
            // tamaño del programa, para no empezar a escribirlo mientras
            // el barrido todavía está limpiando direcciones.
            LOAD_CLEAR: begin
                imem_load_clear_o = ~load_target_reg;
                dmem_load_clear_o = load_target_reg;
                load_addr_next     = 32'b0;
                state_next          = LOAD_CLEAR_WAIT;
            end

            LOAD_CLEAR_WAIT: begin
                if (~(load_target_reg ? dmem_clear_busy_i : imem_clear_busy_i))
                    state_next = LOAD_SZ_LO;
            end

            LOAD_SZ_LO: begin
                if (~rx_empty_i) begin
                    rd_o             = 1'b1;
                    word_count_next  = {word_count_reg[15:8], r_data_i};
                    state_next        = LOAD_SZ_HI;
                end
            end

            LOAD_SZ_HI: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_count_next = {r_data_i, word_count_reg[7:0]};
                    state_next = (word_count_next == 16'd0) ? RECV_CMD : LOAD_B0;
                end
            end

            LOAD_B0: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:8], r_data_i};
                    state_next = LOAD_B1;
                end
            end

            LOAD_B1: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:16], r_data_i, word_acc_reg[7:0]};
                    state_next = LOAD_B2;
                end
            end

            LOAD_B2: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:24], r_data_i, word_acc_reg[15:0]};
                    state_next = LOAD_B3;
                end
            end

            LOAD_B3: begin
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {r_data_i, word_acc_reg[23:0]};
                    state_next = LOAD_WRITE;
                end
            end

            LOAD_WRITE: begin
                imem_load_en_o    = ~load_target_reg;
                imem_load_addr_o  = load_addr_reg;
                imem_load_data_o  = word_acc_reg;
                dmem_load_en_o    = load_target_reg;
                dmem_load_addr_o  = load_addr_reg;
                dmem_load_data_o  = word_acc_reg;
                load_addr_next     = load_addr_reg + 32'd4;
                word_count_next    = word_count_reg - 16'd1;
                state_next          = (word_count_reg == 16'd1) ? RECV_CMD : LOAD_B0;
            end

            RUN_EXEC: begin
                // Con el HALT ya en WB el core no avanza ni un ciclo más:
                // CYCLE_COUNT queda exactamente en el ciclo en que terminó.
                core_stall_o = core_halted_i;
                if (core_halted_i) begin
                    state_next = DUMP_TRIG;
                end
                else if (~rx_empty_i) begin
                    // Pausa (ver header): el byte se consume y se descarta.
                    // Si coincide con el HALT, gana el HALT y el byte queda
                    // para RECV_CMD, que lo descarta como desconocido.
                    rd_o       = 1'b1;
                    state_next = DUMP_TRIG;
                end
            end

            STEP_EXEC: begin
                // Se libera exactamente 1 ciclo, salvo que el core ya esté
                // detenido: ahí el STEP es un no-op real (sólo vuelca).
                core_stall_o = core_halted_i;
                state_next    = DUMP_TRIG;
            end

            DUMP_TRIG: begin
                dump_trigger_o = 1'b1;
                state_next      = DUMP_WAIT;
            end

            DUMP_WAIT: begin
                if (dump_done_i) state_next = RECV_CMD;
            end

            RST_PULSE: begin
                state_next = RECV_CMD; // el pulso lo da soft_reset_state()
            end

            default: state_next = RECV_CMD;
        endcase
    end

endmodule
