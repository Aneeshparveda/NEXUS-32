`timescale 1ns/1ps
// NEXUS-32 transmit-only UART, 8N1, LSB first.
//
// Contract:
// - Active-high synchronous reset; the line idles high.
// - A byte is accepted on a rising edge with valid_i && ready_o.
// - ready_o is high only when no frame is in progress; there is no FIFO.
// - Each frame is 1 start bit (low), 8 data bits LSB first, 1 stop bit (high),
//   each held for exactly CLKS_PER_BIT clock cycles.
// - CLKS_PER_BIT = clock_hz / baud, e.g. 868 for 100 MHz at 115200 baud.
module nexus32_uart_tx #(
    parameter int CLKS_PER_BIT = 868
) (
    input  logic       clk_i,
    input  logic       rst_i,
    input  logic       valid_i,
    input  logic [7:0] data_i,
    output logic       ready_o,
    output logic       tx_o
);
    if (CLKS_PER_BIT < 2) begin : gen_bad_divisor
        UART_CLKS_PER_BIT_MUST_BE_AT_LEAST_2 invalid();
    end

    localparam int COUNT_W = $clog2(CLKS_PER_BIT);

    logic busy_q;
    logic [8:0] frame_q;        // {stop, data[7:0]}; the start bit is driven directly
    logic [3:0] bits_left_q;    // bits still to drive, including the current one
    logic [COUNT_W-1:0] count_q;

    assign ready_o = !busy_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            busy_q <= 1'b0;
            frame_q <= 9'h1ff;
            bits_left_q <= 4'd0;
            count_q <= '0;
            tx_o <= 1'b1;
        end else if (!busy_q) begin
            tx_o <= 1'b1;
            if (valid_i) begin
                busy_q <= 1'b1;
                frame_q <= {1'b1, data_i};
                bits_left_q <= 4'd10;
                count_q <= '0;
                tx_o <= 1'b0;   // start bit begins on the accepting edge
            end
        end else if (count_q == COUNT_W'(CLKS_PER_BIT - 1)) begin
            count_q <= '0;
            if (bits_left_q == 4'd1) begin
                busy_q <= 1'b0;
                tx_o <= 1'b1;
            end else begin
                frame_q <= {1'b1, frame_q[8:1]};
                tx_o <= frame_q[0];
                bits_left_q <= bits_left_q - 4'd1;
            end
        end else begin
            count_q <= count_q + 1'b1;
        end
    end
endmodule
