`timescale 1ns/1ps

// Verification-only direct pipelined-engine latency experiment.
//
// Transfer edges are sampled at posedge before NBA updates:
//   input edge  = in_valid && in_ready
//   output edge = out_valid && out_ready
// A #1 delay is used only to record when out_valid/result become visible after
// an output register update.  The no-stall transfer latency is the measured
// contract quantity; cycles_o is reported separately as nominal metadata.
module tb_fir_pipelined_latency #(
    parameter int LANES = 32
);
    localparam int TREE_LEVELS = $clog2(LANES);
    localparam int STAGES = TREE_LEVELS + 2;
    localparam int REPORTED_LATENCY = TREE_LEVELS + 1;
    localparam int TRANSFER_LATENCY = TREE_LEVELS + 2;
    localparam int STREAM_COUNT = 24;
    localparam int QUEUE_LIMIT = 256;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [5:0] tap_count = 6'd0;
    logic [LANES*32-1:0] sample_vector = '0;
    logic [LANES*32-1:0] coefficient_vector = '0;
    logic out_valid;
    logic out_ready = 1'b1;
    logic signed [31:0] out_result;
    logic out_error;
    logic [15:0] cycles;

    fir_pipelined_engine #(.LANES(LANES)) dut (
        .clk_i(clk), .rst_i(rst),
        .in_valid_i(in_valid), .in_ready_o(in_ready),
        .tap_count_i(tap_count),
        .sample_vector_i(sample_vector),
        .coefficient_vector_i(coefficient_vector),
        .out_valid_o(out_valid), .out_ready_i(out_ready),
        .out_result_o(out_result), .out_error_o(out_error),
        .cycles_o(cycles)
    );

    always #5 clk = ~clk;

    logic signed [31:0] expected_result [0:QUEUE_LIMIT-1];
    logic expected_error [0:QUEUE_LIMIT-1];
    integer accepted_edge [0:QUEUE_LIMIT-1];
    integer visible_edge [0:QUEUE_LIMIT-1];
    integer transfer_latency [0:QUEUE_LIMIT-1];
    integer visible_latency [0:QUEUE_LIMIT-1];
    integer q_wr = 0;
    integer q_rd = 0;
    integer cycle_count = 0;
    integer failures = 0;
    integer functional_failures = 0;
    integer latency_failures = 0;
    integer harness_errors = 0;
    integer last_output_cycle = -1;
    integer throughput_gaps = 0;
    integer baseline_mode = 0;
    integer experiment_phase = 0;
    integer visible_records = 0;

    function automatic logic signed [31:0] deterministic_sample(
        input integer item, input integer lane
    );
        integer value;
        begin
            value = (((item + 3) * (lane + 5) + 11) % 19) - 9;
            if (((item + lane) & 1) != 0)
                value = -value;
            deterministic_sample = value * 32'sh0000_0400;
        end
    endfunction

    function automatic logic signed [31:0] deterministic_coefficient(input integer lane);
        integer value;
        begin
            value = ((lane * 5 + 3) % 11) - 5;
            deterministic_coefficient = value * 32'sh0000_0800;
        end
    endfunction

    function automatic logic signed [31:0] reference_result(
        input logic [5:0] taps,
        input logic [LANES*32-1:0] samples_in,
        input logic [LANES*32-1:0] coefficients_in
    );
        logic signed [31:0] sample_word;
        logic signed [31:0] coefficient_word;
        logic signed [63:0] product;
        logic signed [71:0] accumulator;
        logic signed [71:0] shifted;
        integer lane;
        begin
            accumulator = 72'sd0;
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (lane < taps) begin
                    sample_word = $signed(samples_in[lane*32 +: 32]);
                    coefficient_word = $signed(coefficients_in[lane*32 +: 32]);
                    product = sample_word * coefficient_word;
                    accumulator = accumulator + $signed({{8{product[63]}}, product});
                end
            end
            shifted = accumulator >>> 16;
            if (shifted > 72'sd2147483647)
                reference_result = 32'sh7fff_ffff;
            else if (shifted < -72'sd2147483648)
                reference_result = 32'sh8000_0000;
            else
                reference_result = shifted[31:0];
        end
    endfunction

    task automatic fail_functional(input string message);
        begin
            failures = failures + 1;
            functional_failures = functional_failures + 1;
            $display("PIPE_FUNCTIONAL_FAIL lanes=%0d phase=%0d edge=%0d: %s",
                     LANES, experiment_phase, cycle_count, message);
        end
    endtask

    task automatic fail_latency(input string message);
        begin
            failures = failures + 1;
            latency_failures = latency_failures + 1;
            $display("PIPE_LATENCY_FAIL lanes=%0d phase=%0d edge=%0d: %s",
                     LANES, experiment_phase, cycle_count, message);
        end
    endtask

    task automatic fail_harness(input string message);
        begin
            failures = failures + 1;
            harness_errors = harness_errors + 1;
            $display("PIPE_HARNESS_FAIL lanes=%0d phase=%0d edge=%0d: %s",
                     LANES, experiment_phase, cycle_count, message);
        end
    endtask

    // Independent ready/valid scoreboard. Output comparison happens before
    // input enqueue on a shared edge, so simultaneous retire/accept preserves
    // the pre-edge queue ordering. Visibility is recorded after NBA at #1.
    always @(posedge clk) begin : PIPE_SCOREBOARD
        integer index;
        integer observed_latency;
        logic input_edge;
        logic output_edge;

        if (rst) begin
            cycle_count = 0;
            q_wr = 0;
            q_rd = 0;
            last_output_cycle = -1;
            visible_records = 0;
            for (index = 0; index < QUEUE_LIMIT; index = index + 1) begin
                visible_edge[index] = -1;
                visible_latency[index] = -1;
                transfer_latency[index] = -1;
            end
        end else begin
            cycle_count = cycle_count + 1;
            input_edge = in_valid && in_ready;
            output_edge = out_valid && out_ready;

            if (output_edge) begin
                if (q_rd >= q_wr)
                    fail_harness("output transfer without a queued accepted input");
                else begin
                    if (out_error !== expected_error[q_rd])
                        fail_functional($sformatf("output[%0d] error=%b expected=%b",
                                                  q_rd, out_error, expected_error[q_rd]));
                    if (out_result !== expected_result[q_rd])
                        fail_functional($sformatf("output[%0d] result=%08x expected=%08x",
                                                  q_rd, out_result, expected_result[q_rd]));
                    if (cycles !== 16'(REPORTED_LATENCY))
                        fail_latency($sformatf("output[%0d] cycles_o=%0d expected=%0d",
                                               q_rd, cycles, REPORTED_LATENCY));
                    observed_latency = cycle_count - accepted_edge[q_rd];
                    transfer_latency[q_rd] = observed_latency;
                    if (baseline_mode && observed_latency != TRANSFER_LATENCY)
                        fail_latency($sformatf(
                            "output[%0d] transfer latency=%0d expected=%0d",
                            q_rd, observed_latency, TRANSFER_LATENCY));
                    if (baseline_mode && last_output_cycle >= 0 &&
                        cycle_count != last_output_cycle + 1)
                        throughput_gaps = throughput_gaps + 1;
                    last_output_cycle = cycle_count;
                    q_rd = q_rd + 1;
                end
            end

            if (input_edge) begin
                if (q_wr >= QUEUE_LIMIT)
                    fail_harness("accepted-input queue overflow");
                else begin
                    expected_error[q_wr] = (tap_count == 6'd0) || (tap_count > 6'(LANES));
                    if (expected_error[q_wr])
                        expected_result[q_wr] = 32'sd0;
                    else
                        expected_result[q_wr] = reference_result(
                            tap_count, sample_vector, coefficient_vector);
                    accepted_edge[q_wr] = cycle_count;
                    q_wr = q_wr + 1;
                end
            end
        end

        if (!rst) begin
            #1;
            if (out_valid && q_rd < q_wr && visible_edge[q_rd] < 0) begin
                visible_edge[q_rd] = cycle_count;
                visible_latency[q_rd] = cycle_count - accepted_edge[q_rd];
                visible_records = visible_records + 1;
            end
        end
    end

    task automatic build_stream_item(input integer item);
        integer lane;
        integer taps;
        begin
            taps = 1 + (item % LANES);
            tap_count = taps;
            sample_vector = '0;
            coefficient_vector = '0;
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (lane < taps) begin
                    sample_vector[lane*32 +: 32] = deterministic_sample(item, lane);
                    coefficient_vector[lane*32 +: 32] = deterministic_coefficient(lane);
                end
            end
        end
    endtask

    task automatic hardware_reset;
        begin
            in_valid = 1'b0;
            out_ready = 1'b1;
            @(negedge clk);
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic submit_stream(input integer item_count);
        integer index;
        begin
            index = 0;
            @(negedge clk);
            build_stream_item(index);
            in_valid = 1'b1;
            while (index < item_count) begin
                @(posedge clk);
                if (in_ready) begin
                    index = index + 1;
                    if (index < item_count) begin
                        @(negedge clk);
                        build_stream_item(index);
                    end
                end else begin
                    @(negedge clk);
                end
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic wait_for_drain(input integer target);
        integer waited;
        begin
            waited = 0;
            while (q_rd < target && waited < 1000) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (q_rd < target)
                fail_harness($sformatf("drain timeout rd=%0d target=%0d", q_rd, target));
        end
    endtask

    task automatic check_no_stall_results;
        integer index;
        begin
            if (q_wr != STREAM_COUNT || q_rd != STREAM_COUNT)
                fail_harness($sformatf("no-stall counts wr=%0d rd=%0d expected=%0d",
                                      q_wr, q_rd, STREAM_COUNT));
            if (throughput_gaps != 0)
                fail_latency($sformatf("no-stall output gaps=%0d", throughput_gaps));
            if (visible_records != STREAM_COUNT)
                fail_latency($sformatf("visible output records=%0d expected=%0d",
                                      visible_records, STREAM_COUNT));
            for (index = 0; index < STREAM_COUNT; index = index + 1) begin
                if (transfer_latency[index] != TRANSFER_LATENCY)
                    fail_latency($sformatf("item[%0d] measured transfer latency=%0d expected=%0d",
                                          index, transfer_latency[index], TRANSFER_LATENCY));
                if (visible_latency[index] != REPORTED_LATENCY)
                    fail_latency($sformatf("item[%0d] measured visible latency=%0d expected=%0d",
                                          index, visible_latency[index], REPORTED_LATENCY));
            end
        end
    endtask

    task automatic run_no_stall_experiment;
        begin
            experiment_phase = 1;
            hardware_reset();
            baseline_mode = 1;
            throughput_gaps = 0;
            submit_stream(STREAM_COUNT);
            wait_for_drain(STREAM_COUNT);
            @(negedge clk);
            baseline_mode = 0;
            check_no_stall_results();
            $display("PIPELINE_LATENCY_RESULT {\"lanes\":%0d,\"tree_levels\":%0d,\"stages\":%0d,\"reported_cycles\":%0d,\"visible_latency\":%0d,\"transfer_latency\":%0d,\"clock_period_ns\":10,\"out_ready\":1,\"edge_convention\":\"posedge valid&&ready before NBA\"}",
                     LANES, TREE_LEVELS, STAGES, REPORTED_LATENCY,
                     REPORTED_LATENCY, TRANSFER_LATENCY);
        end
    endtask

    task automatic run_backpressure_experiment;
        integer index;
        logic signed [31:0] held_result;
        logic held_error;
        logic [15:0] held_cycles;
        begin
            experiment_phase = 2;
            hardware_reset();
            out_ready = 1'b0;
            submit_stream(STAGES);
            wait_for_drain(0);
            repeat (TREE_LEVELS + 3) @(negedge clk);
            if (!out_valid)
                fail_functional("backpressure phase never produced a held output");
            held_result = out_result;
            held_error = out_error;
            held_cycles = cycles;
            for (index = 0; index < 5; index = index + 1) begin
                @(negedge clk);
                if (!out_valid || out_result !== held_result ||
                    out_error !== held_error || cycles !== held_cycles)
                    fail_functional("output/result/error/cycles changed while stalled");
            end
            out_ready = 1'b1;
            wait_for_drain(STAGES);
            if (q_wr != STAGES || q_rd != STAGES)
                fail_harness($sformatf("backpressure counts wr=%0d rd=%0d expected=%0d",
                                      q_wr, q_rd, STAGES));
            baseline_mode = 0;
        end
    endtask

    initial begin : RUN_LATENCY_EXPERIMENT
        run_no_stall_experiment();
        run_backpressure_experiment();
        $display("PIPELINE_LATENCY_SUMMARY lanes=%0d failures=%0d functional_failures=%0d latency_failures=%0d harness_errors=%0d",
                 LANES, failures, functional_failures, latency_failures, harness_errors);
        if (failures != 0)
            $fatal(1, "pipelined latency experiment failed");
        $display("PASS: NEXUS-32 pipelined latency experiment");
        $finish;
    end

    initial begin
        #1000000;
        fail_harness("global watchdog expired");
        $fatal(1, "pipelined latency experiment watchdog expired");
    end
endmodule
