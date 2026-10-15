`timescale 1ns/1ps
module tb_nexus32_soc_reset_recovery;
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;
    logic reset_injected = 1'b0;

    always #5 clk = ~clk;

    nexus32_soc #(.IMEM_INIT_FILE("firmware/nexus32_smoke.hex")) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault), .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done), .accelerator_error_o(accel_error)
    );

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;

        // Interrupt the first run only after the accelerator has entered BUSY.
        for (cycle = 0; cycle < 200000 && !reset_injected; cycle = cycle + 1) begin
            @(negedge clk);
            if (accel_busy === 1'b1) begin
                rst = 1'b1;
                repeat (4) @(negedge clk);
                if (dut.bridge_state_q !== 2'd0)
                    $fatal(1, "CPU bridge failed to return to IDLE during reset");
                if (dut.u_accel_bus.state_q !== 3'd0)
                    $fatal(1, "accelerator bus failed to return to IDLE during reset");
                if (accel_busy !== 1'b0 || accel_done !== 1'b0 || accel_error !== 1'b0)
                    $fatal(1, "accelerator status did not clear during reset");
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "sticky CPU/system fault did not clear during reset");

                // The DMEM is not reset by RTL; clear the software sentinel
                // from the interrupted run in this simulation-only testbench.
                dut.dmem[0] = 32'd0;
                dut.dmem[1] = 32'd0;
                dut.dmem[2] = 32'd0;
                reset_injected = 1'b1;
                rst = 1'b0;
            end
        end
        if (!reset_injected) $fatal(1, "timed out waiting to reset while accelerator busy");

        // The same firmware must restart from the reset vector and complete.
        for (cycle = 0; cycle < 200000; cycle = cycle + 1) begin
            @(negedge clk);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "firmware reported failure after reset: result=%08x", dut.dmem[1]);
            if (trap === 1'b1)
                $fatal(1, "CPU trapped after reset recovery; dmem[0..2]=%08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332 || dut.dmem[1] !== 32'h00020000)
                    $fatal(1, "firmware signatures incorrect after reset: %08x %08x",
                           dut.dmem[0], dut.dmem[1]);
                if (cpu_bus_fault !== 1'b0 || accel_error !== 1'b0 || accel_done !== 1'b1)
                    $fatal(1, "fault/status mismatch after reset recovery");
                $display("PASS: reset aborts in-flight accelerator operation and firmware restarts successfully");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for firmware completion after reset recovery");
    end

    initial begin
        #3000000;
        $fatal(1, "global reset-recovery testbench timeout");
    end
endmodule
