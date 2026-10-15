`timescale 1ns/1ps

// Models a one-cycle synchronous dual-read tap source: on each clock with
// tap_req_o high, data and read_valid_q are registered. This verifies that the
// engine aligns returned data with its ordered request stream.
module tb_fir_seq_sync_source;
    logic clk_i = 1'b0;
    logic rst_i = 1'b1;
    logic start_i = 1'b0;
    logic [5:0] tap_count_i = 6'd0;
    logic tap_req_o;
    logic [4:0] tap_addr_o;
    logic read_valid_q = 1'b0;
    logic signed [31:0] sample_tap_q = 32'sd0;
    logic signed [31:0] coefficient_tap_q = 32'sd0;
    logic busy_o, done_o, error_o;
    logic signed [31:0] result_o;
    logic [15:0] cycles_o;

    logic signed [31:0] sample_mem [0:31];
    logic signed [31:0] coefficient_mem [0:31];
    integer issue_count = 0;

    always #5 clk_i = ~clk_i;

    always @(posedge clk_i) begin
        if (rst_i) begin
            read_valid_q <= 1'b0;
            sample_tap_q <= 32'sd0;
            coefficient_tap_q <= 32'sd0;
        end else begin
            read_valid_q <= tap_req_o;
            if (tap_req_o) begin
                sample_tap_q <= sample_mem[tap_addr_o];
                coefficient_tap_q <= coefficient_mem[tap_addr_o];
            end
        end
    end

    // Independently check that each requested address is 0,1,...,tap_count-1.
    always @(posedge clk_i) begin
        if (rst_i) begin
            issue_count = 0;
        end else if (tap_req_o) begin
            if (tap_addr_o !== issue_count[4:0])
                $fatal(1, "request order mismatch: addr=%0d expected=%0d",
                       tap_addr_o, issue_count);
            issue_count = issue_count + 1;
        end
    end

    fir_seq_engine dut (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .start_i(start_i),
        .tap_count_i(tap_count_i),
        .tap_req_o(tap_req_o),
        .tap_addr_o(tap_addr_o),
        .tap_valid_i(read_valid_q),
        .sample_tap_i(sample_tap_q),
        .coefficient_tap_i(coefficient_tap_q),
        .busy_o(busy_o),
        .done_o(done_o),
        .error_o(error_o),
        .result_o(result_o),
        .cycles_o(cycles_o)
    );

    task automatic run_case(
        input logic [5:0] taps,
        input logic signed [31:0] expected_result,
        input logic [15:0] expected_cycles
    );
        integer guard;
        begin
            @(negedge clk_i);
            issue_count = 0;
            tap_count_i = taps;
            start_i = 1'b1;
            @(negedge clk_i);
            start_i = 1'b0;

            guard = 0;
            while ((done_o !== 1'b1) && (error_o !== 1'b1) && (guard < 80)) begin
                @(negedge clk_i);
                guard = guard + 1;
            end

            if (error_o !== 1'b0)
                $fatal(1, "valid synchronous-source request rejected");
            if (done_o !== 1'b1)
                $fatal(1, "timeout waiting for synchronous-source result");
            if (result_o !== expected_result)
                $fatal(1, "sync-source result mismatch: got=%0d expected=%0d",
                       result_o, expected_result);
            if (cycles_o !== expected_cycles)
                $fatal(1, "sync-source cycle mismatch: got=%0d expected=%0d",
                       cycles_o, expected_cycles);
            if (issue_count != taps)
                $fatal(1, "issued %0d addresses, expected %0d", issue_count, taps);
            if (busy_o !== 1'b0)
                $fatal(1, "engine remained busy after synchronous-source result");
            @(negedge clk_i);
            if (done_o !== 1'b0)
                $fatal(1, "done_o was not a one-cycle pulse");
        end
    endtask

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1) begin
            sample_mem[i] = 32'sd0;
            coefficient_mem[i] = 32'sd0;
        end

        // Four taps: 1*0.5 + (-1)*0.5 + 2*0.25 + 1*0 = 0.5.
        sample_mem[0] = 32'sd65536;
        coefficient_mem[0] = 32'sd32768;
        sample_mem[1] = -32'sd65536;
        coefficient_mem[1] = 32'sd32768;
        sample_mem[2] = 32'sd131072;
        coefficient_mem[2] = 32'sd16384;
        sample_mem[3] = 32'sd65536;
        coefficient_mem[3] = 32'sd0;

        repeat (2) @(negedge clk_i);
        rst_i = 1'b0;

        run_case(6'd4, 32'sd32768, 16'd5);

        // Repeat with a one-tap unity product; one source-latency cycle plus
        // one valid-response cycle gives two busy cycles.
        sample_mem[0] = 32'sd65536;
        coefficient_mem[0] = 32'sd65536;
        run_case(6'd1, 32'sd65536, 16'd2);

        $display("PASS: NEXUS-32 synchronous tap-source alignment tests");
        $finish;
    end
endmodule
