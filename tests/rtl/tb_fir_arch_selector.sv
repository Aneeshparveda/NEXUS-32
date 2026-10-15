`timescale 1ns/1ps
module tb_fir_arch_selector;
    localparam logic [1:0] ARCH_SEQ  = 2'd0;
    localparam logic [1:0] ARCH_PAR  = 2'd1;
    localparam logic [1:0] ARCH_PIPE = 2'd2;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [1:0] arch_select = ARCH_SEQ;
    logic [5:0] tap_count = 6'd1;
    logic [1023:0] sample_vector = '0;
    logic [1023:0] coefficient_vector = '0;
    logic out_valid;
    logic out_ready = 1'b0;
    logic signed [31:0] out_result;
    logic out_error;
    logic [15:0] cycles;
    logic [1:0] active_arch;

    logic [31:0] rng = 32'h1A2B_3C4D;
    integer transactions_checked = 0;
    integer k, tap;

    always #5 clk = ~clk;

    fir_arch_selector dut (
        .clk_i(clk), .rst_i(rst),
        .in_valid_i(in_valid), .in_ready_o(in_ready),
        .arch_select_i(arch_select), .tap_count_i(tap_count),
        .sample_vector_i(sample_vector), .coefficient_vector_i(coefficient_vector),
        .out_valid_o(out_valid), .out_ready_i(out_ready),
        .out_result_o(out_result), .out_error_o(out_error),
        .cycles_o(cycles), .active_arch_o(active_arch)
    );

    function automatic logic signed [31:0] golden_result(
        input logic [5:0] n,
        input logic [1023:0] svec,
        input logic [1023:0] cvec
    );
        logic signed [31:0] s, c;
        logic signed [63:0] p;
        logic signed [71:0] acc, shifted;
        integer idx;
        begin
            acc = 72'sd0;
            for (idx = 0; idx < 32; idx = idx + 1) begin
                if (idx < n) begin
                    s = $signed(svec[idx*32 +: 32]);
                    c = $signed(cvec[idx*32 +: 32]);
                    p = s * c;
                    acc = acc + $signed({{8{p[63]}}, p});
                end
            end
            shifted = acc >>> 16;
            if (shifted > 72'sd2147483647)
                golden_result = 32'sh7fff_ffff;
            else if (shifted < -72'sd2147483648)
                golden_result = 32'sh8000_0000;
            else
                golden_result = shifted[31:0];
        end
    endfunction

    function automatic logic [31:0] xorshift32(input logic [31:0] value);
        logic [31:0] x;
        begin
            x = value;
            x = x ^ (x << 13);
            x = x ^ (x >> 17);
            x = x ^ (x << 5);
            xorshift32 = x;
        end
    endfunction

    task automatic transact(
        input logic [1:0] arch,
        input logic [5:0] n,
        input logic [1023:0] sv,
        input logic [1023:0] cv,
        input logic expect_error,
        input integer stall_cycles
    );
        logic signed [31:0] expected;
        integer guard, stall;
        begin
            expected = expect_error ? 32'sd0 : golden_result(n, sv, cv);
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            arch_select = arch;
            tap_count = n;
            sample_vector = sv;
            coefficient_vector = cv;
            out_ready = 1'b0;
            in_valid = 1'b1;

            @(posedge clk);
            if (!(in_valid && in_ready))
                $fatal(1, "input handshake did not occur for arch=%0d", arch);
            @(negedge clk);
            in_valid = 1'b0;

            guard = 0;
            while (!out_valid && guard < 120) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!out_valid)
                $fatal(1, "timeout arch=%0d taps=%0d", arch, n);
            if (out_error !== expect_error)
                $fatal(1, "error flag mismatch arch=%0d taps=%0d got=%b expected=%b",
                       arch, n, out_error, expect_error);
            if (out_result !== expected)
                $fatal(1, "result mismatch arch=%0d taps=%0d got=%h expected=%h",
                       arch, n, out_result, expected);
            if (active_arch !== arch)
                $fatal(1, "active architecture mismatch got=%0d expected=%0d", active_arch, arch);

            for (stall = 0; stall < stall_cycles; stall = stall + 1) begin
                @(negedge clk);
                if (!out_valid || out_result !== expected || out_error !== expect_error)
                    $fatal(1, "output changed/dropped under stall arch=%0d", arch);
            end

            out_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            out_ready = 1'b0;
            transactions_checked = transactions_checked + 1;
        end
    endtask

    initial begin : test_sequence
        logic [1023:0] sv, cv;
        logic [5:0] n;
        integer arch, case_idx;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Directed values: unity/fractional, negative floor, saturation.
        sv = '0; cv = '0;
        sv[0*32 +: 32] = 32'h0001_0000; cv[0*32 +: 32] = 32'h0002_0000;
        for (arch = 0; arch < 3; arch = arch + 1)
            transact(arch[1:0], 6'd1, sv, cv, 1'b0, 2);

        sv = '0; cv = '0;
        sv[0*32 +: 32] = 32'sd1; cv[0*32 +: 32] = -32'sd1;
        for (arch = 0; arch < 3; arch = arch + 1)
            transact(arch[1:0], 6'd1, sv, cv, 1'b0, 1);

        sv = '0; cv = '0;
        for (tap = 0; tap < 32; tap = tap + 1) begin
            sv[tap*32 +: 32] = 32'sh8000_0000;
            cv[tap*32 +: 32] = 32'sh8000_0000;
        end
        for (arch = 0; arch < 3; arch = arch + 1)
            transact(arch[1:0], 6'd32, sv, cv, 1'b0, 3);

        sv = '0; cv = '0;
        sv[0*32 +: 32] = 32'sh8000_0000; cv[0*32 +: 32] = 32'sh7fff_ffff;
        sv[1*32 +: 32] = 32'sh8000_0000; cv[1*32 +: 32] = 32'sh7fff_ffff;
        for (arch = 0; arch < 3; arch = arch + 1)
            transact(arch[1:0], 6'd2, sv, cv, 1'b0, 2);

        // Deterministic pseudo-random trials, each architecture checked against
        // the same bit-exact reference calculation.
        for (case_idx = 0; case_idx < 12; case_idx = case_idx + 1) begin
            sv = '0; cv = '0;
            rng = xorshift32(rng);
            n = (rng[4:0] == 5'd31) ? 6'd32 : {1'b0, rng[4:0]} + 6'd1;
            for (tap = 0; tap < 32; tap = tap + 1) begin
                rng = xorshift32(rng);
                sv[tap*32 +: 32] = rng;
                rng = xorshift32(rng);
                cv[tap*32 +: 32] = rng;
            end
            for (arch = 0; arch < 3; arch = arch + 1)
                transact(arch[1:0], n, sv, cv, 1'b0, case_idx % 4);
        end

        // Invalid tap counts and reserved architecture code produce a held,
        // backpressured local error response without starting an engine.
        sv = '0; cv = '0;
        transact(ARCH_SEQ, 6'd0, sv, cv, 1'b1, 3);
        transact(ARCH_PAR, 6'd33, sv, cv, 1'b1, 2);
        transact(2'd3, 6'd4, sv, cv, 1'b1, 3);

        // Reset flush: start a pipeline transaction, reset before it can retire,
        // then ensure no stale response survives and a new request can complete.
        @(negedge clk);
        while (!in_ready) @(negedge clk);
        arch_select = ARCH_PIPE;
        tap_count = 6'd32;
        sample_vector = sv;
        coefficient_vector = cv;
        out_ready = 1'b0;
        in_valid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        repeat (2) @(negedge clk);
        rst = 1'b1;
        repeat (2) @(negedge clk);
        if (out_valid !== 1'b0)
            $fatal(1, "stale output valid survived reset");
        rst = 1'b0;
        @(negedge clk);
        transact(ARCH_PIPE, 6'd1, sv, cv, 1'b0, 1);

        $display("PASS: NEXUS-32 architecture selector, all three engines, validation, stalls, and reset");
        $display("Transactions checked (excluding reset-flushed request): %0d", transactions_checked);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "global selector test timeout");
    end
endmodule
