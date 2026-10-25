`timescale 1ns/1ps
module tb_fir_arch_selector #(
    parameter int LANES = 32
);
    localparam logic [1:0] ARCH_SEQ  = 2'd0;
    localparam logic [1:0] ARCH_PAR  = 2'd1;
    localparam logic [1:0] ARCH_PIPE = 2'd2;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic in_valid = 1'b0;
    logic in_ready;
    logic [1:0] arch_select = ARCH_SEQ;
    logic [5:0] tap_count = 6'd1;
    logic [LANES*32-1:0] sample_vector = '0;
    logic [LANES*32-1:0] coefficient_vector = '0;
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

    fir_arch_selector #(.LANES(LANES)) dut (
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
        input logic [LANES*32-1:0] svec,
        input logic [LANES*32-1:0] cvec
    );
        logic signed [31:0] s, c;
        logic signed [63:0] p;
        logic signed [71:0] acc, shifted;
        integer idx;
        begin
            acc = 72'sd0;
            for (idx = 0; idx < LANES; idx = idx + 1) begin
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
        input logic [LANES*32-1:0] sv,
        input logic [LANES*32-1:0] cv,
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

    // U-A7a: PIPE legal with out_ready toggled mid-flight. The toggle
    // lasts 2 cycles after acceptance, before the pipelined output can
    // appear (LATENCY >= 3 at every LANES), so the toggle cannot consume
    // the output early. After the output is consumed, out_valid must
    // clear and in_ready must return to 1, proving active_q cleared only
    // on the consuming edge, and a second transaction must then be
    // accepted (checked by the transact call that follows in the test).
    task automatic transact_pipe_midflight(
        input logic [5:0] n,
        input logic [LANES*32-1:0] sv,
        input logic [LANES*32-1:0] cv
    );
        logic signed [31:0] expected;
        integer guard, stall;
        begin
            expected = golden_result(n, sv, cv);
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            arch_select = ARCH_PIPE;
            tap_count = n;
            sample_vector = sv;
            coefficient_vector = cv;
            out_ready = 1'b0;
            in_valid = 1'b1;
            @(posedge clk);
            if (!(in_valid && in_ready))
                $fatal(1, "U-A7a: input handshake did not occur for PIPE");
            @(negedge clk);
            in_valid = 1'b0;
            out_ready = 1'b1;
            @(negedge clk);
            out_ready = 1'b0;
            @(negedge clk);
            guard = 0;
            while (!out_valid && guard < 120) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!out_valid)
                $fatal(1, "U-A7a: timeout waiting for PIPE output");
            if (out_error !== 1'b0)
                $fatal(1, "U-A7a: error flag mismatch got=%b expected=0", out_error);
            if (out_result !== expected)
                $fatal(1, "U-A7a: result mismatch got=%h expected=%h", out_result, expected);
            if (active_arch !== ARCH_PIPE)
                $fatal(1, "U-A7a: active architecture mismatch got=%0d", active_arch);
            for (stall = 0; stall < 2; stall = stall + 1) begin
                @(negedge clk);
                if (!out_valid || out_result !== expected || out_error !== 1'b0)
                    $fatal(1, "U-A7a: output changed/dropped under stall");
            end
            out_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            out_ready = 1'b0;
            if (out_valid)
                $fatal(1, "U-A7a: output not cleared after consumption");
            if (!in_ready)
                $fatal(1, "U-A7a: selector not ready after PIPE consumption");
            transactions_checked = transactions_checked + 1;
        end
    endtask

    // U-A7b: PIPE invalid tap via the selector, with the named probe from
    // T3-6 addendum R6-2. pipe_in_valid is dut.pipe_in_valid
    // (fir_arch_selector.sv:99-100: in_valid && in_ready &&
    // !invalid_request && arch == ARCH_PIPE). For an invalid request it
    // must never pulse, and the pipelined engine must never present an
    // output for it (dut.u_pipelined_engine.out_valid_o). Both are
    // sampled at every negedge of the local-response window, plus #1
    // after the driving negedge so the combinational probe can settle.
    task automatic transact_pipe_invalid_monitored(input logic [5:0] n);
        integer guard, stall;
        begin
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            arch_select = ARCH_PIPE;
            tap_count = n;
            sample_vector = '0;
            coefficient_vector = '0;
            out_ready = 1'b0;
            in_valid = 1'b1;
            #1;
            if (dut.pipe_in_valid)
                $fatal(1, "U-A7b: pipe_in_valid pulsed for invalid tap=%0d before acceptance", n);
            if (dut.u_pipelined_engine.out_valid_o)
                $fatal(1, "U-A7b: engine output present before invalid tap=%0d acceptance", n);
            @(posedge clk);
            if (!(in_valid && in_ready))
                $fatal(1, "U-A7b: input handshake did not occur for invalid tap=%0d", n);
            @(negedge clk);
            in_valid = 1'b0;
            #1;
            if (dut.pipe_in_valid)
                $fatal(1, "U-A7b: pipe_in_valid pulsed for invalid tap=%0d after acceptance", n);
            guard = 0;
            while (!out_valid && guard < 120) begin
                @(negedge clk);
                #1;
                if (dut.pipe_in_valid)
                    $fatal(1, "U-A7b: pipe_in_valid pulsed while waiting for invalid tap=%0d response", n);
                if (dut.u_pipelined_engine.out_valid_o)
                    $fatal(1, "U-A7b: engine output appeared for invalid tap=%0d", n);
                guard = guard + 1;
            end
            if (!out_valid)
                $fatal(1, "U-A7b: timeout waiting for invalid tap=%0d local response", n);
            if (out_error !== 1'b1)
                $fatal(1, "U-A7b: error flag mismatch tap=%0d got=%b expected=1", n, out_error);
            if (out_result !== 32'sd0)
                $fatal(1, "U-A7b: result mismatch tap=%0d got=%h expected=0", n, out_result);
            if (cycles !== 16'd0)
                $fatal(1, "U-A7b: cycles mismatch tap=%0d got=%0d expected=0", n, cycles);
            if (active_arch !== ARCH_PIPE)
                $fatal(1, "U-A7b: active architecture mismatch got=%0d expected=PIPE", active_arch);
            for (stall = 0; stall < 2; stall = stall + 1) begin
                @(negedge clk);
                #1;
                if (!out_valid || out_result !== 32'sd0 || out_error !== 1'b1)
                    $fatal(1, "U-A7b: invalid response changed/dropped under stall tap=%0d", n);
                if (dut.pipe_in_valid)
                    $fatal(1, "U-A7b: pipe_in_valid pulsed under stall tap=%0d", n);
                if (dut.u_pipelined_engine.out_valid_o)
                    $fatal(1, "U-A7b: engine output appeared under stall tap=%0d", n);
            end
            out_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            out_ready = 1'b0;
            if (out_valid)
                $fatal(1, "U-A7b: invalid response not cleared after consumption tap=%0d", n);
            repeat (2) begin
                @(posedge clk); #1;
                if (out_valid)
                    $fatal(1, "U-A7b: extra output after invalid tap=%0d consumption", n);
                if (dut.u_pipelined_engine.out_valid_o)
                    $fatal(1, "U-A7b: extra engine output after invalid tap=%0d consumption", n);
            end
            transactions_checked = transactions_checked + 1;
        end
    endtask

    initial begin : test_sequence
        logic [LANES*32-1:0] sv, cv;
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
        for (tap = 0; tap < LANES; tap = tap + 1) begin
            sv[tap*32 +: 32] = 32'sh8000_0000;
            cv[tap*32 +: 32] = 32'sh8000_0000;
        end
        for (arch = 0; arch < 3; arch = arch + 1)
            transact(arch[1:0], 6'(LANES), sv, cv, 1'b0, 3);

        if (LANES >= 2) begin
            sv = '0; cv = '0;
            sv[0*32 +: 32] = 32'sh8000_0000; cv[0*32 +: 32] = 32'sh7fff_ffff;
            sv[1*32 +: 32] = 32'sh8000_0000; cv[1*32 +: 32] = 32'sh7fff_ffff;
            for (arch = 0; arch < 3; arch = arch + 1)
                transact(arch[1:0], 6'd2, sv, cv, 1'b0, 2);
        end

        // Deterministic pseudo-random trials, each architecture checked against
        // the same bit-exact reference calculation.
        for (case_idx = 0; case_idx < 12; case_idx = case_idx + 1) begin
            sv = '0; cv = '0;
            rng = xorshift32(rng);
            n = 6'(1 + (rng % LANES));
            for (tap = 0; tap < LANES; tap = tap + 1) begin
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
        // Confirm common 1..LANES tap count bound is enforced across all 3 architectures:
        sv = '0; cv = '0;
        for (arch = 0; arch < 3; arch = arch + 1) begin
            transact(arch[1:0], 6'd0, sv, cv, 1'b1, 2);
            transact(arch[1:0], 6'(LANES + 1), sv, cv, 1'b1, 2);
            if (LANES < 32) begin
                transact(arch[1:0], 6'd32, sv, cv, 1'b1, 1);
                transact(arch[1:0], 6'd33, sv, cv, 1'b1, 1);
            end else begin
                transact(arch[1:0], 6'd33, sv, cv, 1'b1, 1);
            end
        end
        transact(2'd3, 6'd1, sv, cv, 1'b1, 3);

        // Reset flush: start a pipeline transaction, reset before it can retire,
        // then ensure no stale response survives and a new request can complete.
        @(negedge clk);
        while (!in_ready) @(negedge clk);
        arch_select = ARCH_PIPE;
        tap_count = 6'(LANES);
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

        // U-A7 (T3-6 §A.7, LANES pinned by R6-4: all LANES).
        // (a) PIPE legal with out_ready toggled mid-flight, then a
        // second PIPE transaction to prove the selector cleared and
        // re-accepted. (b) PIPE invalid taps with the pipe_in_valid /
        // engine-output monitor, then a legal PIPE transaction to prove
        // no extra engine output interfered before the next legal one.
        sv = '0; cv = '0;
        sv[0*32 +: 32] = 32'h0001_0000; cv[0*32 +: 32] = 32'h0000_8000;
        transact_pipe_midflight(6'd1, sv, cv);
        transact(ARCH_PIPE, 6'd1, sv, cv, 1'b0, 1);
        transact_pipe_invalid_monitored(6'd0);
        transact_pipe_invalid_monitored(6'(LANES + 1));
        transact(ARCH_PIPE, 6'd1, sv, cv, 1'b0, 1);

        // Fingerprint line: prints only if U-A7a and U-A7b above reached
        // it without $fatal. The Transactions checked line below is a
        // second fingerprint: it must be 5 higher than the pre-U-A count
        // (67/67/67/64 for LANES 4/8/16/32, versus 62/62/62/59 before).
        $display("PASS: U-A7 selector stall and invalid-engine-quiescence scenarios");

        if (LANES == 32)
            $display("PASS: NEXUS-32 architecture selector, all three engines, validation, stalls, and reset");
        else
            $display("PASS: NEXUS-32 architecture selector (LANES=%0d), all three engines, validation, stalls, and reset", LANES);
        $display("Transactions checked (excluding reset-flushed request): %0d", transactions_checked);
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "global selector test timeout");
    end
endmodule
