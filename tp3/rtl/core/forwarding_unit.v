// =============================================================================
// Módulo:         forwarding_unit
//
// Descripción:
// Detecta dependencias RAW y decide, para cada operando, si hay que
// adelantar un valor que todavía no llegó al banco de registros. Cubre DOS
// puntos de adelantamiento distintos, ambos necesarios por haber elegido
// resolver los saltos en ID (Patterson 4.8):
//
//   - Hacia EX (el caso clásico de 4.7): los operandos de la ALU en EX
//     pueden venir del banco de registros, de EX/MEM o de MEM/WB.
//     Prioridad EX/MEM > MEM/WB (el productor más reciente gana).
//   - Hacia ID (necesario porque branch_unit compara ahí mismo): los
//     operandos del comparador de saltos pueden venir del banco de
//     registros, de la salida combinacional *actual* de EX (la instrucción
//     inmediatamente anterior al salto, si ya tiene un resultado listo
//     este mismo ciclo), de EX/MEM o de MEM/WB. Prioridad EX > EX/MEM >
//     MEM/WB.
//
// Importante: esta unidad decide DE DÓNDE viene el valor asumiendo que el
// valor ya está disponible. El caso en que NO está disponible todavía
// (un load inmediatamente antes de un branch/jalr, cuyo dato no está listo
// ni en EX ni en EX/MEM) no lo resuelve esta unidad -- lo detecta
// hazard_unit y fuerza un stall antes de que se llegue a usar el valor
// incorrecto de acá.
// =============================================================================
module forwarding_unit (
    // --- ID (fuente para branch_unit) ---
    input  wire [4:0] id_rs1_addr_i,
    input  wire [4:0] id_rs2_addr_i,

    // --- EX (instrucción ya latcheada en ID/EX) ---
    input  wire [4:0] id_ex_rs1_addr_i,
    input  wire [4:0] id_ex_rs2_addr_i,
    input  wire [4:0] id_ex_rd_addr_i,
    input  wire       id_ex_reg_write_i,

    // --- MEM (instrucción latcheada en EX/MEM) ---
    input  wire [4:0] ex_mem_rd_addr_i,
    input  wire       ex_mem_reg_write_i,

    // --- WB (instrucción latcheada en MEM/WB) ---
    input  wire [4:0] mem_wb_rd_addr_i,
    input  wire       mem_wb_reg_write_i,

    output reg  [1:0] forward_a_ex_o,
    output reg  [1:0] forward_b_ex_o,
    output reg  [1:0] forward_a_id_o,
    output reg  [1:0] forward_b_id_o
);

    localparam FWD_EX_NONE  = 2'b00; // banco de registros (valor ya en id_ex)
    localparam FWD_EX_EXMEM = 2'b01;
    localparam FWD_EX_MEMWB = 2'b10;

    localparam FWD_ID_NONE  = 2'b00; // banco de registros
    localparam FWD_ID_EX    = 2'b01; // salida combinacional actual de EX
    localparam FWD_ID_EXMEM = 2'b10;
    localparam FWD_ID_MEMWB = 2'b11;

    // --- Hacia EX ---
    always @(*) begin
        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs1_addr_i)
            forward_a_ex_o = FWD_EX_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_ex_rs1_addr_i)
            forward_a_ex_o = FWD_EX_MEMWB;
        else
            forward_a_ex_o = FWD_EX_NONE;
    end

    always @(*) begin
        if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_ex_rs2_addr_i)
            forward_b_ex_o = FWD_EX_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_ex_rs2_addr_i)
            forward_b_ex_o = FWD_EX_MEMWB;
        else
            forward_b_ex_o = FWD_EX_NONE;
    end

    // --- Hacia ID (branch_unit) ---
    always @(*) begin
        if (id_ex_reg_write_i && id_ex_rd_addr_i != 5'd0 && id_ex_rd_addr_i == id_rs1_addr_i)
            forward_a_id_o = FWD_ID_EX;
        else if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_rs1_addr_i)
            forward_a_id_o = FWD_ID_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_rs1_addr_i)
            forward_a_id_o = FWD_ID_MEMWB;
        else
            forward_a_id_o = FWD_ID_NONE;
    end

    always @(*) begin
        if (id_ex_reg_write_i && id_ex_rd_addr_i != 5'd0 && id_ex_rd_addr_i == id_rs2_addr_i)
            forward_b_id_o = FWD_ID_EX;
        else if (ex_mem_reg_write_i && ex_mem_rd_addr_i != 5'd0 && ex_mem_rd_addr_i == id_rs2_addr_i)
            forward_b_id_o = FWD_ID_EXMEM;
        else if (mem_wb_reg_write_i && mem_wb_rd_addr_i != 5'd0 && mem_wb_rd_addr_i == id_rs2_addr_i)
            forward_b_id_o = FWD_ID_MEMWB;
        else
            forward_b_id_o = FWD_ID_NONE;
    end

endmodule
