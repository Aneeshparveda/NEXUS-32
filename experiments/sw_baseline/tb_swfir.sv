`timescale 1ns/1ps
// Runs the software FIR baseline on the SoC CPU and prints its cycle count.
module tb_swfir #(parameter int LANES = 8);
    logic clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire trap, bus_fault, busy, done, err, booted, fpass, tx;
    nexus32_soc #(.IMEM_INIT_FILE("experiments/sw_baseline/sw_fir.hex"), .LANES(LANES),
                  .CLK_MHZ(100), .UART_CLKS_PER_BIT(8)) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap), .cpu_bus_fault_o(bus_fault),
        .accelerator_busy_o(busy), .accelerator_done_o(done), .accelerator_error_o(err),
        .firmware_booted_o(booted), .firmware_pass_o(fpass), .uart_tx_o(tx));
    longint cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    initial begin
        repeat (6) @(negedge clk);
        rst = 0;
        while (dut.dmem[2] !== 32'h600d600d && dut.dmem[2] !== 32'hdead0001 && cyc < 200_000_000) begin
            @(negedge clk);
            if (trap === 1'b1) $fatal(1, "FAIL: trap at %0d", cyc);
        end
        $display("SWFIR taps=%0d cycles=%0d checksum=0x%08x sig=0x%08x trap=%b bus_fault=%b accel_busy_seen=%b",
                 dut.dmem[32'h42], dut.dmem[32'h40], dut.dmem[32'h41], dut.dmem[2], trap, bus_fault, busy);
        if (dut.dmem[2] !== 32'h600d600d) $fatal(1, "FAIL: software result does not match golden checksum");
        $finish;
    end
endmodule
