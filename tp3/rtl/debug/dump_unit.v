// =============================================================================
// Módulo:         dump_unit
//
// Descripción:
// Serializa el snapshot completo de estado del core (registros, los 4
// latches de pipeline, status, ciclos, y toda la memoria de datos) hacia
// el lado Tx del Interface Circuit (uart_interface.v de TP2), palabra de
// 32 bits a palabra, cada una en 4 bytes little-endian. Formato exacto
// (qué índice de palabra es cada campo) documentado en
// tp3/docs/debug_protocol.md -- este archivo es la implementación fiel de
// esa spec.
//
// El handshake byte a byte con la UART es el mismo de dos pasos que ya
// usaba tp2/rtl/alu_link.v: sostener 'wr_o' hasta VER 'tx_full_i' en alto
// (confirma que uart_interface aceptó el byte) y esperar a que vuelva a
// bajar (confirma que se transmitió de verdad) antes de mandar el
// siguiente.
//
// Para las palabras 53 en adelante (memoria de datos), el valor no está
// en un puerto directo sino detrás de un mux+memoria externa
// (dmem_dbg_addr_o -> riscv_core.v -> dmem.v -> dmem_dbg_rdata_i,
// combinacional de punta a punta): por eso hay un estado 'PREP_WORD'
// dedicado, separado de 'SEND_BYTE', que le da un ciclo entero de reloj a
// esa cadena para asentarse antes de capturar el valor en
// 'current_word_reg'. Para las palabras fijas (campos directos del core)
// ese ciclo extra no hace falta, pero se aplica igual a todas por
// uniformidad -- el costo (unos pocos microsegundos en todo el volcado) es
// insignificante comparado con el tiempo real de transmisión UART.
// =============================================================================
module dump_unit #(
    parameter DMEM_DEPTH_WORDS = 256
)(
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire        dump_trigger_i,
    output reg          dump_done_o,

    // --- Status / ciclos ---
    input  wire        core_halted_i,
    input  wire        branch_taken_i,
    input  wire        pc_write_en_i,
    input  wire [31:0] cycle_count_i,

    // --- Latch IF/ID ---
    input  wire [31:0] if_id_pc_i,
    input  wire [31:0] if_id_instr_i,

    // --- Latch ID/EX ---
    input  wire [31:0] id_ex_pc_i,
    input  wire [31:0] id_ex_instr_i,
    input  wire [31:0] id_ex_rs1_data_i,
    input  wire [31:0] id_ex_rs2_data_i,
    input  wire [31:0] id_ex_imm_i,
    input  wire        id_ex_reg_write_i,
    input  wire        id_ex_mem_read_i,
    input  wire        id_ex_mem_write_i,
    input  wire        id_ex_mem_to_reg_i,
    input  wire        id_ex_is_jal_i,
    input  wire        id_ex_is_jalr_i,
    input  wire        id_ex_is_halt_i,

    // --- Latch EX/MEM ---
    input  wire [31:0] ex_mem_pc_i,
    input  wire [31:0] ex_mem_instr_i,
    input  wire [31:0] ex_mem_ex_result_i,
    input  wire [31:0] ex_mem_rs2_data_i,
    input  wire        ex_mem_reg_write_i,
    input  wire        ex_mem_mem_read_i,
    input  wire        ex_mem_mem_write_i,
    input  wire        ex_mem_mem_to_reg_i,
    input  wire        ex_mem_is_halt_i,

    // --- Latch MEM/WB ---
    input  wire [31:0] mem_wb_pc_i,
    input  wire [31:0] mem_wb_instr_i,
    input  wire [31:0] mem_wb_result_i,
    input  wire [31:0] mem_wb_mem_read_data_i,
    input  wire        mem_wb_reg_write_i,
    input  wire        mem_wb_mem_to_reg_i,
    input  wire        mem_wb_is_halt_i,

    // --- Banco de registros completo ---
    input  wire [32*32-1:0] regs_flat_i,

    // --- Lectura de debug de dmem (ver riscv_core.v / dmem.v) ---
    output reg  [31:0] dmem_dbg_addr_o,
    input  wire [31:0] dmem_dbg_rdata_i,

    // --- Lado Tx del Interface Circuit ---
    output reg  [7:0]  w_data_o,
    input  wire        tx_full_i,
    output reg          wr_o
);

    localparam [31:0] SYNC_WORD    = 32'hAA55AA55;
    localparam        FIXED_WORDS  = 53;
    localparam        TOTAL_WORDS  = FIXED_WORDS + DMEM_DEPTH_WORDS;
    localparam         IDX_BITS     = $clog2(TOTAL_WORDS);

    localparam [2:0]
        IDLE       = 3'd0,
        PREP_WORD  = 3'd1,
        SEND_BYTE  = 3'd2,
        WAIT_SENT  = 3'd3,
        DONE       = 3'd4;

    reg [2:0]           state_reg, state_next;
    reg [IDX_BITS-1:0]  word_idx_reg, word_idx_next;
    reg [1:0]           byte_idx_reg, byte_idx_next;
    reg [31:0]          current_word_reg, current_word_next;

    // Palabra actual segun 'word_idx_reg': campos fijos (0..52) leen
    // directo de los puertos del core; de ahi en más (53..) es
    // 'dmem_dbg_rdata_i', ya direccionado por 'dmem_dbg_addr_o' (ver
    // abajo) durante todo el ciclo de PREP_WORD.
    reg [31:0] word_value;
    always @(*) begin
        case (word_idx_reg)
            0:  word_value = SYNC_WORD;
            1:  word_value = {29'b0, ~pc_write_en_i, branch_taken_i, core_halted_i};
            2:  word_value = cycle_count_i;
            3:  word_value = if_id_pc_i;
            4:  word_value = if_id_instr_i;
            5:  word_value = id_ex_pc_i;
            6:  word_value = id_ex_instr_i;
            7:  word_value = id_ex_rs1_data_i;
            8:  word_value = id_ex_rs2_data_i;
            9:  word_value = id_ex_imm_i;
            10: word_value = {25'b0, id_ex_is_halt_i, id_ex_is_jalr_i, id_ex_is_jal_i,
                               id_ex_mem_to_reg_i, id_ex_mem_write_i, id_ex_mem_read_i, id_ex_reg_write_i};
            11: word_value = ex_mem_pc_i;
            12: word_value = ex_mem_instr_i;
            13: word_value = ex_mem_ex_result_i;
            14: word_value = ex_mem_rs2_data_i;
            15: word_value = {27'b0, ex_mem_is_halt_i,
                               ex_mem_mem_to_reg_i, ex_mem_mem_write_i, ex_mem_mem_read_i, ex_mem_reg_write_i};
            16: word_value = mem_wb_pc_i;
            17: word_value = mem_wb_instr_i;
            18: word_value = mem_wb_result_i;
            19: word_value = mem_wb_mem_read_data_i;
            20: word_value = {29'b0, mem_wb_is_halt_i, mem_wb_mem_to_reg_i, mem_wb_reg_write_i};
            21: word_value = regs_flat_i[32*0  +: 32];
            22: word_value = regs_flat_i[32*1  +: 32];
            23: word_value = regs_flat_i[32*2  +: 32];
            24: word_value = regs_flat_i[32*3  +: 32];
            25: word_value = regs_flat_i[32*4  +: 32];
            26: word_value = regs_flat_i[32*5  +: 32];
            27: word_value = regs_flat_i[32*6  +: 32];
            28: word_value = regs_flat_i[32*7  +: 32];
            29: word_value = regs_flat_i[32*8  +: 32];
            30: word_value = regs_flat_i[32*9  +: 32];
            31: word_value = regs_flat_i[32*10 +: 32];
            32: word_value = regs_flat_i[32*11 +: 32];
            33: word_value = regs_flat_i[32*12 +: 32];
            34: word_value = regs_flat_i[32*13 +: 32];
            35: word_value = regs_flat_i[32*14 +: 32];
            36: word_value = regs_flat_i[32*15 +: 32];
            37: word_value = regs_flat_i[32*16 +: 32];
            38: word_value = regs_flat_i[32*17 +: 32];
            39: word_value = regs_flat_i[32*18 +: 32];
            40: word_value = regs_flat_i[32*19 +: 32];
            41: word_value = regs_flat_i[32*20 +: 32];
            42: word_value = regs_flat_i[32*21 +: 32];
            43: word_value = regs_flat_i[32*22 +: 32];
            44: word_value = regs_flat_i[32*23 +: 32];
            45: word_value = regs_flat_i[32*24 +: 32];
            46: word_value = regs_flat_i[32*25 +: 32];
            47: word_value = regs_flat_i[32*26 +: 32];
            48: word_value = regs_flat_i[32*27 +: 32];
            49: word_value = regs_flat_i[32*28 +: 32];
            50: word_value = regs_flat_i[32*29 +: 32];
            51: word_value = regs_flat_i[32*30 +: 32];
            52: word_value = regs_flat_i[32*31 +: 32];
            default: word_value = dmem_dbg_rdata_i; // 53..TOTAL_WORDS-1
        endcase
    end

    // Dirección de debug hacia dmem: sólo importa (y sólo se usa) para
    // word_idx_reg >= FIXED_WORDS, pero se calcula siempre, sin costo.
    always @(*) begin
        if (word_idx_reg >= FIXED_WORDS)
            dmem_dbg_addr_o = (word_idx_reg - FIXED_WORDS) * 4;
        else
            dmem_dbg_addr_o = 32'b0;
    end

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            state_reg        <= IDLE;
            word_idx_reg      <= {IDX_BITS{1'b0}};
            byte_idx_reg      <= 2'b0;
            current_word_reg  <= 32'b0;
        end
        else begin
            state_reg        <= state_next;
            word_idx_reg      <= word_idx_next;
            byte_idx_reg      <= byte_idx_next;
            current_word_reg  <= current_word_next;
        end
    end

    always @(*) begin
        state_next          = state_reg;
        word_idx_next        = word_idx_reg;
        byte_idx_next        = byte_idx_reg;
        current_word_next    = current_word_reg;

        w_data_o             = 8'b0;
        wr_o                 = 1'b0;
        dump_done_o          = 1'b0;

        case (state_reg)
            IDLE: begin
                if (dump_trigger_i) begin
                    word_idx_next = {IDX_BITS{1'b0}};
                    state_next     = PREP_WORD;
                end
            end

            // Un ciclo entero para que 'dmem_dbg_rdata_i' (si aplica) ya
            // refleje 'dmem_dbg_addr_o' de este 'word_idx_reg'.
            PREP_WORD: begin
                current_word_next = word_value;
                byte_idx_next      = 2'b0;
                state_next          = SEND_BYTE;
            end

            SEND_BYTE: begin
                w_data_o = current_word_reg[8*byte_idx_reg +: 8];
                wr_o     = 1'b1; // sostenido hasta confirmar aceptacion
                if (tx_full_i) begin
                    state_next = WAIT_SENT;
                end
            end

            WAIT_SENT: begin
                if (~tx_full_i) begin
                    if (byte_idx_reg == 2'd3) begin
                        if (word_idx_reg == TOTAL_WORDS - 1) begin
                            state_next = DONE;
                        end
                        else begin
                            word_idx_next = word_idx_reg + 1'b1;
                            state_next     = PREP_WORD;
                        end
                    end
                    else begin
                        byte_idx_next = byte_idx_reg + 1'b1;
                        state_next     = SEND_BYTE;
                    end
                end
            end

            DONE: begin
                dump_done_o = 1'b1;
                state_next   = IDLE;
            end

            default: state_next = IDLE;
        endcase
    end

endmodule
