`timescale 1ns/1ps
module tb_nexus32_soc_fault_data #(
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
    logic saw_response = 1'b0;

    always #5 clk = ~clk;

    nexus32_soc #(
        .IMEM_INIT_FILE("firmware/nexus32_smoke.hex"),
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

    initial begin
        repeat (6) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // Simulation-only setup: make the accelerator-owned state visible to
        // the bus while forcing one CPU-side read through the real bridge.
        force dut.u_accel_bus.u_accel.busy_q = 1'b1;
        force dut.cpu_mem_valid = 1'b1;
        force dut.cpu_mem_instr = 1'b0;
        force dut.cpu_mem_addr = 32'h0002_1000;
        force dut.cpu_mem_wdata = 32'd0;
        force dut.cpu_mem_wstrb = 4'h0;

        begin : WAIT_FOR_RESPONSE
            for (cycle = 0; cycle < 20; cycle = cycle + 1) begin
                @(negedge clk);
                if (dut.cpu_mem_ready) begin
                    if (dut.cpu_mem_rdata !== 32'hbad0_0001)
                        $fatal(1, "CPU bridge masked protected-read sentinel: %08x", dut.cpu_mem_rdata);
                    if (dut.accel_rsp_error !== 1'b1)
                        $fatal(1, "protected read did not carry accelerator response error");
                    saw_response = 1'b1;
                    disable WAIT_FOR_RESPONSE;
                end
            end
        end

        release dut.cpu_mem_wstrb;
        release dut.cpu_mem_wdata;
        release dut.cpu_mem_addr;
        release dut.cpu_mem_instr;
        release dut.cpu_mem_valid;
        release dut.u_accel_bus.u_accel.busy_q;

        if (!saw_response)
            $fatal(1, "timed out waiting for protected-read CPU response");
        if (!cpu_bus_fault)
            $fatal(1, "CPU bus-fault sticky diagnostic did not set");

        rst = 1'b1;
        repeat (3) @(negedge clk);
        if (cpu_bus_fault !== 1'b0)
            $fatal(1, "external reset did not clear CPU bus-fault sticky diagnostic");

        $display("PASS: CPU bridge preserved protected-read sentinel and reset cleared sticky fault");
        $finish;
    end

    initial begin
        #300000;
        $fatal(1, "CPU bridge diagnostic test timed out");
    end
endmodule
