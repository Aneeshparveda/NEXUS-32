`timescale 1ns/1ps
module tb_nexus32_soc_invalid_tap #(
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
        .IMEM_INIT_FILE("build/nexus32_invalid_tap.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault), .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done), .accelerator_error_o(accel_error)
    );

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (cycle = 0; cycle < 100000; cycle = cycle + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during invalid-tap test; dmem[0..7]=%08x %08x %08x %08x %08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                       dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7]);
            if (dut.dmem[2] === 32'h600d600d)
                $fatal(1, "invalid TAP_COUNT unexpectedly completed successfully");
            if (dut.dmem[2] === 32'hdead0001) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "invalid-tap boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[6] !== 32'd2)
                    $fatal(1, "invalid-tap failure cause=%0d expected 2", dut.dmem[6]);
                if (dut.dmem[7] !== 32'h00000004)
                    $fatal(1, "invalid-tap STATUS snapshot=%08x expected 00000004", dut.dmem[7]);
                if (accel_busy || accel_done || !accel_error)
                    $fatal(1, "invalid-tap terminal status invalid: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "invalid-tap stimulus raised an unexpected CPU bus fault");
                if (cycle >= 10000)
                    $fatal(1, "invalid-tap verdict was not prompt: cycle=%0d", cycle);
                $display("PASS: invalid TAP_COUNT terminated ERROR-first with cause 2 and STATUS=00000004");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for invalid-tap FAIL; dmem[0..7]=%08x %08x %08x %08x %08x %08x %08x %08x",
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7]);
    end

    initial begin
        #3000000;
        $fatal(1, "global invalid-tap testbench timeout");
    end
endmodule
