`timescale 1ns/1ps
// Directed check of nexus32_uart_tx: idle level, exact bit timing, LSB-first
// data, stop bit, ready/valid acceptance, back-to-back frames, and that a
// valid presented while busy is not accepted.
module tb_nexus32_uart_tx #(
    parameter int CLKS_PER_BIT = 5
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic valid = 1'b0;
    logic [7:0] data = 8'h00;
    wire ready;
    wire tx;
    integer failures = 0;
    integer frames = 0;

    always #5 clk = ~clk;

    nexus32_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk_i(clk), .rst_i(rst), .valid_i(valid), .data_i(data),
        .ready_o(ready), .tx_o(tx)
    );

    localparam int NUM_BYTES = 6;
    logic [7:0] bytes [0:NUM_BYTES-1];
    initial begin
        bytes[0] = 8'h55; bytes[1] = 8'h00; bytes[2] = 8'hff;
        bytes[3] = 8'ha3; bytes[4] = 8'h0d; bytes[5] = 8'h80;
    end

    // Receiver: wait for the start edge, then check every bit is held for
    // exactly CLKS_PER_BIT cycles (sampled at every cycle of the bit).
    task automatic expect_frame(input logic [7:0] expected);
        integer bit_index;
        integer c;
        logic [9:0] frame;
        begin
            frame = {1'b1, expected, 1'b0};
            @(negedge tx);
            for (bit_index = 0; bit_index < 10; bit_index = bit_index + 1) begin
                for (c = 0; c < CLKS_PER_BIT; c = c + 1) begin
                    @(negedge clk);
                    if (tx !== frame[bit_index]) begin
                        $display("FAIL: byte %02x bit %0d cycle %0d tx=%b expected %b",
                                 expected, bit_index, c, tx, frame[bit_index]);
                        failures = failures + 1;
                    end
                end
            end
            frames = frames + 1;
        end
    endtask

    initial begin : RECEIVER
        integer i;
        for (i = 0; i < NUM_BYTES; i = i + 1)
            expect_frame(bytes[i]);
    end

    initial begin : DRIVER
        integer i;
        integer cycle;
        repeat (3) @(negedge clk);
        if (tx !== 1'b1 || ready !== 1'b1) begin
            $display("FAIL: line must idle high and ready during/after reset (tx=%b ready=%b)", tx, ready);
            failures = failures + 1;
        end
        rst = 1'b0;
        // Back-to-back: hold valid with the next byte until accepted.
        for (i = 0; i < NUM_BYTES; i = i + 1) begin
            @(negedge clk);
            valid = 1'b1;
            data = bytes[i];
            @(posedge clk);
            while (!ready) @(posedge clk);
            @(negedge clk);
            valid = 1'b0;
            // While a frame is in flight, a presented byte must not be taken.
            if (i == 2) begin
                valid = 1'b1;
                data = 8'hee;
                @(negedge clk);
                if (ready !== 1'b0) begin
                    $display("FAIL: ready asserted mid-frame");
                    failures = failures + 1;
                end
                valid = 1'b0;
            end
        end
        for (cycle = 0; cycle < 20 * CLKS_PER_BIT && frames < NUM_BYTES; cycle = cycle + 1)
            @(negedge clk);
        repeat (2 * CLKS_PER_BIT) @(negedge clk);
        if (frames != NUM_BYTES) begin
            $display("FAIL: received %0d of %0d frames", frames, NUM_BYTES);
            failures = failures + 1;
        end
        if (tx !== 1'b1 || ready !== 1'b1) begin
            $display("FAIL: line not idle after the last frame");
            failures = failures + 1;
        end
        if (failures != 0)
            $fatal(1, "FAIL: nexus32_uart_tx CLKS_PER_BIT=%0d failures=%0d", CLKS_PER_BIT, failures);
        $display("PASS: nexus32_uart_tx CLKS_PER_BIT=%0d %0d frames, exact bit timing, LSB first, busy rejection",
                 CLKS_PER_BIT, frames);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "FAIL: nexus32_uart_tx watchdog expired");
    end
endmodule
