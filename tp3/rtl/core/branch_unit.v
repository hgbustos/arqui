// =============================================================================
// Módulo:         branch_unit
//
// Descripción:
// Resuelve TODOS los cambios de flujo (beq/bne/jal/jalr) en la etapa ID,
// en vez de en EX -- la optimización que describe el Patterson en 4.8
// (fig. 4.62) para bajar la penalización de salto tomado de 2 burbujas a 1.
// Es puramente combinacional: no sabe nada de forwarding ni de hazards,
// consume rs1_data_i/rs2_data_i ya resueltos (forwarding_unit decide, río
// arriba en riscv_core, si esos valores vienen del banco de registros o
// adelantados desde EX/MEM/WB) y devuelve si hay que redirigir el PC y
// hacia dónde.
//
//   - beq/bne: destino = PC + imm (imm ya viene en formato B de imm_gen).
//     Se toma si son iguales (funct3=000, beq) o distintos (funct3=001,
//     bne) -- 'funct3_i[0]' alcanza para distinguirlos.
//   - jal: siempre se toma, destino = PC + imm (formato J).
//   - jalr: siempre se toma, destino = (rs1 + imm) & ~1 (formato I; el bit
//     0 se fuerza a 0 por la propia definición de jalr en la especificación
//     RISC-V, aunque este diseño no soporta instrucciones de 16 bits/C
//     extension así que en la práctica los targets ya caen alineados a 4).
// =============================================================================
module branch_unit (
    input  wire [31:0] pc_i,
    input  wire [31:0] rs1_data_i,
    input  wire [31:0] rs2_data_i,
    input  wire [31:0] imm_i,
    input  wire [2:0]  funct3_i,
    input  wire        is_branch_i,
    input  wire        is_jal_i,
    input  wire        is_jalr_i,

    output wire        branch_taken_o,
    output wire [31:0] target_pc_o
);

    wire branch_condition = funct3_i[0] ? (rs1_data_i != rs2_data_i)
                                         : (rs1_data_i == rs2_data_i);

    assign branch_taken_o = is_jal_i | is_jalr_i | (is_branch_i & branch_condition);

    wire [31:0] pc_plus_imm   = pc_i + imm_i;
    wire [31:0] jalr_target   = (rs1_data_i + imm_i) & 32'hFFFFFFFE;

    assign target_pc_o = is_jalr_i ? jalr_target : pc_plus_imm;

endmodule
