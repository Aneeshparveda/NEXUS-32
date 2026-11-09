`timescale 1ns/1ps
// End-to-end board demo: PicoRV32 runs firmware/nexus32_demo.hex, which
// executes a 1024-sample block on all three FIR engines, checks each against
// the Python-golden checksum, and reports over the UART. This bench decodes
// the UART line independently, echoes it, and requires:
//   - three "check=PASS" architecture lines and no "check=FAIL";
//   - the final "NEXUS32 RESULT: PASS" line;
//   - the DMEM PASS signature, the firmware_pass board signal, and no trap,
//     CPU bus fault, accelerator error, or UART overrun.
// A small UART divisor keeps simulation short; bit timing at the real
// divisor is covered by tb_nexus32_uart_tx.
module tb_nexus32_soc_demo #(
    parameter int LANES = 32,
    parameter int UART_DIV = 8
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    wire firmware_booted;
    wire firmware_pass;
    wire uart_tx;

    integer cycle = 0;
    integer chars = 0;
    integer pass_checks = 0;
    integer fail_checks = 0;
    logic result_pass_seen = 1'b0;
    logic result_fail_seen = 1'b0;
    logic [8*20-1:0] window = '0;   // last 20 received characters

    always #5 clk = ~clk;
    always @(posedge clk) cycle <= cycle + 1;

    nexus32_soc #(
        .IMEM_INIT_FILE("firmware/nexus32_demo.hex"),
        .LANES(LANES),
        .CLK_MHZ(100),
        .UART_CLKS_PER_BIT(UART_DIV)
    ) dut (
        .clk_i(clk),
        .rst_i(rst),
        .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault),
        .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done),
        .accelerator_error_o(accel_error),
        .firmware_booted_o(firmware_booted),
        .firmware_pass_o(firmware_pass),
        .uart_tx_o(uart_tx)
    );

    function automatic logic ends_with(input logic [8*20-1:0] w, input logic [8*20-1:0] pattern,
                                       input integer length);
        integer k;
        begin
            ends_with = 1'b1;
            for (k = 0; k < length; k = k + 1)
                if (w[8*k +: 8] !== pattern[8*k +: 8])
                    ends_with = 1'b0;
        end
    endfunction

    // Independent 8N1 receiver: sample mid-bit after a start edge.
    initial begin : UART_RX
        integer b;
        logic [7:0] ch;
        forever begin
            @(negedge uart_tx);
            repeat (UART_DIV / 2) @(posedge clk);
            if (uart_tx !== 1'b0)
                $fatal(1, "FAIL: UART start bit glitch at cycle %0d", cycle);
            for (b = 0; b < 8; b = b + 1) begin
                repeat (UART_DIV) @(posedge clk);
                ch[b] = uart_tx;
            end
            repeat (UART_DIV) @(posedge clk);
            if (uart_tx !== 1'b1)
                $fatal(1, "FAIL: UART framing error (stop bit low) at cycle %0d", cycle);
            chars = chars + 1;
            if (ch != 8'h0d)
                $write("%c", ch);
            window = {window[8*19-1:0], ch};
            if (ends_with(window, "check=PASS", 10)) pass_checks = pass_checks + 1;
            if (ends_with(window, "check=FAIL", 10)) fail_checks = fail_checks + 1;
            if (ends_with(window, "RESULT: PASS", 12)) result_pass_seen = 1'b1;
            if (ends_with(window, "RESULT: FAIL", 12)) result_fail_seen = 1'b1;
        end
    end

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        while (!result_pass_seen && !result_fail_seen && cycle < 6000000) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "FAIL: PicoRV32 trapped at cycle %0d", cycle);
        end
        // Let the trailing CR/LF drain.
        repeat (40 * UART_DIV) @(negedge clk);
        $display("");
        if (!result_pass_seen)
            $fatal(1, "FAIL: demo did not report PASS (fail_seen=%0d, cycle=%0d, chars=%0d)",
                   result_fail_seen, cycle, chars);
        if (pass_checks != 3 || fail_checks != 0)
            $fatal(1, "FAIL: expected 3 architecture PASS lines, got pass=%0d fail=%0d",
                   pass_checks, fail_checks);
        if (dut.dmem[2] !== 32'h600d600d || dut.dmem[0] !== 32'h4e583332 || dut.dmem[1] !== 32'd0)
            $fatal(1, "FAIL: DMEM signatures %08x %08x %08x", dut.dmem[0], dut.dmem[1], dut.dmem[2]);
        if (dut.dmem[3] !== {16'h4e58, 8'd100, 8'(LANES)})
            $fatal(1, "FAIL: SYS_INFO read back as %08x", dut.dmem[3]);
        if (!firmware_booted || !firmware_pass)
            $fatal(1, "FAIL: board signals booted=%b pass=%b", firmware_booted, firmware_pass);
        if (cpu_bus_fault || accel_error || dut.uart_overrun_q)
            $fatal(1, "FAIL: fault indicators bus=%b accel=%b uart_overrun=%b",
                   cpu_bus_fault, accel_error, dut.uart_overrun_q);
        $display("PASS: board demo firmware LANES=%0d: 3/3 architectures match the golden checksum, UART report decoded (%0d chars, %0d cycles)",
                 LANES, chars, cycle);
        $finish;
    end
endmodule
