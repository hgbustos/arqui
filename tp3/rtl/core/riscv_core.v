// =============================================================================
// Módulo:         riscv_core
//
// Descripción:
// Integra el datapath completo del pipeline de 5 etapas RV32I de TP3:
// IF -> IF/ID -> ID -> ID/EX -> EX -> EX/MEM -> MEM -> MEM/WB -> WB.
// Los saltos (beq/bne/jal/jalr) se resuelven enteramente en ID
// (branch_unit), con forwarding propio hacia esa etapa además del
// forwarding clásico hacia EX (forwarding_unit) -- ver tp3/informe.md para
// la justificación completa de esta decisión y de cada uno de los puntos
// de diseño abiertos que pide el enunciado.
//
// Todas las etapas que necesitan rs1/rs2/rd/funct3/funct7 los extraen con
// un slice combinacional de la 'instr' de 32 bits que viaja en el latch
// correspondiente, en vez de latchear copias separadas de esos campos: en
// RV32I esas posiciones son fijas sin importar el tipo de instrucción, así
// que no hace falta decodificar el formato antes de extraerlas (la misma
// razón por la que el propio ISA se diseñó así).
//
// Ningún stall/freeze/burbuja de este módulo (ni de hazard_unit, que es
// quien los decide) toca el clock: todo son enables síncronos sobre PC,
// IF/ID e ID/EX. 'global_stall_i' es la entrada de control externa (Debug
// Unit, TP3 Fase 2) para el modo paso a paso: combina con las razones
// internas de freeze de la misma manera (nunca gatea el clock tampoco).
//
// Puertos de carga separados hacia imem/dmem ('*_load_*'): pensados para
// la Debug Unit de Fase 2, y ya usados desde esta Fase 1 por
// tb_riscv_core.v para inyectar programas de prueba sin pasar por UART.
// =============================================================================
module riscv_core #(
    parameter IMEM_DEPTH_WORDS = 1024,
    parameter DMEM_DEPTH_WORDS = 1024
)(
    input  wire        clk_i,
    input  wire        rst_i,
    input  wire        global_stall_i,

    input  wire         imem_load_en_i,
    input  wire [31:0]  imem_load_addr_i,
    input  wire [31:0]  imem_load_data_i,
    input  wire         imem_load_clear_i,
    output wire          imem_load_clear_busy_o,

    input  wire         dmem_load_en_i,
    input  wire [31:0]  dmem_load_addr_i,
    input  wire [31:0]  dmem_load_data_i,
    input  wire         dmem_load_clear_i,
    output wire          dmem_load_clear_busy_o,

    // --- Lectura de debug de dmem (Dump Unit, Fase 2): puerto propio,
    // independiente del que usa el pipeline en MEM ---
    input  wire [31:0] dmem_dbg_addr_i,
    output wire [31:0] dmem_dbg_rdata_o,

    // --- Debug: banco de registros completo + estado de halt ---
    output wire [32*32-1:0] regs_flat_o,
    output wire              core_halted_o,
    output wire              branch_taken_o,
    output wire              pc_write_en_o,
    output wire [31:0]       cycle_count_o,

    // --- Debug: latch IF/ID ---
    output wire [31:0] if_id_pc_o,
    output wire [31:0] if_id_instr_o,

    // --- Debug: latch ID/EX ---
    output wire [31:0] id_ex_pc_o,
    output wire [31:0] id_ex_instr_o,
    output wire [31:0] id_ex_rs1_data_o,
    output wire [31:0] id_ex_rs2_data_o,
    output wire [31:0] id_ex_imm_o,
    output wire         id_ex_reg_write_o,
    output wire         id_ex_mem_read_o,
    output wire         id_ex_mem_write_o,
    output wire         id_ex_mem_to_reg_o,
    output wire         id_ex_is_jal_o,
    output wire         id_ex_is_jalr_o,
    output wire         id_ex_is_halt_o,

    // --- Debug: latch EX/MEM ---
    output wire [31:0] ex_mem_pc_o,
    output wire [31:0] ex_mem_instr_o,
    output wire [31:0] ex_mem_ex_result_o,
    output wire [31:0] ex_mem_rs2_data_o,
    output wire         ex_mem_reg_write_o,
    output wire         ex_mem_mem_read_o,
    output wire         ex_mem_mem_write_o,
    output wire         ex_mem_mem_to_reg_o,
    output wire         ex_mem_is_halt_o,

    // --- Debug: latch MEM/WB ---
    output wire [31:0] mem_wb_pc_o,
    output wire [31:0] mem_wb_instr_o,
    output wire [31:0] mem_wb_result_o,
    output wire [31:0] mem_wb_mem_read_data_o,
    output wire         mem_wb_reg_write_o,
    output wire         mem_wb_mem_to_reg_o,
    output wire         mem_wb_is_halt_o
);

    // =========================================================================
    // Declaraciones adelantadas: 'ex_result' y 'wb_write_data' se usan en el
    // mux de forwarding hacia ID (más arriba en el archivo que donde se
    // calculan de verdad, en EX y WB) -- en Verilog no importa el orden
    // textual de módulos/assigns combinacionales, pero se declaran acá para
    // que quede documentado de entrada que son señales compartidas entre
    // etapas no adyacentes.
    // =========================================================================
    wire [31:0] ex_result;      // salida de EX ya resuelta (ALU o PC+4 de jal/jalr)
    wire [31:0] wb_write_data;  // dato final que se escribe en WB

    // =========================================================================
    // IF
    // =========================================================================
    reg  [31:0] pc_reg;
    wire [31:0] pc_plus4 = pc_reg + 32'd4;
    wire        branch_taken;
    wire [31:0] branch_target;
    wire [31:0] pc_next = branch_taken ? branch_target : pc_plus4;

    wire hazard_pc_we, hazard_ifid_we, hazard_ifid_flush, hazard_idex_bubble;
    wire pc_write_en    = hazard_pc_we    & ~global_stall_i;
    wire if_id_write_en = hazard_ifid_we  & ~global_stall_i;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) pc_reg <= 32'b0;
        else if (pc_write_en) pc_reg <= pc_next;
    end

    // Ciclos transcurridos desde el ultimo reset/soft-reset (no desde el
    // power-on del FPGA): cuenta SIEMPRE que no haya reset, incluso
    // congelado (stall/halt) -- es "cuanto tardo esta ejecucion", el dato
    // util para la Debug Unit y para correlacionar con la frecuencia real
    // una vez cerrado el timing en Vivado (Fase 4).
    reg [31:0] cycle_count_reg;
    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) cycle_count_reg <= 32'b0;
        else       cycle_count_reg <= cycle_count_reg + 32'd1;
    end
    assign cycle_count_o = cycle_count_reg;

    wire [31:0] imem_instr;
    imem #(.DEPTH_WORDS(IMEM_DEPTH_WORDS)) u_imem (
        .clk_i       (clk_i),
        .addr_i      (pc_reg),
        .instr_o     (imem_instr),
        .load_en_i   (imem_load_en_i),
        .load_addr_i (imem_load_addr_i),
        .load_data_i (imem_load_data_i),
        .load_clear_i(imem_load_clear_i),
        .clear_busy_o(imem_load_clear_busy_o)
    );

    // =========================================================================
    // IF/ID
    // =========================================================================
    wire [31:0] if_id_pc, if_id_instr;

    if_id_reg u_if_id (
        .clk_i     (clk_i),
        .rst_i     (rst_i),
        .write_en_i(if_id_write_en),
        .flush_i   (hazard_ifid_flush),
        .pc_i      (pc_reg),
        .instr_i   (imem_instr),
        .pc_o      (if_id_pc),
        .instr_o   (if_id_instr)
    );

    // =========================================================================
    // ID
    // =========================================================================
    wire [6:0] id_opcode    = if_id_instr[6:0];
    wire [4:0] id_rs1_addr  = if_id_instr[19:15];
    wire [4:0] id_rs2_addr  = if_id_instr[24:20];
    wire [2:0] id_funct3    = if_id_instr[14:12];

    wire id_reg_write, id_alu_src_a, id_alu_src_b, id_mem_read, id_mem_write,
         id_mem_to_reg, id_is_jal, id_is_jalr, id_is_branch, id_is_halt;
    wire [1:0] id_alu_op;
    wire [2:0] id_imm_sel;

    control_unit u_control (
        .opcode_i    (id_opcode),
        .reg_write_o (id_reg_write),
        .alu_src_a_o (id_alu_src_a),
        .alu_src_b_o (id_alu_src_b),
        .alu_op_o    (id_alu_op),
        .mem_read_o  (id_mem_read),
        .mem_write_o (id_mem_write),
        .mem_to_reg_o(id_mem_to_reg),
        .is_jal_o    (id_is_jal),
        .is_jalr_o   (id_is_jalr),
        .is_branch_o (id_is_branch),
        .is_halt_o   (id_is_halt),
        .imm_sel_o   (id_imm_sel)
    );

    wire [31:0] id_rs1_data_raw, id_rs2_data_raw;

    register_file u_regfile (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .rs1_addr_i (id_rs1_addr),
        .rs2_addr_i (id_rs2_addr),
        .rs1_data_o (id_rs1_data_raw),
        .rs2_data_o (id_rs2_data_raw),
        .rd_addr_i  (mem_wb_rd_addr),
        .rd_data_i  (wb_write_data),
        .reg_write_i(mem_wb_reg_write),
        .regs_flat_o(regs_flat_o)
    );

    wire [31:0] id_imm;
    imm_gen u_imm_gen (
        .instr_i  (if_id_instr),
        .imm_sel_i(id_imm_sel),
        .imm_o    (id_imm)
    );

    // --- Forwarding hacia ID (para branch_unit) ---
    wire [1:0] fwd_a_ex, fwd_b_ex, fwd_a_id, fwd_b_id;

    reg [31:0] id_rs1_fwd, id_rs2_fwd;
    always @(*) begin
        case (fwd_a_id)
            2'b01:   id_rs1_fwd = ex_result;
            2'b10:   id_rs1_fwd = ex_mem_ex_result;
            2'b11:   id_rs1_fwd = wb_write_data;
            default: id_rs1_fwd = id_rs1_data_raw;
        endcase
    end
    always @(*) begin
        case (fwd_b_id)
            2'b01:   id_rs2_fwd = ex_result;
            2'b10:   id_rs2_fwd = ex_mem_ex_result;
            2'b11:   id_rs2_fwd = wb_write_data;
            default: id_rs2_fwd = id_rs2_data_raw;
        endcase
    end

    branch_unit u_branch (
        .pc_i          (if_id_pc),
        .rs1_data_i    (id_rs1_fwd),
        .rs2_data_i    (id_rs2_fwd),
        .imm_i         (id_imm),
        .funct3_i      (id_funct3),
        .is_branch_i   (id_is_branch),
        .is_jal_i      (id_is_jal),
        .is_jalr_i     (id_is_jalr),
        .branch_taken_o(branch_taken),
        .target_pc_o   (branch_target)
    );

    assign branch_taken_o = branch_taken;
    assign pc_write_en_o  = pc_write_en;

    hazard_unit u_hazard (
        .id_rs1_addr_i    (id_rs1_addr),
        .id_rs2_addr_i    (id_rs2_addr),
        .id_is_branch_i   (id_is_branch),
        .id_is_jalr_i     (id_is_jalr),
        .id_is_halt_i     (id_is_halt),
        .id_ex_rd_addr_i  (id_ex_rd_addr),
        .id_ex_mem_read_i (id_ex_mem_read),
        .ex_mem_rd_addr_i (ex_mem_rd_addr),
        .ex_mem_mem_read_i(ex_mem_mem_read),
        .branch_taken_i   (branch_taken),
        .pc_write_en_o    (hazard_pc_we),
        .if_id_write_en_o (hazard_ifid_we),
        .if_id_flush_o    (hazard_ifid_flush),
        .id_ex_bubble_o   (hazard_idex_bubble)
    );

    // =========================================================================
    // ID/EX
    // =========================================================================
    wire [31:0] id_ex_pc, id_ex_rs1_data, id_ex_rs2_data, id_ex_imm, id_ex_instr;
    wire id_ex_reg_write, id_ex_alu_src_a, id_ex_alu_src_b, id_ex_mem_read,
         id_ex_mem_write, id_ex_mem_to_reg, id_ex_is_jal, id_ex_is_jalr, id_ex_is_halt;
    wire [1:0] id_ex_alu_op;

    id_ex_reg u_id_ex (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .bubble_i    (hazard_idex_bubble),
        .pc_i        (if_id_pc),
        .rs1_data_i  (id_rs1_data_raw),
        .rs2_data_i  (id_rs2_data_raw),
        .imm_i       (id_imm),
        .instr_i     (if_id_instr),
        .reg_write_i (id_reg_write),
        .alu_src_a_i (id_alu_src_a),
        .alu_src_b_i (id_alu_src_b),
        .alu_op_i    (id_alu_op),
        .mem_read_i  (id_mem_read),
        .mem_write_i (id_mem_write),
        .mem_to_reg_i(id_mem_to_reg),
        .is_jal_i    (id_is_jal),
        .is_jalr_i   (id_is_jalr),
        .is_halt_i   (id_is_halt),
        .pc_o        (id_ex_pc),
        .rs1_data_o  (id_ex_rs1_data),
        .rs2_data_o  (id_ex_rs2_data),
        .imm_o       (id_ex_imm),
        .instr_o     (id_ex_instr),
        .reg_write_o (id_ex_reg_write),
        .alu_src_a_o (id_ex_alu_src_a),
        .alu_src_b_o (id_ex_alu_src_b),
        .alu_op_o    (id_ex_alu_op),
        .mem_read_o  (id_ex_mem_read),
        .mem_write_o (id_ex_mem_write),
        .mem_to_reg_o(id_ex_mem_to_reg),
        .is_jal_o    (id_ex_is_jal),
        .is_jalr_o   (id_ex_is_jalr),
        .is_halt_o   (id_ex_is_halt)
    );

    // =========================================================================
    // EX
    // =========================================================================
    wire [4:0] id_ex_rs1_addr  = id_ex_instr[19:15];
    wire [4:0] id_ex_rs2_addr  = id_ex_instr[24:20];
    wire [4:0] id_ex_rd_addr   = id_ex_instr[11:7];
    wire [2:0] id_ex_funct3    = id_ex_instr[14:12];
    wire       id_ex_funct7_b5 = id_ex_instr[30];

    forwarding_unit u_forwarding (
        .id_rs1_addr_i      (id_rs1_addr),
        .id_rs2_addr_i      (id_rs2_addr),
        .id_ex_rs1_addr_i   (id_ex_rs1_addr),
        .id_ex_rs2_addr_i   (id_ex_rs2_addr),
        .id_ex_rd_addr_i    (id_ex_rd_addr),
        .id_ex_reg_write_i  (id_ex_reg_write),
        .ex_mem_rd_addr_i   (ex_mem_rd_addr),
        .ex_mem_reg_write_i (ex_mem_reg_write),
        .mem_wb_rd_addr_i   (mem_wb_rd_addr),
        .mem_wb_reg_write_i (mem_wb_reg_write),
        .forward_a_ex_o     (fwd_a_ex),
        .forward_b_ex_o     (fwd_b_ex),
        .forward_a_id_o     (fwd_a_id),
        .forward_b_id_o     (fwd_b_id)
    );

    reg [31:0] ex_rs1_fwd, ex_rs2_fwd;
    always @(*) begin
        case (fwd_a_ex)
            2'b01:   ex_rs1_fwd = ex_mem_ex_result;
            2'b10:   ex_rs1_fwd = wb_write_data;
            default: ex_rs1_fwd = id_ex_rs1_data;
        endcase
    end
    always @(*) begin
        case (fwd_b_ex)
            2'b01:   ex_rs2_fwd = ex_mem_ex_result;
            2'b10:   ex_rs2_fwd = wb_write_data;
            default: ex_rs2_fwd = id_ex_rs2_data;
        endcase
    end

    wire [31:0] alu_operand_a = id_ex_alu_src_a ? 32'b0 : ex_rs1_fwd;
    wire [31:0] alu_operand_b = id_ex_alu_src_b ? id_ex_imm : ex_rs2_fwd;

    wire [5:0] alu_ctrl;
    alu_control u_alu_control (
        .alu_op_i     (id_ex_alu_op),
        .funct3_i     (id_ex_funct3),
        .funct7_bit5_i(id_ex_funct7_b5),
        .alu_ctrl_o   (alu_ctrl)
    );

    // --- Deben coincidir con tp1/ALU.v: enmascarado del shift amount a los
    // 5 bits bajos que exige RV32I. Responsabilidad de quien instancia la
    // ALU genérica (acá), no de tp1/ALU.v (ver ese archivo). ---
    localparam OP_SLL = 6'b000001;
    localparam OP_SRL = 6'b000010;
    localparam OP_SRA = 6'b000011;
    wire is_shift_op = (alu_ctrl == OP_SLL) || (alu_ctrl == OP_SRL) || (alu_ctrl == OP_SRA);
    wire [31:0] alu_operand_b_final = is_shift_op ? {27'b0, alu_operand_b[4:0]} : alu_operand_b;

    wire [31:0] alu_result;
    wire        alu_zero_unused, alu_co_unused; // no se usan: los saltos se resuelven en ID (branch_unit)

    ALU #(.N(32)) u_alu (
        .opcode(alu_ctrl),
        .in1   (alu_operand_a),
        .in2   (alu_operand_b_final),
        .out   (alu_result),
        .zero  (alu_zero_unused),
        .co    (alu_co_unused)
    );

    // --- jal/jalr: el resultado que viaja a EX/MEM es PC+4 (valor de
    // enlace), no la salida de la ALU. ---
    wire [31:0] ex_link_value = id_ex_pc + 32'd4;
    assign ex_result = (id_ex_is_jal | id_ex_is_jalr) ? ex_link_value : alu_result;

    // =========================================================================
    // EX/MEM
    // =========================================================================
    wire [31:0] ex_mem_pc, ex_mem_ex_result, ex_mem_rs2_data, ex_mem_instr;
    wire ex_mem_reg_write, ex_mem_mem_read, ex_mem_mem_write, ex_mem_mem_to_reg, ex_mem_is_halt;

    ex_mem_reg u_ex_mem (
        .clk_i       (clk_i),
        .rst_i       (rst_i),
        .pc_i        (id_ex_pc),
        .ex_result_i (ex_result),
        .rs2_data_i  (ex_rs2_fwd),
        .instr_i     (id_ex_instr),
        .reg_write_i (id_ex_reg_write),
        .mem_read_i  (id_ex_mem_read),
        .mem_write_i (id_ex_mem_write),
        .mem_to_reg_i(id_ex_mem_to_reg),
        .is_halt_i   (id_ex_is_halt),
        .pc_o        (ex_mem_pc),
        .ex_result_o (ex_mem_ex_result),
        .rs2_data_o  (ex_mem_rs2_data),
        .instr_o     (ex_mem_instr),
        .reg_write_o (ex_mem_reg_write),
        .mem_read_o  (ex_mem_mem_read),
        .mem_write_o (ex_mem_mem_write),
        .mem_to_reg_o(ex_mem_mem_to_reg),
        .is_halt_o   (ex_mem_is_halt)
    );

    // =========================================================================
    // MEM
    // =========================================================================
    wire [4:0] ex_mem_rd_addr = ex_mem_instr[11:7];
    wire [2:0] ex_mem_funct3  = ex_mem_instr[14:12];

    wire [31:0] dmem_rdata;
    dmem #(.DEPTH_WORDS(DMEM_DEPTH_WORDS)) u_dmem (
        .clk_i       (clk_i),
        .addr_i      (ex_mem_ex_result),
        .wdata_i     (ex_mem_rs2_data),
        .funct3_i    (ex_mem_funct3),
        .mem_write_i (ex_mem_mem_write),
        .rdata_o     (dmem_rdata),
        .load_en_i   (dmem_load_en_i),
        .load_addr_i (dmem_load_addr_i),
        .load_data_i (dmem_load_data_i),
        .load_clear_i(dmem_load_clear_i),
        .clear_busy_o(dmem_load_clear_busy_o),
        .dbg_addr_i  (dmem_dbg_addr_i),
        .dbg_rdata_o (dmem_dbg_rdata_o)
    );

    // =========================================================================
    // MEM/WB
    // =========================================================================
    wire [31:0] mem_wb_pc, mem_wb_result, mem_wb_mem_read_data, mem_wb_instr;
    wire mem_wb_reg_write, mem_wb_mem_to_reg, mem_wb_is_halt;

    mem_wb_reg u_mem_wb (
        .clk_i          (clk_i),
        .rst_i          (rst_i),
        .pc_i           (ex_mem_pc),
        .result_i       (ex_mem_ex_result),
        .mem_read_data_i(dmem_rdata),
        .instr_i        (ex_mem_instr),
        .reg_write_i    (ex_mem_reg_write),
        .mem_to_reg_i   (ex_mem_mem_to_reg),
        .is_halt_i      (ex_mem_is_halt),
        .pc_o           (mem_wb_pc),
        .result_o       (mem_wb_result),
        .mem_read_data_o(mem_wb_mem_read_data),
        .instr_o        (mem_wb_instr),
        .reg_write_o    (mem_wb_reg_write),
        .mem_to_reg_o   (mem_wb_mem_to_reg),
        .is_halt_o      (mem_wb_is_halt)
    );

    // =========================================================================
    // WB
    // =========================================================================
    wire [4:0] mem_wb_rd_addr = mem_wb_instr[11:7];
    assign wb_write_data = mem_wb_mem_to_reg ? mem_wb_mem_read_data : mem_wb_result;
    assign core_halted_o = mem_wb_is_halt;

    // =========================================================================
    // Salidas de debug (una por campo latcheado, ver header)
    // =========================================================================
    assign if_id_pc_o    = if_id_pc;
    assign if_id_instr_o = if_id_instr;

    assign id_ex_pc_o         = id_ex_pc;
    assign id_ex_instr_o      = id_ex_instr;
    assign id_ex_rs1_data_o   = id_ex_rs1_data;
    assign id_ex_rs2_data_o   = id_ex_rs2_data;
    assign id_ex_imm_o        = id_ex_imm;
    assign id_ex_reg_write_o  = id_ex_reg_write;
    assign id_ex_mem_read_o   = id_ex_mem_read;
    assign id_ex_mem_write_o  = id_ex_mem_write;
    assign id_ex_mem_to_reg_o = id_ex_mem_to_reg;
    assign id_ex_is_jal_o     = id_ex_is_jal;
    assign id_ex_is_jalr_o    = id_ex_is_jalr;
    assign id_ex_is_halt_o    = id_ex_is_halt;

    assign ex_mem_pc_o         = ex_mem_pc;
    assign ex_mem_instr_o      = ex_mem_instr;
    assign ex_mem_ex_result_o  = ex_mem_ex_result;
    assign ex_mem_rs2_data_o   = ex_mem_rs2_data;
    assign ex_mem_reg_write_o  = ex_mem_reg_write;
    assign ex_mem_mem_read_o   = ex_mem_mem_read;
    assign ex_mem_mem_write_o  = ex_mem_mem_write;
    assign ex_mem_mem_to_reg_o = ex_mem_mem_to_reg;
    assign ex_mem_is_halt_o    = ex_mem_is_halt;

    assign mem_wb_pc_o             = mem_wb_pc;
    assign mem_wb_instr_o          = mem_wb_instr;
    assign mem_wb_result_o         = mem_wb_result;
    assign mem_wb_mem_read_data_o  = mem_wb_mem_read_data;
    assign mem_wb_reg_write_o      = mem_wb_reg_write;
    assign mem_wb_mem_to_reg_o     = mem_wb_mem_to_reg;
    assign mem_wb_is_halt_o        = mem_wb_is_halt;

endmodule
