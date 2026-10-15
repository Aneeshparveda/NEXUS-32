`timescale 1ns/1ps
// NEXUS-32 direct-form FIR with a six-cycle registered balanced reduction pipeline.
//
// Numerical contract:
// - Signed Q16.16 32-bit samples and coefficients.
// - 32-bit x 32-bit signed products are 64-bit; each product is sign-extended
//   to 72 bits before accumulation. No intermediate rounding or saturation.
// - One arithmetic >>> 16 followed by signed int32 saturation.
// - Tap k is sample_vector_i[k*32 +: 32] and coefficient_vector_i[k*32 +: 32].
// - tap_count_i must be in [1,32]. Every accepted transaction produces one
//   out_valid_o response; an invalid tap count produces out_error_o=1 and
//   out_result_o=0. This error response is ordered with normal responses.
//
// Pipeline stages (all elastic with ready/valid propagation):
//   S0 products, S1 2-term sums, S2 4-term sums, S3 8-term sums,
//   S4 16-term sums, S5 32-term root, S6 shift/saturate output register.
// The result becomes visible six clock periods after the accepting edge, and
// the pipeline can accept/retire one transaction per cycle after fill if the
// downstream remains ready. cycles_o=6 reports nominal no-stall pipeline depth;
// it is not elapsed wall-clock latency when backpressure inserts stalls.
module fir_pipelined_engine (
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
    output logic                    out_error_o,
    output logic [15:0]             cycles_o
);
    logic signed [63:0] product_comb [0:31];
    logic signed [71:0] tree0_q [0:31];
    logic signed [71:0] tree1_q [0:15];
    logic signed [71:0] tree2_q [0:7];
    logic signed [71:0] tree3_q [0:3];
    logic signed [71:0] tree4_q [0:1];
    logic signed [71:0] tree5_q;

    logic [6:0] valid_q;
    logic [6:0] error_q;
    logic [6:0] stage_ready;
    logic signed [31:0] postprocessed_result;
    logic signed [31:0] result_q;
    logic [15:0] cycles_q;
    logic invalid_input;

    assign invalid_input = (tap_count_i == 6'd0) || (tap_count_i > 6'd32);

    for (genvar lane = 0; lane < 32; lane++) begin : gen_product_lanes
        logic signed [31:0] sample_word;
        logic signed [31:0] coefficient_word;
        assign sample_word = $signed(sample_vector_i[lane*32 +: 32]);
        assign coefficient_word = $signed(coefficient_vector_i[lane*32 +: 32]);
        assign product_comb[lane] = sample_word * coefficient_word;
    end

    // Stage-ready chain: downstream backpressure propagates to the input.
    assign stage_ready[6] = !valid_q[6] || out_ready_i;
    for (genvar stage = 0; stage < 6; stage++) begin : gen_ready_chain
        assign stage_ready[stage] = !valid_q[stage] || stage_ready[stage+1];
    end

    assign in_ready_o = stage_ready[0];
    assign out_valid_o = valid_q[6];
    assign out_error_o = error_q[6];
    assign out_result_o = result_q;
    assign cycles_o = cycles_q;

    fir_q16_postprocess u_postprocess (
        .accumulator_i(tree5_q),
        .result_o(postprocessed_result)
    );

    integer i;
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            valid_q  <= 7'b0;
            error_q  <= 7'b0;
            result_q <= 32'sd0;
            cycles_q <= 16'd0;
        end else begin
            // S0: parallel signed products, sign-extended into 72-bit lanes.
            if (stage_ready[0]) begin
                valid_q[0] <= in_valid_i;
                if (in_valid_i) begin
                    error_q[0] <= invalid_input;
                    for (i = 0; i < 32; i = i + 1) begin
                        if (!invalid_input && (tap_count_i > i))
                            tree0_q[i] <= $signed({{8{product_comb[i][63]}}, product_comb[i]});
                        else
                            tree0_q[i] <= 72'sd0;
                    end
                end else begin
                    error_q[0] <= 1'b0;
                end
            end

            // S1: pairwise sums (32 -> 16).
            if (stage_ready[1]) begin
                valid_q[1] <= valid_q[0];
                error_q[1] <= error_q[0];
                if (valid_q[0]) begin
                    for (i = 0; i < 16; i = i + 1)
                        tree1_q[i] <= tree0_q[2*i] + tree0_q[2*i+1];
                end
            end

            // S2: 16 -> 8.
            if (stage_ready[2]) begin
                valid_q[2] <= valid_q[1];
                error_q[2] <= error_q[1];
                if (valid_q[1]) begin
                    for (i = 0; i < 8; i = i + 1)
                        tree2_q[i] <= tree1_q[2*i] + tree1_q[2*i+1];
                end
            end

            // S3: 8 -> 4.
            if (stage_ready[3]) begin
                valid_q[3] <= valid_q[2];
                error_q[3] <= error_q[2];
                if (valid_q[2]) begin
                    for (i = 0; i < 4; i = i + 1)
                        tree3_q[i] <= tree2_q[2*i] + tree2_q[2*i+1];
                end
            end

            // S4: 4 -> 2.
            if (stage_ready[4]) begin
                valid_q[4] <= valid_q[3];
                error_q[4] <= error_q[3];
                if (valid_q[3]) begin
                    for (i = 0; i < 2; i = i + 1)
                        tree4_q[i] <= tree3_q[2*i] + tree3_q[2*i+1];
                end
            end

            // S5: root sum.
            if (stage_ready[5]) begin
                valid_q[5] <= valid_q[4];
                error_q[5] <= error_q[4];
                if (valid_q[4])
                    tree5_q <= tree4_q[0] + tree4_q[1];
            end

            // S6: one final shift/saturation, registered for stable ready/valid.
            if (stage_ready[6]) begin
                valid_q[6] <= valid_q[5];
                error_q[6] <= error_q[5];
                if (valid_q[5]) begin
                    cycles_q <= 16'd6;
                    if (error_q[5])
                        result_q <= 32'sd0;
                    else
                        result_q <= postprocessed_result;
                end else begin
                    cycles_q <= 16'd0;
                end
            end
        end
    end
endmodule
