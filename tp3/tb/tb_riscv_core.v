`timescale 1ns / 1ps
`include "riscv_isa_encode.vh"
// =============================================================================
// Módulo:         tb_riscv_core
//
// Descripción:
// Testbench de integración del datapath completo (sin UART todavía, ver
// Fase 2 del plan): arma programas RV32I con los encoders de
// riscv_isa_encode.vh, los carga en imem por el puerto de loader, corre el
// core hasta HALT (explícito o implícito) y verifica el estado final de
// registros/memoria contra lo esperado a mano. Cubre, en orden:
//
//   1) R-type básico   5) Branches (beq/bne, tomados y no tomados)
//   2) I-type aritmético 6) Prioridad de forwarding (EX/MEM > MEM/WB)
//   3) Loads/stores (todos los anchos + signo) 7) Load-use hazard
//   4) LUI + JAL/JALR (valor de enlace + target) 8) Load-antes-de-branch (0-gap y 1-gap)
//                                                  9) HALT explícito e implícito
//  10) Modo paso a paso (global_stall_i): el freeze es una pausa perfecta
//  11) Decodificación completa (blt/mul -> HALT implícito) y load-use sin
//      stalls espurios (CYCLE_COUNT exacto con y sin dependencia real)
//
// Los programas 1-9 se corren de punta a punta hasta HALT (no se
// inspecciona ciclo a ciclo): si el valor final de un registro es el
// esperado, es evidencia de que todo el camino que lo produjo -- decode,
// forwarding, hazards, memoria -- funcionó bien, que es lo que realmente
// importa ahí. El 10 sí compara ciclo a ciclo, porque lo que verifica es
// justamente la equivalencia ciclo a ciclo entre correr y paso a paso.
// =============================================================================
module tb_riscv_core;

    parameter CLK_PERIOD = 10;
    localparam TB_DMEM_WORDS = 256;

    reg tb_clk, tb_rst, tb_global_stall;
    reg tb_imem_load_en, tb_imem_load_clear;
    reg [31:0] tb_imem_load_addr, tb_imem_load_data;
    reg tb_dmem_load_en, tb_dmem_load_clear;
    reg [31:0] tb_dmem_load_addr, tb_dmem_load_data;
    wire tb_imem_clear_busy, tb_dmem_clear_busy;

    wire [32*32-1:0] regs_flat;
    wire core_halted;
    wire branch_taken, pc_write_en;
    wire [31:0] cycle_count;
    wire hazard_stall;           // seccion 12
    wire [7:0] fwd_sel;          // seccion 12: {fwd_b_id, fwd_a_id, fwd_b_ex, fwd_a_ex}
    wire [31:0] if_pc, if_instr; // seccion 12

    integer pass_count, fail_count;
    reg [31:0] cycles_no_dep; // seccion 11b

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    riscv_core #(.IMEM_DEPTH_WORDS(256), .DMEM_DEPTH_WORDS(TB_DMEM_WORDS)) uut (
        .clk_i           (tb_clk),
        .rst_i           (tb_rst),
        .global_stall_i  (tb_global_stall),
        .imem_load_en_i  (tb_imem_load_en),
        .imem_load_addr_i(tb_imem_load_addr),
        .imem_load_data_i(tb_imem_load_data),
        .imem_load_clear_i(tb_imem_load_clear),
        .imem_load_clear_busy_o(tb_imem_clear_busy),
        .dmem_load_en_i  (tb_dmem_load_en),
        .dmem_load_addr_i(tb_dmem_load_addr),
        .dmem_load_data_i(tb_dmem_load_data),
        .dmem_load_clear_i(tb_dmem_load_clear),
        .dmem_load_clear_busy_o(tb_dmem_clear_busy),
        .dmem_dbg_addr_i (32'b0),
        .dmem_dbg_rdata_o(),
        .regs_flat_o     (regs_flat),
        .core_halted_o   (core_halted),
        .branch_taken_o  (branch_taken),
        .pc_write_en_o   (pc_write_en),
        .cycle_count_o   (cycle_count),
        .hazard_stall_o  (hazard_stall),
        .fwd_sel_o       (fwd_sel),
        .if_pc_o         (if_pc),
        .if_instr_o      (if_instr)
    );

    // ------------------------------------------------------------------
    // Infraestructura de test
    // ------------------------------------------------------------------
    reg [31:0] prog_mem [0:255];
    integer prog_len;

    task reset_core;
        begin
            tb_rst = 1;
            @(posedge tb_clk);
            @(posedge tb_clk);
            #1;
            tb_rst = 0;
            #1;
        end
    endtask

    // Limpia imem Y dmem, despues carga 'prog_mem[0..prog_len-1]' en imem
    // (mismo mecanismo que va a usar la Debug Unit en Fase 2 para
    // CMD_LOAD_PROG: limpiar toda la memoria de programa antes de escribir
    // el nuevo binario, ver tp3/informe.md sobre el halt implicito).
    //
    // Sostiene rst_i en alto durante TODA la carga (varios ciclos de
    // reloj: uno por palabra) y recien lo libera al final. Sin esto, el
    // core corre libremente mientras el programa todavia se esta
    // escribiendo palabra a palabra -- ve memoria vacia (opcode 0 =
    // invalido), dispara el halt implicito casi al instante, y queda
    // congelado para siempre antes de que el programa real termine de
    // cargarse. Es exactamente el mismo problema que va a tener que
    // resolver la Debug Unit real en Fase 2 (por eso ahi tambien va a
    // sostener el equivalente de reset/stall durante todo CMD_LOAD_PROG).
    task load_program;
        integer i;
        begin
            tb_rst = 1;
            tb_imem_load_clear = 1;
            tb_dmem_load_clear = 1;
            @(posedge tb_clk);
            #1;
            tb_imem_load_clear = 0;
            tb_dmem_load_clear = 0;
            // El barrido de clear tarda DEPTH_WORDS ciclos (una direccion
            // por ciclo, ver imem.v/dmem.v): hay que esperar a que termine
            // antes de empezar a escribir el programa, si no las
            // escrituras se pierden mientras el barrido sigue en curso.
            while (tb_imem_clear_busy || tb_dmem_clear_busy) @(posedge tb_clk);
            #1;

            for (i = 0; i < prog_len; i = i + 1) begin
                tb_imem_load_en   = 1;
                tb_imem_load_addr = i * 4;
                tb_imem_load_data = prog_mem[i];
                @(posedge tb_clk);
                #1;
                tb_imem_load_en = 0;
            end

            // El programa ya esta adentro: recien aca se libera el reset.
            @(posedge tb_clk);
            #1;
            tb_rst = 0;
            #1;
        end
    endtask

    task run_until_halt;
        integer timeout;
        begin
            timeout = 0;
            while (!core_halted && timeout < 500) begin
                @(posedge tb_clk);
                timeout = timeout + 1;
            end
            #1;
            if (!core_halted) begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | Timeout: no se alcanzo HALT en %0d ciclos", timeout);
            end
        end
    endtask

    task check_reg;
        input [511:0] label;
        input [4:0]   idx;
        input [31:0]  expected;
        reg [31:0] got;
        begin
            got = regs_flat[32*idx +: 32];
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: x%0d=0x%08h", label, idx, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: x%0d esperado=0x%08h, recibido=0x%08h", label, idx, expected, got);
            end
        end
    endtask

    task check_mem;
        input [511:0] label;
        input [31:0]  word_idx;
        input [31:0]  expected;
        reg [31:0] got;
        begin
            got = uut.u_dmem.mem[word_idx];
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: mem[%0d]=0x%08h", label, word_idx, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: mem[%0d] esperado=0x%08h, recibido=0x%08h", label, word_idx, expected, got);
            end
        end
    endtask

    // Avanza (con el núcleo libre) hasta que el contador de ciclos valga 'k':
    // deja el estado tal como lo vería un volcado tras k CMD_STEP.
    task wait_cycle;
        input [31:0] k;
        begin
            while (cycle_count < k) begin
                @(posedge tb_clk);
                #1;
            end
        end
    endtask

    task check_val;
        input [511:0] label;
        input [31:0]  got;
        input [31:0]  expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: %0d", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%0d, recibido=%0d", label, expected, got);
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Snapshot del estado completo del núcleo (sección 10)
    // ------------------------------------------------------------------
    // Todo lo que la Dump Unit mandaría en un volcado: los bits de STATUS
    // que dependen del core (pc_write_en, branch_taken; core_halted ya
    // viaja en MEM/WB), el PC, los 4 latches con sus señales de control,
    // el contador de ciclos, los 32 registros y un checksum de toda la
    // dmem. Dos snapshots iguales = dos volcados idénticos.
    //
    // Layout en bloques de 32 bits, para poder ubicar una diferencia:
    // bloque 0 = checksum de dmem, bloques 1..32 = x0..x31, bloque 33 =
    // contador de ciclos, bloques 34 en adelante = PC, latches y STATUS.
    localparam SNAP_W = 2 + 32 + 2*32 + (5*32 + 11) + (4*32 + 5) + (4*32 + 3) + 32 + 32*32 + 32;
    localparam MAX_GOLDEN = 128;

    task take_snapshot;
        output [SNAP_W-1:0] snap;
        reg [31:0] dmem_sum;
        integer w;
        begin
            // Rotar-y-XOR: sensible al contenido Y a la posición de cada palabra.
            dmem_sum = 32'b0;
            for (w = 0; w < TB_DMEM_WORDS; w = w + 1)
                dmem_sum = {dmem_sum[30:0], dmem_sum[31]} ^ uut.u_dmem.mem[w];
            snap = {
                pc_write_en, branch_taken,
                uut.pc_reg,
                uut.if_id_pc, uut.if_id_instr,
                uut.id_ex_pc, uut.id_ex_instr, uut.id_ex_rs1_data, uut.id_ex_rs2_data, uut.id_ex_imm,
                uut.id_ex_reg_write, uut.id_ex_alu_src_a, uut.id_ex_alu_src_b, uut.id_ex_alu_op,
                uut.id_ex_mem_read, uut.id_ex_mem_write, uut.id_ex_mem_to_reg,
                uut.id_ex_is_jal, uut.id_ex_is_jalr, uut.id_ex_is_halt,
                uut.ex_mem_pc, uut.ex_mem_instr, uut.ex_mem_ex_result, uut.ex_mem_rs2_data,
                uut.ex_mem_reg_write, uut.ex_mem_mem_read, uut.ex_mem_mem_write,
                uut.ex_mem_mem_to_reg, uut.ex_mem_is_halt,
                uut.mem_wb_pc, uut.mem_wb_instr, uut.mem_wb_result, uut.mem_wb_mem_read_data,
                uut.mem_wb_reg_write, uut.mem_wb_mem_to_reg, uut.mem_wb_is_halt,
                cycle_count, regs_flat, dmem_sum
            };
        end
    endtask

    // Diagnóstico ante una falla: dice QUÉ parte del estado difiere.
    task report_snapshot_diff;
        input [SNAP_W-1:0] got;
        input [SNAP_W-1:0] expected;
        integer c;
        begin
            for (c = 0; c < (SNAP_W + 31) / 32; c = c + 1) begin
                if (got[32*c +: 32] !== expected[32*c +: 32]) begin
                    if (c == 0)
                        $display("           dmem difiere (checksum esperado=0x%08h, recibido=0x%08h)",
                                 expected[31:0], got[31:0]);
                    else if (c <= 32)
                        $display("           x%0d difiere: esperado=0x%08h, recibido=0x%08h",
                                 c - 1, expected[32*c +: 32], got[32*c +: 32]);
                    else if (c == 33)
                        $display("           contador de ciclos difiere: esperado=%0d, recibido=%0d",
                                 expected[32*c +: 32], got[32*c +: 32]);
                    else
                        $display("           PC/latches/STATUS difieren (bloque %0d)", c);
                end
            end
        end
    endtask

    reg [SNAP_W-1:0] golden [0:MAX_GOLDEN-1]; // corrida libre: estado tras k ciclos
    reg [SNAP_W-1:0] snap, snap_before;
    integer n_golden, k, gap, frozen_total;
    reg freeze_ok, step_ok;

    // ------------------------------------------------------------------
    // Programa de prueba
    // ------------------------------------------------------------------
    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de riscv_core (integracion)");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_global_stall = 0;
        tb_imem_load_en = 0; tb_imem_load_clear = 0; tb_imem_load_addr = 0; tb_imem_load_data = 0;
        tb_dmem_load_en = 0; tb_dmem_load_clear = 0; tb_dmem_load_addr = 0; tb_dmem_load_data = 0;

        // ================================================================
        $display("\n===== 1) R-type basico =====");
        // ================================================================
        prog_mem[0]  = i_addi(1, 0, 10);        // x1 = 10
        prog_mem[1]  = i_addi(2, 0, 3);          // x2 = 3
        prog_mem[2]  = i_add (3, 1, 2);           // x3 = 13
        prog_mem[3]  = i_sub (4, 1, 2);            // x4 = 7
        prog_mem[4]  = i_and (5, 1, 2);             // x5 = 2
        prog_mem[5]  = i_or  (6, 1, 2);              // x6 = 11
        prog_mem[6]  = i_xor (7, 1, 2);               // x7 = 9
        prog_mem[7]  = i_sll (8, 1, 2);                // x8 = 80
        prog_mem[8]  = i_srl (9, 1, 2);                 // x9 = 1
        prog_mem[9]  = i_slt (10, 2, 1);                  // x10 = (3<10) = 1
        prog_mem[10] = i_sltu(11, 1, 2);                   // x11 = (10<u3) = 0
        prog_mem[11] = i_halt(0);
        prog_len = 12;
        load_program; run_until_halt;
        check_reg("add",  3,  32'd13);
        check_reg("sub",  4,  32'd7);
        check_reg("and",  5,  32'd2);
        check_reg("or",   6,  32'd11);
        check_reg("xor",  7,  32'd9);
        check_reg("sll",  8,  32'd80);
        check_reg("srl",  9,  32'd1);
        check_reg("slt",  10, 32'd1);
        check_reg("sltu", 11, 32'd0);

        // ================================================================
        $display("\n===== 2) I-type aritmetico =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 100);       // x1 = 100
        prog_mem[1] = i_andi(2, 1, 12'h00F);     // x2 = 100 & 15 = 4
        prog_mem[2] = i_ori (3, 1, 12'h00F);      // x3 = 100 | 15 = 111
        prog_mem[3] = i_xori(4, 1, 12'h0FF);       // x4 = 100 ^ 255 = 155
        prog_mem[4] = i_slti(5, 1, 12'd200);         // x5 = (100<200) = 1
        prog_mem[5] = i_sltiu(6, 1, 12'd50);           // x6 = (100<u50) = 0
        prog_mem[6] = i_slli(7, 1, 5'd2);                // x7 = 400
        prog_mem[7] = i_srli(8, 1, 5'd2);                 // x8 = 25
        prog_mem[8] = i_addi(9, 0, -12'sd50);               // x9 = -50
        prog_mem[9] = i_srai(10, 9, 5'd1);                    // x10 = -25
        prog_mem[10] = i_halt(0);
        prog_len = 11;
        load_program; run_until_halt;
        check_reg("andi",  2,  32'd4);
        check_reg("ori",   3,  32'd111);
        check_reg("xori",  4,  32'd155);
        check_reg("slti",  5,  32'd1);
        check_reg("sltiu", 6,  32'd0);
        check_reg("slli",  7,  32'd400);
        check_reg("srli",  8,  32'd25);
        check_reg("addi negativo", 9, 32'hFFFFFFCE); // -50
        check_reg("srai (aritmetico, conserva signo)", 10, 32'hFFFFFFE7); // -25

        // ================================================================
        $display("\n===== 3) Loads/stores, todos los anchos y signo =====");
        // ================================================================
        prog_mem[0]  = i_addi(1, 0, 0);           // x1 = base = 0
        prog_mem[1]  = i_addi(2, 0, -1);            // x2 = 0xFFFFFFFF
        prog_mem[2]  = i_sw  (1, 2, 12'd0);           // mem[0] = 0xFFFFFFFF
        prog_mem[3]  = i_lw  (3, 1, 12'd0);            // x3 = 0xFFFFFFFF
        prog_mem[4]  = i_lbu (4, 1, 12'd0);             // x4 = 0x000000FF
        prog_mem[5]  = i_lb  (5, 1, 12'd0);              // x5 = 0xFFFFFFFF
        prog_mem[6]  = i_lhu (6, 1, 12'd0);               // x6 = 0x0000FFFF
        prog_mem[7]  = i_lh  (7, 1, 12'd0);                // x7 = 0xFFFFFFFF
        prog_mem[8]  = i_addi(8, 0, 12'h07F);                // x8 = 127
        prog_mem[9]  = i_sb  (1, 8, 12'd4);                   // mem byte[4] = 0x7F
        prog_mem[10] = i_lb  (9, 1, 12'd4);                    // x9 = 127 (signo no afecta, MSB=0)
        prog_mem[11] = i_lbu (10, 1, 12'd4);                    // x10 = 127
        prog_mem[12] = i_lui (11, 20'hABCDE);                     // x11 = 0xABCDE000
        prog_mem[13] = i_addi(11, 11, 12'h123);                    // x11 = 0xABCDE123
        prog_mem[14] = i_sh  (1, 11, 12'd8);                         // mem half[8] = 0xE123
        prog_mem[15] = i_lhu (12, 1, 12'd8);                          // x12 = 0x0000E123
        prog_mem[16] = i_lh  (13, 1, 12'd8);                           // x13 = 0xFFFFE123
        prog_mem[17] = i_halt(0);
        prog_len = 18;
        load_program; run_until_halt;
        check_reg("lw tras sw",           3,  32'hFFFFFFFF);
        check_reg("lbu (byte 0xFF, u)",   4,  32'h000000FF);
        check_reg("lb  (byte 0xFF, con signo)", 5, 32'hFFFFFFFF);
        check_reg("lhu (half 0xFFFF, u)", 6,  32'h0000FFFF);
        check_reg("lh  (half 0xFFFF, con signo)", 7, 32'hFFFFFFFF);
        check_reg("lb  (0x7F, positivo)", 9,  32'h0000007F);
        check_reg("lbu (0x7F)",           10, 32'h0000007F);
        check_reg("lui+addi (constante 32b)", 11, 32'hABCDE123);
        check_reg("lhu (0xE123, u)",      12, 32'h0000E123);
        check_reg("lh  (0xE123, con signo -> negativo)", 13, 32'hFFFFE123);

        // ================================================================
        $display("\n===== 4) LUI + JAL/JALR (valor de enlace y target) =====");
        // ================================================================
        prog_mem[0] = i_lui (1, 20'h12345);        // addr 0:  x1 = 0x12345000
        prog_mem[1] = i_jal (2, 21'd12);             // addr 4:  x2=PC+4=8; salta a PC+12=16
        prog_mem[2] = i_addi(3, 0, 999);              // addr 8:  SKIPPED
        prog_mem[3] = i_addi(3, 0, 888);               // addr 12: SKIPPED
        prog_mem[4] = i_addi(4, 0, 111);                // addr 16: x4 = 111
        prog_mem[5] = i_jal (0, 21'd12);                  // addr 20: descarta link (x0); salta a PC+12=32
        prog_mem[6] = i_addi(6, 0, 777);                   // addr 24: SKIPPED
        prog_mem[7] = i_addi(6, 0, 666);                    // addr 28: SKIPPED
        prog_mem[8] = i_addi(7, 1, 12'h123);                  // addr 32: x7 = x1+0x123 = 0x12345123
        prog_mem[9] = i_addi(8, 0, 48);                         // addr 36: x8 = 48
        prog_mem[10] = i_jalr(9, 8, 12'd4);                        // addr 40: target=(48+4)&~1=52; x9=PC+4=44
        prog_mem[11] = i_addi(10, 0, 555);                           // addr 44: SKIPPED
        prog_mem[12] = i_addi(10, 0, 444);                            // addr 48: SKIPPED
        prog_mem[13] = i_addi(11, 0, 333);                             // addr 52: x11 = 333
        prog_mem[14] = i_halt(0);                                        // addr 56
        prog_len = 15;
        load_program; run_until_halt;
        check_reg("lui",                    1,  32'h12345000);
        check_reg("jal link value",         2,  32'd8);
        check_reg("jal no ejecuta lo saltado", 3, 32'h0);
        check_reg("jal target",             4,  32'd111);
        check_reg("jal x0 (descarta link) no ejecuta lo saltado", 6, 32'h0);
        check_reg("addi tras el 2do jal",   7,  32'h12345123);
        check_reg("jalr link value",        9,  32'd44);
        check_reg("jalr no ejecuta el fallthrough ni el destino falso", 10, 32'h0);
        check_reg("jalr target real",       11, 32'd333);

        // ================================================================
        $display("\n===== 5) Branches (beq/bne tomados y no tomados) =====");
        // ================================================================
        prog_mem[0]  = i_addi(1, 0, 5);          // addr0:  x1=5
        prog_mem[1]  = i_addi(2, 0, 5);           // addr4:  x2=5
        prog_mem[2]  = i_beq (1, 2, 13'd12);        // addr8:  tomado (5==5) -> salta a 20
        prog_mem[3]  = i_addi(3, 0, 999);            // addr12: SKIPPED
        prog_mem[4]  = i_addi(3, 0, 888);             // addr16: SKIPPED
        prog_mem[5]  = i_addi(4, 0, 5);                 // addr20: x4=5
        prog_mem[6]  = i_bne (1, 2, 13'd12);              // addr24: NO tomado (5==5)
        prog_mem[7]  = i_addi(5, 0, 111);                   // addr28: x5=111 (fallthrough)
        prog_mem[8]  = i_addi(1, 0, 7);                       // addr32: x1=7
        prog_mem[9]  = i_beq (1, 2, 13'd12);                    // addr36: NO tomado (7!=5)
        prog_mem[10] = i_addi(6, 0, 222);                          // addr40: x6=222 (fallthrough)
        prog_mem[11] = i_bne (1, 2, 13'd12);                          // addr44: tomado (7!=5) -> salta a 56
        prog_mem[12] = i_addi(7, 0, 999);                                // addr48: SKIPPED
        prog_mem[13] = i_addi(7, 0, 888);                                 // addr52: SKIPPED
        prog_mem[14] = i_addi(8, 0, 333);                                   // addr56: x8=333
        prog_mem[15] = i_halt(0);
        prog_len = 16;
        load_program; run_until_halt;
        check_reg("beq tomado no ejecuta lo saltado", 3, 32'h0);
        check_reg("fallthrough tras beq tomado",       4, 32'd5);
        check_reg("bne no tomado -> fallthrough",       5, 32'd111);
        check_reg("beq no tomado -> fallthrough",        6, 32'd222);
        check_reg("bne tomado no ejecuta lo saltado",     7, 32'h0);
        check_reg("target final",                          8, 32'd333);

        // ================================================================
        $display("\n===== 6) Prioridad de forwarding (EX/MEM > MEM/WB) =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 50);
        prog_mem[1] = i_addi(9, 0, 1);            // filler (crea el hueco de 1 instr)
        prog_mem[2] = i_add (2, 1, 1);              // x2 = 50+50 = 100: forward desde MEM/WB
        prog_mem[3] = i_addi(6, 0, 9);
        prog_mem[4] = i_add (7, 6, 6);                // x7 = 9+9 = 18: forward desde EX/MEM (adyacente)
        prog_mem[5] = i_addi(1, 0, 111);
        prog_mem[6] = i_addi(1, 0, 222);                // reescribe x1 inmediatamente
        prog_mem[7] = i_add (5, 1, 0);                    // x5 = 222: EX/MEM (mas reciente) debe ganarle a MEM/WB (111)
        prog_mem[8] = i_halt(0);
        prog_len = 9;
        load_program; run_until_halt;
        check_reg("forward desde MEM/WB",                  2, 32'd100);
        check_reg("forward desde EX/MEM (adyacente)",       7, 32'd18);
        check_reg("prioridad EX/MEM > MEM/WB (mismo destino)", 5, 32'd222);

        // ================================================================
        $display("\n===== 7) Load-use hazard (stall obligatorio) =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 0);
        prog_mem[1] = i_addi(2, 0, 77);
        prog_mem[2] = i_sw  (1, 2, 12'd0);
        prog_mem[3] = i_lw  (3, 1, 12'd0);   // x3 = 77
        prog_mem[4] = i_add (4, 3, 3);         // usa x3 INMEDIATAMENTE -> load-use hazard
        prog_mem[5] = i_halt(0);
        prog_len = 6;
        load_program; run_until_halt;
        check_reg("load-use: valor correcto pese al stall", 4, 32'd154);

        // ================================================================
        $display("\n===== 8) Load antes de un branch (0-gap y 1-gap) =====");
        // ================================================================
        // -- 0-gap: el load es la instruccion INMEDIATAMENTE anterior al branch --
        prog_mem[0]  = i_addi(1, 0, 0);
        prog_mem[1]  = i_addi(2, 0, 42);
        prog_mem[2]  = i_sw  (1, 2, 12'd0);
        prog_mem[3]  = i_lw  (3, 1, 12'd0);     // addr12: x3 = 42
        prog_mem[4]  = i_beq (3, 2, 13'd12);      // addr16: depende del load SIN hueco -> stall de 2 ciclos; tomado -> salta a 28
        prog_mem[5]  = i_addi(4, 0, 999);           // addr20: SKIPPED
        prog_mem[6]  = i_addi(4, 0, 888);            // addr24: SKIPPED
        prog_mem[7]  = i_addi(5, 0, 111);              // addr28: x5=111
        // -- 1-gap: una instruccion sin relacion entre el load y el branch --
        prog_mem[8]  = i_addi(1, 0, 4);                  // addr32: nueva base
        prog_mem[9]  = i_addi(6, 0, 55);
        prog_mem[10] = i_sw  (1, 6, 12'd0);
        prog_mem[11] = i_lw  (7, 1, 12'd0);                 // addr44: x7 = 55
        prog_mem[12] = i_addi(8, 0, 1);                       // addr48: filler (1-gap)
        prog_mem[13] = i_beq (7, 6, 13'd12);                    // addr52: depende del load CON 1 hueco -> stall de 1 ciclo; tomado -> salta a 64
        prog_mem[14] = i_addi(9, 0, 999);                          // addr56: SKIPPED
        prog_mem[15] = i_addi(9, 0, 888);                           // addr60: SKIPPED
        prog_mem[16] = i_addi(10, 0, 222);                            // addr64: x10=222
        prog_mem[17] = i_halt(0);
        prog_len = 18;
        load_program; run_until_halt;
        check_reg("0-gap: load correcto",                    3,  32'd42);
        check_reg("0-gap: branch no ejecuta lo saltado",      4,  32'h0);
        check_reg("0-gap: target del branch",                  5,  32'd111);
        check_reg("1-gap: load correcto",                       7,  32'd55);
        check_reg("1-gap: branch no ejecuta lo saltado",         9,  32'h0);
        check_reg("1-gap: target del branch",                     10, 32'd222);

        // ================================================================
        $display("\n===== 9a) HALT explicito =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 42);
        prog_mem[1] = i_halt(0);
        prog_mem[2] = i_addi(1, 0, 999); // jamas deberia ejecutarse
        prog_len = 3;
        load_program; run_until_halt;
        check_reg("halt explicito detiene antes del resto", 1, 32'd42);
        // Lo que retiene el HALT es IF/ID congelado; el PC queda en la
        // instruccion siguiente (HALT+4), que se busca pero nunca entra.
        check_val("PC queda en HALT+4 (addr 8)",          uut.pc_reg,    32'd8);
        check_val("IF/ID retiene el HALT (pc del HALT=4)", uut.if_id_pc, 32'd4);

        // ================================================================
        $display("\n===== 9b) HALT implicito (sin instruccion de parada) =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 42);
        prog_mem[1] = i_addi(2, 0, 99);
        prog_len = 2; // nada mas: mas alla, imem quedo en 0x00000000 (opcode invalido)
        load_program; run_until_halt;
        check_reg("halt implicito: x1 correcto", 1, 32'd42);
        check_reg("halt implicito: x2 correcto", 2, 32'd99);

        // ================================================================
        $display("\n===== 10) Modo paso a paso: global_stall congela TODO el nucleo =====");
        // ================================================================
        // Propiedad verificada: congelar el nucleo es una PAUSA perfecta.
        //  (a) Durante un freeze no cambia ningun estado, por largo que sea
        //      (en hardware dura lo que tarda un volcado por UART: ~10^7
        //      ciclos).
        //  (b) Tras k pasos de exactamente 1 ciclo, con freezes de largo
        //      variable intercalados, el estado es identico bit a bit al de
        //      una corrida libre en el ciclo k. O sea: el volcado de cada
        //      CMD_STEP muestra exactamente el pipeline real de ese ciclo.
        //
        // Primero se graba la corrida libre (referencia), despues se repite
        // el mismo programa paso a paso comparando contra ella. El programa
        // junta los casos donde un freeze incompleto rompe algo: una
        // instruccion NO idempotente (addi x1,x1,1: si se re-emitiera
        // durante el freeze, x1 subiria en cada ciclo congelado), un store
        // (escritura en dmem), un load-use (burbuja en ID/EX), saltos
        // tomados (flush de IF/ID), jal (valor de enlace) y un load justo
        // antes de un branch (stall de 2 ciclos).
        prog_mem[0]  = i_addi(1, 0, 0);          // addr0:  x1 = 0 (contador)
        prog_mem[1]  = i_addi(2, 0, 3);           // addr4:  x2 = 3 (limite)
        prog_mem[2]  = i_addi(5, 0, 8);            // addr8:  x5 = 8 (base: palabra 2 de dmem)
        prog_mem[3]  = i_addi(1, 1, 1);             // addr12: loop: x1 = x1 + 1 (NO idempotente)
        prog_mem[4]  = i_sw  (5, 1, 12'd0);           // addr16: mem[x5] = x1
        prog_mem[5]  = i_lw  (3, 5, 12'd0);            // addr20: x3 = mem[x5]
        prog_mem[6]  = i_add (4, 3, 1);                 // addr24: x4 = x3 + x1 (load-use -> burbuja)
        prog_mem[7]  = i_bne (1, 2, -13'sd16);           // addr28: x1 != 3 -> vuelve a loop (flush)
        prog_mem[8]  = i_jal (6, 21'd8);                  // addr32: x6 = 36; salta a 40
        prog_mem[9]  = i_addi(7, 0, 999);                  // addr36: SKIPPED
        prog_mem[10] = i_lw  (8, 5, 12'd0);                 // addr40: x8 = 3
        prog_mem[11] = i_beq (8, 2, 13'd8);                  // addr44: load justo antes (0-gap), tomado -> 52
        prog_mem[12] = i_addi(9, 0, 999);                     // addr48: SKIPPED
        prog_mem[13] = i_halt(0);                              // addr52
        prog_len = 14;

        // --- (1) Corrida libre de referencia, grabando el estado de cada ciclo ---
        tb_global_stall = 0;
        load_program;
        n_golden = 0;
        take_snapshot(snap);
        golden[0] = snap;
        while (!core_halted && n_golden < MAX_GOLDEN - 4) begin
            @(posedge tb_clk); #1;
            n_golden = n_golden + 1;
            take_snapshot(snap);
            golden[n_golden] = snap;
        end
        if (!core_halted) begin
            fail_count = fail_count + 1;
            $error("  -> FALLO | Corrida de referencia: no se alcanzo HALT en %0d ciclos", n_golden);
        end
        // Unos ciclos mas tras el HALT: el paso a paso tambien tiene que
        // coincidir con el pipeline ya detenido y drenando.
        repeat (3) begin
            @(posedge tb_clk); #1;
            n_golden = n_golden + 1;
            take_snapshot(snap);
            golden[n_golden] = snap;
        end
        $display("  Corrida libre de referencia: HALT en WB en el ciclo %0d (se graban %0d ciclos)",
                 n_golden - 3, n_golden);

        // --- (2) El mismo programa, paso a paso ---
        tb_global_stall = 1; // como la Debug Unit: el core arranca congelado
        load_program;
        take_snapshot(snap);
        if (snap === golden[0]) begin
            pass_count = pass_count + 1;
            $display("  -> EXITO | estado inicial congelado == corrida libre (ciclo 0)");
        end else begin
            fail_count = fail_count + 1;
            $error("  -> FALLO | estado inicial congelado != corrida libre (ciclo 0)");
            report_snapshot_diff(snap, golden[0]);
        end
        check_val("freeze externo no marca stalled (pc_write_en_o=1)", pc_write_en, 1);

        frozen_total = 0;
        for (k = 1; k <= n_golden; k = k + 1) begin
            // Freeze de largo variable antes de cada paso (cada 8 pasos,
            // uno largo, para emular el tiempo de un volcado).
            gap = ((k % 8) == 0) ? 200 : 1 + ((k * 7) % 5);
            snap_before = snap;
            repeat (gap) @(posedge tb_clk);
            #1;
            take_snapshot(snap);
            frozen_total = frozen_total + gap;
            freeze_ok = (snap === snap_before);
            if (!freeze_ok) begin
                $error("  -> FALLO | paso %0d: el estado cambio durante %0d ciclos congelados", k, gap);
                report_snapshot_diff(snap, snap_before);
            end

            // Un CMD_STEP: global_stall en 0 durante exactamente un flanco.
            tb_global_stall = 0;
            @(posedge tb_clk); #1;
            tb_global_stall = 1;
            #1;
            take_snapshot(snap);
            step_ok = (snap === golden[k]);
            if (!step_ok) begin
                $error("  -> FALLO | paso %0d: estado != corrida libre en el ciclo %0d", k, k);
                report_snapshot_diff(snap, golden[k]);
            end

            if (freeze_ok) pass_count = pass_count + 1; else fail_count = fail_count + 1;
            if (step_ok)   pass_count = pass_count + 1; else fail_count = fail_count + 1;
            if (freeze_ok && step_ok)
                $display("  -> EXITO | paso %0d: %0d ciclos congelados sin cambios, estado == corrida libre (ciclo %0d)",
                         k, gap, k);
        end

        // --- (3) Resultado final, contra valores calculados a mano ---
        $display("  (%0d pasos, %0d ciclos congelados intercalados en total)", n_golden, frozen_total);
        check_val("core detenido (HALT en WB) tras el ultimo paso", core_halted, 1);
        check_val("contador de ciclos == pasos (no cuenta congelados)", cycle_count, n_golden);
        check_reg("contador: no se re-incremento en los freezes", 1, 32'd3);
        check_reg("load dentro del loop",                          3, 32'd3);
        check_reg("load-use dentro del loop",                      4, 32'd6);
        check_reg("valor de enlace de jal",                        6, 32'd36);
        check_reg("jal no ejecuta lo saltado",                     7, 32'h0);
        check_reg("load justo antes del branch",                   8, 32'd3);
        check_reg("beq tomado no ejecuta lo saltado",              9, 32'h0);
        check_mem("store del loop",                                2, 32'd3);

        // ================================================================
        $display("\n===== 11a) Opcode conocido pero instruccion fuera del subset -> HALT implicito =====");
        // ================================================================
        // blt comparte opcode con beq/bne y branch_unit solo mira
        // funct3[0]: sin validar funct3 en control_unit, este blt se
        // ejecutaria en silencio como un beq (1==3 falso -> no salta ->
        // x3=7). Tiene que frenar el core en el lugar, como cualquier otra
        // instruccion que no esta en el enunciado.
        tb_global_stall = 0; // la seccion 10 lo deja en 1 (paso a paso)
        prog_mem[0] = i_addi(1, 0, 1);
        prog_mem[1] = i_addi(2, 0, 3);
        prog_mem[2] = enc_b(13'd8, 5'd2, 5'd1, 3'b100, 7'b1100011); // blt x1, x2, +8
        prog_mem[3] = i_addi(3, 0, 7);   // no se ejecuta (ni como fallthrough de un "beq")
        prog_mem[4] = i_addi(4, 0, 9);   // no se ejecuta (ni como destino de un blt tomado)
        prog_mem[5] = i_halt(0);
        prog_len = 6;
        load_program; run_until_halt;
        check_reg("blt: lo anterior se completo (x1)", 1, 32'd1);
        check_reg("blt: lo anterior se completo (x2)", 2, 32'd3);
        check_reg("blt: no siguio como beq (x3)",      3, 32'd0);
        check_reg("blt: no salto (x4)",                4, 32'd0);
        check_val("blt: la instruccion que freno es la propia blt (MEM/WB.instr)",
                  uut.mem_wb_instr, prog_mem[2]);
        check_val("blt: IF/ID la retiene (pc=8)", uut.if_id_pc, 32'd8);

        // mul (extension M, funct7=0000001): sin validar funct7 se
        // ejecutaria como add (6+7=13).
        prog_mem[0] = i_addi(1, 0, 6);
        prog_mem[1] = i_addi(2, 0, 7);
        prog_mem[2] = enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd5, 7'b0110011); // mul x5, x1, x2
        prog_mem[3] = i_addi(6, 0, 1);   // no se ejecuta
        prog_mem[4] = i_halt(0);
        prog_len = 5;
        load_program; run_until_halt;
        check_reg("mul: no se ejecuto como add (x5)", 5, 32'd0);
        check_reg("mul: lo posterior no se ejecuto (x6)", 6, 32'd0);

        // ================================================================
        $display("\n===== 11b) Load-use: solo frena una dependencia REAL =====");
        // ================================================================
        // addi x6, x2, 5: los bits [24:20] (campo rs2) son imm[4:0] = 5,
        // el mismo numero que el rd del load (x5), pero addi no lee rs2.
        // Antes se comparaba el campo crudo y eso costaba un stall espurio.
        // 5 instrucciones sin stalls = 5 + 3 = 8 ciclos hasta que el HALT
        // entra a MEM/WB; acá se lee 1 más porque en este testbench nadie
        // congela el núcleo al llegar el HALT (eso lo hace la Debug Unit,
        // ver tb_riscv_uart_top.v) y run_until_halt recién ve core_halted
        // en el flanco siguiente.
        prog_mem[0] = i_addi(1, 0, 77);
        prog_mem[1] = i_sw(0, 1, 12'd0);   // sw x1, 0(x0): mem[0] = 77
        prog_mem[2] = i_lw(5, 0, 12'd0);   // x5 = 77
        prog_mem[3] = i_addi(6, 2, 12'd5); // x6 = x2 + 5 = 5 (no depende de x5)
        prog_mem[4] = i_halt(0);
        prog_len = 5;
        load_program; run_until_halt;
        cycles_no_dep = cycle_count;
        check_val("sin dependencia real: 0 stalls (8 ciclos + 1 de lectura)", cycles_no_dep, 32'd9);
        check_reg("sin dependencia real: x6 = x2 + 5", 6, 32'd5);

        // Mismo programa, pero ahora el consumidor SI lee x5: el stall de
        // load-use es obligatorio (1 ciclo) y el valor tiene que llegar.
        prog_mem[3] = i_add(6, 5, 2);      // x6 = x5 + x2 = 77
        load_program; run_until_halt;
        check_val("dependencia real: exactamente 1 stall mas", cycle_count - cycles_no_dep, 32'd1);
        check_reg("dependencia real: x6 = x5 + x2", 6, 32'd77);

        // ================================================================
        $display("\n===== 12) Salidas de debug para la GUI (IF, stall de datos, forwarding) =====");
        // ================================================================
        // Lo que la Dump Unit manda en STATUS[3], STATUS[15:8] y las
        // palabras 53-54, comparado ciclo a ciclo contra la cronología que
        // se deriva a mano del programa:
        //   c3: add x2 en EX con addi x1 en MEM  -> fwd_a_ex = fwd_b_ex = EX/MEM
        //   c4: lw x3 en EX, add x4 (lee x3) en ID -> stall de datos
        //   c6: beq x4,x2 en ID con add x4 en EX -> fwd_a_id = EX (salida actual
        //       de la ALU); add x4 en EX toma x3 del lw que está en MEM/WB.
        //       x4 = x3 + x2 = 0 + 10 = x2 -> salto tomado
        tb_global_stall = 0;
        prog_mem[0] = i_addi(1, 0, 5);        // 0x00
        prog_mem[1] = i_add (2, 1, 1);        // 0x04  x2 = 10
        prog_mem[2] = i_lw  (3, 0, 12'd0);    // 0x08  x3 = mem[0] = 0
        prog_mem[3] = i_add (4, 3, 2);        // 0x0C  x4 = 10 (load-use)
        prog_mem[4] = i_beq (4, 2, 13'd8);    // 0x10  tomado -> 0x18
        prog_mem[5] = i_addi(9, 0, 1);        // 0x14  descartada (flush)
        prog_mem[6] = i_halt(0);              // 0x18
        prog_len = 7;
        load_program;
        check_val("c0: IF.pc = 0",                           if_pc, 32'h00);
        check_val("c0: IF.instr = imem[0]",                  if_instr, prog_mem[0]);
        wait_cycle(3);
        check_val("c3: IF.pc = 0x0C",                        if_pc, 32'h0C);
        check_val("c3: fwd_sel (add x2 en EX desde EX/MEM)", fwd_sel, 8'b00_00_01_01);
        check_val("c3: sin stall de datos",                  hazard_stall, 1'b0);
        wait_cycle(4);
        check_val("c4: stall de datos (load-use)",           hazard_stall, 1'b1);
        check_val("c4: PC congelado",                        pc_write_en, 1'b0);
        check_val("c4: IF.pc = 0x10",                        if_pc, 32'h10);
        wait_cycle(5);
        check_val("c5: stall resuelto",                      hazard_stall, 1'b0);
        check_val("c5: IF.pc sigue en 0x10 (lo retuvo el stall)", if_pc, 32'h10);
        check_val("c5: ID/EX es la burbuja (NOP)",           uut.id_ex_instr, 32'h00000013);
        wait_cycle(6);
        check_val("c6: fwd_sel (beq<-EX, add x4<-MEM/WB)",   fwd_sel, 8'b00_01_00_10);
        check_val("c6: beq tomado",                          branch_taken, 1'b1);
        check_val("c6: IF.instr = la que se descarta",       if_instr, prog_mem[5]);
        wait_cycle(7);
        check_val("c7: IF.pc = destino del salto (0x18)",    if_pc, 32'h18);
        check_val("c7: IF/ID vaciado por el flush",          uut.if_id_instr, 32'h00000013);
        run_until_halt;
        check_reg("salto tomado: la instruccion descartada no escribio x9", 9, 32'h0);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("RISCV_CORE: TODOS LOS TESTS PASARON");
        else $display("RISCV_CORE: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
