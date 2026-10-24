`timescale 1ns/1ps
module tb_nexus32_soc_latency #(
    parameter int LANES = 32
);
    localparam logic [31:0] CTRL_START_ADDR = 32'h1000_5000;
    localparam logic [31:0] VERDICT_ADDR = 32'h0001_0008;
    localparam logic [31:0] PASS_SIGNATURE = 32'h600d_600d;
    localparam logic [31:0] FAIL_SIGNATURE = 32'hdead_0001;

    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer clock_cycle = 0;
    integer start_cycle = -1;
    integer verdict_cycle = -1;
    logic saw_start = 1'b0;
    logic saw_verdict = 1'b0;

    always #5 clk = ~clk;

    nexus32_soc #(
        .IMEM_INIT_FILE("firmware/nexus32_smoke.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault), .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done), .accelerator_error_o(accel_error)
    );

    // Both event timestamps are sampled at the same active posedge, before
    // DUT nonblocking updates.  T_start is the accepted CTRL.START request on
    // the CPU-to-accelerator bridge.  T_verdict is the actual bridge-side
    // full-word DMEM write of PASS_SIGNATURE to DMEM[2], identified while the
    // bridge is in ST_IDLE and executing its local-memory write path.  The
    // final DMEM value is checked on the following negedge after NBA updates.
    always @(posedge clk) begin
        clock_cycle = clock_cycle + 1;
        if (!rst) begin
            if (!saw_start && dut.accel_req_valid && dut.accel_req_ready &&
                dut.accel_req_write && dut.accel_req_wstrb == 4'hf &&
                dut.accel_req_addr == CTRL_START_ADDR &&
                dut.accel_req_wdata[0] && !dut.accel_req_wdata[1] &&
                dut.accel_req_wdata[31:4] == 28'd0) begin
                saw_start = 1'b1;
                start_cycle = clock_cycle;
            end

            if (!saw_verdict && dut.bridge_state_q == 2'd0 &&
                dut.cpu_mem_valid && dut.cpu_mem_is_dmem &&
                dut.cpu_mem_wstrb == 4'hf &&
                dut.cpu_mem_addr == VERDICT_ADDR &&
                dut.cpu_mem_wdata == PASS_SIGNATURE) begin
                saw_verdict = 1'b1;
                verdict_cycle = clock_cycle;
            end
        end
    end

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (integer watchdog = 0; watchdog < 200000; watchdog = watchdog + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during firmware-latency measurement");
            if (dut.dmem[2] === FAIL_SIGNATURE)
                $fatal(1, "smoke firmware reported FAIL during latency measurement: result=%08x",
                       dut.dmem[1]);
            if (saw_verdict) begin
                if (!saw_start)
                    $fatal(1, "verdict write observed before accepted CTRL.START");
                if (verdict_cycle <= start_cycle)
                    $fatal(1, "invalid event order: T_start=%0d T_verdict=%0d",
                           start_cycle, verdict_cycle);
                if (dut.dmem[0] !== 32'h4e58_3332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'h0002_0000)
                    $fatal(1, "smoke result mismatch: %08x", dut.dmem[1]);
                if (dut.dmem[2] !== PASS_SIGNATURE)
                    $fatal(1, "verdict value mismatch: %08x", dut.dmem[2]);
                if (cpu_bus_fault !== 1'b0 || accel_error !== 1'b0 ||
                    accel_busy !== 1'b0 || accel_done !== 1'b1)
                    $fatal(1, "terminal status invalid: fault=%b busy=%b done=%b error=%b",
                           cpu_bus_fault, accel_busy, accel_done, accel_error);
                $display("FIRMWARE_LATENCY_RESULT lanes=%0d t_start=%0d t_verdict=%0d latency=%0d verdict=%08x",
                         LANES, start_cycle, verdict_cycle,
                         verdict_cycle - start_cycle, dut.dmem[2]);
                $display("FIRMWARE_LATENCY_DEFINITION start=accepted_CTRL_START_bridge_transaction verdict=physical_DMEM2_PASS_write sampled_at_same_pre-NBA_posedge");
                $display("PASS: normal smoke firmware START-to-verdict latency measured");
                $finish;
            end
        end
        $fatal(1, "200000-cycle latency watchdog expired: start=%0d verdict=%0d dmem[0..2]=%08x %08x %08x",
               start_cycle, verdict_cycle, dut.dmem[0], dut.dmem[1], dut.dmem[2]);
    end

    initial begin
        #3000000;
        $fatal(1, "global firmware-latency testbench timeout: start=%0d verdict=%0d",
               start_cycle, verdict_cycle);
    end
endmodule
