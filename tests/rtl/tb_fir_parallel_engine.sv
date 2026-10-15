`timescale 1ns/1ps
module tb_fir_parallel_engine #(
    parameter int LANES = 32
);
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
    logic error;
    logic [15:0] cycles;
    logic [LANES*32-1:0] s_work;
    logic [LANES*32-1:0] c_work;
    logic signed [31:0] expected_work;
    integer i;
    integer t;

    fir_parallel_engine #(.LANES(LANES)) dut (
        .clk_i(clk), .rst_i(rst),
        .in_valid_i(in_valid), .in_ready_o(in_ready),
        .tap_count_i(tap_count),
        .sample_vector_i(sample_vector),
        .coefficient_vector_i(coefficient_vector),
        .out_valid_o(out_valid), .out_ready_i(out_ready),
        .out_result_o(out_result), .error_o(error), .cycles_o(cycles)
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
        integer k;
        begin
            acc = 72'sd0;
            for (k = 0; k < LANES; k = k + 1) begin
                if (k < n) begin
                    s = $signed(samples[k*32 +: 32]);
                    c = $signed(coefficients[k*32 +: 32]);
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

    task automatic send_good(
        input logic [5:0] n,
        input logic [LANES*32-1:0] samples,
        input logic [LANES*32-1:0] coefficients
    );
        logic signed [31:0] exp_result;
        begin
            exp_result = reference_result(n, samples, coefficients);
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            in_valid = 1'b1;
            tap_count = n;
            sample_vector = samples;
            coefficient_vector = coefficients;
            @(posedge clk); #1;
            if (!out_valid) $fatal(1, "missing out_valid for tap_count=%0d", n);
            if (error) $fatal(1, "unexpected error for tap_count=%0d", n);
            if (out_result !== exp_result)
                $fatal(1, "parallel mismatch n=%0d got=%0d expected=%0d", n, out_result, exp_result);
            if (cycles !== 16'd1)
                $fatal(1, "expected one-cycle latency, got cycles=%0d", cycles);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic send_bad(input logic [5:0] n);
        begin
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            in_valid = 1'b1;
            tap_count = n;
            sample_vector = '0;
            coefficient_vector = '0;
            @(posedge clk); #1;
            if (!error) $fatal(1, "expected error for invalid tap_count=%0d", n);
            if (out_valid) $fatal(1, "invalid tap_count=%0d produced output", n);
            @(negedge clk);
            in_valid = 1'b0;
        end
    endtask

    task automatic test_backpressure;
        logic [LANES*32-1:0] first_s;
        logic [LANES*32-1:0] first_c;
        logic [LANES*32-1:0] second_s;
        logic [LANES*32-1:0] second_c;
        logic signed [31:0] first_expected;
        logic signed [31:0] second_expected;
        integer stall;
        begin
            first_s = '0;
            first_c = '0;
            second_s = '0;
            second_c = '0;
            first_s[31:0] = 32'sd65536;      // 1.0
            first_c[31:0] = 32'sd65536;      // 1.0 -> 1.0
            second_s[31:0] = 32'sd131072;    // 2.0
            second_c[31:0] = 32'sd65536;     // 1.0 -> 2.0
            first_expected = reference_result(6'd1, first_s, first_c);
            second_expected = reference_result(6'd1, second_s, second_c);

            @(negedge clk);
            out_ready = 1'b0;
            in_valid = 1'b1;
            tap_count = 6'd1;
            sample_vector = first_s;
            coefficient_vector = first_c;
            @(posedge clk); #1;
            if (!out_valid || out_result !== first_expected)
                $fatal(1, "first backpressure result incorrect");

            @(negedge clk);
            // Present a second transaction while the first output is blocked.
            in_valid = 1'b1;
            tap_count = 6'd1;
            sample_vector = second_s;
            coefficient_vector = second_c;
            #1;
            if (in_ready) $fatal(1, "input accepted while output blocked");
            for (stall = 0; stall < 2; stall = stall + 1) begin
                @(posedge clk); #1;
                if (!out_valid || out_result !== first_expected)
                    $fatal(1, "output changed while stalled");
                if (in_ready) $fatal(1, "in_ready high during backpressure");
            end

            @(negedge clk);
            out_ready = 1'b1;
            #1;
            if (!in_ready) $fatal(1, "in_ready did not recover when out_ready asserted");
            @(posedge clk); #1;
            if (!out_valid || out_result !== second_expected)
                $fatal(1, "second result not accepted after backpressure release");
            @(negedge clk);
            in_valid = 1'b0;
            @(posedge clk); #1;
            if (out_valid) $fatal(1, "out_valid did not clear after output consumed");
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
        repeat (3) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // One tap: 1.0 * 0.5 = 0.5.
        s_work = '0;
        c_work = '0;
        s_work[31:0] = 32'sd65536;
        c_work[31:0] = 32'sd32768;
        send_good(6'd1, s_work, c_work);

        // Mixed-sign three-tap example: 0.25 - 0.25 - 0.5 = -0.5.
        if (LANES >= 3) begin
            s_work = '0;
            c_work = '0;
            s_work[0*32 +: 32] = 32'sd65536;
            s_work[1*32 +: 32] = -32'sd32768;
            s_work[2*32 +: 32] = 32'sd131072;
            c_work[0*32 +: 32] = 32'sd16384;
            c_work[1*32 +: 32] = 32'sd32768;
            c_work[2*32 +: 32] = -32'sd16384;
            send_good(6'd3, s_work, c_work);
        end

        // Deterministic LANES-tap window exercises all multiplier lanes and tree levels.
        s_work = '0;
        c_work = '0;
        for (i = 0; i < LANES; i = i + 1) begin
            s_work[i*32 +: 32] = (i - 16) * 65536;
            c_work[i*32 +: 32] = ((i % 5) - 2) * 16384;
        end
        send_good(6'(LANES), s_work, c_work);

        // Tap-count sweep: test every legal tap count 1..LANES with distinct values
        for (t = 1; t <= LANES; t = t + 1) begin
            s_work = '0;
            c_work = '0;
            for (i = 0; i < t; i = i + 1) begin
                s_work[i*32 +: 32] = ((i * 17 + 1) % 65536) * 1024;
                c_work[i*32 +: 32] = (((i * 31 + 7) % 65536) - 32768) * 16;
            end
            send_good(6'(t), s_work, c_work);
        end

        // Full-width operands force positive and negative output saturation.
        s_work = '0;
        c_work = '0;
        s_work[31:0] = 32'h7fffffff;
        c_work[31:0] = 32'h7fffffff;
        send_good(6'd1, s_work, c_work);

        s_work = '0;
        c_work = '0;
        s_work[31:0] = 32'h80000000;
        c_work[31:0] = 32'h7fffffff;
        send_good(6'd1, s_work, c_work);

        // LANES * (INT32_MIN * INT32_MIN) terms remain within signed 72 bits.
        s_work = '0;
        c_work = '0;
        for (i = 0; i < LANES; i = i + 1) begin
            s_work[i*32 +: 32] = 32'h80000000;
            c_work[i*32 +: 32] = 32'h80000000;
        end
        send_good(6'(LANES), s_work, c_work);

        send_bad(6'd0);
        send_bad(6'(LANES + 1));
        if (LANES < 32) begin
            send_bad(6'd32);
            send_bad(6'd33);
        end else begin
            send_bad(6'd33);
        end
        send_bad(6'd63);

        test_backpressure();

        if (LANES == 32)
            $display("PASS: NEXUS-32 parallel FIR, balanced tree, saturation, and backpressure tests");
        else
            $display("PASS: NEXUS-32 parallel FIR (LANES=%0d), balanced tree, saturation, and backpressure tests", LANES);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "parallel engine testbench timeout");
    end
endmodule
