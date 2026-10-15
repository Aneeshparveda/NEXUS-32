`timescale 1ns/1ps
module tb_nexus32_invalid_fetch;
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    logic saw_invalid_fetch = 1'b0;
    logic saw_trap = 1'b0;
    integer cycle;

    always #5 clk = ~clk;

    nexus32_soc #(.IMEM_INIT_FILE("firmware/nexus32_invalid_fetch.hex")) dut (
        .clk_i(clk),
        .rst_i(rst),
        .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault),
        .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done),
        .accelerator_error_o(accel_error)
    );

    always @(posedge clk) begin
        if (rst) begin
            saw_invalid_fetch <= 1'b0;
            saw_trap <= 1'b0;
        end else begin
            if (dut.cpu_mem_valid && dut.cpu_mem_instr && !dut.cpu_mem_is_imem) begin
                saw_invalid_fetch <= 1'b1;
                if (dut.accel_req_valid !== 1'b0)
                    $fatal(1, "invalid instruction fetch leaked onto accelerator bus");
            end
            if (dut.accel_req_valid && dut.cpu_mem_instr)
                $fatal(1, "CPU instruction fetch generated an accelerator request");
            if (trap)
                saw_trap <= 1'b1;
        end
    end

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (cycle = 0; cycle < 500; cycle = cycle + 1) begin
            @(negedge clk);
            if (saw_invalid_fetch && saw_trap && cpu_bus_fault) begin
                if (dut.accel_bus_fault_sticky !== 1'b0)
                    $fatal(1, "invalid instruction fetch incorrectly reached the accelerator bus");
                if (accel_busy || accel_done || accel_error)
                    $fatal(1, "accelerator state changed during invalid instruction fetch");
                $display("PASS: invalid instruction fetch rejected locally; no accelerator request issued");
                $finish;
            end
        end
        $fatal(1, "timeout: invalid-fetch path not fully observed; fetch=%b trap=%b cpu_fault=%b accel_fault=%b",
               saw_invalid_fetch, saw_trap, cpu_bus_fault, dut.accel_bus_fault_sticky);
    end
endmodule
