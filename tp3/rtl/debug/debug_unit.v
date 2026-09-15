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
// comandos): sólo se libera durante CMD_RUN (hasta halt) y CMD_STEP
// (exactamente 1 ciclo).
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

    // Registro de estado (memoria). 'rst_i' acá es el reset FISICO de la
    // placa (o el testbench), nunca 'core_soft_reset_o' -- la FSM de la
    // Debug Unit tiene que seguir sabiendo en qué estado de carga está
    // incluso mientras ella misma sostiene el soft-reset del core.
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg       <= RECV_CMD;
            load_target_reg <= 1'b0;
            word_count_reg  <= 16'b0;
            load_addr_reg   <= 32'b0;
            word_acc_reg    <= 32'b0;
        end
        else begin
            state_reg       <= state_next;
            load_target_reg <= load_target_next;
            word_count_reg  <= word_count_next;
            load_addr_reg   <= load_addr_next;
            word_acc_reg    <= word_acc_next;
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
        core_soft_reset_o  = 1'b0;
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
            // toda la carga -- ver tp3/docs/debug_protocol.md. El pulso de
            // clear dispara un barrido de varios ciclos dentro de
            // imem.v/dmem.v (una dirección por ciclo, ver esos archivos);
            // LOAD_CLEAR_WAIT espera a que termine antes de recibir el
            // tamaño del programa, para no empezar a escribirlo mientras
            // el barrido todavía está limpiando direcciones.
            LOAD_CLEAR: begin
                core_soft_reset_o = 1'b1;
                imem_load_clear_o = ~load_target_reg;
                dmem_load_clear_o = load_target_reg;
                load_addr_next     = 32'b0;
                state_next          = LOAD_CLEAR_WAIT;
            end

            LOAD_CLEAR_WAIT: begin
                core_soft_reset_o = 1'b1;
                if (~(load_target_reg ? dmem_clear_busy_i : imem_clear_busy_i))
                    state_next = LOAD_SZ_LO;
            end

            LOAD_SZ_LO: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o             = 1'b1;
                    word_count_next  = {word_count_reg[15:8], r_data_i};
                    state_next        = LOAD_SZ_HI;
                end
            end

            LOAD_SZ_HI: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_count_next = {r_data_i, word_count_reg[7:0]};
                    state_next = (word_count_next == 16'd0) ? RECV_CMD : LOAD_B0;
                end
            end

            LOAD_B0: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:8], r_data_i};
                    state_next = LOAD_B1;
                end
            end

            LOAD_B1: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:16], r_data_i, word_acc_reg[7:0]};
                    state_next = LOAD_B2;
                end
            end

            LOAD_B2: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {word_acc_reg[31:24], r_data_i, word_acc_reg[15:0]};
                    state_next = LOAD_B3;
                end
            end

            LOAD_B3: begin
                core_soft_reset_o = 1'b1;
                if (~rx_empty_i) begin
                    rd_o = 1'b1;
                    word_acc_next = {r_data_i, word_acc_reg[23:0]};
                    state_next = LOAD_WRITE;
                end
            end

            LOAD_WRITE: begin
                core_soft_reset_o = 1'b1;
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
                core_stall_o = 1'b0;
                if (core_halted_i) state_next = DUMP_TRIG;
            end

            STEP_EXEC: begin
                core_stall_o = 1'b0; // se libera exactamente 1 ciclo
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
                core_soft_reset_o = 1'b1;
                state_next          = RECV_CMD;
            end

            default: state_next = RECV_CMD;
        endcase
    end

endmodule
