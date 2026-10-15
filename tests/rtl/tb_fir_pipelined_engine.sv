`timescale 1ns/1ps
module tb_fir_pipelined_engine #(
    parameter int LANES = 32
);
    localparam int DEPTH   = $clog2(LANES);
    localparam int STAGES  = DEPTH + 2;
    localparam int LATENCY = DEPTH + 1;

    logic clk;
    logic rst;
    logic in_valid;
    logic in_ready;
    logic [5:0] tap_count;
    logic [LANES*32-1:0] sample_vector;
    logic [LANES*32-1:0] coefficient_vector;
    logic out_valid;
    logic out_ready;
    logic signed [31:0] out_result;
    logic out_error;
    logic [15:0] cycles;

    logic signed [31:0] expected_result [0:255];
    logic expected_error [0:255];
    integer q_wr;
    integer q_rd;
    integer cycle_count;
    logic measure_throughput;
    integer measured_outputs;
    integer throughput_gaps;
    integer last_output_cycle;

    integer i;
    integer k;
    integer timeout;
    logic signed [31:0] held_result;
    logic held_error;
    logic [15:0] held_cycles;

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

    function automatic logic signed [31:0] reference_result(
        input logic [5:0] n,
        input logic [LANES*32-1:0] samples,
        input logic [LANES*32-1:0] coefficients
    );
        logic signed [31:0] s;
        logic signed [31:0] c;
        logic signed [63:0] p;
        logic signed [71:0] acc;
        logic signed [71:0] shifted;
        integer tap;
        begin
            acc = 72'sd0;
            for (tap = 0; tap < LANES; tap = tap + 1) begin
                if (tap < n) begin
                    s = $signed(samples[tap*32 +: 32]);
                    c = $signed(coefficients[tap*32 +: 32]);
                    p = s * c;
                    acc = acc + $signed({{8{p[63]}}, p});
                end
            end
            shifted = acc >>> 16;
            if (shifted > 72'sd2147483647)
                reference_result = 32'sh7fffffff;
            else if (shifted < -72'sd2147483648)
                reference_result = 32'sh80000000;
            else
                reference_result = shifted[31:0];
        end
    endfunction

    // Scoreboard is sampled on the active clock edge, before nonblocking
    // assignments update DUT state. A reset intentionally flushes in-flight
    // transactions, so pending expected entries are discarded at that edge.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
            q_rd = q_wr;
        end else begin
            cycle_count = cycle_count + 1;

            if (out_valid && out_ready) begin
                if (q_rd >= q_wr)
                    $fatal(1, "unexpected output with no queued accepted input");
                if (out_error !== expected_error[q_rd])
                    $fatal(1, "error mismatch idx=%0d got=%b expected=%b",
                           q_rd, out_error, expected_error[q_rd]);
                if (out_result !== expected_result[q_rd])
                    $fatal(1, "result mismatch idx=%0d got=%0d expected=%0d",
                           q_rd, out_result, expected_result[q_rd]);
                if (cycles !== 16'(LATENCY))
                    $fatal(1, "nominal pipeline depth mismatch: got cycles=%0d, expected=%0d", cycles, LATENCY);

                if (measure_throughput) begin
                    if ((measured_outputs > 0) &&
                        (cycle_count != last_output_cycle + 1))
                        throughput_gaps = throughput_gaps + 1;
                    measured_outputs = measured_outputs + 1;
                    last_output_cycle = cycle_count;
                end
                q_rd = q_rd + 1;
            end

            if (in_valid && in_ready) begin
                if (q_wr >= 256)
                    $fatal(1, "scoreboard queue overflow");
                expected_error[q_wr] = (tap_count == 6'd0) || (tap_count > 6'(LANES));
                if (expected_error[q_wr])
                    expected_result[q_wr] = 32'sd0;
                else
                    expected_result[q_wr] = reference_result(
                        tap_count, sample_vector, coefficient_vector
                    );
                q_wr = q_wr + 1;
            end
        end
    end

    task automatic build_stream_item(input integer idx);
        integer lane;
        integer n;
        begin
            sample_vector = '0;
            coefficient_vector = '0;
            n = 1 + (idx % LANES);
            tap_count = n;
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (lane < n) begin
                    sample_vector[lane*32 +: 32] =
                        (idx*17 + lane*31 - 300) * 1024;
                    coefficient_vector[lane*32 +: 32] =
                        (((idx + lane) % 7) - 3) * 4096;
                end
            end
        end
    endtask

    task automatic submit_one(
        input logic [5:0] n,
        input logic [LANES*32-1:0] samples,
        input logic [LANES*32-1:0] coefficients
    );
        logic accepted;
        begin
            @(negedge clk);
            in_valid = 1'b1;
            tap_count = n;
            sample_vector = samples;
            coefficient_vector = coefficients;
            accepted = 1'b0;
            while (!accepted) begin
                @(posedge clk);
                if (in_ready)
                    accepted = 1'b1;
                else
                    @(negedge clk); // keep valid and payload unchanged while stalled
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    // Send a continuous stream. When a request is not accepted, valid and the
    // payload remain unchanged until a later accepting edge.
    task automatic submit_stream(input integer item_count);
        integer idx;
        logic accepted;
        begin
            idx = 0;
            @(negedge clk);
            build_stream_item(idx);
            in_valid = 1'b1;
            while (idx < item_count) begin
                @(posedge clk);
                accepted = in_ready;
                if (accepted) begin
                    idx = idx + 1;
                    if (idx < item_count) begin
                        @(negedge clk);
                        build_stream_item(idx);
                    end
                end else begin
                    @(negedge clk); // stable pending request
                end
            end
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic wait_for_drain(input integer target_wr);
        integer guard;
        begin
            guard = 0;
            while ((q_rd < target_wr) && (guard < 500)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (q_rd < target_wr)
                $fatal(1, "timeout waiting for drain: rd=%0d target=%0d", q_rd, target_wr);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        in_valid = 1'b0;
        tap_count = 6'd0;
        sample_vector = '0;
        coefficient_vector = '0;
        out_ready = 1'b1;
        q_wr = 0;
        q_rd = 0;
        cycle_count = 0;
        measure_throughput = 1'b0;
        measured_outputs = 0;
        throughput_gaps = 0;
        last_output_cycle = -1000;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // One tap: 1.0 * 0.5 = 0.5.
        sample_vector = '0;
        coefficient_vector = '0;
        sample_vector[31:0] = 32'sd65536;
        coefficient_vector[31:0] = 32'sd32768;
        submit_one(6'd1, sample_vector, coefficient_vector);
        wait_for_drain(q_wr);

        // Mixed-sign three-tap result: +0.25 - 0.25 - 0.5 = -0.5.
        if (LANES >= 3) begin
            sample_vector = '0;
            coefficient_vector = '0;
            sample_vector[0*32 +: 32] = 32'sd65536;
            sample_vector[1*32 +: 32] = -32'sd32768;
            sample_vector[2*32 +: 32] = 32'sd131072;
            coefficient_vector[0*32 +: 32] = 32'sd16384;
            coefficient_vector[1*32 +: 32] = 32'sd32768;
            coefficient_vector[2*32 +: 32] = -32'sd16384;
            submit_one(6'd3, sample_vector, coefficient_vector);
            wait_for_drain(q_wr);
        end

        // Legal tap count sweep across all tap counts 1..LANES.
        for (k = 1; k <= LANES; k = k + 1) begin
            sample_vector = '0;
            coefficient_vector = '0;
            for (i = 0; i < k; i = i + 1) begin
                sample_vector[i*32 +: 32] = ((i * 17 + 1) % 65536) * 1024;
                coefficient_vector[i*32 +: 32] = (((i * 31 + 7) % 65536) - 32768) * 16;
            end
            submit_one(6'(k), sample_vector, coefficient_vector);
            wait_for_drain(q_wr);
        end

        // Exercise positive saturation.
        sample_vector = '0;
        coefficient_vector = '0;
        sample_vector[31:0] = 32'h7fffffff;
        coefficient_vector[31:0] = 32'h7fffffff;
        submit_one(6'd1, sample_vector, coefficient_vector);
        wait_for_drain(q_wr);

        // Exercise negative saturation.
        sample_vector = '0;
        coefficient_vector = '0;
        sample_vector[31:0] = 32'h80000000;
        coefficient_vector[31:0] = 32'h7fffffff;
        submit_one(6'd1, sample_vector, coefficient_vector);
        wait_for_drain(q_wr);

        // LANES maximum-magnitude positive products exercise every tree lane.
        sample_vector = '0;
        coefficient_vector = '0;
        for (i = 0; i < LANES; i = i + 1) begin
            sample_vector[i*32 +: 32] = 32'h80000000;
            coefficient_vector[i*32 +: 32] = 32'h80000000;
        end
        submit_one(6'(LANES), sample_vector, coefficient_vector);
        wait_for_drain(q_wr);

        // Invalid tap counts return ordered error responses, not outputs that
        // look like valid calculations.
        submit_one(6'd0, '0, '0);
        wait_for_drain(q_wr);
        submit_one(6'(LANES + 1), '0, '0);
        wait_for_drain(q_wr);
        if (LANES < 32) begin
            submit_one(6'd32, '0, '0);
            wait_for_drain(q_wr);
            submit_one(6'd33, '0, '0);
            wait_for_drain(q_wr);
        end else begin
            submit_one(6'd33, '0, '0);
            wait_for_drain(q_wr);
        end
        submit_one(6'd63, '0, '0);
        wait_for_drain(q_wr);

        // Continuous valid stream: prove one output transfer per cycle after fill.
        measure_throughput = 1'b1;
        measured_outputs = 0;
        throughput_gaps = 0;
        last_output_cycle = -1000;
        submit_stream(24);
        wait_for_drain(q_wr);
        measure_throughput = 1'b0;
        if (measured_outputs != 24)
            $fatal(1, "expected 24 measured outputs, got %0d", measured_outputs);
        if (throughput_gaps != 0)
            $fatal(1, "throughput had %0d gaps after output stream started", throughput_gaps);

        // Fill all STAGES pipeline stages while the output is blocked.
        out_ready = 1'b0;
        submit_stream(STAGES);
        if (!out_valid)
            $fatal(1, "expected valid output while backpressured");
        if (in_ready)
            $fatal(1, "expected input backpressure when every stage is occupied");
        held_result = out_result;
        held_error = out_error;
        held_cycles = cycles;
        repeat (3) begin
            @(posedge clk); #1;
            if (!out_valid || out_result !== held_result ||
                out_error !== held_error || cycles !== held_cycles)
                $fatal(1, "output fields changed while stalled");
            if (in_ready)
                $fatal(1, "pipeline failed to backpressure input while full");
        end
        @(negedge clk);
        out_ready = 1'b1;
        wait_for_drain(q_wr);

        // Reset flushes an in-flight response and clears valid state.
        out_ready = 1'b0;
        sample_vector = '0;
        coefficient_vector = '0;
        sample_vector[31:0] = 32'sd65536;
        coefficient_vector[31:0] = 32'sd65536;
        submit_one(6'd1, sample_vector, coefficient_vector);
        timeout = 0;
        while (!out_valid && timeout < 30) begin
            @(negedge clk);
            timeout = timeout + 1;
        end
        if (!out_valid)
            $fatal(1, "no pending output before reset-flush test");
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk); #1;
        if (out_valid)
            $fatal(1, "reset did not clear output valid");
        @(negedge clk);
        rst = 1'b0;
        out_ready = 1'b1;
        repeat (STAGES + 1) begin
            @(posedge clk); #1;
            if (out_valid)
                $fatal(1, "stale output reappeared after pipeline reset");
        end

        // Confirm the reset engine accepts a fresh transaction correctly.
        sample_vector = '0;
        coefficient_vector = '0;
        sample_vector[31:0] = 32'sd131072;
        coefficient_vector[31:0] = 32'sd65536;
        submit_one(6'd1, sample_vector, coefficient_vector);
        wait_for_drain(q_wr);

        if (LANES == 32)
            $display("PASS: NEXUS-32 pipelined FIR arithmetic, 1/cycle throughput, backpressure, errors, and reset tests");
        else
            $display("PASS: NEXUS-32 pipelined FIR (LANES=%0d) arithmetic, 1/cycle throughput, backpressure, errors, and reset tests", LANES);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "pipelined engine testbench timeout");
    end
endmodule
