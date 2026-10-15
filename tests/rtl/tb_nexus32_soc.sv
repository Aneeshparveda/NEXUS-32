`timescale 1ns/1ps
module tb_nexus32_soc;
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;

    always #5 clk = ~clk;

    nexus32_soc #(.IMEM_INIT_FILE("firmware/nexus32_smoke.hex")) dut (
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
                $fatal(1, "RV32I firmware reported FIR failure; result=%08x", dut.dmem[1]);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped before firmware PASS; dmem[0..2]=%08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'h00020000)
                    $fatal(1, "firmware result mismatch: %08x", dut.dmem[1]);
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "unexpected sticky CPU/system bus fault");
                if (accel_error !== 1'b0)
                    $fatal(1, "accelerator reported sticky error");
                if (accel_done !== 1'b1)
                    $fatal(1, "accelerator DONE was not asserted");
                $display("PASS: PicoRV32 boot, RV32I firmware, memory bridge, and FIR accelerator end-to-end");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for firmware PASS; trap=%b fault=%b busy=%b done=%b error=%b dmem[0..2]=%08x %08x %08x",
               trap, cpu_bus_fault, accel_busy, accel_done, accel_error,
               dut.dmem[0], dut.dmem[1], dut.dmem[2]);
    end

    initial begin
        #2000000;
        $fatal(1, "global testbench timeout");
    end
endmodule
