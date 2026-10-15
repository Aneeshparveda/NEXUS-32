`timescale 1ns/1ps
// NEXUS-32 parallel direct-form FIR engine, 1-cycle registered result.
//
// Window/packing contract:
// - sample_vector_i[31:0] and coefficient_vector_i[31:0] are tap 0.
// - Tap k is in [k*32 +: 32].
// - All vector values and tap_count_i must remain stable through the
//   accepting rising edge (in_valid_i && in_ready_o).
// - Up to LANES signed Q16.16 terms are multiplied in parallel; inactive
//   lanes are zero-padded, then summed in a canonical balanced LANES->1 tree.
// - Each signed 64-bit product is sign-extended to 72 bits before addition.
// - There is no intermediate rounding or saturation. Postprocessing performs
//   one arithmetic >>> 16 followed by signed int32 saturation.
// - Ready/valid permits one accepted input per cycle when out_ready_i is high.
//   A stalled output is held stable, and blocks new input until consumed.
// - Invalid tap counts (0 or >LANES) are accepted as an error, not an output.
module fir_parallel_engine #(
    parameter int LANES = 32
) (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    in_valid_i,
    output logic                    in_ready_o,
    input  logic [5:0]              tap_count_i,
    input  logic [LANES*32-1:0]     sample_vector_i,
    input  logic [LANES*32-1:0]     coefficient_vector_i,
    output logic                    out_valid_o,
    input  logic                    out_ready_i,
    output logic signed [31:0]      out_result_o,
    output logic                    error_o,
    output logic [15:0]             cycles_o
);
    localparam int DEPTH = $clog2(LANES);

    // ---- Elaboration-time guard (fires in synthesis and simulation) ----
    if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32) begin : gen_lanes_error
        LANES_MUST_BE_4_8_16_OR_32 invalid();
    end

    // ---- Simulation-time guard (descriptive message, ignored by synthesis) ----
    // synthesis translate_off
    initial begin
        if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32)
            $fatal(1, "LANES must be 4, 8, 16, or 32; got %0d", LANES);
    end
    // synthesis translate_on

    // Each generate block owns its own array, avoiding UNOPTFLAT from a shared
    // 2D signal. Level 0 has LANES elements (products), level k has LANES >> k
    // elements, level DEPTH has 1 element (root sum).
    for (genvar level = 0; level <= DEPTH; level++) begin : gen_tree
        localparam int ELEMS = LANES >> level;
        logic signed [71:0] val [0:ELEMS-1];
    end

    logic signed [31:0] postprocessed_result;
    logic out_valid_q;
    logic signed [31:0] result_q;

    // Replicated signed multipliers. Tap indices >= tap_count_i contribute 0.
    for (genvar g = 0; g < LANES; g++) begin : gen_product_lanes
        localparam logic [5:0] TAP_INDEX = g[5:0];
        logic signed [31:0] sample_word;
        logic signed [31:0] coefficient_word;
        logic signed [63:0] product;

        assign sample_word      = $signed(sample_vector_i[g*32 +: 32]);
        assign coefficient_word = $signed(coefficient_vector_i[g*32 +: 32]);
        assign product = sample_word * coefficient_word;
        assign gen_tree[0].val[g] = (tap_count_i > TAP_INDEX) ?
                          $signed({{8{product[63]}}, product}) : 72'sd0;
    end

    // Canonical balanced reduction tree; all levels preserve signed 72-bit sums.
    for (genvar level = 1; level <= DEPTH; level++) begin : gen_reduce
        for (genvar g = 0; g < (LANES >> level); g++) begin : gen_pairs
            assign gen_tree[level].val[g] = gen_tree[level-1].val[2*g]
                                          + gen_tree[level-1].val[2*g + 1];
        end
    end

    fir_q16_postprocess u_postprocess (
        .accumulator_i(gen_tree[DEPTH].val[0]),
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
                    if ((tap_count_i == 6'd0) || (tap_count_i > 6'(LANES))) begin
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
