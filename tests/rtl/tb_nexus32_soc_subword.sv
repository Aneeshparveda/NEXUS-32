`timescale 1ns/1ps
module tb_nexus32_soc_subword #(
    parameter int LANES = 32
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;

    always #5 clk = ~clk;

    nexus32_soc #(
        .IMEM_INIT_FILE("build/nexus32_subword.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk),
        .rst_i(rst),
        .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault),
        .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done),
        .accelerator_error_o(accel_error)
    );

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (cycle = 0; cycle < 10000; cycle = cycle + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during sub-word regression; dmem[0..11]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                       dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
                       dut.dmem[8], dut.dmem[9], dut.dmem[10], dut.dmem[11]);
            if (cpu_bus_fault === 1'b1)
                $fatal(1, "unexpected CPU bus fault during aligned sub-word accesses; dmem[6..7]=%08x %08x",
                       dut.dmem[6], dut.dmem[7]);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "sub-word firmware failure cause=%0d status=%08x observed=%08x %08x %08x %08x %08x %08x %08x",
                       dut.dmem[6], dut.dmem[7], dut.dmem[3], dut.dmem[4],
                       dut.dmem[5], dut.dmem[8], dut.dmem[9], dut.dmem[10],
                       dut.dmem[11]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[3] !== 32'hffff_ff80 || dut.dmem[4] !== 32'h0000_0080 ||
                    dut.dmem[5] !== 32'hffff_8001 || dut.dmem[8] !== 32'h0000_8001 ||
                    dut.dmem[9] !== 32'h0000_007f || dut.dmem[10] !== 32'h0000_7fff ||
                    dut.dmem[11] !== 32'h0000_7fff)
                    $fatal(1, "sub-word observed-value mismatch: LB=%08x LBU=%08x LH=%08x LHU=%08x LBU+=%08x LH+=%08x LHU+=%08x",
                           dut.dmem[3], dut.dmem[4], dut.dmem[5], dut.dmem[8],
                           dut.dmem[9], dut.dmem[10], dut.dmem[11]);
                if (accel_busy || accel_done || accel_error)
                    $fatal(1, "unexpected accelerator state during sub-word test: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                $display("PASS: CPU-driven SB/SH/LB/LH/LBU/LHU regression");
                $finish;
            end
        end
        $fatal(1, "sub-word regression timeout; dmem[0..11]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
               dut.dmem[8], dut.dmem[9], dut.dmem[10], dut.dmem[11]);
    end

    initial begin
        #200000;
        $fatal(1, "global sub-word testbench timeout");
    end
endmodule
