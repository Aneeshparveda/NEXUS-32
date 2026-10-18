`timescale 1ns/1ps

// Batch 3B-3A acceptance specification, NOT a replacement for existing tests.
// Normative: ACCELERATOR_CONTRACT_V1.md sections 2, 4.1, 6.1, 6.4 and 7.
// Run from the repository root (no generated fixtures or network required):
// mkdir -p results/rtl
// iverilog -g2012 -Wall -s tb_fir_seq_accel_block_processing \
//   -o results/rtl/tb_fir_seq_accel_block_processing.vvp \
//   rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
//   rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv \
//   rtl/fir_arch_selector.sv rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv \
//   rtl/nexus32_accel_bus.sv tests/rtl/tb_fir_seq_accel_block_processing.sv
// vvp results/rtl/tb_fir_seq_accel_block_processing.vvp
//
// This bench observes the existing selector boundary rather than referring to
// nonexistent future pending/history register names. While input valid is high,
// lane 0 is the pending sample and lanes 1..T-1 expose pre-acceptance history.
// The reference history advances ONLY at input transfer. Every presented window
// (including stalled cycles) must match it, not merely the eventual output.
// Active configuration registers, in contrast, already exist and are asserted
// directly on START and throughout each run; CSR readback is not their oracle.
// Result commits are observed at the REAL bus result_mem write edge, not when
// the shell raises its registered write request. No production logic is mocked.
module tb_fir_seq_accel_block_processing;
    localparam int LANES = 32;
    localparam int RUN_BOUND = 1000;
    localparam logic [31:0] CSR_BASE = 32'h1000_5000;
    localparam logic [31:0] COEFF_BASE = 32'h0002_0000;
    localparam logic [31:0] SAMPLE_BASE = 32'h0002_1000;
    localparam logic [31:0] RESULT_BASE = 32'h0002_2000;
    localparam logic [31:0] RESULT_LIMIT = 32'h0002_3000;
    localparam logic [11:0] CTRL = 12'h000, STATUS = 12'h004;
    localparam logic [11:0] TAP_COUNT = 12'h008, COEFF_PTR = 12'h00c;
    localparam logic [11:0] INPUT_PTR = 12'h010, OUTPUT_PTR = 12'h014;
    localparam logic [11:0] CYCLES_TOTAL = 12'h018, SAMPLE_COUNT = 12'h01c;
    localparam logic [11:0] COMPUTE_CYCLES = 12'h020, DBG_STATUS = 12'h030;
    localparam logic [11:0] RESULT_COUNT = 12'h03c;

    localparam int WINDOW = 0, NUMERIC = 1, TRAVERSAL = 2, COMMIT = 3;
    localparam int VALIDITY = 4, STALL = 5, RESET = 6, SNAPSHOT = 7;
    localparam int PREFLIGHT = 8, INTERFACE = 9, CATEGORY_COUNT = 10;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic req_valid = 1'b0, req_write = 1'b0;
    logic [31:0] req_addr = 32'd0, req_wdata = 32'd0;
    logic [3:0] req_wstrb = 4'hf;
    wire req_ready, rsp_valid, rsp_error, bus_fault;
    wire [31:0] rsp_rdata;
    wire busy, done, error_status;

    nexus32_accel_bus #(.LANES(LANES)) dut (
        .clk_i(clk), .rst_i(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .req_write_i(req_write), .req_addr_i(req_addr),
        .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_rdata_o(rsp_rdata),
        .rsp_error_o(rsp_error), .bus_fault_sticky_o(bus_fault),
        .accelerator_busy_o(busy), .accelerator_done_o(done),
        .accelerator_error_o(error_status)
    );
    always #5 clk = ~clk;

    logic [31:0] vectors [0:47];
    logic signed [31:0] samples [0:3];
    logic signed [31:0] coefficients [0:3];
    logic signed [31:0] expected [0:3];
    logic signed [31:0] accepted_history [0:LANES-2];
    logic [31:0] memory_before [0:1023];
    integer failures = 0, testbench_errors = 0, cases = 0;
    integer category_failures [0:CATEGORY_COUNT-1];
    logic [CATEGORY_COUNT-1:0] reported = '0;
    string case_name = "initialization";
    integer cfg_m, cfg_t, cfg_arch, sample_word, coefficient_word, result_word;
    logic [31:0] cfg_input, cfg_coefficient, cfg_output;
    integer input_count = 0, output_count = 0, commit_count = 0;
    integer stalled_cycles = 0, snapshot_checks = 0;
    integer legacy_requests = 0, sample_requests = 0, coefficient_requests = 0;
    logic ownership_seen = 1'b0;
    logic watch_run = 1'b0, started = 1'b0, snapshot_live = 1'b0;
    logic reject_watch = 1'b0, flush_guard = 1'b0;
    logic gate_installed = 1'b0, stall_engine = 1'b0;
    logic [31:0] guard_before, guard_after;

    // Gate the SINGLE ready signal used by both the shell and the selector's
    // own acceptance logic. Forcing only the shell's copy would allow a phantom
    // engine transfer and would be a testbench bug. The native expression below
    // mirrors fir_arch_selector's current readiness, NOT any compute behavior.
    // Keeping a continuous expression also avoids stale procedural-ready state
    // when a force is released. Data, valid, snapshots and results are never forced.
    wire native_engine_ready = !dut.u_accel.u_arch_selector.active_q &&
        ((dut.u_accel.run_arch_q == 2'd0) ? !dut.u_accel.u_arch_selector.seq_busy :
         (dut.u_accel.run_arch_q == 2'd1) ? dut.u_accel.u_arch_selector.par_in_ready :
         (dut.u_accel.run_arch_q == 2'd2) ? dut.u_accel.u_arch_selector.pipe_in_ready : 1'b1);
    wire gated_engine_ready = native_engine_ready && !stall_engine;

    function automatic string category_name(input integer category);
        case (category)
            WINDOW: category_name = "WINDOW/HISTORY";
            NUMERIC: category_name = "GOLDEN_OUTPUT";
            TRAVERSAL: category_name = "BLOCK_TRAVERSAL";
            COMMIT: category_name = "PHYSICAL_COMMIT";
            VALIDITY: category_name = "RESULT_VALIDITY";
            STALL: category_name = "PENDING_STALL";
            RESET: category_name = "RESET_FLUSH";
            SNAPSHOT: category_name = "ACTIVE_SNAPSHOT";
            PREFLIGHT: category_name = "PREFLIGHT";
            default: category_name = "BUS/ENGINE_PROTOCOL";
        endcase
    endfunction

    task automatic check(input logic condition, input integer category, input string detail);
        begin
            // Suppress repeated messages, NOT checks, for one category in a case.
            // Every violation still makes the overall simulation fail.
            if (condition !== 1'b1 && !reported[category]) begin
                failures = failures + 1;
                category_failures[category] = category_failures[category] + 1;
                reported[category] = 1'b1;
                $display("CONTRACT_FAIL [%s] %s: %s", category_name(category), case_name, detail);
            end
        end
    endtask

    task automatic tb_error(input string detail);
        begin
            testbench_errors = testbench_errors + 1;
            $fatal(1, "TB_ERROR %s: %s (contract_failures=%0d)", case_name, detail, failures);
        end
    endtask

    function automatic logic signed [31:0] reference_output(input integer n, input integer taps);
        logic signed [31:0] s, c;
        logic signed [63:0] product;
        logic signed [71:0] accumulator, term72, shifted;
        integer k;
        begin
            accumulator = 72'sd0;
            for (k = 0; k < taps; k = k + 1) begin
                s = (n >= k) ? samples[n-k] : 32'sd0;
                c = coefficients[k];
                product = s * c;
                term72 = $signed({{8{product[63]}}, product});
                accumulator = accumulator + term72;
            end
            shifted = accumulator >>> 16;
            if (shifted > 72'sd2147483647) reference_output = 32'sh7fff_ffff;
            else if (shifted < -72'sd2147483648) reference_output = 32'sh8000_0000;
            else reference_output = shifted[31:0];
        end
    endfunction

    task automatic install_ready_gate;
        begin
            gate_installed = 1'b1;
            force dut.u_accel.u_arch_selector.in_ready_o = gated_engine_ready;
        end
    endtask

    task automatic remove_ready_gate;
        begin
            stall_engine = 1'b0;
            #1;
            if (gate_installed) release dut.u_accel.u_arch_selector.in_ready_o;
            gate_installed = 1'b0;
        end
    endtask

    task automatic bus_xfer(
        input logic write_op, input logic [31:0] address, input logic [31:0] data,
        output logic [31:0] read_data, output logic transaction_error
    );
        integer waited;
        begin
            @(negedge clk);
            waited = 0;
            while (req_ready !== 1'b1 && waited < 50) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (req_ready !== 1'b1) tb_error("bus never became ready");
            req_valid = 1'b1;
            req_write = write_op;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 4'hf;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            waited = 0;
            while (rsp_valid !== 1'b1 && waited < 50) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (rsp_valid !== 1'b1) tb_error($sformatf("bus response missing at %08x", address));
            read_data = rsp_rdata;
            transaction_error = rsp_error;
            req_write = 1'b0;
            req_addr = 32'd0;
            req_wdata = 32'd0;
            @(negedge clk);
        end
    endtask

    task automatic csr_write(input logic [11:0] offset, input logic [31:0] data,
                             input logic expected_error);
        logic [31:0] rd;
        logic err;
        begin
            bus_xfer(1'b1, CSR_BASE + {20'd0, offset}, data, rd, err);
            check(err === expected_error && rd === 32'd0, INTERFACE,
                  $sformatf("CSR write %03x response error=%b data=%08x", offset, err, rd));
        end
    endtask

    task automatic csr_expect(input logic [11:0] offset, input logic [31:0] value,
                              input integer category);
        logic [31:0] rd;
        logic err;
        begin
            bus_xfer(1'b0, CSR_BASE + {20'd0, offset}, 32'd0, rd, err);
            check(!err && rd === value, category,
                  $sformatf("CSR %03x got %08x expected %08x error=%b", offset, rd, value, err));
        end
    endtask

    wire [135:0] active_snapshot = {
        dut.u_accel.tap_count_active_q, dut.u_accel.sample_count_active_q,
        dut.u_accel.coefficient_ptr_active_q, dut.u_accel.input_ptr_active_q,
        dut.u_accel.output_ptr_active_q, dut.u_accel.run_arch_q
    };

    task automatic check_active_snapshot;
        begin
            snapshot_checks = snapshot_checks + 1;
            check(dut.u_accel.tap_count_active_q === 6'(cfg_t) &&
                  dut.u_accel.sample_count_active_q === 32'(cfg_m) &&
                  dut.u_accel.coefficient_ptr_active_q === cfg_coefficient &&
                  dut.u_accel.input_ptr_active_q === cfg_input &&
                  dut.u_accel.output_ptr_active_q === cfg_output &&
                  dut.u_accel.run_arch_q === 2'(cfg_arch), SNAPSHOT,
                  "active tap/count/pointer/architecture snapshot changed or was not captured on START");
        end
    endtask

    function automatic logic [LANES*32-1:0] active_lanes(
        input logic [LANES*32-1:0] vector_in
    );
        integer k;
        begin
            active_lanes = '0;
            for (k = 0; k < cfg_t; k = k + 1)
                active_lanes[k*32 +: 32] = vector_in[k*32 +: 32];
        end
    endfunction

    task automatic check_presented_window;
        integer k;
        logic signed [31:0] wanted, observed;
        begin
            check(input_count < cfg_m, TRAVERSAL, "extra or duplicated engine input");
            if (input_count < cfg_m) begin
                for (k = 0; k < cfg_t; k = k + 1) begin
                    wanted = (k == 0) ? samples[input_count] : accepted_history[k-1];
                    observed = $signed(dut.u_accel.u_arch_selector.sample_vector_i[k*32 +: 32]);
                    check(observed === wanted, WINDOW,
                          $sformatf("window[%0d] lane %0d got %08x expected %08x (pre-acceptance history)",
                                    input_count, k, observed, wanted));
                    check(dut.u_accel.u_arch_selector.coefficient_vector_i[k*32 +: 32] ===
                          coefficients[k], WINDOW,
                          $sformatf("coefficient lane %0d changed or is out of order", k));
                end
            end
            check(dut.u_accel.u_arch_selector.tap_count_i === 6'(cfg_t) &&
                  dut.u_accel.u_arch_selector.arch_select_i === 2'(cfg_arch), SNAPSHOT,
                  "engine is not using the active tap/architecture snapshot");
        end
    endtask

    // Sample edge events BEFORE NBA updates, inspect memories/status AFTER NBA.
    // This is the same edge at which nexus32_accel_bus actually writes result_mem.
    // Counting result_commit after NBA instead would hide the current early-DONE
    // and early-RESULT_COUNT deviations by calling a write request a commit.
    always @(posedge clk) begin : OBSERVE_EVENTS
        logic reset_edge, input_edge, output_edge, commit_edge, stalled_edge;
        logic [LANES*32-1:0] held_window, held_coefficients;
        logic [31:0] written_address, written_data;
        integer k;
        reset_edge = rst || dut.u_accel.soft_reset_request_now;
        input_edge = dut.u_accel.u_arch_selector.in_valid_i &&
                     dut.u_accel.u_arch_selector.in_ready_o;
        output_edge = dut.u_accel.u_arch_selector.out_valid_o &&
                      dut.u_accel.u_arch_selector.out_ready_i;
        commit_edge = !rst && dut.result_commit &&
                      (dut.result_commit_addr >= RESULT_BASE) &&
                      (dut.result_commit_addr < RESULT_LIMIT) &&
                      (dut.result_commit_addr[1:0] == 2'b00);
        written_address = dut.result_commit_addr;
        written_data = dut.result_commit_data;
        stalled_edge = 1'b0;

        if ((watch_run || reject_watch) && !reset_edge) begin
            if (dut.u_accel.prefetch_req) legacy_requests = legacy_requests + 1;
            if (dut.u_accel.u_tap_bram.accelerator_sample_re_i)
                sample_requests = sample_requests + 1;
            if (dut.u_accel.u_tap_bram.accelerator_coefficient_re_i)
                coefficient_requests = coefficient_requests + 1;
            if (dut.bank_owned || dut.u_accel.reserve_banks_now) ownership_seen = 1'b1;
        end
        if (reject_watch && !reset_edge) begin
            check(!dut.u_accel.prefetch_req &&
                  !dut.u_accel.u_tap_bram.accelerator_sample_re_i &&
                  !dut.u_accel.u_tap_bram.accelerator_coefficient_re_i &&
                  !dut.result_commit && !dut.bank_owned && !dut.u_accel.reserve_banks_now,
                  PREFLIGHT, "invalid START issued accelerator traffic or acquired ownership");
        end

        if (reset_edge) begin
            if (watch_run) flush_guard = 1'b1;
            started = 1'b0;
            snapshot_live = 1'b0;
        end else begin
            if (watch_run && dut.u_accel.reserve_banks_now) begin
                check(!started, INTERFACE, "a second run was accepted while a run was active");
                started = 1'b1;
                snapshot_live = 1'b1;
            end
            if (watch_run && started) begin
                if (dut.u_accel.u_arch_selector.in_valid_i === 1'b1)
                    check_presented_window();
                // The selector and all three selected-engine starts must agree
                // with the controller handshake, including under injected stalls.
                check((dut.u_accel.u_arch_selector.seq_start ||
                       dut.u_accel.u_arch_selector.par_in_valid ||
                       dut.u_accel.u_arch_selector.pipe_in_valid) === input_edge,
                      INTERFACE, "phantom/missing engine acceptance at selector boundary");
                if (dut.u_accel.u_arch_selector.in_valid_i &&
                    !dut.u_accel.u_arch_selector.in_ready_o) begin
                    stalled_edge = 1'b1;
                    stalled_cycles = stalled_cycles + 1;
                    held_window = active_lanes(dut.u_accel.u_arch_selector.sample_vector_i);
                    held_coefficients = active_lanes(dut.u_accel.u_arch_selector.coefficient_vector_i);
                end
                if (input_edge) begin
                    // This is the only reference-history update in the bench.
                    // Neither a memory response, an output nor a commit updates it.
                    if (input_count < cfg_m) begin
                        for (k = cfg_t-2; k > 0; k = k - 1)
                            accepted_history[k] = accepted_history[k-1];
                        if (cfg_t > 1) accepted_history[0] = samples[input_count];
                    end
                    input_count = input_count + 1;
                end
                if (output_edge) begin
                    check(output_count < input_count && output_count < cfg_m, TRAVERSAL,
                          "engine output without a unique ordered accepted input");
                    if (output_count < cfg_m)
                        check(dut.u_accel.u_arch_selector.out_result_o === expected[output_count] &&
                              !dut.u_accel.u_arch_selector.out_error_o, NUMERIC,
                              $sformatf("output[%0d] got %08x expected golden %08x", output_count,
                                        dut.u_accel.u_arch_selector.out_result_o, expected[output_count]));
                    check(dut.u_accel.u_arch_selector.active_arch_o === 2'(cfg_arch), SNAPSHOT,
                          "output came from the wrong selected architecture");
                    output_count = output_count + 1;
                end
                if (dut.result_commit) begin
                    check(commit_edge && commit_count < cfg_m && commit_count < output_count,
                          COMMIT, "invalid/extra write or result write without an output transfer");
                    check(written_address === cfg_output + 32'(4*commit_count), COMMIT,
                          $sformatf("commit[%0d] address %08x expected %08x", commit_count,
                                    written_address, cfg_output + 32'(4*commit_count)));
                    if (commit_count < cfg_m)
                        check(written_data === expected[commit_count], NUMERIC,
                              $sformatf("commit[%0d] data %08x expected golden %08x",
                                        commit_count, written_data, expected[commit_count]));
                    if (commit_edge) commit_count = commit_count + 1;
                end
            end
        end

        #1;
        if (snapshot_live) check_active_snapshot();
        if (watch_run && started && !reset_edge) begin
            if (stalled_edge) begin
                check(dut.u_accel.u_arch_selector.in_valid_i === 1'b1 &&
                      active_lanes(dut.u_accel.u_arch_selector.sample_vector_i) === held_window &&
                      active_lanes(dut.u_accel.u_arch_selector.coefficient_vector_i) === held_coefficients,
                      STALL, "pending valid/sample/complete active window changed before acceptance");
            end
            if (commit_edge)
                check(dut.result_mem[written_address[11:2]] === written_data, COMMIT,
                      "write request did not reach physical result memory on the observed edge");
            check(dut.u_accel.result_count_q === 32'(commit_count), COMMIT,
                  $sformatf("RESULT_COUNT=%0d but physical commits=%0d (must not count e_out)",
                            dut.u_accel.result_count_q, commit_count));
            if (commit_count < cfg_m)
                check(busy === 1'b1 && dut.bank_owned === 1'b1 && done === 1'b0 &&
                      error_status === 1'b0, VALIDITY,
                      $sformatf("block completed/released ownership before all %0d commits (seen %0d)",
                                cfg_m, commit_count));
            else
                check(busy === 1'b0 && done === 1'b1 && error_status === 1'b0,
                      VALIDITY, "final physical commit did not make the complete block valid");
            if (!busy && done && !error_status && dut.u_accel.result_count_q == 32'(cfg_m))
                check(input_count == cfg_m && output_count == cfg_m && commit_count == cfg_m,
                      VALIDITY, "firmware success predicate became true before all physical commits");
        end
        if (flush_guard)
            check(!dut.u_accel.u_arch_selector.in_valid_i &&
                  !dut.u_accel.u_arch_selector.out_valid_o && !dut.result_commit &&
                  !busy && !done && !error_status && !dut.bank_owned &&
                  dut.u_accel.result_count_q === 32'd0, RESET,
                  "reset-era pending window/output/commit escaped the flush");
    end

    task automatic hardware_reset;
        begin
            watch_run = 1'b0;
            snapshot_live = 1'b0;
            reject_watch = 1'b0;
            flush_guard = 1'b0;
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            rst = 1'b1;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            remove_ready_gate();
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic new_case(
        input string name_in, input integer m, input integer taps,
        input integer architecture, input integer dataset, input logic reset_first
    );
        integer k;
        begin
            watch_run = 1'b0;
            snapshot_live = 1'b0;
            reject_watch = 1'b0;
            flush_guard = 1'b0;
            if (reset_first) hardware_reset();
            case_name = name_in;
            cases = cases + 1;
            reported = '0;
            cfg_m = m;
            cfg_t = taps;
            cfg_arch = architecture;
            // Deliberately nonzero, distinct offsets catch use of reset/base
            // pointers instead of the actual per-run active snapshots.
            coefficient_word = 11 + dataset*8;
            sample_word = 23 + dataset*8;
            result_word = 37 + architecture*8;
            cfg_coefficient = COEFF_BASE + 32'(4*coefficient_word);
            cfg_input = SAMPLE_BASE + 32'(4*sample_word);
            cfg_output = RESULT_BASE + 32'(4*result_word);
            for (k = 0; k < 4; k = k + 1) begin
                samples[k] = $signed(vectors[dataset*16+k]);
                coefficients[k] = $signed(vectors[dataset*16+4+k]);
                expected[k] = $signed(vectors[dataset*16+((taps == 1) ? 8 : 12)+k]);
            end
            for (k = 0; k < 4; k = k + 1)
                if (reference_output(k, taps) !== expected[k])
                    tb_error($sformatf("SV numerical oracle disagrees with golden fixture at n=%0d", k));
            $display("CASE %0d: %s (M=%0d T=%0d ARCH=%0d)", cases, case_name, m, taps, architecture);
        end
    endtask

    task automatic initialize_memories;
        integer k;
        logic [31:0] rd;
        logic err;
        begin
            // Poison both sides of the block. Pre-block BRAM is NOT logical
            // history; future samples are NOT the first sample's older taps.
            for (k = -1; k < 6; k = k + 1) begin
                bus_xfer(1'b1, cfg_input + 32'(4*k), 32'h5a5a_0100 + 32'(k), rd, err);
                check(!err, INTERFACE, "sample poison initialization rejected");
                bus_xfer(1'b1, cfg_coefficient + 32'(4*k), 32'h3535_0200 + 32'(k), rd, err);
                check(!err, INTERFACE, "coefficient poison initialization rejected");
            end
            for (k = 0; k < 4; k = k + 1) begin
                bus_xfer(1'b1, cfg_input + 32'(4*k), samples[k], rd, err);
                check(!err, INTERFACE, "sample initialization rejected");
                bus_xfer(1'b1, cfg_coefficient + 32'(4*k), coefficients[k], rd, err);
                check(!err, INTERFACE, "coefficient initialization rejected");
            end
        end
    endtask

    task automatic configure_run;
        begin
            csr_write(TAP_COUNT, 32'(cfg_t), 1'b0);
            csr_write(SAMPLE_COUNT, 32'(cfg_m), 1'b0);
            csr_write(COEFF_PTR, cfg_coefficient, 1'b0);
            csr_write(INPUT_PTR, cfg_input, 1'b0);
            csr_write(OUTPUT_PTR, cfg_output, 1'b0);
        end
    endtask

    task automatic arm_trace;
        integer k;
        begin
            input_count = 0;
            output_count = 0;
            commit_count = 0;
            stalled_cycles = 0;
            snapshot_checks = 0;
            legacy_requests = 0;
            sample_requests = 0;
            coefficient_requests = 0;
            ownership_seen = 1'b0;
            for (k = 0; k < LANES-1; k = k + 1) accepted_history[k] = 32'sd0;
            guard_before = dut.result_mem[result_word-1];
            guard_after = dut.result_mem[result_word+cfg_m];
            started = 1'b0;
            flush_guard = 1'b0;
            watch_run = 1'b1;
        end
    endtask

    task automatic start_run;
        begin
            arm_trace();
            csr_write(CTRL, (32'(cfg_arch) << 2) | 32'd1, 1'b0);
            check(started && ownership_seen && snapshot_checks > 0, SNAPSHOT,
                  "valid START did not acquire ownership and directly capture an active snapshot");
        end
    endtask

    task automatic finish_run;
        integer waited, k;
        logic [31:0] rd;
        logic err;
        begin
            waited = 0;
            while (busy === 1'b1 && waited < RUN_BOUND) begin
                @(negedge clk);
                waited = waited + 1;
            end
            check(busy === 1'b0, TRAVERSAL, "block failed to terminate within bounded drain");
            // Observe the registered write reaching memory, and catch extra
            // transfers after purported completion, before closing the trace.
            repeat (12) @(negedge clk);
            check(input_count == cfg_m && output_count == cfg_m && commit_count == cfg_m,
                  TRAVERSAL, $sformatf("expected %0d ordered inputs/outputs/commits, got %0d/%0d/%0d",
                                      cfg_m, input_count, output_count, commit_count));
            csr_expect(STATUS, 32'd2, VALIDITY);
            csr_expect(RESULT_COUNT, 32'(cfg_m), COMMIT);
            csr_expect(SAMPLE_COUNT, 32'(cfg_m), SNAPSHOT);
            if (busy === 1'b0) begin
                for (k = 0; k < cfg_m; k = k + 1) begin
                    bus_xfer(1'b0, cfg_output + 32'(4*k), 32'd0, rd, err);
                    check(!err && rd === expected[k], NUMERIC,
                          $sformatf("physical result[%0d] got %08x expected golden %08x error=%b",
                                    k, rd, expected[k], err));
                end
            end
            check(dut.result_mem[result_word-1] === guard_before &&
                  dut.result_mem[result_word+cfg_m] === guard_after, COMMIT,
                  "a write escaped the configured output block");
            $display("TRACE %s: inputs=%0d outputs=%0d physical_commits=%0d stalled_edges=%0d snapshot_checks=%0d",
                     case_name, input_count, output_count, commit_count, stalled_cycles, snapshot_checks);
            watch_run = 1'b0;
            snapshot_live = 1'b0;
        end
    endtask

    task automatic normal_case(input integer m, input integer taps,
                               input integer architecture, input integer dataset);
        begin
            new_case($sformatf("dataset=%0d M=%0d T=%0d arch=%0d", dataset, m, taps, architecture),
                     m, taps, architecture, dataset, 1'b1);
            initialize_memories();
            configure_run();
            start_run();
            finish_run();
        end
    endtask

    task automatic await_pending(input integer index_in, output logic found);
        integer waited;
        begin
            waited = 0;
            while (!(dut.u_accel.u_arch_selector.in_valid_i === 1'b1 &&
                     input_count == index_in) && waited < RUN_BOUND && busy === 1'b1) begin
                @(negedge clk);
                waited = waited + 1;
            end
            found = dut.u_accel.u_arch_selector.in_valid_i === 1'b1 && input_count == index_in;
            check(found, TRAVERSAL,
                  $sformatf("pending window[%0d] was never presented; later stall/reset coverage cannot be credited",
                            index_in));
        end
    endtask

    task automatic hold_pending(input integer cycles_in);
        integer k, accepted_before, committed_before;
        begin
            accepted_before = input_count;
            committed_before = commit_count;
            for (k = 0; k < cycles_in; k = k + 1) begin
                @(negedge clk);
                check(dut.u_accel.u_arch_selector.in_valid_i === 1'b1 &&
                      dut.u_accel.u_arch_selector.in_ready_o === 1'b0 &&
                      input_count == accepted_before, STALL,
                      "stalled pending sample was dropped or spuriously accepted");
            end
            // With no earlier input, a stalled sample cannot cause ANY commit.
            if (accepted_before == 0)
                check(commit_count == committed_before && dut.u_accel.result_count_q === 32'd0,
                      STALL, "unaccepted pending sample changed result count or result memory");
        end
    endtask

    task automatic accept_first_then_stall;
        integer waited;
        begin
            stall_engine = 1'b0;
            waited = 0;
            while (input_count < 1 && waited < RUN_BOUND && busy === 1'b1) begin
                @(negedge clk);
                waited = waited + 1;
            end
            check(input_count == 1, TRAVERSAL, "first pending sample was not accepted exactly once");
            stall_engine = 1'b1;
        end
    endtask

    task automatic stall_case(input integer architecture);
        logic found;
        begin
            new_case($sformatf("first and rolling pending stalls arch=%0d", architecture),
                     4, 3, architecture, 0, 1'b1);
            initialize_memories();
            configure_run();
            stall_engine = 1'b1;
            install_ready_gate();
            start_run();
            await_pending(0, found);
            if (found) begin
                hold_pending(6);
                // Reject all configuration changes while the SAME window is
                // pending. Direct snapshot assertions run on every clock here.
                csr_write(TAP_COUNT, 32'd1, 1'b1);
                csr_write(SAMPLE_COUNT, 32'd2, 1'b1);
                csr_write(COEFF_PTR, cfg_coefficient + 32'd4, 1'b1);
                csr_write(INPUT_PTR, cfg_input + 32'd4, 1'b1);
                csr_write(OUTPUT_PTR, cfg_output + 32'd4, 1'b1);
                csr_write(CTRL, (32'((architecture+1)%3) << 2) | 32'd1, 1'b0);
                csr_expect(DBG_STATUS, 32'h10, SNAPSHOT);
                check_active_snapshot();
                hold_pending(6);
                accept_first_then_stall();
                await_pending(1, found);
                if (found) hold_pending(8);
            end
            // The second stall distinguishes advance-on-capture from advance-
            // on-acceptance: history MUST still be [x0, 0] throughout window 1.
            stall_engine = 1'b0;
            finish_run();
            check(stalled_cycles >= 12, STALL, "input-stall stimulus never exercised a pending window");
            remove_ready_gate();
        end
    endtask

    task automatic reset_pending_case(input integer architecture, input logic software_reset,
                                      input integer pending_index);
        logic found;
        integer k, before_inputs, before_outputs, before_commits, waited;
        string reset_name;
        begin
            if (software_reset) reset_name = "CTRL";
            else reset_name = "hardware";
            new_case($sformatf("%s reset pending[%0d] arch=%0d",
                              reset_name, pending_index, architecture),
                     4, 3, architecture, 0, 1'b1);
            initialize_memories();
            configure_run();
            stall_engine = 1'b1;
            install_ready_gate();
            start_run();
            await_pending(0, found);
            if (found && pending_index == 1) begin
                accept_first_then_stall();
                await_pending(1, found);
            end
            if (found) hold_pending(4);
            else
                $display("UNREACHED %s: reset-pending precondition missing (already a contract failure)", case_name);
            // Drain only EARLIER accepted inputs, even if the required next
            // pending window was absent. BUSY is not the drain oracle: the
            // legacy shell drops it one edge before the physical write. This
            // avoids mislabelling that already-reported commit deviation as a
            // reset failure; it does NOT waive the missing-window assertion.
            waited = 0;
            while (commit_count < input_count && waited < RUN_BOUND) begin
                @(negedge clk);
                waited = waited + 1;
            end
            check(commit_count == input_count, COMMIT, "earlier accepted inputs did not drain");
            before_inputs = input_count;
            before_outputs = output_count;
            before_commits = commit_count;
            for (k = 0; k < 1024; k = k + 1) memory_before[k] = dut.result_mem[k];
            if (software_reset) csr_write(CTRL, 32'd2, 1'b0);
            else begin
                @(negedge clk);
                rst = 1'b1;
                repeat (3) @(negedge clk);
                rst = 1'b0;
            end
            watch_run = 1'b0;
            snapshot_live = 1'b0;
            flush_guard = 1'b1;
            check(active_snapshot === {6'd0, 32'd0, COEFF_BASE, SAMPLE_BASE, RESULT_BASE, 2'd0},
                  RESET, "reset did not clear active configuration snapshots");
            check(dut.u_accel.sample_vector_q === {LANES*32{1'b0}}, RESET,
                  "reset did not discard the unaccepted pending window");
            csr_expect(STATUS, 32'd0, RESET);
            csr_expect(RESULT_COUNT, 32'd0, RESET);
            csr_expect(CYCLES_TOTAL, 32'd0, RESET);
            csr_expect(COMPUTE_CYCLES, 32'd0, RESET);
            repeat (20) @(negedge clk);
            check(input_count == before_inputs && output_count == before_outputs &&
                  commit_count == before_commits, RESET,
                  "pending sample was attributed an input/output/commit during reset");
            for (k = 0; k < 1024; k = k + 1)
                check(dut.result_mem[k] === memory_before[k], RESET,
                      $sformatf("reset or discarded sample changed physical result word %0d", k));
            flush_guard = 1'b0;
            remove_ready_gate();
            // No intervening hardware reset: the next block's exact zero-history
            // window proves that reset flushed history, not just status bits.
            new_case($sformatf("restart after %s pending[%0d] reset arch=%0d",
                              reset_name, pending_index, architecture),
                     2, 3, architecture, 1, 1'b0);
            initialize_memories();
            configure_run();
            start_run();
            finish_run();
        end
    endtask

    task automatic invalid_case(input integer variant);
        integer k;
        logic [135:0] snapshot_before;
        begin
            new_case($sformatf("preflight-invalid variant=%0d", variant), 2, 3, 0, 0, 1'b1);
            if (variant == 0) cfg_m = 0;
            if (variant == 1) cfg_input = 32'h0002_1ffc;
            if (variant == 2) cfg_output = 32'h0002_2ffc;
            configure_run();
            snapshot_before = active_snapshot;
            for (k = 0; k < 1024; k = k + 1) memory_before[k] = dut.result_mem[k];
            legacy_requests = 0;
            sample_requests = 0;
            coefficient_requests = 0;
            ownership_seen = 1'b0;
            reject_watch = 1'b1;
            csr_write(CTRL, 32'd1, 1'b0);
            csr_expect(STATUS, 32'd4, PREFLIGHT);
            csr_expect(DBG_STATUS, 32'h20, PREFLIGHT);
            csr_expect(RESULT_COUNT, 32'd0, PREFLIGHT);
            csr_expect(CYCLES_TOTAL, 32'd0, PREFLIGHT);
            csr_expect(COMPUTE_CYCLES, 32'd0, PREFLIGHT);
            repeat (12) @(negedge clk);
            check(legacy_requests == 0 && sample_requests == 0 && coefficient_requests == 0 &&
                  !ownership_seen && !bus_fault, PREFLIGHT,
                  "preflight rejection accessed memory/ownership or produced a host bus error");
            check(active_snapshot === snapshot_before, SNAPSHOT,
                  "invalid START replaced an active snapshot");
            for (k = 0; k < 1024; k = k + 1)
                check(dut.result_mem[k] === memory_before[k], PREFLIGHT,
                      $sformatf("invalid START changed physical result word %0d", k));
            reject_watch = 1'b0;
        end
    endtask

    initial begin : RUN_ALL_CASES
        integer arch, m, k, gap_failures, regression_failures;
        for (k = 0; k < CATEGORY_COUNT; k = k + 1) category_failures[k] = 0;
        $readmemh("tests/rtl/block_processing_vectors.mem", vectors);
        for (k = 0; k < 48; k = k + 1)
            if (^vectors[k] === 1'bx) tb_error($sformatf("missing/unknown fixture word %0d", k));

        for (arch = 0; arch < 3; arch = arch + 1) begin
            // Full M/T/architecture cross product, not merely cross-architecture
            // agreement (three engines sharing the same wrong window is a failure).
            for (m = 1; m <= 4; m = m*2) begin
                normal_case(m, 1, arch, 0);
                normal_case(m, 3, arch, 0);
            end
            normal_case(4, 3, arch, 1); // impulse history sequence
            normal_case(4, 1, arch, 2); // both saturation signs and floor
            normal_case(4, 3, arch, 2); // cancellation before final shift/saturation
            normal_case(4, 3, arch, 0);
            // A second START without any intervening reset must zero history.
            new_case($sformatf("fresh block without reset arch=%0d", arch), 4, 3, arch, 0, 1'b0);
            configure_run();
            start_run();
            finish_run();
            stall_case(arch);
            reset_pending_case(arch, 1'b0, 0);
            reset_pending_case(arch, 1'b1, 0);
            reset_pending_case(arch, 1'b1, 1);
        end
        for (k = 0; k < 3; k = k + 1) invalid_case(k);

        gap_failures = 0;
        regression_failures = 0;
        for (k = 0; k < CATEGORY_COUNT; k = k + 1) begin
            $display("CATEGORY %s: failing_cases=%0d", category_name(k), category_failures[k]);
            if (k <= STALL) gap_failures = gap_failures + category_failures[k];
            else regression_failures = regression_failures + category_failures[k];
        end
        // These labels classify diagnostics; NO expected-failure waiver exists.
        // Any missing function, regression or harness error produces nonzero exit.
        $display("BLOCK_PROCESSING_SUMMARY cases=%0d contract_failures=%0d known_gap_categories=%0d unexpected_regression_categories=%0d testbench_errors=%0d",
                 cases, failures, gap_failures, regression_failures, testbench_errors);
        if (failures != 0 || testbench_errors != 0)
            $fatal(1, "Batch 3B-3A block-processing acceptance requirements are NOT met");
        $display("PASS: Batch 3B-3A block-processing acceptance contract");
        $finish;
    end

    initial begin
        #5000000;
        tb_error("global watchdog: harness did not finish its bounded directed cases");
    end
endmodule
