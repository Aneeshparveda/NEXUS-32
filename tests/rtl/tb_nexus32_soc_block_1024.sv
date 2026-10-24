`timescale 1ns/1ps
module tb_nexus32_soc_block_1024 #(
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
        .IMEM_INIT_FILE("build/nexus32_block_1024.hex"),
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
        for (cycle = 0; cycle < 2000000; cycle = cycle + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during CPU-driven 1024-sample block; dmem[0..9]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                       dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
                       dut.dmem[8], dut.dmem[9]);
            if (cpu_bus_fault === 1'b1)
                $fatal(1, "unexpected CPU/system bus fault during CPU-driven block; dmem[6..9]=%08x %08x %08x %08x",
                       dut.dmem[6], dut.dmem[7], dut.dmem[8], dut.dmem[9]);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "1024-sample firmware failure cause=%0d status=%08x result_count=%0d result_words=%08x %08x %08x %08x",
                       dut.dmem[6], dut.dmem[7], dut.dmem[8], dut.dmem[1],
                       dut.dmem[3], dut.dmem[4], dut.dmem[5]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'd32768 || dut.dmem[3] !== 32'd49152 ||
                    dut.dmem[4] !== 32'd65536 || dut.dmem[5] !== 32'd65536)
                    $fatal(1, "representative result mismatch: result[0..2]/result[1023]=%08x %08x %08x %08x",
                           dut.dmem[1], dut.dmem[3], dut.dmem[4], dut.dmem[5]);
                if (dut.dmem[8] !== 32'd1024 || dut.dmem[9] !== 32'h00000002)
                    $fatal(1, "firmware predicate observation mismatch: RESULT_COUNT=%0d STATUS=%08x",
                           dut.dmem[8], dut.dmem[9]);
                if (accel_busy || !accel_done || accel_error)
                    $fatal(1, "terminal accelerator state invalid: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                $display("SOC_BLOCK_1024_RESULT lanes=%0d SAMPLE_COUNT=1024 TAP_COUNT=3 RESULT_COUNT=%0d STATUS=%08x architecture=sequential",
                         LANES, dut.dmem[8], dut.dmem[9]);
                $display("PASS: CPU-driven SAMPLE_COUNT=1024 TAP_COUNT=3 RESULT_COUNT=1024 STATUS=0x00000002 block regression; serialized-shell caveat: system-level throughput remains bus-arbitration bound");
                $finish;
            end
        end
        $fatal(1, "1024-sample CPU firmware watchdog expired; dmem[0..9]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
               dut.dmem[8], dut.dmem[9]);
    end

    initial begin
        #250000000;
        $fatal(1, "global CPU-driven 1024-sample block testbench timeout");
    end
endmodule
