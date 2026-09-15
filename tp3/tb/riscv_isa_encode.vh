// =============================================================================
// Archivo:        riscv_isa_encode.vh
//
// Descripción:
// Funciones de codificación RV32I para armar programas de prueba legibles
// en los testbenches de integración (tb_riscv_core.v y, más adelante,
// tb_riscv_uart_top.v) sin escribir literales de 32 bits a mano -- mismo
// espíritu que ya usaron tb_imm_gen.v/tb_control_unit.v armando
// instrucciones por campos nombrados, extendido acá a un encoder completo
// del subset de RV32I que pide el enunciado de TP3 (R/I/S/B/U/J + HALT
// propia). Se incluye con `include desde cada testbench que lo necesite;
// no es un módulo, son sólo funciones de encoding puramente combinacional.
//
// Los valores de opcode/funct3/funct7 tienen que coincidir con
// tp3/rtl/core/control_unit.v y tp3/rtl/core/alu_control.v -- están
// duplicados a propósito (no hay un mecanismo de import de constantes
// entre Verilog y este archivo de testbench) y deben mantenerse en sync.
// =============================================================================

// --- Formatos base ---
function [31:0] enc_r;
    input [6:0] funct7;
    input [4:0] rs2;
    input [4:0] rs1;
    input [2:0] funct3;
    input [4:0] rd;
    input [6:0] opcode;
    enc_r = {funct7, rs2, rs1, funct3, rd, opcode};
endfunction

function [31:0] enc_i;
    input [11:0] imm;
    input [4:0]  rs1;
    input [2:0]  funct3;
    input [4:0]  rd;
    input [6:0]  opcode;
    enc_i = {imm, rs1, funct3, rd, opcode};
endfunction

function [31:0] enc_s;
    input [11:0] imm;
    input [4:0]  rs2;
    input [4:0]  rs1;
    input [2:0]  funct3;
    input [6:0]  opcode;
    enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
endfunction

function [31:0] enc_b;
    input [12:0] imm; // imm[0] siempre 0 (offsets de branch son pares)
    input [4:0]  rs2;
    input [4:0]  rs1;
    input [2:0]  funct3;
    input [6:0]  opcode;
    enc_b = {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
endfunction

function [31:0] enc_u;
    input [19:0] imm20;
    input [4:0]  rd;
    input [6:0]  opcode;
    enc_u = {imm20, rd, opcode};
endfunction

function [31:0] enc_j;
    input [20:0] imm; // imm[0] siempre 0
    input [4:0]  rd;
    input [6:0]  opcode;
    enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
endfunction

// --- R-type (opcode 0110011) ---
function [31:0] i_add;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_add  = enc_r(7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011); endfunction
function [31:0] i_sub;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_sub  = enc_r(7'b0100000, rs2, rs1, 3'b000, rd, 7'b0110011); endfunction
function [31:0] i_sll;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_sll  = enc_r(7'b0000000, rs2, rs1, 3'b001, rd, 7'b0110011); endfunction
function [31:0] i_slt;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_slt  = enc_r(7'b0000000, rs2, rs1, 3'b010, rd, 7'b0110011); endfunction
function [31:0] i_sltu; input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_sltu = enc_r(7'b0000000, rs2, rs1, 3'b011, rd, 7'b0110011); endfunction
function [31:0] i_xor;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_xor  = enc_r(7'b0000000, rs2, rs1, 3'b100, rd, 7'b0110011); endfunction
function [31:0] i_srl;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_srl  = enc_r(7'b0000000, rs2, rs1, 3'b101, rd, 7'b0110011); endfunction
function [31:0] i_sra;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_sra  = enc_r(7'b0100000, rs2, rs1, 3'b101, rd, 7'b0110011); endfunction
function [31:0] i_or;   input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_or   = enc_r(7'b0000000, rs2, rs1, 3'b110, rd, 7'b0110011); endfunction
function [31:0] i_and;  input [4:0] rd; input [4:0] rs1; input [4:0] rs2;
    i_and  = enc_r(7'b0000000, rs2, rs1, 3'b111, rd, 7'b0110011); endfunction

// --- I-type aritmético (opcode 0010011) ---
function [31:0] i_addi;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_addi  = enc_i(imm, rs1, 3'b000, rd, 7'b0010011); endfunction
function [31:0] i_slti;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_slti  = enc_i(imm, rs1, 3'b010, rd, 7'b0010011); endfunction
function [31:0] i_sltiu; input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_sltiu = enc_i(imm, rs1, 3'b011, rd, 7'b0010011); endfunction
function [31:0] i_xori;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_xori  = enc_i(imm, rs1, 3'b100, rd, 7'b0010011); endfunction
function [31:0] i_ori;   input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_ori   = enc_i(imm, rs1, 3'b110, rd, 7'b0010011); endfunction
function [31:0] i_andi;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_andi  = enc_i(imm, rs1, 3'b111, rd, 7'b0010011); endfunction
function [31:0] i_slli;  input [4:0] rd; input [4:0] rs1; input [4:0] shamt;
    i_slli  = enc_i({7'b0000000, shamt}, rs1, 3'b001, rd, 7'b0010011); endfunction
function [31:0] i_srli;  input [4:0] rd; input [4:0] rs1; input [4:0] shamt;
    i_srli  = enc_i({7'b0000000, shamt}, rs1, 3'b101, rd, 7'b0010011); endfunction
function [31:0] i_srai;  input [4:0] rd; input [4:0] rs1; input [4:0] shamt;
    i_srai  = enc_i({7'b0100000, shamt}, rs1, 3'b101, rd, 7'b0010011); endfunction

// --- I-type loads (opcode 0000011) ---
function [31:0] i_lb;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_lb  = enc_i(imm, rs1, 3'b000, rd, 7'b0000011); endfunction
function [31:0] i_lh;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_lh  = enc_i(imm, rs1, 3'b001, rd, 7'b0000011); endfunction
function [31:0] i_lw;  input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_lw  = enc_i(imm, rs1, 3'b010, rd, 7'b0000011); endfunction
function [31:0] i_lbu; input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_lbu = enc_i(imm, rs1, 3'b100, rd, 7'b0000011); endfunction
function [31:0] i_lhu; input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_lhu = enc_i(imm, rs1, 3'b101, rd, 7'b0000011); endfunction

// --- jalr (opcode 1100111) ---
function [31:0] i_jalr; input [4:0] rd; input [4:0] rs1; input [11:0] imm;
    i_jalr = enc_i(imm, rs1, 3'b000, rd, 7'b1100111); endfunction

// --- S-type (opcode 0100011) ---
function [31:0] i_sb; input [4:0] rs1; input [4:0] rs2; input [11:0] imm;
    i_sb = enc_s(imm, rs2, rs1, 3'b000, 7'b0100011); endfunction
function [31:0] i_sh; input [4:0] rs1; input [4:0] rs2; input [11:0] imm;
    i_sh = enc_s(imm, rs2, rs1, 3'b001, 7'b0100011); endfunction
function [31:0] i_sw; input [4:0] rs1; input [4:0] rs2; input [11:0] imm;
    i_sw = enc_s(imm, rs2, rs1, 3'b010, 7'b0100011); endfunction

// --- B-type (opcode 1100011) ---
function [31:0] i_beq; input [4:0] rs1; input [4:0] rs2; input [12:0] imm;
    i_beq = enc_b(imm, rs2, rs1, 3'b000, 7'b1100011); endfunction
function [31:0] i_bne; input [4:0] rs1; input [4:0] rs2; input [12:0] imm;
    i_bne = enc_b(imm, rs2, rs1, 3'b001, 7'b1100011); endfunction

// --- U-type (opcode 0110111) ---
function [31:0] i_lui; input [4:0] rd; input [19:0] imm20;
    i_lui = enc_u(imm20, rd, 7'b0110111); endfunction

// --- J-type (opcode 1101111) ---
function [31:0] i_jal; input [4:0] rd; input [20:0] imm;
    i_jal = enc_j(imm, rd, 7'b1101111); endfunction

// --- HALT propia (custom-0, opcode 0001011) ---
function [31:0] i_halt; input dummy;
    i_halt = {25'b0, 7'b0001011}; endfunction

// --- NOP real de RV32I (addi x0,x0,0), útil para rellenar delay slots
// en los tests o para dejar explícito un hueco en el programa ---
function [31:0] i_nop; input dummy;
    i_nop = 32'h00000013; endfunction
