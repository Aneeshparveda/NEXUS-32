`timescale 1ns/1ps
// NEXUS-32 parallel direct-form FIR engine, 1-cycle registered result.
//
// Window/packing contract:
// - sample_vector_i[31:0] and coefficient_vector_i[31:0] are tap 0.
// - Tap k is in [k*32 +: 32].
// - All vector values and tap_count_i must remain stable through the
//   accepting rising edge (in_valid_i && in_ready_o).
// - Up to 32 signed Q16.16 terms are multiplied in parallel; inactive lanes
//   are zero-padded, then summed in a canonical balanced 32->1 tree.
// - Each signed 64-bit product is sign-extended to 72 bits before addition.
// - There is no intermediate rounding or saturation. Postprocessing performs
//   one arithmetic >>> 16 followed by signed int32 saturation.
// - Ready/valid permits one accepted input per cycle when out_ready_i is high.
//   A stalled output is held stable, and blocks new input until consumed.
// - Invalid tap counts (0 or >32) are accepted as an error, not an output.
module fir_parallel_engine (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    in_valid_i,
    output logic                    in_ready_o,
    input  logic [5:0]              tap_count_i,
    input  logic [1023:0]           sample_vector_i,
    input  logic [1023:0]           coefficient_vector_i,
    output logic                    out_valid_o,
    input  logic                    out_ready_i,
    output logic signed [31:0]      out_result_o,
    output logic                    error_o,
    output logic [15:0]             cycles_o
);
    logic signed [71:0] tree0 [0:31];
    logic signed [71:0] tree1 [0:15];
    logic signed [71:0] tree2 [0:7];
    logic signed [71:0] tree3 [0:3];
    logic signed [71:0] tree4 [0:1];
    logic signed [71:0] tree5;
    logic signed [31:0] postprocessed_result;
    logic out_valid_q;
    logic signed [31:0] result_q;

    // Replicated signed multipliers. Tap indices >= tap_count_i contribute 0.
    for (genvar g = 0; g < 32; g++) begin : gen_product_lanes
        localparam logic [5:0] TAP_INDEX = g;
        logic signed [31:0] sample_word;
        logic signed [31:0] coefficient_word;
        logic signed [63:0] product;

        assign sample_word      = $signed(sample_vector_i[g*32 +: 32]);
        assign coefficient_word = $signed(coefficient_vector_i[g*32 +: 32]);
        assign product = sample_word * coefficient_word;
        assign tree0[g] = (tap_count_i > TAP_INDEX) ?
                          $signed({{8{product[63]}}, product}) : 72'sd0;
    end

    // Canonical balanced reduction tree; all levels preserve signed 72-bit sums.
    for (genvar g = 0; g < 16; g++) begin : gen_sum_level1
        assign tree1[g] = tree0[2*g] + tree0[2*g + 1];
    end
    for (genvar g = 0; g < 8; g++) begin : gen_sum_level2
        assign tree2[g] = tree1[2*g] + tree1[2*g + 1];
    end
    for (genvar g = 0; g < 4; g++) begin : gen_sum_level3
        assign tree3[g] = tree2[2*g] + tree2[2*g + 1];
    end
    for (genvar g = 0; g < 2; g++) begin : gen_sum_level4
        assign tree4[g] = tree3[2*g] + tree3[2*g + 1];
    end
    assign tree5 = tree4[0] + tree4[1];

    fir_q16_postprocess u_postprocess (
        .accumulator_i(tree5),
        .result_o(postprocessed_result)
    );

    assign in_ready_o   = !out_valid_q || out_ready_i;
    assign out_valid_o  = out_valid_q;
    assign out_result_o = result_q;

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            out_valid_q <= 1'b0;
            result_q     <= 32'sd0;
            error_o      <= 1'b0;
            cycles_o     <= 16'd0;
        end else begin
            error_o <= 1'b0;

            if (in_ready_o) begin
                if (in_valid_i) begin
                    if ((tap_count_i == 6'd0) || (tap_count_i > 6'd32)) begin
                        out_valid_q <= 1'b0;
                        error_o     <= 1'b1;
                        cycles_o    <= 16'd0;
                    end else begin
                        out_valid_q <= 1'b1;
                        result_q     <= postprocessed_result;
                        // The combinational multiplier/tree is captured at this
                        // edge; the result is visible in the following cycle.
                        cycles_o     <= 16'd1;
                    end
                end else begin
                    out_valid_q <= 1'b0;
                end
            end
            // When output is stalled, valid/result/cycles are held stable.
        end
    end
endmodule
