`timescale 1ns/1ps
module tb_nexus32_soc_timeout #(
    parameter int LANES = 32
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer clock_cycle = 0;
    integer t0_cycle = -1;
    integer verdict_cycle = -1;
    logic saw_boot = 1'b0;
    logic saw_status_read = 1'b0;

    always #5 clk = ~clk;

    nexus32_soc #(
        .IMEM_INIT_FILE("build/nexus32_timeout.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault), .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done), .accelerator_error_o(accel_error)
    );

    // The first STATUS observation is the actual accepted CPU bridge request,
    // not a guessed delay from reset or firmware setup.
    always @(posedge clk) begin
        clock_cycle = clock_cycle + 1;
        if (!rst && dut.dmem[0] === 32'h4e583332)
            saw_boot = 1'b1;

        if (!rst && t0_cycle >= 0 &&
            (dut.u_accel_bus.u_accel.busy_q !== 1'b0 ||
             dut.u_accel_bus.u_accel.done_sticky_q !== 1'b0 ||
             dut.u_accel_bus.u_accel.error_sticky_q !== 1'b0)) begin
            $fatal(1, "timeout precondition changed during wait: busy=%b done=%b error=%b",
                   dut.u_accel_bus.u_accel.busy_q,
                   dut.u_accel_bus.u_accel.done_sticky_q,
                   dut.u_accel_bus.u_accel.error_sticky_q);
        end

        if (!rst && dut.accel_req_valid && dut.accel_req_ready &&
            !dut.accel_req_write && dut.accel_req_addr == 32'h1000_5004) begin
            if (!saw_boot)
                $fatal(1, "first STATUS read was accepted before boot signature was visible");
            if (dut.u_accel_bus.u_accel.busy_q !== 1'b0 ||
                dut.u_accel_bus.u_accel.done_sticky_q !== 1'b0 ||
                dut.u_accel_bus.u_accel.error_sticky_q !== 1'b0)
                $fatal(1, "nonzero STATUS at accepted timeout poll request");
            if (!saw_status_read) begin
                saw_status_read = 1'b1;
                t0_cycle = clock_cycle;
            end
        end
    end

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (integer watchdog = 0; watchdog < 6000000; watchdog = watchdog + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during timeout test");
            if (dut.dmem[2] === 32'h600d600d)
                $fatal(1, "timeout firmware unexpectedly reported PASS");
            if (dut.dmem[2] === 32'hdead0001) begin
                verdict_cycle = clock_cycle;
                if (t0_cycle < 0)
                    $fatal(1, "timeout verdict appeared without an observed STATUS T0");
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "timeout boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[6] !== 32'd3)
                    $fatal(1, "timeout failure cause=%0d expected 3", dut.dmem[6]);
                if (dut.dmem[7] !== 32'h00000000)
                    $fatal(1, "timeout STATUS snapshot=%08x expected 00000000", dut.dmem[7]);
                if (accel_busy || accel_done || accel_error)
                    $fatal(1, "timeout terminal STATUS changed: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                if ((verdict_cycle - t0_cycle) < 1400000 ||
                    (verdict_cycle - t0_cycle) > 6000000)
                    $fatal(1, "timeout verdict delta=%0d outside [1400000,6000000] (T0=%0d verdict=%0d)",
                           verdict_cycle - t0_cycle, t0_cycle, verdict_cycle);
                $display("PASS: bounded timeout cause=3 STATUS=00000000 T0=%0d verdict=%0d delta=%0d",
                         t0_cycle, verdict_cycle, verdict_cycle - t0_cycle);
                $finish;
            end
        end
        $fatal(1, "six-million-cycle timeout watchdog expired before firmware verdict; T0=%0d dmem[0..7]=%08x %08x %08x %08x %08x %08x %08x %08x",
               t0_cycle, dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7]);
    end
endmodule
