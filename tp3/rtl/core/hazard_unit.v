// =============================================================================
// Módulo:         hazard_unit
//
// Descripción:
// Dueño de todas las señales de stall/flush/bubble del pipeline. Nunca
// toca el clock (ni acá ni en ningún lado del proyecto): todo se resuelve
// con enables síncronos sobre PC e IF/ID, y una burbuja (NOP forzado)
// hacia ID/EX. Cubre tres motivos de frenado:
//
//   1) Load-use clásico (Patterson 4.7): un consumidor genérico en ID
//      necesita el resultado de un load que todavía está en EX. Se
//      compara sólo contra los registros que la instrucción en ID LEE de
//      verdad ('id_uses_rs1_i'/'id_uses_rs2_i', de control_unit): los
//      campos rs1/rs2 existen en toda instrucción, pero en un I-type los
//      bits de rs2 son parte del inmediato (y en lui/jal, los de rs1
//      también). Sin ese filtro, 'lw x5,0(x0)' seguido de
//      'addi x6,x2,5' frenaba un ciclo sin ninguna dependencia real
//      (imm[4:0]=5 coincide con rd=x5) -- el resultado igual era
//      correcto, pero el ciclo de más se veía en CYCLE_COUNT y en el modo
//      paso a paso.
//
//   2) Load justo antes de un branch/jalr -- propio de haber elegido
//      resolver saltos en ID (ver tp3/informe.md). Ni el forwarding desde
//      EX (la ALU todavía no tiene el dato, es un load) ni desde EX/MEM
//      (ese latch, para un load, sólo tiene la DIRECCIÓN; el dato recién
//      está al final de MEM) llegan a tiempo. Por eso se chequea tanto
//      "el load está en EX" (mismo caso que (1)) como "el load está en
//      MEM" (un lugar más atrás en el programa): se re-evalúa cada ciclo,
//      así que si el load sigue en vuelo se lo sigue frenando, hasta que
//      su dato ya esté en MEM/WB -- ahí lo toma forwarding_unit con
//      prioridad 3 y el salto se libera.
//
//   3) Halt (explícito o implícito): frena la búsqueda de instrucciones
//      NUEVAS apenas se decodifica -- no hace falta esperar a que llegue
//      a WB para esto, las instrucciones más viejas que ya estaban en
//      EX/MEM/WB en ese momento no se ven afectadas, siguen drenando
//      solas (por eso no corta nada "en vuelo"). Lo que retiene el HALT
//      es IF/ID congelado: el PC queda en HALT+4 (la instrucción
//      siguiente, que se busca pero nunca entra a IF/ID), y el HALT se
//      sigue decodificando en ID cada ciclo, así que la condición se
//      auto-sostiene sin necesitar un latch aparte. Como ID/EX sí avanza,
//      cada ciclo entra a EX una nueva copia del HALT: es justo lo que
//      hace que la flag de halt termine viéndose en todas las etapas
//      más tarde. A diferencia de (1)/(2),
//      acá NUNCA se burbujea ID/EX: hace falta que la propia instrucción
//      de halt (con sus señales de control ya inertes, ver
//      control_unit.v) fluya de verdad hasta WB, porque eso es lo que la
//      Debug Unit mira para saber que el pipeline drenó por completo.
// =============================================================================
module hazard_unit (
    input  wire [4:0] id_rs1_addr_i,
    input  wire [4:0] id_rs2_addr_i,
    input  wire       id_uses_rs1_i,
    input  wire       id_uses_rs2_i,
    input  wire       id_is_branch_i,
    input  wire       id_is_jalr_i,
    input  wire       id_is_halt_i,

    input  wire [4:0] id_ex_rd_addr_i,
    input  wire       id_ex_mem_read_i,

    input  wire [4:0] ex_mem_rd_addr_i,
    input  wire       ex_mem_mem_read_i,

    input  wire       branch_taken_i,

    output wire        pc_write_en_o,
    output wire        if_id_write_en_o,
    output wire        if_id_flush_o,
    output wire        id_ex_bubble_o
);

    wire load_use_hazard =
        id_ex_mem_read_i && (id_ex_rd_addr_i != 5'd0) &&
        ((id_uses_rs1_i && id_ex_rd_addr_i == id_rs1_addr_i) ||
         (id_uses_rs2_i && id_ex_rd_addr_i == id_rs2_addr_i));

    wire load_before_branch_mem =
        ex_mem_mem_read_i && (ex_mem_rd_addr_i != 5'd0) &&
        ((id_uses_rs1_i && ex_mem_rd_addr_i == id_rs1_addr_i) ||
         (id_uses_rs2_i && ex_mem_rd_addr_i == id_rs2_addr_i));

    wire load_before_branch_hazard =
        (id_is_branch_i || id_is_jalr_i) && (load_use_hazard || load_before_branch_mem);

    wire stall_hazard = load_use_hazard || load_before_branch_hazard;

    wire halt_freeze = id_is_halt_i;

    assign pc_write_en_o    = ~(stall_hazard | halt_freeze);
    assign if_id_write_en_o = ~(stall_hazard | halt_freeze);
    assign if_id_flush_o    = branch_taken_i & ~stall_hazard;
    assign id_ex_bubble_o   = stall_hazard; // nunca por halt: halt debe propagarse, no burbujear

endmodule
