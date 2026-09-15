`timescale 1ns / 1ps
// =============================================================================
// Módulo:         tb_hazard_unit
//
// Descripción:
// Verifica hazard_unit.v: caso sin hazard, load-use clásico, load-antes-de-
// branch en sus dos variantes (load en EX / load en MEM), que ese chequeo
// NO dispara para un consumidor que no es branch/jalr, branch tomado sin
// hazard (flush), la prioridad stall-sobre-flush cuando ambos coinciden,
// halt (freeze sin burbuja) y que rd=0 nunca genera hazard.
// =============================================================================
module tb_hazard_unit;

    reg  [4:0] tb_id_rs1, tb_id_rs2;
    reg        tb_id_is_branch, tb_id_is_jalr, tb_id_is_halt;
    reg  [4:0] tb_idex_rd;
    reg        tb_idex_memread;
    reg  [4:0] tb_exmem_rd;
    reg        tb_exmem_memread;
    reg        tb_branch_taken;

    wire tb_pc_we, tb_ifid_we, tb_ifid_flush, tb_idex_bubble;

    integer pass_count, fail_count;

    hazard_unit uut (
        .id_rs1_addr_i     (tb_id_rs1),
        .id_rs2_addr_i     (tb_id_rs2),
        .id_is_branch_i    (tb_id_is_branch),
        .id_is_jalr_i      (tb_id_is_jalr),
        .id_is_halt_i      (tb_id_is_halt),
        .id_ex_rd_addr_i   (tb_idex_rd),
        .id_ex_mem_read_i  (tb_idex_memread),
        .ex_mem_rd_addr_i  (tb_exmem_rd),
        .ex_mem_mem_read_i (tb_exmem_memread),
        .branch_taken_i    (tb_branch_taken),
        .pc_write_en_o     (tb_pc_we),
        .if_id_write_en_o  (tb_ifid_we),
        .if_id_flush_o     (tb_ifid_flush),
        .id_ex_bubble_o    (tb_idex_bubble)
    );

    task check;
        input [511:0] label;
        input pc_we; input ifid_we; input ifid_flush; input idex_bub;
        begin
            #1;
            if (tb_pc_we === pc_we && tb_ifid_we === ifid_we &&
                tb_ifid_flush === ifid_flush && tb_idex_bubble === idex_bub) begin
                pass_count = pass_count + 1;
                $display("  -> EXITO | %0s", label);
            end else begin
                fail_count = fail_count + 1;
                $error("  -> FALLO | %0s: esperado pc_we=%0b ifid_we=%0b flush=%0b bubble=%0b | recibido pc_we=%0b ifid_we=%0b flush=%0b bubble=%0b",
                       label, pc_we, ifid_we, ifid_flush, idex_bub, tb_pc_we, tb_ifid_we, tb_ifid_flush, tb_idex_bubble);
            end
        end
    endtask

    initial begin
        $display("========================================");
        $display("Inicio de la Verificacion de hazard_unit");
        $display("========================================");
        pass_count = 0;
        fail_count = 0;

        // Defaults: nada en vuelo, nada pide nada.
        tb_id_rs1 = 5'd1; tb_id_rs2 = 5'd2;
        tb_id_is_branch = 0; tb_id_is_jalr = 0; tb_id_is_halt = 0;
        tb_idex_rd = 5'd9; tb_idex_memread = 0;
        tb_exmem_rd = 5'd10; tb_exmem_memread = 0;
        tb_branch_taken = 0;

        check("Sin hazard: todo fluye", 1'b1, 1'b1, 1'b0, 1'b0);

        $display("\n--- Load-use clasico ---");
        tb_idex_rd = 5'd1; tb_idex_memread = 1; // EX es un load, rd=x1=rs1@ID
        check("Load-use (consumidor generico) -> stall", 1'b0, 1'b0, 1'b0, 1'b1);
        tb_idex_rd = 5'd9; tb_idex_memread = 0;

        $display("\n--- Load-use no dispara si rd=x0 ---");
        tb_idex_rd = 5'd0; tb_idex_memread = 1;
        check("Load con rd=x0 -> nunca hazard", 1'b1, 1'b1, 1'b0, 1'b0);
        tb_idex_rd = 5'd9; tb_idex_memread = 0;

        $display("\n--- Load antes de un branch: 0-gap (load en EX) ---");
        tb_id_is_branch = 1;
        tb_idex_rd = 5'd1; tb_idex_memread = 1; // load en EX, rd=x1=rs1@ID
        check("Load en EX + branch en ID -> stall", 1'b0, 1'b0, 1'b0, 1'b1);
        tb_idex_rd = 5'd9; tb_idex_memread = 0;

        $display("\n--- Load antes de un branch: 1-gap (load en MEM) ---");
        tb_exmem_rd = 5'd2; tb_exmem_memread = 1; // load en MEM, rd=x2=rs2@ID
        check("Load en EX/MEM + branch en ID -> stall", 1'b0, 1'b0, 1'b0, 1'b1);
        tb_exmem_rd = 5'd10; tb_exmem_memread = 0;

        $display("\n--- El chequeo 1-gap NO dispara para un consumidor que no es branch/jalr ---");
        tb_id_is_branch = 0; tb_id_is_jalr = 0;
        tb_exmem_rd = 5'd2; tb_exmem_memread = 1; // mismo load en MEM, pero ID no es branch/jalr
        check("Load en EX/MEM, consumidor generico -> NO stall", 1'b1, 1'b1, 1'b0, 1'b0);
        tb_exmem_rd = 5'd10; tb_exmem_memread = 0;

        $display("\n--- jalr tambien protegido (no solo branch) ---");
        tb_id_is_jalr = 1;
        tb_idex_rd = 5'd1; tb_idex_memread = 1;
        check("Load en EX + jalr en ID -> stall", 1'b0, 1'b0, 1'b0, 1'b1);
        tb_idex_rd = 5'd9; tb_idex_memread = 0; tb_id_is_jalr = 0;

        $display("\n--- Branch tomado, sin hazard -> flush ---");
        tb_branch_taken = 1;
        check("Branch tomado sin hazard -> flush de IF/ID", 1'b1, 1'b1, 1'b1, 1'b0);

        $display("\n--- Branch tomado a la vez que un stall: stall gana, no flush ---");
        tb_idex_rd = 5'd1; tb_idex_memread = 1; // fuerza load-use tambien
        check("Stall + branch_taken simultaneos -> flush suprimido", 1'b0, 1'b0, 1'b0, 1'b1);
        tb_idex_rd = 5'd9; tb_idex_memread = 0; tb_branch_taken = 0;

        $display("\n--- Halt: freeze de PC/IF-ID SIN burbujear ID/EX ---");
        tb_id_is_halt = 1;
        check("Halt -> freeze, bubble=0 (halt debe propagarse)", 1'b0, 1'b0, 1'b0, 1'b0);
        tb_id_is_halt = 0;

        $display("\n========================================");
        $display("Resultado: %0d EXITO / %0d FALLO", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0) $display("HAZARD_UNIT: TODOS LOS TESTS PASARON");
        else $display("HAZARD_UNIT: HAY TESTS FALLADOS");
        $finish;
    end

endmodule
