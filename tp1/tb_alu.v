`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_alu (Test Bench de Verificación Completa)
//
// Descripción:
// Valida el módulo 'ALU_top' con un enfoque estructurado. Realiza verificaciones
// completas de todas las salidas y contiene secciones de prueba dedicadas para
// cada opcode válido, utilizando datos de entrada aleatorios.
// =============================================================================
`timescale 1ns / 1ps

module tb_alu;

    parameter N = 8;
    parameter CLK_PERIOD = 10;

    reg             tb_clk;
    reg             tb_rst;
    reg [N-1:0]     tb_sw;
    reg             tb_btn_load_a;
    reg             tb_btn_load_b;
    reg             tb_btn_load_op;
    wire [N+1:0]    tb_led;

    integer i;
    reg [N-1:0] a, b;
    reg [5:0]   op;

    ALU_top #(.N(N)) uut (
        .clk_i(tb_clk), .rst_i(tb_rst), .sw_i(tb_sw),
        .btn_load_a_i(tb_btn_load_a), .btn_load_b_i(tb_btn_load_b),
        .btn_load_op_i(tb_btn_load_op), .led_o(tb_led)
    );

    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    task run_test_case;
        input [N-1:0] in_a;
        input [N-1:0] in_b;
        input [5:0]   in_op;
        reg [N-1:0]   expected_out;
        reg           expected_zero;
        reg           expected_co;
        
        localparam OP_ADD = 6'b100000, OP_SUB = 6'b100010, OP_AND = 6'b100100;
        localparam OP_OR  = 6'b100101, OP_XOR = 6'b100110, OP_SRA = 6'b000011;
        localparam OP_SRL = 6'b000010, OP_NOR = 6'b100111;
        
        begin
            tb_sw = in_a;
            tb_btn_load_a = 1; #(CLK_PERIOD); tb_btn_load_a = 0; #(CLK_PERIOD * 2);

            tb_sw = in_b;
            tb_btn_load_b = 1; #(CLK_PERIOD); tb_btn_load_b = 0; #(CLK_PERIOD * 2);

            tb_sw = {2'b0, in_op};
            tb_btn_load_op = 1; #(CLK_PERIOD); tb_btn_load_op = 0; #(CLK_PERIOD * 5);

            expected_co = 1'b0;
            case (in_op)
                OP_ADD: {expected_co, expected_out} = in_a + in_b;
                OP_SUB: {expected_co, expected_out} = in_a - in_b;
                OP_AND: expected_out = in_a & in_b;
                OP_OR:  expected_out = in_a | in_b;
                OP_XOR: expected_out = in_a ^ in_b;
                OP_SRA: expected_out = $signed(in_a) >>> in_b;
                OP_SRL: expected_out = in_a >> in_b;
                OP_NOR: expected_out = ~(in_a | in_b);
                default:   expected_out = {N{1'b0}};
            endcase
            expected_zero = ~|expected_out;

            if ({tb_led[N+1], tb_led[N], tb_led[N-1:0]} === {expected_co, expected_zero, expected_out}) begin
                $display("  -> EXITO | A:%4d, B:%4d -> Recibido (C,Z,Out): %1b,%1b,%4d",
                         in_a, in_b, tb_led[N+1], tb_led[N], tb_led[N-1:0]);
            end else begin
                $error("  -> FALLO | A:%4d, B:%4d, Op:%b", in_a, in_b, in_op);
                $error("     Esperado (C,Z,Out): %1b,%1b,%4d", expected_co, expected_zero, expected_out);
                $error("     Recibido (C,Z,Out): %1b,%1b,%4d", tb_led[N+1], tb_led[N], tb_led[N-1:0]);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificación Completa de la ALU");
        $display("========================================");

        tb_rst = 1; tb_sw = 0; tb_btn_load_a = 0; tb_btn_load_b = 0; tb_btn_load_op = 0;
        #(CLK_PERIOD * 5);
        tb_rst = 0;
        $display("INFO: Reset liberado. Comenzando pruebas estructuradas...");
        #(CLK_PERIOD * 2);

        $display("\n--- Probando ADD ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100000);
        $display("\n--- Probando SUB ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100010);
        $display("\n--- Probando AND ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100100);
        $display("\n--- Probando OR ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100101);
        $display("\n--- Probando XOR ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100110);
        $display("\n--- Probando SRA ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b000011);
        $display("\n--- Probando SRL ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b000010);
        $display("\n--- Probando NOR ---");
        for(i=0; i<20; i=i+1) run_test_case($random, $random, 6'b100111);

        $display("\n--- Probando Opcodes Inválidos ---");
        run_test_case(123, 45, 6'b000000);
        run_test_case(255, 255, 6'b111111);
        
        $display("\n========================================");
        $display("Simulación completada.");
        $display("========================================");
        $finish;
    end

endmodule