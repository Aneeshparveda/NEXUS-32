#!/usr/bin/env python3
"""Run a deterministic Python-model versus three-engine RTL regression.

The existing differential bench is intentionally left unchanged.  This script
recreates its directed legal vectors, its xorshift32 seed, and its invalid-tap
checks in a temporary self-checking SystemVerilog harness.  The Python model
supplies every legal expected value before the simulator runs.
"""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LANES = 32
SEED = 0x3ACE_B00C
RANDOM_CASES = 1024
STIMULUS_WORDS = 2 + (LANES * 2)


def xorshift32(value: int) -> int:
    value &= 0xFFFF_FFFF
    value ^= (value << 13) & 0xFFFF_FFFF
    value ^= value >> 17
    value ^= (value << 5) & 0xFFFF_FFFF
    return value & 0xFFFF_FFFF


def signed32(value: int) -> int:
    value &= 0xFFFF_FFFF
    return value - (1 << 32) if value & 0x8000_0000 else value


def word_hex(value: int) -> str:
    return f"{value & 0xFFFF_FFFF:08x}"


def zero_vector() -> list[int]:
    return [0] * LANES


def add_case(cases: list[tuple[int, list[int], list[int]]], taps: int,
             samples: list[int], coefficients: list[int]) -> None:
    if len(samples) != LANES or len(coefficients) != LANES:
        raise ValueError("every vector must contain exactly LANES entries")
    cases.append((taps, [signed32(v) for v in samples],
                  [signed32(v) for v in coefficients]))


def build_directed_cases() -> list[tuple[int, list[int], list[int]]]:
    cases: list[tuple[int, list[int], list[int]]] = []

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0] = 65_536
    coefficients[0] = 65_536
    add_case(cases, 1, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0] = -1
    coefficients[0] = 32_768
    add_case(cases, 1, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0:3] = [65_536, 131_072, -65_536]
    coefficients[0:3] = [32_768, -32_768, 65_536]
    add_case(cases, 3, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0] = 0x7FFF_FFFF
    coefficients[0] = 0x7FFF_FFFF
    add_case(cases, 1, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0] = 0x8000_0000
    coefficients[0] = 0x7FFF_FFFF
    add_case(cases, 1, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    samples[0:4] = [98_304, -98_304, 147_456, -147_456]
    coefficients[0:4] = [65_536, 65_536, 65_536, 65_536]
    add_case(cases, 4, samples, coefficients)

    samples = [-16_384] * LANES
    coefficients = [32_768] * LANES
    add_case(cases, 4, samples, coefficients)

    samples = zero_vector()
    coefficients = zero_vector()
    for lane in range(LANES):
        samples[lane] = signed32((lane + 1) * 65_536)
        magnitude = 16_384 + lane * 512
        coefficients[lane] = magnitude if lane % 2 == 0 else -magnitude
    add_case(cases, LANES, samples, coefficients)
    if LANES > 4:
        add_case(cases, LANES // 2, samples, coefficients)

    samples = [0x8000_0000] * LANES
    coefficients = [0x7FFF_FFFF] * LANES
    add_case(cases, LANES, samples, coefficients)
    return cases


def build_random_cases() -> list[tuple[int, list[int], list[int]]]:
    cases: list[tuple[int, list[int], list[int]]] = []
    rng = SEED
    for _ in range(RANDOM_CASES):
        rng = xorshift32(rng)
        taps = (rng % LANES) + 1
        samples: list[int] = []
        coefficients: list[int] = []
        for _lane in range(LANES):
            rng = xorshift32(rng)
            samples.append(signed32(rng))
            rng = xorshift32(rng)
            coefficients.append(signed32(rng))
        cases.append((taps, samples, coefficients))
    return cases


def write_stimulus(path: Path, cases: list[tuple[int, list[int], list[int]]]) -> None:
    lines: list[str] = []
    for taps, samples, coefficients in cases:
        expected = fir_dot(samples[:taps], coefficients[:taps])
        words = [word_hex(taps), word_hex(expected)]
        for sample, coefficient in zip(samples, coefficients):
            words.extend((word_hex(sample), word_hex(coefficient)))
        if len(words) != STIMULUS_WORDS:
            raise AssertionError("generated stimulus record has the wrong width")
        lines.extend(words)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def fir_dot(window: list[int], coefficients: list[int]) -> int:
    # Import lazily so the command's initial failure remains a normal Python
    # traceback if the repository model itself is unavailable.
    from golden_model.fir_q16 import fir_dot_q16_16

    return fir_dot_q16_16(window, coefficients)


def generate_harness(path: Path, stimulus_path: Path, case_count: int) -> None:
    stimulus_literal = str(stimulus_path).replace("\\", "\\\\").replace('"', '\\"')
    harness = f'''`timescale 1ns/1ps
module tb_golden_regression;
    localparam int LANES = {LANES};
    localparam int CASE_COUNT = {case_count};
    localparam int RECORD_WORDS = {STIMULUS_WORDS};
    localparam int LATENCY = $clog2(LANES) + 1;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic [5:0] tap_count = 6'd0;
    logic [LANES*32-1:0] sample_vector = '0;
    logic [LANES*32-1:0] coefficient_vector = '0;
    logic seq_start = 1'b0;
    logic seq_tap_req;
    logic [4:0] seq_tap_addr;
    logic seq_busy, seq_done, seq_error;
    logic signed [31:0] seq_sample_tap, seq_coefficient_tap;
    logic signed [31:0] seq_result;
    logic [15:0] seq_cycles;
    logic signed [31:0] sample_mem [0:31];
    logic signed [31:0] coefficient_mem [0:31];
    logic par_in_valid = 1'b0, par_in_ready;
    logic par_out_valid, par_out_ready = 1'b0, par_error;
    logic signed [31:0] par_result;
    logic [15:0] par_cycles;
    logic pipe_in_valid = 1'b0, pipe_in_ready;
    logic pipe_out_valid, pipe_out_ready = 1'b0, pipe_error;
    logic signed [31:0] pipe_result;
    logic [15:0] pipe_cycles;
    logic [31:0] stimulus [0:CASE_COUNT*RECORD_WORDS-1];
    integer cases_checked = 0;
    integer invalid_cases_checked = 0;

    always #5 clk = ~clk;

    always @* begin
        seq_sample_tap = sample_mem[seq_tap_addr];
        seq_coefficient_tap = coefficient_mem[seq_tap_addr];
    end

    fir_seq_engine u_seq (
        .clk_i(clk), .rst_i(rst), .start_i(seq_start),
        .tap_count_i(tap_count), .tap_req_o(seq_tap_req),
        .tap_addr_o(seq_tap_addr), .tap_valid_i(1'b1),
        .sample_tap_i(seq_sample_tap),
        .coefficient_tap_i(seq_coefficient_tap),
        .busy_o(seq_busy), .done_o(seq_done), .error_o(seq_error),
        .result_o(seq_result), .cycles_o(seq_cycles)
    );

    fir_parallel_engine #(.LANES(LANES)) u_parallel (
        .clk_i(clk), .rst_i(rst),
        .in_valid_i(par_in_valid), .in_ready_o(par_in_ready),
        .tap_count_i(tap_count), .sample_vector_i(sample_vector),
        .coefficient_vector_i(coefficient_vector),
        .out_valid_o(par_out_valid), .out_ready_i(par_out_ready),
        .out_result_o(par_result), .error_o(par_error),
        .cycles_o(par_cycles)
    );

    fir_pipelined_engine #(.LANES(LANES)) u_pipelined (
        .clk_i(clk), .rst_i(rst),
        .in_valid_i(pipe_in_valid), .in_ready_o(pipe_in_ready),
        .tap_count_i(tap_count), .sample_vector_i(sample_vector),
        .coefficient_vector_i(coefficient_vector),
        .out_valid_o(pipe_out_valid), .out_ready_i(pipe_out_ready),
        .out_result_o(pipe_result), .out_error_o(pipe_error),
        .cycles_o(pipe_cycles)
    );

    task automatic print_vector(input integer case_id);
        integer tap;
        begin
            $write("GOLDEN_VECTOR case=%0d lanes=%0d taps=%0d samples=", case_id,
                   LANES, stimulus[case_id*RECORD_WORDS][5:0]);
            for (tap = 0; tap < LANES; tap = tap + 1)
                $write("%08x%s", stimulus[case_id*RECORD_WORDS+2+(tap*2)],
                       (tap == LANES-1) ? "" : ",");
            $write(" coefficients=");
            for (tap = 0; tap < LANES; tap = tap + 1)
                $write("%08x%s", stimulus[case_id*RECORD_WORDS+3+(tap*2)],
                       (tap == LANES-1) ? "\\n" : ",");
        end
    endtask

    task automatic run_legal(input integer case_id);
        integer tap;
        integer guard;
        integer base;
        logic seq_seen, par_seen, pipe_seen;
        logic par_accepted, pipe_accepted;
        logic par_accept_this_cycle, pipe_accept_this_cycle;
        logic par_fire_this_cycle, pipe_fire_this_cycle;
        logic signed [31:0] expected;
        begin
            base = case_id * RECORD_WORDS;
            expected = $signed(stimulus[base+1]);
            seq_seen = 1'b0;
            par_seen = 1'b0;
            pipe_seen = 1'b0;
            par_accepted = 1'b0;
            pipe_accepted = 1'b0;
            guard = 0;
            @(negedge clk);
            tap_count = stimulus[base][5:0];
            for (tap = 0; tap < LANES; tap = tap + 1) begin
                sample_vector[tap*32 +: 32] = stimulus[base+2+(tap*2)];
                coefficient_vector[tap*32 +: 32] = stimulus[base+3+(tap*2)];
                sample_mem[tap] = $signed(stimulus[base+2+(tap*2)]);
                coefficient_mem[tap] = $signed(stimulus[base+3+(tap*2)]);
            end
            seq_start = 1'b1;
            par_in_valid = 1'b1;
            pipe_in_valid = 1'b1;
            par_out_ready = 1'b1;
            pipe_out_ready = 1'b1;
            while (!(seq_seen && par_seen && pipe_seen) && guard < 1000) begin
                @(posedge clk);
                par_accept_this_cycle = par_in_valid && par_in_ready;
                pipe_accept_this_cycle = pipe_in_valid && pipe_in_ready;
                par_fire_this_cycle = par_out_valid && par_out_ready;
                pipe_fire_this_cycle = pipe_out_valid && pipe_out_ready;
                if (par_fire_this_cycle) begin
                    if (par_error !== 1'b0 || par_result !== expected) begin
                        $display("GOLDEN_MISMATCH engine=parallel case=%0d lanes=%0d taps=%0d expected=%08x sequential=%08x parallel=%08x pipelined=%08x",
                                 case_id, LANES, stimulus[base][5:0], expected,
                                 seq_result, par_result, pipe_result);
                        print_vector(case_id);
                        $fatal(1, "parallel mismatch");
                    end
                    if (par_cycles !== 16'd1)
                        $fatal(1, "parallel nominal cycle mismatch case=%0d got=%0d", case_id, par_cycles);
                    par_seen = 1'b1;
                end
                if (pipe_fire_this_cycle) begin
                    if (pipe_error !== 1'b0 || pipe_result !== expected) begin
                        $display("GOLDEN_MISMATCH engine=pipelined case=%0d lanes=%0d taps=%0d expected=%08x sequential=%08x parallel=%08x pipelined=%08x",
                                 case_id, LANES, stimulus[base][5:0], expected,
                                 seq_result, par_result, pipe_result);
                        print_vector(case_id);
                        $fatal(1, "pipelined mismatch");
                    end
                    if (pipe_cycles !== 16'(LATENCY))
                        $fatal(1, "pipelined nominal cycle mismatch case=%0d got=%0d", case_id, pipe_cycles);
                    pipe_seen = 1'b1;
                end
                #1;
                if (seq_error !== 1'b0) begin
                    $display("GOLDEN_MISMATCH engine=sequential case=%0d lanes=%0d taps=%0d expected=%08x sequential=%08x parallel=%08x pipelined=%08x",
                             case_id, LANES, stimulus[base][5:0], expected,
                             seq_result, par_result, pipe_result);
                    print_vector(case_id);
                    $fatal(1, "sequential error on legal vector");
                end
                if (seq_done) begin
                    if (seq_result !== expected) begin
                        $display("GOLDEN_MISMATCH engine=sequential case=%0d lanes=%0d taps=%0d expected=%08x sequential=%08x parallel=%08x pipelined=%08x",
                                 case_id, LANES, stimulus[base][5:0], expected,
                                 seq_result, par_result, pipe_result);
                        print_vector(case_id);
                        $fatal(1, "sequential mismatch");
                    end
                    seq_seen = 1'b1;
                end
                if (par_accept_this_cycle)
                    par_accepted = 1'b1;
                if (pipe_accept_this_cycle)
                    pipe_accepted = 1'b1;
                @(negedge clk);
                seq_start = 1'b0;
                if (par_accepted)
                    par_in_valid = 1'b0;
                if (pipe_accepted)
                    pipe_in_valid = 1'b0;
                guard = guard + 1;
            end
            if (!(seq_seen && par_seen && pipe_seen && par_accepted && pipe_accepted)) begin
                $display("GOLDEN_MISMATCH engine=timeout case=%0d lanes=%0d taps=%0d expected=%08x sequential=%08x parallel=%08x pipelined=%08x",
                         case_id, LANES, stimulus[base][5:0], expected,
                         seq_result, par_result, pipe_result);
                print_vector(case_id);
                $fatal(1, "timeout or missing handshake");
            end
            cases_checked = cases_checked + 1;
        end
    endtask

    task automatic run_invalid(input integer bad_taps);
        integer guard;
        logic par_done, pipe_done, seq_done_or_error;
        logic par_accepted, pipe_accepted;
        begin
            guard = 0;
            par_done = 1'b0;
            pipe_done = 1'b0;
            seq_done_or_error = 1'b0;
            par_accepted = 1'b0;
            pipe_accepted = 1'b0;
            @(negedge clk);
            tap_count = bad_taps[5:0];
            sample_vector = '0;
            coefficient_vector = '0;
            seq_start = 1'b1;
            par_in_valid = 1'b1;
            pipe_in_valid = 1'b1;
            par_out_ready = 1'b1;
            pipe_out_ready = 1'b1;
            while (!(par_done && pipe_done && seq_done_or_error) && guard < 200) begin
                @(posedge clk);
                #1;
                if (par_in_valid && par_in_ready) begin
                    par_accepted = 1'b1;
                    if (par_error !== 1'b1 || par_out_valid !== 1'b0)
                        $fatal(1, "invalid tap count %0d was not rejected by parallel engine", bad_taps);
                    par_done = 1'b1;
                end
                if (pipe_in_valid && pipe_in_ready)
                    pipe_accepted = 1'b1;
                if (pipe_out_valid && pipe_out_ready) begin
                    if (pipe_error !== 1'b1 || pipe_result !== 32'd0)
                        $fatal(1, "invalid tap count %0d was not rejected by pipelined engine", bad_taps);
                    pipe_done = 1'b1;
                end
                if (seq_error)
                    seq_done_or_error = 1'b1;
                @(negedge clk);
                seq_start = 1'b0;
                if (par_accepted)
                    par_in_valid = 1'b0;
                if (pipe_accepted)
                    pipe_in_valid = 1'b0;
                guard = guard + 1;
            end
            if (!(par_done && pipe_done && seq_done_or_error))
                $fatal(1, "invalid tap count %0d did not terminate all engines", bad_taps);
            invalid_cases_checked = invalid_cases_checked + 1;
        end
    endtask

    initial begin : RUN
        integer case_id;
        integer tap;
        $readmemh("{stimulus_literal}", stimulus);
        for (tap = 0; tap < 32; tap = tap + 1) begin
            sample_mem[tap] = 32'sd0;
            coefficient_mem[tap] = 32'sd0;
        end
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        for (case_id = 0; case_id < CASE_COUNT; case_id = case_id + 1)
            run_legal(case_id);
        run_invalid(0);
        run_invalid(33);
        run_invalid(63);
        $display("PASS: golden regression lanes=%0d directed_cases={len(build_directed_cases())} random_cases={RANDOM_CASES} legal_vectors=%0d invalid_cases=%0d seed=0x{SEED:08X} engines=sequential,parallel,pipelined mismatches=0",
                 LANES, cases_checked, invalid_cases_checked);
        $finish;
    end

    initial begin
        #200000000;
        $fatal(1, "golden regression watchdog expired");
    end
endmodule
'''
    path.write_text(harness, encoding="utf-8")


def main() -> int:
    sys.path.insert(0, str(ROOT))
    cases = build_directed_cases() + build_random_cases()
    temp_dir = Path(tempfile.mkdtemp(prefix="nexus32-golden-regression-"))
    stimulus_path = temp_dir / "stimulus.mem"
    harness_path = temp_dir / "tb_golden_regression.sv"
    output_path = temp_dir / "tb_golden_regression.vvp"

    try:
        write_stimulus(stimulus_path, cases)
        generate_harness(harness_path, stimulus_path, len(cases))
        compile_command = [
            "iverilog", "-g2012", "-Wall", "-s", "tb_golden_regression",
            "-o", str(output_path),
            "rtl/fir_q16_mac.sv",
            "rtl/fir_q16_postprocess.sv",
            "rtl/fir_seq_engine.sv",
            "rtl/fir_parallel_engine.sv",
            "rtl/fir_pipelined_engine.sv",
            str(harness_path),
        ]
        compile_result = subprocess.run(
            compile_command, cwd=ROOT, text=True, capture_output=True, check=False
        )
        if compile_result.stdout:
            print(compile_result.stdout, end="")
        if compile_result.stderr:
            print(compile_result.stderr, end="", file=sys.stderr)
        if compile_result.returncode != 0:
            print(f"ERROR: golden regression compile failed; harness preserved at {temp_dir}", file=sys.stderr)
            return compile_result.returncode

        run_result = subprocess.run(
            ["vvp", str(output_path)], cwd=ROOT, text=True,
            capture_output=True, check=False
        )
        if run_result.stdout:
            print(run_result.stdout, end="")
        if run_result.stderr:
            print(run_result.stderr, end="", file=sys.stderr)
        if run_result.returncode != 0:
            print(f"ERROR: golden regression runtime failed; harness preserved at {temp_dir}", file=sys.stderr)
            return run_result.returncode

        print(f"Golden harness completed from temporary directory: {temp_dir}")
        shutil.rmtree(temp_dir)
        return 0
    except Exception as exc:  # pragma: no cover - command-line failure path
        print(f"ERROR: golden regression setup failed: {exc}", file=sys.stderr)
        print(f"Harness and stimulus preserved at {temp_dir}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
