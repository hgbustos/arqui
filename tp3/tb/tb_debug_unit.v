`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_debug_unit
//
// Descripción:
// Verifica debug_unit.v manejando directamente la interfaz Rx tipo
// registro (r_data_i/rx_empty_i/rd_o) -- no simula timing real de UART
// (eso lo hace tb_riscv_uart_top.v, end-to-end). Cubre: CMD_LOAD_PROG y
// CMD_LOAD_DATA completos (clear + N palabras a la memoria correcta, con
// soft-reset sostenido durante toda la carga), N=0 (sólo clear, sin
// escrituras), CMD_RUN (stall liberado hasta halt, dump disparado),
// CMD_STEP (stall liberado exactamente 1 ciclo), CMD_DUMP (dump inmediato
// sin liberar el stall), CMD_RESET (pulso de soft-reset sin dump) y un
// comando desconocido (se descarta, sin efecto).
// =============================================================================
module tb_debug_unit;

    localparam [7:0] CMD_LOAD_PROG = 8'h10;
    localparam [7:0] CMD_LOAD_DATA = 8'h11;
    localparam [7:0] CMD_RUN       = 8'h20;
    localparam [7:0] CMD_STEP      = 8'h21;
    localparam [7:0] CMD_DUMP      = 8'h22;
    localparam [7:0] CMD_RESET     = 8'h23;

    parameter CLK_PERIOD = 10;
    reg tb_clk, tb_rst;
    reg [7:0] tb_r_data;
    reg       tb_rx_empty;
    wire      tb_rd;

    wire        tb_imem_en;
    wire [31:0] tb_imem_addr, tb_imem_data;
    wire        tb_imem_clear;
    reg         tb_imem_clear_busy;
    wire        tb_dmem_en;
    wire [31:0] tb_dmem_addr, tb_dmem_data;
    wire        tb_dmem_clear;
    reg         tb_dmem_clear_busy;

    reg  tb_core_halted;
    wire tb_soft_reset, tb_stall;
    wire tb_dump_trigger;
    reg  tb_dump_done;

    integer pass_count, fail_count;

    debug_unit uut (
        .clk_i(tb_clk), .rst_i(tb_rst),
        .r_data_i(tb_r_data), .rx_empty_i(tb_rx_empty), .rd_o(tb_rd),
        .imem_load_en_o(tb_imem_en), .imem_load_addr_o(tb_imem_addr),
        .imem_load_data_o(tb_imem_data), .imem_load_clear_o(tb_imem_clear),
        .imem_clear_busy_i(tb_imem_clear_busy),
        .dmem_load_en_o(tb_dmem_en), .dmem_load_addr_o(tb_dmem_addr),
        .dmem_load_data_o(tb_dmem_data), .dmem_load_clear_o(tb_dmem_clear),
        .dmem_clear_busy_i(tb_dmem_clear_busy),
        .core_soft_reset_o(tb_soft_reset), .core_stall_o(tb_stall),
        .core_halted_i(tb_core_halted),
        .dump_trigger_o(tb_dump_trigger), .dump_done_i(tb_dump_done)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD/2) tb_clk = ~tb_clk;

    // Monitor: cuenta pulsos de imem_load_en_o/dmem_load_en_o y guarda el
    // ultimo addr/data visto en cada pulso, para verificar la secuencia de
    // escrituras de un CMD_LOAD_* completo.
    integer imem_en_count, dmem_en_count;
    reg [31:0] imem_last_addr, imem_last_data;
    reg [31:0] dmem_last_addr, dmem_last_data;
    integer imem_clear_count, dmem_clear_count;

    always @(posedge tb_clk) begin
        if (tb_imem_en) begin
            imem_en_count = imem_en_count + 1;
            imem_last_addr = tb_imem_addr;
            imem_last_data = tb_imem_data;
        end
        if (tb_dmem_en) begin
            dmem_en_count = dmem_en_count + 1;
            dmem_last_addr = tb_dmem_addr;
            dmem_last_data = tb_dmem_data;
        end
        if (tb_imem_clear) imem_clear_count = imem_clear_count + 1;
        if (tb_dmem_clear) dmem_clear_count = dmem_clear_count + 1;
    end

    task send_byte;
        input [7:0] data;
        begin
            tb_r_data = data;
            tb_rx_empty = 0;
            @(posedge tb_clk);
            #1;
            tb_rx_empty = 1;
            @(posedge tb_clk);
            #1;
        end
    endtask

    // Variante SIN el ciclo de respiro final: hace falta para comandos de
    // un solo byte cuyo efecto dura exactamente 1 ciclo (CMD_STEP,
    // CMD_RESET) o se dispara inmediatamente al llegar (CMD_DUMP) --
    // send_byte's ciclo extra "se comería" ese unico ciclo activo antes de
    // que el test lo pueda observar.
    task dispatch_cmd;
        input [7:0] cmd;
        begin
            tb_r_data = cmd;
            tb_rx_empty = 0;
            @(posedge tb_clk);
            #1;
            tb_rx_empty = 1;
        end
    endtask

    // Confirma un dump (DUMP_TRIG -> DUMP_WAIT -> RECV_CMD) sosteniendo
    // dump_done_i en alto durante LAS DOS transiciones, no solo la
    // primera: dump_done_i sólo importa una vez que el FSM ya está en
    // DUMP_WAIT (no en DUMP_TRIG, que pasa a DUMP_WAIT incondicionalmente
    // sin mirarlo), así que hace falta un segundo flanco con la señal
    // todavía en alto antes de bajarla -- si se baja después de un solo
    // flanco, el FSM queda trabado para siempre en DUMP_WAIT.
    task finish_dump;
        begin
            tb_dump_done = 1;
            @(posedge tb_clk); #1;
            @(posedge tb_clk); #1;
            tb_dump_done = 0;
            #1;
        end
    endtask

    task check;
        input [511:0] label;
        input got;
        input expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=%0d, recibido=%0d", label, expected, got);
            end
        end
    endtask

    task check32;
        input [511:0] label;
        input [31:0] got;
        input [31:0] expected;
        begin
            if (got === expected) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s: 0x%08h", label, got);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado=0x%08h, recibido=0x%08h", label, expected, got);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de debug_unit");
        $display("========================================");
        pass_count = 0; fail_count = 0;
        tb_rst = 1; tb_r_data = 0; tb_rx_empty = 1; tb_core_halted = 0; tb_dump_done = 0;
        // Este testbench maneja debug_unit de forma aislada (ver header):
        // imem/dmem no existen acá, así que el barrido de clear se modela
        // como instantáneo (nunca ocupado) -- el timing real del barrido
        // multi-ciclo se verifica end-to-end en tb_riscv_uart_top.v, con
        // imem.v/dmem.v de verdad.
        tb_imem_clear_busy = 0; tb_dmem_clear_busy = 0;
        #(CLK_PERIOD*2);
        tb_rst = 0;
        #1;

        // ================================================================
        $display("\n===== CMD_LOAD_PROG: clear + 2 palabras a imem =====");
        // ================================================================
        imem_en_count = 0; dmem_en_count = 0; imem_clear_count = 0; dmem_clear_count = 0;
        send_byte(CMD_LOAD_PROG);
        // 1 ciclo extra: LOAD_CLEAR_WAIT espera a que imem_clear_busy_i
        // baje (acá, instantáneo) antes de pasar a recibir el tamaño.
        @(posedge tb_clk); #1;
        send_byte(8'h02); send_byte(8'h00); // N=2, little-endian
        // palabra 0 = 0x11223344
        send_byte(8'h44); send_byte(8'h33); send_byte(8'h22); send_byte(8'h11);
        // palabra 1 = 0xAABBCCDD
        send_byte(8'hDD); send_byte(8'hCC); send_byte(8'hBB); send_byte(8'hAA);
        #(CLK_PERIOD);
        check("imem_load_clear_o pulso exactamente 1 vez", imem_clear_count, 1);
        check("dmem_load_clear_o nunca (target=imem)", dmem_clear_count, 0);
        check("imem_load_en_o pulso 2 veces (2 palabras)", imem_en_count, 2);
        check("dmem_load_en_o nunca (target=imem)", dmem_en_count, 0);
        check32("ultima escritura: addr=4", imem_last_addr, 32'd4);
        check32("ultima escritura: data=0xAABBCCDD", imem_last_data, 32'hAABBCCDD);

        // ================================================================
        $display("\n===== CMD_LOAD_DATA: clear + 1 palabra a dmem =====");
        // ================================================================
        imem_en_count = 0; dmem_en_count = 0; imem_clear_count = 0; dmem_clear_count = 0;
        send_byte(CMD_LOAD_DATA);
        @(posedge tb_clk); #1; // ver nota de LOAD_CLEAR_WAIT arriba
        send_byte(8'h01); send_byte(8'h00); // N=1
        send_byte(8'hEF); send_byte(8'hBE); send_byte(8'hAD); send_byte(8'hDE); // 0xDEADBEEF
        #(CLK_PERIOD);
        check("dmem_load_clear_o pulso exactamente 1 vez", dmem_clear_count, 1);
        check("imem_load_clear_o nunca (target=dmem)", imem_clear_count, 0);
        check("dmem_load_en_o pulso 1 vez", dmem_en_count, 1);
        check("imem_load_en_o nunca (target=dmem)", imem_en_count, 0);
        check32("escritura: addr=0", dmem_last_addr, 32'd0);
        check32("escritura: data=0xDEADBEEF", dmem_last_data, 32'hDEADBEEF);

        // ================================================================
        $display("\n===== CMD_LOAD_PROG con N=0: solo clear, sin escrituras =====");
        // ================================================================
        imem_en_count = 0; imem_clear_count = 0;
        send_byte(CMD_LOAD_PROG);
        @(posedge tb_clk); #1; // ver nota de LOAD_CLEAR_WAIT arriba
        send_byte(8'h00); send_byte(8'h00); // N=0
        #(CLK_PERIOD);
        check("N=0: clear si ocurre", imem_clear_count, 1);
        check("N=0: ninguna escritura", imem_en_count, 0);

        // ================================================================
        $display("\n===== CMD_RUN: libera stall hasta halt, despues dump =====");
        // ================================================================
        tb_core_halted = 0;
        send_byte(CMD_RUN);
        #1;
        check("CMD_RUN: stall liberado mientras no hay halt", tb_stall, 1'b0);
        #(CLK_PERIOD*3);
        check("CMD_RUN: sigue liberado (todavia sin halt)", tb_stall, 1'b0);
        tb_core_halted = 1;
        #1;
        @(posedge tb_clk); #1;
        check("CMD_RUN: dump_trigger_o se dispara al ver halt", tb_dump_trigger, 1'b1);
        finish_dump;
        #1;
        check("CMD_RUN: stall vuelve a 1 despues del dump", tb_stall, 1'b1);
        tb_core_halted = 0;

        // ================================================================
        $display("\n===== CMD_STEP: libera stall exactamente 1 ciclo =====");
        // ================================================================
        dispatch_cmd(CMD_STEP);
        #1;
        check("CMD_STEP: stall liberado en el ciclo del step", tb_stall, 1'b0);
        @(posedge tb_clk); #1;
        check("CMD_STEP: stall vuelve a 1 al ciclo siguiente", tb_stall, 1'b1);
        check("CMD_STEP: dump_trigger_o se dispara", tb_dump_trigger, 1'b1);
        finish_dump;

        // ================================================================
        $display("\n===== CMD_DUMP: dispara dump sin liberar el stall =====");
        // ================================================================
        dispatch_cmd(CMD_DUMP);
        #1;
        check("CMD_DUMP: nunca libera el stall", tb_stall, 1'b1);
        check("CMD_DUMP: dump_trigger_o se dispara", tb_dump_trigger, 1'b1);
        finish_dump;

        // ================================================================
        $display("\n===== CMD_RESET: pulso de soft-reset, sin dump =====");
        // ================================================================
        dispatch_cmd(CMD_RESET);
        #1;
        check("CMD_RESET: soft_reset_o en alto", tb_soft_reset, 1'b1);
        check("CMD_RESET: no dispara dump", tb_dump_trigger, 1'b0);
        @(posedge tb_clk); #1;
        check("CMD_RESET: soft_reset_o vuelve a 0", tb_soft_reset, 1'b0);

        // ================================================================
        $display("\n===== Comando desconocido: se descarta sin efecto =====");
        // ================================================================
        imem_en_count = 0; dmem_en_count = 0;
        dispatch_cmd(8'hFF);
        #(CLK_PERIOD*3);
        check("comando desconocido: no dispara dump", tb_dump_trigger, 1'b0);
        check("comando desconocido: no libera el stall", tb_stall, 1'b1);
        // Confirma que quedo listo para el proximo comando real:
        dispatch_cmd(CMD_DUMP);
        #1;
        check("tras descartar basura, el proximo comando real funciona", tb_dump_trigger, 1'b1);
        finish_dump;

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("DEBUG_UNIT: TODOS LOS TESTS PASARON");
        else $display("DEBUG_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
