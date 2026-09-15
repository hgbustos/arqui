`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_forwarding_unit
//
// Descripción:
// Verifica forwarding_unit.v: los 3 casos de cada pista (sin hazard,
// EX/MEM, MEM/WB para la pista hacia EX; sin hazard, EX, EX/MEM, MEM/WB
// para la pista hacia ID), la prioridad cuando mas de una fuente calza
// (la mas reciente gana en ambas pistas), y que x0 nunca se adelanta aunque
// alguna entrada malformada diga reg_write=1 con rd=0.
// =============================================================================
module tb_forwarding_unit;

    localparam FWD_EX_NONE  = 2'b00;
    localparam FWD_EX_EXMEM = 2'b01;
    localparam FWD_EX_MEMWB = 2'b10;

    localparam FWD_ID_NONE  = 2'b00;
    localparam FWD_ID_EX    = 2'b01;
    localparam FWD_ID_EXMEM = 2'b10;
    localparam FWD_ID_MEMWB = 2'b11;

    reg [4:0] tb_id_rs1, tb_id_rs2;
    reg [4:0] tb_idex_rs1, tb_idex_rs2, tb_idex_rd;
    reg       tb_idex_rw;
    reg [4:0] tb_exmem_rd;
    reg       tb_exmem_rw;
    reg [4:0] tb_memwb_rd;
    reg       tb_memwb_rw;

    wire [1:0] tb_fwd_a_ex, tb_fwd_b_ex, tb_fwd_a_id, tb_fwd_b_id;

    integer pass_count, fail_count;

    forwarding_unit uut (
        .id_rs1_addr_i    (tb_id_rs1),
        .id_rs2_addr_i    (tb_id_rs2),
        .id_ex_rs1_addr_i (tb_idex_rs1),
        .id_ex_rs2_addr_i (tb_idex_rs2),
        .id_ex_rd_addr_i  (tb_idex_rd),
        .id_ex_reg_write_i(tb_idex_rw),
        .ex_mem_rd_addr_i (tb_exmem_rd),
        .ex_mem_reg_write_i(tb_exmem_rw),
        .mem_wb_rd_addr_i (tb_memwb_rd),
        .mem_wb_reg_write_i(tb_memwb_rw),
        .forward_a_ex_o   (tb_fwd_a_ex),
        .forward_b_ex_o   (tb_fwd_b_ex),
        .forward_a_id_o   (tb_fwd_a_id),
        .forward_b_id_o   (tb_fwd_b_id)
    );

    task check4;
        input [511:0] label;
        input [1:0] got_a_ex; input [1:0] exp_a_ex;
        input [1:0] got_b_ex; input [1:0] exp_b_ex;
        input [1:0] got_a_id; input [1:0] exp_a_id;
        input [1:0] got_b_id; input [1:0] exp_b_id;
        begin
            if (got_a_ex === exp_a_ex && got_b_ex === exp_b_ex &&
                got_a_id === exp_a_id && got_b_id === exp_b_id) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado a_ex=%0d b_ex=%0d a_id=%0d b_id=%0d | recibido a_ex=%0d b_ex=%0d a_id=%0d b_id=%0d",
                       label, exp_a_ex, exp_b_ex, exp_a_id, exp_b_id, got_a_ex, got_b_ex, got_a_id, got_b_id);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de forwarding_unit");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        // Defaults: nada escribe nada, direcciones todas distintas entre si.
        // tb_id_rs1/tb_id_rs2 (pista ID) se dejan en 5'd30/5'd31 durante toda
        // la seccion de pista EX para que nunca puedan calzar por accidente
        // con los rd de 1 digito que usa esa seccion.
        tb_id_rs1 = 5'd30; tb_id_rs2 = 5'd31;
        tb_idex_rs1 = 5'd1; tb_idex_rs2 = 5'd2; tb_idex_rd = 5'd9; tb_idex_rw = 0;
        tb_exmem_rd = 5'd10; tb_exmem_rw = 0;
        tb_memwb_rd = 5'd11; tb_memwb_rw = 0;
        #1;
        check4("Sin ningun hazard", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                     tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_NONE);

        $display("\n--- Pista EX (clasica, Patterson 4.7) ---");
        // rs1 de EX (idex_rs1=x1) coincide con rd de EX/MEM (x1)
        tb_idex_rs1 = 5'd1; tb_exmem_rd = 5'd1; tb_exmem_rw = 1;
        #1;
        check4("rs1@EX <- EX/MEM", tb_fwd_a_ex, FWD_EX_EXMEM, tb_fwd_b_ex, FWD_EX_NONE,
                                    tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_NONE);
        tb_exmem_rw = 0; tb_exmem_rd = 5'd10;

        // rs2 de EX (idex_rs2=x2) coincide con rd de MEM/WB (x2), EX/MEM no coincide
        tb_idex_rs2 = 5'd2; tb_memwb_rd = 5'd2; tb_memwb_rw = 1;
        #1;
        check4("rs2@EX <- MEM/WB", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_MEMWB,
                                    tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_NONE);

        // Prioridad: EX/MEM y MEM/WB compiten por rs1@EX -> gana EX/MEM (mas reciente)
        tb_idex_rs1 = 5'd3;
        tb_exmem_rd = 5'd3; tb_exmem_rw = 1;
        tb_memwb_rd = 5'd3; tb_memwb_rw = 1;
        #1;
        check4("Prioridad EX/MEM > MEM/WB hacia EX", tb_fwd_a_ex, FWD_EX_EXMEM, tb_fwd_b_ex, FWD_EX_NONE,
                                                       tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_NONE);

        // x0 nunca se adelanta aunque reg_write venga en 1 (no deberia pasar
        // en la practica -- register_file ya protege x0 -- pero se prueba
        // la defensa extra de esta unidad).
        tb_idex_rs1 = 5'd0; tb_exmem_rd = 5'd0; tb_exmem_rw = 1; tb_memwb_rd = 5'd0; tb_memwb_rw = 1;
        #1;
        check4("x0 nunca se adelanta hacia EX", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                                  tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_NONE);

        $display("\n--- Pista ID (branch_unit, propia de resolver saltos en ID) ---");
        tb_idex_rs1 = 5'd20; tb_idex_rs2 = 5'd21; tb_idex_rd = 5'd20; tb_idex_rw = 0; // reset ruido pista EX
        tb_exmem_rd = 5'd20; tb_exmem_rw = 0;
        tb_memwb_rd = 5'd20; tb_memwb_rw = 0;

        // rs1@ID coincide con rd@EX (id_ex) -> prioridad maxima (FWD_ID_EX)
        tb_id_rs1 = 5'd5; tb_id_rs2 = 5'd6;
        tb_idex_rd = 5'd5; tb_idex_rw = 1;
        #1;
        check4("rs1@ID <- EX (prioridad 1)", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                              tb_fwd_a_id, FWD_ID_EX, tb_fwd_b_id, FWD_ID_NONE);
        tb_idex_rw = 0; tb_idex_rd = 5'd20;

        // rs2@ID coincide con rd@EX/MEM, EX no coincide -> FWD_ID_EXMEM
        tb_exmem_rd = 5'd6; tb_exmem_rw = 1;
        #1;
        check4("rs2@ID <- EX/MEM (prioridad 2)", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                                   tb_fwd_a_id, FWD_ID_NONE, tb_fwd_b_id, FWD_ID_EXMEM);
        tb_exmem_rw = 0; tb_exmem_rd = 5'd20;

        // rs1@ID coincide solo con rd@MEM/WB -> FWD_ID_MEMWB
        tb_memwb_rd = 5'd5; tb_memwb_rw = 1;
        #1;
        check4("rs1@ID <- MEM/WB (prioridad 3)", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                                   tb_fwd_a_id, FWD_ID_MEMWB, tb_fwd_b_id, FWD_ID_NONE);
        tb_memwb_rw = 0; tb_memwb_rd = 5'd20;

        // Las 3 fuentes compiten por rs1@ID -> gana EX (prioridad 1)
        tb_idex_rd = 5'd5; tb_idex_rw = 1;
        tb_exmem_rd = 5'd5; tb_exmem_rw = 1;
        tb_memwb_rd = 5'd5; tb_memwb_rw = 1;
        #1;
        check4("Prioridad EX > EX/MEM > MEM/WB hacia ID", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                                            tb_fwd_a_id, FWD_ID_EX, tb_fwd_b_id, FWD_ID_NONE);

        // EX/MEM y MEM/WB compiten (EX ya no calza) -> gana EX/MEM
        tb_idex_rd = 5'd20; tb_idex_rw = 0;
        #1;
        check4("Prioridad EX/MEM > MEM/WB hacia ID", tb_fwd_a_ex, FWD_EX_NONE, tb_fwd_b_ex, FWD_EX_NONE,
                                                        tb_fwd_a_id, FWD_ID_EXMEM, tb_fwd_b_id, FWD_ID_NONE);

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("FORWARDING_UNIT: TODOS LOS TESTS PASARON");
        else $display("FORWARDING_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
