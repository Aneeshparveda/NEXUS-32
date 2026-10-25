`timescale 1ns/1ps
// NEXUS-32 direct-form FIR with a registered balanced reduction pipeline.
// Nominal latency is LATENCY = $clog2(LANES) + 1 cycles (3/4/5/6 for
// LANES 4/8/16/32); "six-cycle" holds only at LANES=32, not at all LANES.
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
//   S0 products, S1..S_DEPTH reduction tree, S_{STAGES-1} shift/saturate output register.
// The result becomes visible LATENCY clock periods after the accepting edge, and
// the pipeline can accept/retire one transaction per cycle after fill if the
// downstream remains ready. cycles_o reports nominal no-stall pipeline depth (LATENCY);
// it is not elapsed wall-clock latency when backpressure inserts stalls.
module fir_pipelined_engine #(
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
    output logic                    out_error_o,
    output logic [15:0]             cycles_o
);
    localparam int DEPTH   = $clog2(LANES);
    localparam int STAGES  = DEPTH + 2;
    localparam int LATENCY = DEPTH + 1;

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

    logic signed [63:0] product_comb [0:LANES-1];

    // Tree registers: level 0 has LANES elements, level k has LANES >> k elements
    for (genvar level = 0; level <= DEPTH; level++) begin : gen_tree
        localparam int ELEMS = LANES >> level;
        logic signed [71:0] val_q [0:ELEMS-1];
    end

    logic [STAGES-1:0] valid_q;
    logic [STAGES-1:0] error_q;
    logic [STAGES-1:0] stage_ready;
    logic signed [31:0] postprocessed_result;
    logic signed [31:0] result_q;
    logic [15:0] cycles_q;
    logic invalid_input;

    assign invalid_input = (tap_count_i == 6'd0) || (tap_count_i > 6'(LANES));

    for (genvar lane = 0; lane < LANES; lane++) begin : gen_product_lanes
        logic signed [31:0] sample_word;
        logic signed [31:0] coefficient_word;
        assign sample_word = $signed(sample_vector_i[lane*32 +: 32]);
        assign coefficient_word = $signed(coefficient_vector_i[lane*32 +: 32]);
        assign product_comb[lane] = sample_word * coefficient_word;
    end

    // The stage_ready chain is acyclic: stage_ready[STAGES-1] depends only on
    // registered valid_q[STAGES-1] and out_ready_i; stage_ready[s] depends only
    // on registered valid_q[s] and stage_ready[s+1]. Therefore no stage depends
    // on itself or on an earlier stage, so there is no combinational loop here.
    assign stage_ready[STAGES-1] = !valid_q[STAGES-1] || out_ready_i;
    for (genvar s = 0; s < STAGES-1; s++) begin : gen_ready_chain
        assign stage_ready[s] = !valid_q[s] || stage_ready[s+1];
    end

    assign in_ready_o   = stage_ready[0];
    assign out_valid_o  = valid_q[STAGES-1];
    assign out_error_o  = error_q[STAGES-1];
    assign out_result_o = result_q;
    assign cycles_o     = cycles_q;

    fir_q16_postprocess u_postprocess (
        .accumulator_i(gen_tree[DEPTH].val_q[0]),
        .result_o(postprocessed_result)
    );

    // -------------------------------------------------------------------------
    // Control path: Single sequential process for valid_q, error_q, result_q, cycles_q.
    // Strictly adheres to IEEE 1800 single-writer semantics for always_ff variables.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            valid_q  <= '0;
            error_q  <= '0;
            result_q <= 32'sd0;
            cycles_q <= 16'd0;
        end else begin
            // Stage 0: input capture control
            if (stage_ready[0]) begin
                valid_q[0] <= in_valid_i;
                if (in_valid_i)
                    error_q[0] <= invalid_input;
                else
                    error_q[0] <= 1'b0;
            end

            // Stages 1..DEPTH: reduction tree control propagation
            for (int lvl = 1; lvl <= DEPTH; lvl++) begin
                if (stage_ready[lvl]) begin
                    valid_q[lvl] <= valid_q[lvl-1];
                    error_q[lvl] <= error_q[lvl-1];
                end
            end

            // Stage STAGES-1: output registration control & result capture
            if (stage_ready[STAGES-1]) begin
                valid_q[STAGES-1] <= valid_q[STAGES-2];
                error_q[STAGES-1] <= error_q[STAGES-2];
                if (valid_q[STAGES-2]) begin
                    cycles_q <= 16'(LATENCY);
                    if (error_q[STAGES-2])
                        result_q <= 32'sd0;
                    else
                        result_q <= postprocessed_result;
                end else begin
                    cycles_q <= 16'd0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Datapath: Stage 0 parallel products sign-extended into 72-bit lanes
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (stage_ready[0]) begin
            if (in_valid_i) begin
                for (int i = 0; i < LANES; i++) begin
                    if (!invalid_input && (tap_count_i > i[5:0]))
                        gen_tree[0].val_q[i] <= $signed({{8{product_comb[i][63]}}, product_comb[i]});
                    else
                        gen_tree[0].val_q[i] <= 72'sd0;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Datapath: Stages 1..DEPTH pairwise tree additions
    // Each level owns its own val_q register array; single-writer per array.
    // -------------------------------------------------------------------------
    for (genvar lvl = 1; lvl <= DEPTH; lvl++) begin : gen_stages
        localparam int NUM_PAIRS = LANES >> lvl;
        always_ff @(posedge clk_i) begin
            if (stage_ready[lvl]) begin
                if (valid_q[lvl-1]) begin
                    for (int i = 0; i < NUM_PAIRS; i++) begin
                        gen_tree[lvl].val_q[i] <= gen_tree[lvl-1].val_q[2*i]
                                                + gen_tree[lvl-1].val_q[2*i+1];
                    end
                end
            end
        end
    end
endmodule
