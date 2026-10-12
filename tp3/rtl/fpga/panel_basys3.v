// =============================================================================
// Módulo:         panel_basys3
//
// Descripción:
// Panel de la placa: muestra en el display de 7 segmentos y en los 16 LEDs
// lo que está pasando DENTRO de la FPGA, al mismo tiempo que la GUI. Sólo
// observa: ninguna de sus salidas vuelve al núcleo ni a la Debug Unit, así
// que no puede alterar la ejecución.
//
// Display (4 dígitos, por prioridad):
//   - Al salir del reset físico: "rISC-5" entra por la derecha y sale por
//     la izquierda (una pasada; un comando la interrumpe).
//   - Carga de programa o datos (soft-reset largo): "LoAd". CMD_RESET
//     (soft-reset de 1 ciclo): "rESt". Ambos durante MSG_MS.
//   - CMD_RUN: "rUn" durante RUN_WORD_MS y después una viborita que da
//     vueltas por el borde de los 4 dígitos, hasta que el núcleo se frena.
//   - Terminado por HALT: alterna "HALt" con los ciclos ejecutados.
//   - Run interrumpido por una pausa (CMD_BREAK): "StOP".
//   - Paso a paso y reposo: CYCLE_COUNT en decimal. Si pasa de 9999 se ven
//     las últimas 4 cifras y se prende el punto del dígito izquierdo.
//
// LEDs: espejo de los riesgos del ciclo actual, con las mismas reglas que
// usa la GUI para dibujarlos (tp3/host/riscv_pipeview.py). En paso a paso el
// núcleo queda congelado entre comandos, así que muestran exactamente el
// ciclo que dibuja la GUI.
//   led[15] HALT llegó a WB          led[14] stall por riesgo de datos
//   led[13] salto tomado (flush)
//   led[11:9] rs1 del comparador de ID <- {EX, EX/MEM, MEM/WB}
//   led[8:6]  rs2 del comparador de ID <- {EX, EX/MEM, MEM/WB}
//   led[4:3]  rs1 de la ALU (EX)       <- {EX/MEM, MEM/WB}
//   led[2:1]  rs2 de la ALU (EX)       <- {EX/MEM, MEM/WB}
//   led[12], led[5], led[0] apagados (separadores).
// Una flecha de forwarding sólo se muestra si la instrucción usa de verdad
// ese registro: las instrucciones de ID y de EX se decodifican con la misma
// control_unit del núcleo (uses_rs1/uses_rs2, is_branch, is_jalr, is_halt).
//
// El clock no se toca: el refresco del display, las animaciones y los
// temporizadores salen de un contador que genera un pulso de habilitación
// ('tick', cada 1 ms) con el mismo clock del diseño. Todas las entradas se
// registran al entrar, así el panel le agrega una sola carga a cada señal
// del núcleo (algunas, como branch_taken, están en el camino crítico).
// =============================================================================
module panel_basys3 #(
    parameter CLK_FREQ        = 65_000_000,
    parameter TICK_HZ         = 1000,   // base de tiempo del panel: 1 ms
    parameter MSG_MS          = 1000,   // LoAd / rESt
    parameter RUN_WORD_MS     = 1000,   // "rUn" antes de la viborita
    parameter HALT_ALT_MS     = 1000,   // alternancia HALt <-> ciclos
    parameter SNAKE_STEP_MS   = 70,     // velocidad de la viborita
    parameter MARQUEE_STEP_MS = 280     // velocidad de la marquesina
)(
    input  wire        clk_i,
    input  wire        rst_i,             // reset físico, ya sincronizado

    // --- Lo que se observa del núcleo y de la Debug Unit ---
    input  wire        core_stall_i,      // 1 = núcleo congelado por la Debug Unit
    input  wire        core_halted_i,     // HALT en WB
    input  wire        core_soft_reset_i, // carga de programa/datos o CMD_RESET
    input  wire        hazard_stall_i,
    input  wire        branch_taken_i,
    input  wire [7:0]  fwd_sel_i,         // {b_id, a_id, b_ex, a_ex}
    input  wire [31:0] if_id_instr_i,     // instrucción en ID
    input  wire [31:0] id_ex_instr_i,     // instrucción en EX
    input  wire [31:0] cycle_count_i,

    // --- Placa (display de ánodo común: todo activo en bajo) ---
    output reg  [6:0]  seg_o,             // seg_o[0] = a ... seg_o[6] = g
    output reg         dp_o,
    output reg  [3:0]  an_o,              // an_o[0] = dígito de la derecha
    output reg  [15:0] led_o
);

    // =========================================================================
    // Entradas registradas
    // =========================================================================
    reg        r_stall, r_halted, r_soft, r_hz, r_br;
    reg [7:0]  r_fwd;
    reg [31:0] r_id_instr, r_ex_instr, r_cycles;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            r_stall <= 1'b1; r_halted <= 1'b0; r_soft <= 1'b0;
            r_hz <= 1'b0; r_br <= 1'b0; r_fwd <= 8'b0;
            r_id_instr <= 32'b0; r_ex_instr <= 32'b0; r_cycles <= 32'b0;
        end
        else begin
            r_stall <= core_stall_i;   r_halted <= core_halted_i;
            r_soft  <= core_soft_reset_i;
            r_hz    <= hazard_stall_i; r_br <= branch_taken_i; r_fwd <= fwd_sel_i;
            r_id_instr <= if_id_instr_i; r_ex_instr <= id_ex_instr_i;
            r_cycles   <= cycle_count_i;
        end
    end

    // =========================================================================
    // LEDs: espejo de los riesgos (mismas reglas que riscv_pipeview.py)
    // =========================================================================
    wire id_branch, id_jalr, id_uses1, id_uses2;
    wire ex_branch, ex_jalr, ex_halt, ex_uses1, ex_uses2;

    control_unit u_dec_id (
        .opcode_i(r_id_instr[6:0]), .funct3_i(r_id_instr[14:12]), .funct7_i(r_id_instr[31:25]),
        .reg_write_o(), .alu_src_a_o(), .alu_src_b_o(), .alu_op_o(), .mem_read_o(),
        .mem_write_o(), .mem_to_reg_o(), .is_jal_o(), .is_jalr_o(id_jalr),
        .is_branch_o(id_branch), .is_halt_o(), .imm_sel_o(),
        .uses_rs1_o(id_uses1), .uses_rs2_o(id_uses2)
    );

    control_unit u_dec_ex (
        .opcode_i(r_ex_instr[6:0]), .funct3_i(r_ex_instr[14:12]), .funct7_i(r_ex_instr[31:25]),
        .reg_write_o(), .alu_src_a_o(), .alu_src_b_o(), .alu_op_o(), .mem_read_o(),
        .mem_write_o(), .mem_to_reg_o(), .is_jal_o(), .is_jalr_o(ex_jalr),
        .is_branch_o(ex_branch), .is_halt_o(ex_halt), .imm_sel_o(),
        .uses_rs1_o(ex_uses1), .uses_rs2_o(ex_uses2)
    );

    wire [1:0] a_ex = r_fwd[1:0], b_ex = r_fwd[3:2], a_id = r_fwd[5:4], b_id = r_fwd[7:6];
    // Hacia la ALU: la instrucción en EX es válida (no HALT ni fuera del
    // subset), no es un salto (esos ya se resolvieron en ID) y usa el registro.
    wire ex_ok = ~ex_halt & ~ex_branch & ~ex_jalr;
    // Hacia el comparador de ID: sólo beq/bne/jalr, y no durante un stall
    // (con el dato todavía viejo, la selección no tiene efecto).
    wire id_ok = (id_branch | id_jalr) & ~r_hz;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) led_o <= 16'b0;
        else begin
            led_o[15] <= r_halted;
            led_o[14] <= r_hz;
            led_o[13] <= r_br & ~r_hz;
            led_o[12] <= 1'b0;
            led_o[11] <= id_ok & id_uses1 & (a_id == 2'd1);
            led_o[10] <= id_ok & id_uses1 & (a_id == 2'd2);
            led_o[9]  <= id_ok & id_uses1 & (a_id == 2'd3);
            led_o[8]  <= id_ok & id_uses2 & (b_id == 2'd1);
            led_o[7]  <= id_ok & id_uses2 & (b_id == 2'd2);
            led_o[6]  <= id_ok & id_uses2 & (b_id == 2'd3);
            led_o[5]  <= 1'b0;
            led_o[4]  <= ex_ok & ex_uses1 & (a_ex == 2'd1);
            led_o[3]  <= ex_ok & ex_uses1 & (a_ex == 2'd2);
            led_o[2]  <= ex_ok & ex_uses2 & (b_ex == 2'd1);
            led_o[1]  <= ex_ok & ex_uses2 & (b_ex == 2'd2);
            led_o[0]  <= 1'b0;
        end
    end

    // =========================================================================
    // Base de tiempo: un pulso 'tick' por milisegundo (enable, no un clock)
    // =========================================================================
    localparam integer TICK_DIV = CLK_FREQ / TICK_HZ;
    localparam integer TICK_W   = (TICK_DIV > 1) ? $clog2(TICK_DIV) : 1;
    reg [TICK_W-1:0] tick_cnt;
    reg              tick;
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            tick_cnt <= {TICK_W{1'b0}};
            tick     <= 1'b0;
        end
        else if (tick_cnt == TICK_DIV - 1) begin
            tick_cnt <= {TICK_W{1'b0}};
            tick     <= 1'b1;
        end
        else begin
            tick_cnt <= tick_cnt + 1'b1;
            tick     <= 1'b0;
        end
    end

    // =========================================================================
    // CYCLE_COUNT a decimal: double dabble secuencial, 33 ciclos por
    // conversión, se repite todo el tiempo (10 cifras: hasta 4294967295)
    // =========================================================================
    reg  [71:0] dd_reg;      // {40 bits BCD, 32 bits binario}
    reg  [5:0]  dd_cnt;
    reg  [39:0] bcd;         // resultado de la última conversión completa

    function [39:0] add3;    // suma 3 a cada cifra >= 5 (paso del double dabble)
        input [39:0] b;
        integer k;
        begin
            for (k = 0; k < 10; k = k + 1)
                add3[4*k +: 4] = (b[4*k +: 4] >= 4'd5) ? b[4*k +: 4] + 4'd3 : b[4*k +: 4];
        end
    endfunction

    wire [71:0] dd_next = {add3(dd_reg[71:32]), dd_reg[31:0]} << 1;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            dd_reg <= 72'b0;
            dd_cnt <= 6'd0;
            bcd    <= 40'b0;
        end
        else if (dd_cnt == 6'd0) begin
            dd_reg <= {40'b0, r_cycles};
            dd_cnt <= 6'd32;
        end
        else begin
            dd_reg <= dd_next;
            dd_cnt <= dd_cnt - 1'b1;
            if (dd_cnt == 6'd1) bcd <= dd_next[71:32];
        end
    end

    // =========================================================================
    // Qué muestra el display: modo según lo que hace el núcleo
    // =========================================================================
    localparam [2:0] M_GREET = 3'd0, M_MSG = 3'd1, M_RUN = 3'd2,
                     M_HALT  = 3'd3, M_STOP = 3'd4, M_IDLE = 3'd5;

    reg [2:0]  mode;
    reg        msg_reset;     // en M_MSG: 1 = "rESt", 0 = "LoAd"
    reg [7:0]  soft_len;      // ciclos seguidos de soft-reset (satura)
    reg        en_prev;       // el núcleo avanzó en el ciclo anterior
    reg [15:0] ms_timer;      // ms desde que se entró al modo actual
    reg        halt_phase;    // alternancia HALt / ciclos
    reg [15:0] alt_timer;
    reg [3:0]  snake_pos;     // 0..11, posición de la cabeza en el borde
    reg [15:0] snake_timer;
    reg [3:0]  mq_pos;        // marquesina: primer carácter visible
    reg [15:0] mq_timer;

    wire core_en  = ~r_stall;
    localparam [3:0] MQ_LAST = 4'd10;   // texto de 14 caracteres -> 11 posiciones
    wire mq_done = (mode == M_GREET) && tick && (mq_pos == MQ_LAST) &&
                   (mq_timer == MARQUEE_STEP_MS - 1);

    // Modo: lo deciden los eventos del núcleo y de la Debug Unit
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            mode <= M_GREET; msg_reset <= 1'b0; soft_len <= 8'd0; en_prev <= 1'b0;
            ms_timer <= 16'd0;
        end
        else begin
            en_prev <= core_en;
            if (tick && ms_timer != 16'hFFFF) ms_timer <= ms_timer + 1'b1;

            if (r_soft) begin
                // Carga o CMD_RESET en curso: un soft-reset de más de 8 ciclos
                // sólo puede ser una carga (el de CMD_RESET dura 1 ciclo).
                if (soft_len != 8'hFF) soft_len <= soft_len + 1'b1;
                if (soft_len > 8'd8) begin
                    mode <= M_MSG; msg_reset <= 1'b0; ms_timer <= 16'd0;
                end
            end
            else if (soft_len != 8'd0) begin
                // Terminó el soft-reset: se decide el mensaje por su duración.
                soft_len  <= 8'd0;
                mode      <= M_MSG;
                msg_reset <= (soft_len <= 8'd8);
                ms_timer  <= 16'd0;
            end
            else if (core_en && en_prev) begin
                // Dos ciclos seguidos avanzando: es un CMD_RUN (un CMD_STEP
                // libera el núcleo exactamente un ciclo).
                if (mode != M_RUN) begin
                    mode <= M_RUN; ms_timer <= 16'd0;
                end
            end
            else if (!core_en && en_prev) begin
                // El núcleo se acaba de frenar.
                if (r_halted)            mode <= M_HALT;
                else if (mode == M_RUN)  mode <= M_STOP;   // pausa de un Run
                else                     mode <= M_IDLE;   // fin de un Step
            end
            else if (mq_done)
                mode <= M_IDLE;
            else if (mode == M_MSG && ms_timer >= MSG_MS)
                mode <= r_halted ? M_HALT : M_IDLE;
        end
    end

    // Animaciones: avanzan con 'tick' mientras dura su modo, y arrancan de
    // cero cada vez que se entra a él.
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            halt_phase <= 1'b0; alt_timer <= 16'd0;
            snake_pos <= 4'd0; snake_timer <= 16'd0; mq_pos <= 4'd0; mq_timer <= 16'd0;
        end
        else begin
            if (mode != M_RUN) begin
                snake_pos <= 4'd0; snake_timer <= 16'd0;
            end
            else if (tick) begin
                if (snake_timer == SNAKE_STEP_MS - 1) begin
                    snake_timer <= 16'd0;
                    snake_pos   <= (snake_pos == 4'd11) ? 4'd0 : snake_pos + 1'b1;
                end
                else snake_timer <= snake_timer + 1'b1;
            end

            if (mode != M_HALT) begin
                halt_phase <= 1'b0; alt_timer <= 16'd0;
            end
            else if (tick) begin
                if (alt_timer == HALT_ALT_MS - 1) begin
                    alt_timer  <= 16'd0;
                    halt_phase <= ~halt_phase;
                end
                else alt_timer <= alt_timer + 1'b1;
            end

            if (mode == M_GREET && tick) begin
                if (mq_timer == MARQUEE_STEP_MS - 1) begin
                    mq_timer <= 16'd0;
                    if (mq_pos != MQ_LAST) mq_pos <= mq_pos + 1'b1;
                end
                else mq_timer <= mq_timer + 1'b1;
            end
        end
    end

    // =========================================================================
    // Contenido de los 4 dígitos (patrones a..g, activos en ALTO; se
    // invierten recién a la salida)
    // =========================================================================
    localparam [6:0] S_BLANK = 7'h00, S_DASH = 7'h40,
                     S_A = 7'h77, S_C = 7'h39, S_D = 7'h5E, S_E = 7'h79, S_H = 7'h76,
                     S_I = 7'h30, S_L = 7'h38, S_N = 7'h54, S_O = 7'h3F, S_LO = 7'h5C,
                     S_P = 7'h73, S_R = 7'h50, S_S = 7'h6D, S_T = 7'h78, S_U = 7'h3E,
                     S_5 = 7'h6D;

    function [6:0] digit7;
        input [3:0] d;
        case (d)
            4'd0: digit7 = 7'h3F; 4'd1: digit7 = 7'h06; 4'd2: digit7 = 7'h5B;
            4'd3: digit7 = 7'h4F; 4'd4: digit7 = 7'h66; 4'd5: digit7 = 7'h6D;
            4'd6: digit7 = 7'h7D; 4'd7: digit7 = 7'h07; 4'd8: digit7 = 7'h7F;
            4'd9: digit7 = 7'h6F; default: digit7 = 7'h00;
        endcase
    endfunction

    // Marquesina: "    rISC-5    " (14 caracteres), ventana de 4 desde mq_pos
    function [6:0] mq_char;
        input [3:0] i;
        case (i)
            4'd4: mq_char = S_R;    4'd5: mq_char = S_I;  4'd6: mq_char = S_S;
            4'd7: mq_char = S_C;    4'd8: mq_char = S_DASH;
            4'd9: mq_char = S_5;    default: mq_char = S_BLANK;
        endcase
    endfunction

    // Viborita: 12 posiciones alrededor del borde. 0..3 = segmento a de los
    // dígitos 3..0 (arriba, de izquierda a derecha), 4/5 = b/c del dígito 0,
    // 6..9 = segmento d de los dígitos 0..3 (abajo, de derecha a izquierda),
    // 10/11 = e/f del dígito 3. Se prenden la cabeza y dos segmentos de cola.
    function snake_on;
        input [3:0] p;          // posición a evaluar
        input [3:0] head;
        reg   [4:0] diff;
        begin
            diff     = {1'b0, head} + 5'd12 - {1'b0, p};
            if (diff >= 5'd12) diff = diff - 5'd12;
            snake_on = (diff <= 5'd2);
        end
    endfunction

    reg [6:0] dig [0:3];   // dig[3] = dígito izquierdo ... dig[0] = derecho
    reg       dot3;        // punto del dígito izquierdo (más de 4 cifras)
    integer   n;
    reg       over;
    always @(*) begin
        over = (bcd[39:16] != 24'b0);
        dot3 = 1'b0;
        for (n = 0; n < 4; n = n + 1) dig[n] = S_BLANK;
        case (mode)
            M_GREET: begin
                dig[3] = mq_char(mq_pos);       dig[2] = mq_char(mq_pos + 4'd1);
                dig[1] = mq_char(mq_pos + 4'd2); dig[0] = mq_char(mq_pos + 4'd3);
            end
            M_MSG: begin
                if (msg_reset) begin dig[3] = S_R; dig[2] = S_E;  dig[1] = S_S; dig[0] = S_T; end
                else           begin dig[3] = S_L; dig[2] = S_LO; dig[1] = S_A; dig[0] = S_D; end
            end
            M_RUN: begin
                if (ms_timer < RUN_WORD_MS) begin
                    dig[2] = S_R; dig[1] = S_U; dig[0] = S_N;
                end
                else begin
                    dig[3][0] = snake_on(4'd0, snake_pos);  dig[2][0] = snake_on(4'd1, snake_pos);
                    dig[1][0] = snake_on(4'd2, snake_pos);  dig[0][0] = snake_on(4'd3, snake_pos);
                    dig[0][1] = snake_on(4'd4, snake_pos);  dig[0][2] = snake_on(4'd5, snake_pos);
                    dig[0][3] = snake_on(4'd6, snake_pos);  dig[1][3] = snake_on(4'd7, snake_pos);
                    dig[2][3] = snake_on(4'd8, snake_pos);  dig[3][3] = snake_on(4'd9, snake_pos);
                    dig[3][4] = snake_on(4'd10, snake_pos); dig[3][5] = snake_on(4'd11, snake_pos);
                end
            end
            M_STOP: begin
                dig[3] = S_S; dig[2] = S_T; dig[1] = S_O; dig[0] = S_P;
            end
            default: begin   // M_IDLE, y M_HALT en la fase de ciclos
                if (mode == M_HALT && !halt_phase) begin
                    dig[3] = S_H; dig[2] = S_A; dig[1] = S_L; dig[0] = S_T;
                end
                else begin
                    // Últimas 4 cifras; ceros a la izquierda en blanco salvo
                    // que haya más cifras (ahí se prende el punto izquierdo).
                    dig[0] = digit7(bcd[3:0]);
                    dig[1] = (over || bcd[15:4]  != 12'b0) ? digit7(bcd[7:4])   : S_BLANK;
                    dig[2] = (over || bcd[15:8]  != 8'b0)  ? digit7(bcd[11:8])  : S_BLANK;
                    dig[3] = (over || bcd[15:12] != 4'b0)  ? digit7(bcd[15:12]) : S_BLANK;
                    dot3   = over;
                end
            end
        endcase
    end

    // =========================================================================
    // Multiplexado del display: un dígito por ms (refresco de 250 Hz)
    // =========================================================================
    reg [1:0] scan;
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            scan  <= 2'd0;
            seg_o <= 7'h7F;
            dp_o  <= 1'b1;
            an_o  <= 4'hF;
        end
        else begin
            if (tick) scan <= scan + 1'b1;
            seg_o <= ~dig[scan];
            dp_o  <= ~(dot3 && scan == 2'd3);
            an_o  <= ~(4'b0001 << scan);
        end
    end

endmodule
