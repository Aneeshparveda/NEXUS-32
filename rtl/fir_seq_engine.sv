`timescale 1ns/1ps
// NEXUS-32 sequential direct-form FIR engine.
//
// Tap-source contract:
// - tap_req_o/tap_addr_o issue one ordered tap read per cycle while work remains.
// - tap_valid_i marks a valid response; responses must be in request order.
// - The source must sustain one request per cycle (e.g. combinational mux or
//   one-cycle synchronous BRAM). The engine accepts response bubbles, but it
//   does not provide request backpressure or support out-of-order responses.
// - With a combinational source, tie tap_valid_i high and select data using
//   tap_addr_o. With one-cycle synchronous BRAM, register data and valid from
//   tap_req_o/tap_addr_o; the first response arrives one cycle later.
//
// Functional contract:
// - Active-high synchronous reset.
// - start_i is a one-cycle pulse accepted only while idle.
// - tap_count_i must be in [1,32]; invalid requests pulse error_o.
// - One 32x32 signed MAC is performed per valid tap response.
// - 72-bit Q40.32 accumulation; one final arithmetic shift and saturation.
// - done_o/error_o are one-cycle pulses. Start while busy is ignored.
// - cycles_o counts busy clock cycles, including source wait/latency cycles,
//   and saturates at 65535 rather than wrapping.
module fir_seq_engine (
    input  logic                 clk_i,
    input  logic                 rst_i,
    input  logic                 start_i,
    input  logic [5:0]           tap_count_i,
    output logic                 tap_req_o,
    output logic [4:0]           tap_addr_o,
    input  logic                 tap_valid_i,
    input  logic signed [31:0]   sample_tap_i,
    input  logic signed [31:0]   coefficient_tap_i,
    output logic                 busy_o,
    output logic                 done_o,
    output logic                 error_o,
    output logic signed [31:0]   result_o,
    output logic [15:0]          cycles_o
);
    logic busy_q;
    logic [5:0] tap_count_q;
    logic [5:0] issue_count_q;
    logic [5:0] response_count_q;
    logic signed [71:0] accumulator_q;
    logic signed [63:0] product_unused;
    logic signed [71:0] accumulator_next;
    logic signed [31:0] final_result;
    logic [15:0] elapsed_cycles_q;

    fir_q16_mac u_mac (
        .sample_i(sample_tap_i),
        .coefficient_i(coefficient_tap_i),
        .accumulator_i(accumulator_q),
        .product_o(product_unused),
        .accumulator_o(accumulator_next)
    );

    fir_q16_postprocess u_postprocess (
        .accumulator_i(accumulator_next),
        .result_o(final_result)
    );

    assign busy_o = busy_q;
    assign tap_req_o = busy_q && (issue_count_q < tap_count_q);
    assign tap_addr_o = tap_req_o ? issue_count_q[4:0] : 5'd0;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            busy_q          <= 1'b0;
            tap_count_q     <= 6'd0;
            issue_count_q   <= 6'd0;
            response_count_q <= 6'd0;
            accumulator_q   <= 72'sd0;
            elapsed_cycles_q <= 16'd0;
            cycles_o        <= 16'd0;
            result_o        <= 32'sd0;
            done_o          <= 1'b0;
            error_o         <= 1'b0;
        end else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            if (!busy_q) begin
                if (start_i) begin
                    cycles_o <= 16'd0;
                    if ((tap_count_i == 6'd0) || (tap_count_i > 6'd32)) begin
                        error_o <= 1'b1;
                    end else begin
                        busy_q           <= 1'b1;
                        tap_count_q      <= tap_count_i;
                        issue_count_q    <= 6'd0;
                        response_count_q <= 6'd0;
                        accumulator_q    <= 72'sd0;
                        elapsed_cycles_q <= 16'd0;
                    end
                end
            end else begin
                if (elapsed_cycles_q != 16'hffff)
                    elapsed_cycles_q <= elapsed_cycles_q + 16'd1;

                // Issue ordered tap reads at one request per clock until all
                // taps have been sent to the source.
                if (tap_req_o)
                    issue_count_q <= issue_count_q + 6'd1;

                // Responses are accumulated only when the source marks data
                // valid. The source must preserve request order.
                if (tap_valid_i) begin
                    if (response_count_q == (tap_count_q - 6'd1)) begin
                        result_o <= final_result;
                        if (elapsed_cycles_q == 16'hffff)
                            cycles_o <= 16'hffff;
                        else
                            cycles_o <= elapsed_cycles_q + 16'd1;
                        busy_q <= 1'b0;
                        done_o <= 1'b1;
                    end else begin
                        accumulator_q <= accumulator_next;
                        response_count_q <= response_count_q + 6'd1;
                    end
                end
            end
        end
    end
endmodule
