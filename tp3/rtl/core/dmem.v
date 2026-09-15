// =============================================================================
// Módulo:         dmem
//
// Descripción:
// Memoria de datos, con el mismo criterio de lectura asíncrona que imem.v
// (ver ese header) y, además, la lógica de alineación de bytes que pide
// RV32I: escritura enmascarada por byte/media palabra/palabra (sb/sh/sw) y
// lectura con extensión de signo o de cero según el ancho (lb/lh/lw/lbu/
// lhu), decodificado directo de 'funct3_i':
//
//   funct3   ancho      signo (solo lectura)
//   000      byte       con signo   (lb / sb)
//   001      media pal. con signo   (lh / sh)
//   010      palabra    -           (lw / sw)
//   100      byte       sin signo   (lbu)
//   101      media pal. sin signo   (lhu)
//
// La lectura es incondicional (no depende de mem_read_i): siempre expone
// la palabra en 'addr_i' ya recortada/extendida, y quien la usa (WB, vía
// mem_to_reg) simplemente la ignora cuando la instrucción no es un load.
// Evita un mux extra sin costar nada, mismo criterio que ya usa
// branch_unit.v con su target_pc_o.
//
// Mismo puerto de carga ('load_*') que imem.v, con el mismo propósito
// (Debug Unit en Fase 2, testbenches desde Fase 1): escribe una palabra
// CRUDA (sin máscara) en la dirección dada, para precargar datos antes de
// correr un programa. 'load_clear_i' barre una dirección por ciclo (no
// todas a la vez) por la misma razón documentada en imem.v: es lo que le
// permite a Vivado inferir distributed RAM en vez de flip-flops sueltos.
// 'clear_busy_o' avisa cuándo terminó el barrido.
//
// Puerto de lectura de debug ('dbg_*'), agregado en Fase 2: la Dump Unit
// necesita recorrer TODA la memoria palabra por palabra para volcarla por
// UART, sin pisar ni contender con el puerto que usa el pipeline en MEM.
// Es un tercer puerto de lectura, totalmente independiente y combinacional
// -- una memoria puede tener varios lectores simultáneos sin conflicto
// (el conflicto sólo existiría entre dos escritores, y acá el único
// escritor de verdad en un momento dado es 'load_en_i' o 'mem_write_i',
// nunca los dos a la vez). Devuelve la palabra cruda, sin el recorte ni la
// extensión de signo que sí aplica 'rdata_o' -- la Dump Unit quiere ver la
// memoria tal cual está, no como la vería una instrucción lb/lh puntual.
// =============================================================================
module dmem #(
    parameter DEPTH_WORDS = 1024
)(
    input  wire        clk_i,

    // --- Puerto del pipeline (MEM) ---
    input  wire [31:0] addr_i,
    input  wire [31:0] wdata_i,
    input  wire [2:0]  funct3_i,
    input  wire        mem_write_i,
    output wire [31:0] rdata_o,

    // --- Carga (Debug Unit / testbench) ---
    input  wire         load_en_i,
    input  wire [31:0]  load_addr_i,
    input  wire [31:0]  load_data_i,
    input  wire         load_clear_i,
    output wire          clear_busy_o,

    // --- Lectura de debug (Dump Unit) ---
    input  wire [31:0] dbg_addr_i,
    output wire [31:0] dbg_rdata_o
);

    localparam ADDR_BITS = $clog2(DEPTH_WORDS);

    reg [31:0] mem [0:DEPTH_WORDS-1];

    reg                 clearing;
    reg [ADDR_BITS-1:0] clear_addr;

    initial begin
        clearing   = 1'b0;
        clear_addr = {ADDR_BITS{1'b0}};
    end

    assign clear_busy_o = clearing;

    wire [ADDR_BITS-1:0] word_addr = addr_i[ADDR_BITS+1:2];
    wire [1:0]            byte_off  = addr_i[1:0];
    wire [31:0]            raw_word = mem[word_addr];

    // --- Lectura: recorte + extensión de signo/cero ---
    reg [31:0] rdata;
    always @(*) begin
        case (funct3_i)
            3'b000: begin // LB
                case (byte_off)
                    2'b00: rdata = {{24{raw_word[7]}},  raw_word[7:0]};
                    2'b01: rdata = {{24{raw_word[15]}}, raw_word[15:8]};
                    2'b10: rdata = {{24{raw_word[23]}}, raw_word[23:16]};
                    default: rdata = {{24{raw_word[31]}}, raw_word[31:24]};
                endcase
            end
            3'b001: begin // LH
                if (byte_off[1]) rdata = {{16{raw_word[31]}}, raw_word[31:16]};
                else              rdata = {{16{raw_word[15]}}, raw_word[15:0]};
            end
            3'b100: begin // LBU
                case (byte_off)
                    2'b00: rdata = {24'b0, raw_word[7:0]};
                    2'b01: rdata = {24'b0, raw_word[15:8]};
                    2'b10: rdata = {24'b0, raw_word[23:16]};
                    default: rdata = {24'b0, raw_word[31:24]};
                endcase
            end
            3'b101: begin // LHU
                if (byte_off[1]) rdata = {16'b0, raw_word[31:16]};
                else              rdata = {16'b0, raw_word[15:0]};
            end
            default: rdata = raw_word; // LW (funct3=010) y cualquier otro caso
        endcase
    end
    assign rdata_o = rdata;

    assign dbg_rdata_o = mem[dbg_addr_i[ADDR_BITS+1:2]];

    // --- Escritura: máscara de bytes segun funct3 ---
    always @(posedge clk_i) begin
        if (load_clear_i) begin
            clearing   <= 1'b1;
            clear_addr <= {ADDR_BITS{1'b0}};
        end
        else if (clearing) begin
            mem[clear_addr] <= 32'b0;
            clear_addr       <= clear_addr + 1'b1;
            if (clear_addr == DEPTH_WORDS-1) clearing <= 1'b0;
        end
        else if (load_en_i) begin
            mem[load_addr_i[ADDR_BITS+1:2]] <= load_data_i;
        end
        else if (mem_write_i) begin
            case (funct3_i)
                3'b000: begin // SB
                    case (byte_off)
                        2'b00: mem[word_addr][7:0]   <= wdata_i[7:0];
                        2'b01: mem[word_addr][15:8]  <= wdata_i[7:0];
                        2'b10: mem[word_addr][23:16] <= wdata_i[7:0];
                        2'b11: mem[word_addr][31:24] <= wdata_i[7:0];
                    endcase
                end
                3'b001: begin // SH
                    if (byte_off[1]) mem[word_addr][31:16] <= wdata_i[15:0];
                    else              mem[word_addr][15:0]  <= wdata_i[15:0];
                end
                default: begin // SW (funct3=010)
                    mem[word_addr] <= wdata_i;
                end
            endcase
        end
    end

endmodule
