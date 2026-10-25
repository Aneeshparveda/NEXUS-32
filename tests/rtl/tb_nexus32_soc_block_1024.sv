`timescale 1ns/1ps
// T3-2 full-1024 check (Mac-run clone only, accepted by name 2026-10-25).
// Changes vs the shipped bench, and nothing else:
//   * plusarg parsing for +expected_file, +expected_sha,
//     +neg_corrupt_index, +neg_expected_count (defaults below);
//   * load_expected task: fail-closed $fopen/$fscanf load of exactly
//     1024 hex words (MISSING / SHORT / LONG fatals, R2-7 form: the
//     loader counts words, it does NOT claim blank-line detection;
//     blank-line freedom is enforced by the generator + SHA anchor,
//     see APPLY_NOTE.md);
//   * check_full_results automatic task: one loop, called once in the
//     clean run and twice in N1/N2 mode (R2-8), case-inequality (!==),
//     first mismatch only, $fatal with the exact index/expected/actual;
//   * count check takes its expected value from the +neg_expected_count
//     plusarg in N3 mode and emits NEGATIVE_COUNT_MISMATCH there
//     (R2-3 option (a)); the shipped fatal is unchanged otherwise;
//   * in N1/N2 mode no PASS line and no $finish is printed after the
//     clean check (R2-4); the corruption re-check must $fatal first.
// Existing checks, their order, their messages, the PASS line, the
// watchdog, and the global timeout are byte-identical apart from the
// inserted full check and negative hooks. No firmware, RTL, Makefile,
// or CI change is part of this file.
module tb_nexus32_soc_block_1024 #(
    parameter int LANES = 32
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;

    // T3-2 state. expected_sha defaults to the case-A anchor so a clean
    // run is correct even if a plusarg-string mechanism is ignored by
    // the simulator; the runner still passes it explicitly and checks
    // the FULL_CHECK line's SHA against the generator's SHA.
    logic [31:0] expected [0:1023];
    string expected_file;
    string expected_sha;
    integer neg_corrupt_index;
    integer neg_expected_count;
    logic [31:0] neg_expected_count_word;
    bit neg_corrupt_mode;
    bit neg_count_mode;

    always #5 clk = ~clk;

    nexus32_soc #(
        .IMEM_INIT_FILE("build/nexus32_block_1024.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk),
        .rst_i(rst),
        .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault),
        .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done),
        .accelerator_error_o(accel_error)
    );

    // Fail-closed expected-file load (T3-2 section 3.2, as amended).
    // Called only after the PASS sentinel, i.e. after DONE, so the
    // hierarchical result_mem read in check_full_results observes the
    // complete, final block.
    task automatic load_expected;
        integer fd;
        integer k;
        integer code;
        logic [31:0] extra_word;
        begin
            $display("SOC_BLOCK_1024_EXPECTED_FILE path=%s sha=%s", expected_file, expected_sha);
            fd = $fopen(expected_file, "r");
            if (fd == 0)
                $fatal(1, "EXPECTED_FILE_MISSING path=%s", expected_file);
            for (k = 0; k < 1024; k = k + 1) begin
                code = $fscanf(fd, "%h", expected[k]);
                if (code != 1)
                    $fatal(1, "EXPECTED_FILE_SHORT read=%0d expected=1024 path=%s", k, expected_file);
            end
            code = $fscanf(fd, "%h", extra_word);
            if (code == 1)
                $fatal(1, "EXPECTED_FILE_LONG read_more_than_1024 path=%s", expected_file);
            $fclose(fd);
        end
    endtask

    // Single comparison loop (T3-2 section 3.3, R2-8). Called once in a
    // clean run, twice in N1/N2 mode. Never copy-pasted.
    task automatic check_full_results;
        integer k;
        begin
            for (k = 0; k < 1024; k = k + 1) begin
                if (dut.u_accel_bus.result_mem[k] !== expected[k])
                    $fatal(1, "FULL_RESULT_MISMATCH index=%0d expected=%08x actual=%08x",
                           k, expected[k], dut.u_accel_bus.result_mem[k]);
            end
            $display("SOC_BLOCK_1024_FULL_CHECK lanes=%0d checked=1024 first_mismatch=none expected_sha=%s", LANES, expected_sha);
        end
    endtask

    initial begin : RUN_TEST
        // Defaults, then plusarg overrides (plusarg-primary, T3-2 3.1).
        expected_file = "build/block_1024_expected.mem";
        expected_sha = "6a0dcde7a927d0d181c931f8df773510c0078e4f18d965c1ee6e82da752c0a16";
        neg_corrupt_index = -1;
        neg_expected_count = 1024;
        neg_corrupt_mode = 1'b0;
        neg_count_mode = 1'b0;
        if ($value$plusargs("expected_file=%s", expected_file)) begin end
        if ($value$plusargs("expected_sha=%s", expected_sha)) begin end
        if ($value$plusargs("neg_corrupt_index=%d", neg_corrupt_index))
            neg_corrupt_mode = 1'b1;
        if ($value$plusargs("neg_expected_count=%d", neg_expected_count))
            neg_count_mode = 1'b1;
        neg_expected_count_word = neg_expected_count;
        if (neg_corrupt_mode && neg_count_mode)
            $fatal(1, "NEGATIVE_MODES_EXCLUSIVE corrupt and count modes must not combine");
        if (neg_corrupt_mode && (neg_corrupt_index < 0 || neg_corrupt_index > 1023))
            $fatal(1, "NEGATIVE_CORRUPT_INDEX_OUT_OF_RANGE index=%0d", neg_corrupt_index);

        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (cycle = 0; cycle < 2000000; cycle = cycle + 1) begin
            @(negedge clk);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during CPU-driven 1024-sample block; dmem[0..9]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                       dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
                       dut.dmem[8], dut.dmem[9]);
            if (cpu_bus_fault === 1'b1)
                $fatal(1, "unexpected CPU/system bus fault during CPU-driven block; dmem[6..9]=%08x %08x %08x %08x",
                       dut.dmem[6], dut.dmem[7], dut.dmem[8], dut.dmem[9]);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "1024-sample firmware failure cause=%0d status=%08x result_count=%0d result_words=%08x %08x %08x %08x",
                       dut.dmem[6], dut.dmem[7], dut.dmem[8], dut.dmem[1],
                       dut.dmem[3], dut.dmem[4], dut.dmem[5]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'd32768 || dut.dmem[3] !== 32'd49152 ||
                    dut.dmem[4] !== 32'd65536 || dut.dmem[5] !== 32'd65536)
                    $fatal(1, "representative result mismatch: result[0..2]/result[1023]=%08x %08x %08x %08x",
                           dut.dmem[1], dut.dmem[3], dut.dmem[4], dut.dmem[5]);
                // Count gate. In N3 mode the expected count comes from
                // the plusarg and the fatal string is NEGATIVE_COUNT_
                // MISMATCH (R2-3 option (a)); otherwise the shipped
                // fatal is unchanged.
                if (neg_count_mode) begin
                    if (dut.dmem[8] !== neg_expected_count_word || dut.dmem[9] !== 32'h00000002)
                        $fatal(1, "NEGATIVE_COUNT_MISMATCH observed=%0d expected=%0d",
                               dut.dmem[8], neg_expected_count);
                end else if (dut.dmem[8] !== 32'd1024 || dut.dmem[9] !== 32'h00000002) begin
                    $fatal(1, "firmware predicate observation mismatch: RESULT_COUNT=%0d STATUS=%08x",
                           dut.dmem[8], dut.dmem[9]);
                end
                if (accel_busy || !accel_done || accel_error)
                    $fatal(1, "terminal accelerator state invalid: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                // Full-1024 check, after all existing checks, before
                // RESULT / PASS (T3-2 section 3.3, R2-2 rationale:
                // PASS stays last because it is this bench's own
                // stable signal, not because the closure gate keys on it).
                load_expected;
                if (neg_corrupt_mode) begin
                    // N1/N2 two-stage: clean check first, then corrupt
                    // the completed block hierarchically, then re-check
                    // with the same task. No PASS and no $finish here
                    // (R2-4); only the re-check $fatal ends the run.
                    check_full_results;
                    dut.u_accel_bus.result_mem[neg_corrupt_index] =
                        dut.u_accel_bus.result_mem[neg_corrupt_index] + 32'd1;
                    check_full_results;
                    $fatal(1, "NEGATIVE_CORRUPTION_NOT_DETECTED index=%0d", neg_corrupt_index);
                end else begin
                    check_full_results;
                    $display("SOC_BLOCK_1024_RESULT lanes=%0d SAMPLE_COUNT=1024 TAP_COUNT=3 RESULT_COUNT=%0d STATUS=%08x architecture=sequential",
                             LANES, dut.dmem[8], dut.dmem[9]);
                    $display("PASS: CPU-driven SAMPLE_COUNT=1024 TAP_COUNT=3 RESULT_COUNT=1024 STATUS=0x00000002 block regression; serialized-shell caveat: system-level throughput remains bus-arbitration bound");
                    $finish;
                end
            end
        end
        $fatal(1, "1024-sample CPU firmware watchdog expired; dmem[0..9]=%08x %08x %08x %08x %08x %08x %08x %08x %08x %08x",
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5], dut.dmem[6], dut.dmem[7],
               dut.dmem[8], dut.dmem[9]);
    end

    initial begin
        #250000000;
        $fatal(1, "global CPU-driven 1024-sample block testbench timeout");
    end
endmodule
