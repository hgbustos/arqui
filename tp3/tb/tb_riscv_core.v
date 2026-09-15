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
//
// Cada programa se corre de punta a punta hasta HALT (no se inspecciona
// ciclo a ciclo): si el valor final de un registro es el esperado, es
// evidencia de que todo el camino que lo produjo -- decode, forwarding,
// hazards, memoria -- funcionó bien, que es lo que realmente importa acá.
// =============================================================================
module tb_riscv_core;

    parameter CLK_PERIOD = 10;

    reg tb_clk, tb_rst, tb_global_stall;
    reg tb_imem_load_en, tb_imem_load_clear;
    reg [31:0] tb_imem_load_addr, tb_imem_load_data;
    reg tb_dmem_load_en, tb_dmem_load_clear;
    reg [31:0] tb_dmem_load_addr, tb_dmem_load_data;
    wire tb_imem_clear_busy, tb_dmem_clear_busy;

    wire [32*32-1:0] regs_flat;
    wire core_halted;

    integer pass_count, fail_count;

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    riscv_core #(.IMEM_DEPTH_WORDS(256), .DMEM_DEPTH_WORDS(256)) uut (
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
        .cycle_count_o   ()
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

        // ================================================================
        $display("\n===== 9b) HALT implicito (sin instruccion de parada) =====");
        // ================================================================
        prog_mem[0] = i_addi(1, 0, 42);
        prog_mem[1] = i_addi(2, 0, 99);
        prog_len = 2; // nada mas: mas alla, imem quedo en 0x00000000 (opcode invalido)
        load_program; run_until_halt;
        check_reg("halt implicito: x1 correcto", 1, 32'd42);
        check_reg("halt implicito: x2 correcto", 2, 32'd99);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("RISCV_CORE: TODOS LOS TESTS PASARON");
        else $display("RISCV_CORE: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
