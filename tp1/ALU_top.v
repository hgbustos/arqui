// =============================================================================
// Módulo:         ALU_top
//
// Descripción:
// Módulo principal que integra la ALU en un sistema secuencial. Contiene los
// registros para los operandos y el opcode, y maneja la interfaz con los
// periféricos de la FPGA (reloj, reset, switches, botones y LEDs).
// =============================================================================
module ALU_top #(
    parameter N = 8
)(
    input wire             clk_i,
    input wire             rst_i,
    input wire [N-1:0]     sw_i,
    input wire             btn_load_a_i,
    input wire             btn_load_b_i,
    input wire             btn_load_op_i,

    output wire [N+1:0]    led_o
);

    reg [N-1:0]    reg_A;
    reg [N-1:0]    reg_B;
    reg [5:0]      reg_Op;

    reg btn_load_a_reg;
    reg btn_load_b_reg;
    reg btn_load_op_reg;

    wire [N-1:0]   alu_out;
    wire           alu_zero;
    wire           alu_co;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            reg_A           <= {N{1'b0}};
            reg_B           <= {N{1'b0}};
            reg_Op          <= 6'b0;
            btn_load_a_reg  <= 1'b0;
            btn_load_b_reg  <= 1'b0;
            btn_load_op_reg <= 1'b0;
        end
        else begin
            btn_load_a_reg  <= btn_load_a_i;
            btn_load_b_reg  <= btn_load_b_i;
            btn_load_op_reg <= btn_load_op_i;

            if (btn_load_a_i && !btn_load_a_reg) begin
                reg_A <= sw_i;
            end

            if (btn_load_b_i && !btn_load_b_reg) begin
                reg_B <= sw_i;
            end

            if (btn_load_op_i && !btn_load_op_reg) begin
                reg_Op <= sw_i[5:0];
            end
        end
    end

    ALU #(.N(N)) u_alu (
        .opcode (reg_Op),
        .in1    (reg_A),
        .in2    (reg_B),
        .out    (alu_out),
        .zero   (alu_zero),
        .co     (alu_co)
    );

    assign led_o = {alu_co, alu_zero, alu_out};

endmodule