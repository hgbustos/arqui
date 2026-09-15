// =============================================================================
// Módulo:         register_file
//
// Descripción:
// Banco de 32 registros de 32 bits (x0-x31) de RV32I. x0 está cableado a
// cero: se puede "escribir" (no genera error, la etapa WB no necesita saber
// que rd=0 es especial) pero el valor leído siempre es 0. Dos puertos de
// lectura asíncronos (rs1/rs2, los que necesita la etapa ID en el mismo
// ciclo) y un puerto de escritura síncrono (WB, flanco de subida).
//
// Bypass de escritura-a-lectura en el mismo ciclo: si en el mismo ciclo se
// está escribiendo 'rd_addr_i' y se está leyendo esa misma dirección por
// rs1/rs2, la lectura devuelve 'rd_data_i' directo (no el valor viejo
// todavía guardado en el array). Es la misma técnica que describe el
// Patterson para el banco de registros (WB escribe en la primera mitad del
// ciclo, ID lee en la segunda) y hace falta por una razón concreta: ni el
// forwarding hacia EX ni el forwarding hacia ID (forwarding_unit.v) pueden
// cubrir a un productor que quedó exactamente 3 instrucciones antes de su
// consumidor -- para ese momento el productor ya salió de EX/MEM y de
// MEM/WB (los únicos puntos donde forwarding_unit todavía lo puede
// interceptar), pero recién se está escribiendo en el banco de registros
// en este mismo ciclo. Sin este bypass, ese caso puntual (ni forwarding ni
// "ya escrito de antes") leería el valor viejo. Se encontró exactamente
// este bug integrando riscv_core.v (ver tp3/informe.md).
//
// Expone además los 32 registros como un bus plano de 32*32 bits para la
// Debug Unit (TP3 dump completo por UART, ver informe): es la forma
// portable de sacar un arreglo por un puerto en Verilog-2001 plano (sin
// arrays sin empaquetar en el puerto), indexable con el operador de
// part-select indexado 'bus[32*i +: 32]' tanto acá como del lado que lo
// consume.
// =============================================================================
module register_file (
    input  wire        clk_i,
    input  wire        rst_i,

    input  wire [4:0]  rs1_addr_i,
    input  wire [4:0]  rs2_addr_i,
    output wire [31:0] rs1_data_o,
    output wire [31:0] rs2_data_o,

    input  wire [4:0]  rd_addr_i,
    input  wire [31:0] rd_data_i,
    input  wire        reg_write_i,

    output wire [32*32-1:0] regs_flat_o // debug: x0 en [31:0], x1 en [63:32], ..., x31 en [1023:992]
);

    reg [31:0] regs [0:31];
    integer i;

    always @(posedge clk_i, posedge rst_i) begin
        if (rst_i) begin
            for (i = 0; i < 32; i = i + 1) begin
                regs[i] <= 32'b0;
            end
        end
        else if (reg_write_i && (rd_addr_i != 5'd0)) begin
            regs[rd_addr_i] <= rd_data_i;
        end
    end

    wire bypass_rs1 = reg_write_i && (rd_addr_i != 5'd0) && (rd_addr_i == rs1_addr_i);
    wire bypass_rs2 = reg_write_i && (rd_addr_i != 5'd0) && (rd_addr_i == rs2_addr_i);

    // x0 forzado a 0 también en lectura: nunca depende únicamente de que
    // nadie lo haya escrito (robustez extra, aunque reg_write_i ya lo
    // protege del lado de escritura).
    assign rs1_data_o = (rs1_addr_i == 5'd0) ? 32'b0 :
                         bypass_rs1           ? rd_data_i :
                                                 regs[rs1_addr_i];
    assign rs2_data_o = (rs2_addr_i == 5'd0) ? 32'b0 :
                         bypass_rs2           ? rd_data_i :
                                                 regs[rs2_addr_i];

    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_regs_flat
            assign regs_flat_o[32*g +: 32] = (g == 0) ? 32'b0 : regs[g];
        end
    endgenerate

endmodule
