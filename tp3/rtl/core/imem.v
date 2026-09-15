// =============================================================================
// Módulo:         imem
//
// Descripción:
// Memoria de instrucciones. Lectura ASÍNCRONA (combinacional) a propósito:
// con lectura sincrónica (la que Vivado preferiría inferir como Block RAM)
// se agrega un ciclo de latencia que no está en el modelo de 5 etapas del
// Patterson, y el datapath dejaría de calzar 1 a 1 con las figuras del
// libro. A esta profundidad (1024 palabras por defecto = 4KB) Vivado
// infiere 'distributed RAM' (LUTRAM) para lectura async, con costo
// marginal en la Artix-7 del Basys3 (~1-2% de LUTs) -- alternativa
// considerada y descartada, no pasada por alto (ver tp3/informe.md).
//
// Puerto de carga separado ('load_*'), pensado para la Debug Unit (TP3
// Fase 2) y ya usado desde Fase 1 por los testbenches de integración para
// inyectar programas de prueba sin pasar por UART. 'load_clear_i' vacía
// TODA la memoria: así, cualquier dirección más allá del último programa
// cargado queda en 0x00000000, que no es un opcode válido de RV32I -- es
// la mitad de la respuesta a "¿qué pasa si no hay HALT en memoria?" (la
// otra mitad es que control_unit trata ese opcode como halt implícito).
//
// El barrido de 'load_clear_i' escribe UNA dirección por ciclo (mismo
// puerto que ya usa load_en_i), no todas a la vez: un borrado de todas
// las direcciones en un solo ciclo es exactamente el patrón que le
// impide a Vivado inferir distributed RAM (una RAM real -- LUTRAM o
// Block RAM -- sólo puede escribir una dirección por ciclo), y obliga a
// sintetizar cada palabra como flip-flops sueltos más un mux gigante de
// lectura. Con esta versión, todo el módulo cae dentro del template de
// RAM de puerto único que Vivado sí sabe mapear a LUTRAM (ver
// tp3/informe.md §3.6). 'clear_busy_o' le indica a quien disparó el
// clear (debug_unit.v) cuándo terminó el barrido, para no empezar a
// cargar el programa nuevo mientras el clear todavía está en curso.
// =============================================================================
module imem #(
    parameter DEPTH_WORDS = 1024
)(
    input  wire        clk_i,

    // --- Lectura del pipeline (IF) ---
    input  wire [31:0] addr_i,
    output wire [31:0] instr_o,

    // --- Carga (Debug Unit / testbench) ---
    input  wire         load_en_i,
    input  wire [31:0]  load_addr_i,
    input  wire [31:0]  load_data_i,
    input  wire         load_clear_i,
    output wire          clear_busy_o
);

    localparam ADDR_BITS = $clog2(DEPTH_WORDS);

    reg [31:0] mem [0:DEPTH_WORDS-1];

    reg                 clearing;
    reg [ADDR_BITS-1:0] clear_addr;

    initial begin
        clearing   = 1'b0;
        clear_addr = {ADDR_BITS{1'b0}};
    end

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
    end

    assign clear_busy_o = clearing;
    assign instr_o = mem[addr_i[ADDR_BITS+1:2]];

endmodule
