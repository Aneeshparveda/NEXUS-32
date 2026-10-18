`timescale 1ns/1ps
module tb_nexus32_soc_multiarch #(
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
        .IMEM_INIT_FILE("build/nexus32_multiarch.hex"),
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
        for (cycle = 0; cycle < 200000; cycle = cycle + 1) begin
            @(negedge clk);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "RV32I multi-architecture firmware failed; last result=%08x", dut.dmem[1]);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped before multi-architecture PASS; dmem[0..3]=%08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'h00020000)
                    $fatal(1, "last architecture result mismatch: %08x", dut.dmem[1]);
                if (dut.dmem[3] !== 32'd1)
                    $fatal(1, "expected one result commit in the final legacy run, result count signature=%0d", dut.dmem[3]);
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "unexpected sticky CPU/system bus fault");
                if (accel_error !== 1'b0)
                    $fatal(1, "accelerator reported sticky error");
                if (accel_done !== 1'b1 || accel_busy !== 1'b0)
                    $fatal(1, "final accelerator state invalid: busy=%b done=%b", accel_busy, accel_done);
                $display("PASS: PicoRV32 firmware selected sequential, parallel, and pipelined FIR; all results and commit count match");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for multi-architecture PASS; trap=%b fault=%b busy=%b done=%b error=%b dmem[0..3]=%08x %08x %08x %08x",
               trap, cpu_bus_fault, accel_busy, accel_done, accel_error,
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3]);
    end

    initial begin
        #2000000;
        $fatal(1, "global multi-architecture testbench timeout");
    end
endmodule
