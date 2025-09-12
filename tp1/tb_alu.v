// =============================================================================
// Módulo:         tb_alu (Test Bench de Verificación Completa)
// =============================================================================
`timescale 1ns / 1ps

module tb_alu;

    parameter N = 8;
    parameter CLK_PERIOD = 10;

    // --- Señales y Variables del Test Bench ---
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

    // --- Instanciación del DUT (Device Under Test) ---
    ALU_top #(.N(N)) uut (
        .clk_i(tb_clk), .rst_i(tb_rst), .sw_i(tb_sw),
        .btn_load_a_i(tb_btn_load_a), .btn_load_b_i(tb_btn_load_b),
        .btn_load_op_i(tb_btn_load_op), .led_o(tb_led)
    );

    // --- Generación del Reloj ---
    initial tb_clk = 0;
    always #(CLK_PERIOD / 2) tb_clk = ~tb_clk;

    // --- TAREA: Ejecutar y Verificar un Caso de Prueba ---
    task run_test_case;
        input [N-1:0] in_a;
        input [N-1:0] in_b;
        input [5:0]   in_op;
        reg [N-1:0]   expected_out;
        reg           expected_zero;
        reg           expected_co;
        begin
            // Cargar Operando A
            tb_sw = in_a;
            tb_btn_load_a = 1; #(CLK_PERIOD); tb_btn_load_a = 0;
            #(CLK_PERIOD * 2);

            // Cargar Operando B
            tb_sw = in_b;
            tb_btn_load_b = 1; #(CLK_PERIOD); tb_btn_load_b = 0;
            #(CLK_PERIOD * 2);

            // Cargar Opcode
            tb_sw = {2'b0, in_op};
            tb_btn_load_op = 1; #(CLK_PERIOD); tb_btn_load_op = 0;
            #(CLK_PERIOD * 5);

            // Calcular TODOS los valores esperados
            expected_co = 1'b0; // Valor por defecto para operaciones lógicas
            case (in_op)
                6'b100000: {expected_co, expected_out} = in_a + in_b;
                6'b100010: {expected_co, expected_out} = in_a - in_b;
                6'b100100: expected_out = in_a & in_b;
                6'b100101: expected_out = in_a | in_b;
                6'b100110: expected_out = in_a ^ in_b;
                6'b000011: expected_out = $signed(in_a) >>> in_b;
                6'b000010: expected_out = in_a >> in_b;
                6'b100111: expected_out = ~(in_a | in_b);
                default:   expected_out = {N{1'b0}};
            endcase
            expected_zero = ~|expected_out;

            // Comparación completa del bus de salida
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

    // --- Secuencia de Prueba Principal ---
    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion Completa de la ALU");
        $display("========================================");

        // Fase de Reset
        tb_rst = 1; tb_sw = 0; tb_btn_load_a = 0; tb_btn_load_b = 0; tb_btn_load_op = 0;
        #(CLK_PERIOD * 5);
        tb_rst = 0;
        $display("INFO: Reset liberado. Comenzando pruebas estructuradas...");
        #(CLK_PERIOD * 2);
        
        $display("\n--- Probando ADD (100000) ---");
        op = 6'b100000; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando SUB (100010) ---");
        op = 6'b100010; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando AND (100100) ---");
        op = 6'b100100; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando OR (100101) ---");
        op = 6'b100101; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando XOR (100110) ---");
        op = 6'b100110; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);
        
        $display("\n--- Probando SRA (000011) ---");
        op = 6'b000011; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando SRL (000010) ---");
        op = 6'b000010; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando NOR (100111) ---");
        op = 6'b100111; for(i=0; i<20; i=i+1) run_test_case($random, $random, op);

        $display("\n--- Probando Opcodes Invalidos ---");
        run_test_case(123, 45, 6'b000000);
        run_test_case(255, 255, 6'b111111);
        
        $display("\n========================================");
        $display("Simulacion completada.");
        $display("========================================");
        $finish;
    end

endmodule