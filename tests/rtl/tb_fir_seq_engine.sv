`timescale 1ns/1ps

module tb_fir_seq_engine;
    logic clk_i = 1'b0;
    logic rst_i = 1'b1;
    logic start_i = 1'b0;
    logic [5:0] tap_count_i = 6'd0;
    logic tap_req_o;
    logic [4:0] tap_addr_o;
    logic tap_valid_i = 1'b1;
    logic signed [31:0] sample_tap_i;
    logic signed [31:0] coefficient_tap_i;
    logic busy_o, done_o, error_o;
    logic signed [31:0] result_o;
    logic [15:0] cycles_o;

    logic signed [31:0] samples [0:31];
    logic signed [31:0] coefficients [0:31];

    always #5 clk_i = ~clk_i;

    // This test uses the zero-wait combinational-source mode: valid is always high
    // and the data mux follows the currently issued address.
    always @* begin
        sample_tap_i = samples[tap_addr_o];
        coefficient_tap_i = coefficients[tap_addr_o];
    end

    fir_seq_engine dut (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .start_i(start_i),
        .tap_count_i(tap_count_i),
        .tap_req_o(tap_req_o),
        .tap_addr_o(tap_addr_o),
        .tap_valid_i(tap_valid_i),
        .sample_tap_i(sample_tap_i),
        .coefficient_tap_i(coefficient_tap_i),
        .busy_o(busy_o),
        .done_o(done_o),
        .error_o(error_o),
        .result_o(result_o),
        .cycles_o(cycles_o)
    );

    task automatic clear_vectors;
        integer i;
        begin
            for (i = 0; i < 32; i = i + 1) begin
                samples[i] = 32'sd0;
                coefficients[i] = 32'sd0;
            end
        end
    endtask

    task automatic run_valid_case(
        input logic [5:0] taps,
        input logic signed [31:0] expected_result
    );
        integer guard;
        begin
            @(negedge clk_i);
            tap_count_i = taps;
            start_i = 1'b1;
            @(negedge clk_i);
            start_i = 1'b0;
            guard = 0;
            while ((done_o !== 1'b1) && (error_o !== 1'b1) && (guard < 40)) begin
                @(negedge clk_i);
                guard = guard + 1;
            end
            if (error_o !== 1'b0)
                $fatal(1, "valid tap_count %0d unexpectedly raised error_o", taps);
            if (done_o !== 1'b1)
                $fatal(1, "timeout waiting for %0d-tap result", taps);
            if (result_o !== expected_result)
                $fatal(1, "result mismatch: taps=%0d got=%0d expected=%0d",
                       taps, result_o, expected_result);
            if (cycles_o !== {10'd0, taps})
                $fatal(1, "cycle count mismatch: taps=%0d got=%0d", taps, cycles_o);
            if (busy_o !== 1'b0)
                $fatal(1, "busy_o remained high after completion");
            @(negedge clk_i);
            if (done_o !== 1'b0)
                $fatal(1, "done_o was not a one-cycle pulse");
        end
    endtask

    task automatic run_invalid_case(input logic [5:0] taps);
        begin
            @(negedge clk_i);
            tap_count_i = taps;
            start_i = 1'b1;
            @(negedge clk_i);
            start_i = 1'b0;
            if (error_o !== 1'b1)
                $fatal(1, "tap_count %0d did not raise error_o", taps);
            if (busy_o !== 1'b0 || done_o !== 1'b0)
                $fatal(1, "invalid request entered busy or reported done");
            @(negedge clk_i);
            if (error_o !== 1'b0)
                $fatal(1, "error_o was not a one-cycle pulse");
        end
    endtask

    initial begin
        clear_vectors();
        repeat (2) @(negedge clk_i);
        rst_i = 1'b0;

        // 1. One-tap unity gain: 1.0 * 1.0 = 1.0.
        samples[0] = 32'sd65536;
        coefficients[0] = 32'sd65536;
        run_valid_case(6'd1, 32'sd65536);

        // 2. Negative fractional product: (-1 raw) * 0.5 -> -32768 raw
        // product, then >>>16 floors to -1.
        clear_vectors();
        samples[0] = -32'sd1;
        coefficients[0] = 32'sd32768;
        run_valid_case(6'd1, -32'sd1);

        // 3. Multi-tap mixed-sign accumulation, one final shift only.
        // 2^31 - 2^32 - 2^32 = -6,442,450,944; >>>16 = -98,304.
        clear_vectors();
        samples[0] = 32'sd65536;
        samples[1] = 32'sd131072;
        samples[2] = -32'sd65536;
        coefficients[0] = 32'sd32768;
        coefficients[1] = -32'sd32768;
        coefficients[2] = 32'sd65536;
        run_valid_case(6'd3, -32'sd98304);

        // 4. Positive saturation.
        clear_vectors();
        samples[0] = 32'sh7fff_ffff;
        coefficients[0] = 32'sh7fff_ffff;
        run_valid_case(6'd1, 32'sh7fff_ffff);

        // 5. Negative saturation.
        clear_vectors();
        samples[0] = 32'sh8000_0000;
        coefficients[0] = 32'sh7fff_ffff;
        run_valid_case(6'd1, 32'sh8000_0000);

        // 6. Maximum supported tap count must use exactly 32 MAC cycles.
        clear_vectors();
        samples[0] = 32'sd65536;
        coefficients[0] = 32'sd65536;
        run_valid_case(6'd32, 32'sd65536);

        // 7. Invalid lengths are rejected without starting work.
        run_invalid_case(6'd0);
        run_invalid_case(6'd33);

        // 8. A one-cycle start pulse while busy is ignored.
        clear_vectors();
        samples[0] = 32'sd65536;
        samples[1] = 32'sd131072;
        samples[2] = 32'sd196608;
        coefficients[0] = 32'sd65536;
        coefficients[1] = 32'sd65536;
        coefficients[2] = 32'sd65536;
        @(negedge clk_i);
        tap_count_i = 6'd3;
        start_i = 1'b1;
        @(negedge clk_i);
        start_i = 1'b0;
        @(negedge clk_i);
        start_i = 1'b1;
        @(negedge clk_i);
        start_i = 1'b0;
        begin : wait_busy_case
            integer guard;
            guard = 0;
            while ((done_o !== 1'b1) && (guard < 10)) begin
                @(negedge clk_i);
                guard = guard + 1;
            end
            if (done_o !== 1'b1 || result_o !== 32'sd393216 || cycles_o !== 16'd3)
                $fatal(1, "start-while-busy test failed: done=%b result=%0d cycles=%0d",
                       done_o, result_o, cycles_o);
        end
        @(negedge clk_i);
        if (busy_o !== 1'b0 || done_o !== 1'b0)
            $fatal(1, "engine did not return idle after busy-start test");

        $display("PASS: NEXUS-32 sequential FIR engine directed tests");
        $finish;
    end
endmodule
