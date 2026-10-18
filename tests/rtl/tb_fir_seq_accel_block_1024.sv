`timescale 1ns/1ps

// Verification-only closure bench for the complete 1024-sample serialized
// block.  This bench deliberately uses an independent Q16.16 reference and
// observes the controller/bus transfer edges directly; it does not use the
// controller's windows, nominal engine cycles, BUSY, or DONE as its oracle.
//
// Edge convention: every event is sampled at the active posedge before NBA
// updates.  A #1 delay is used only for post-edge memory/CSR assertions.
//
// Run one lane build at a time, for example:
//   iverilog -g2012 -Wall -s tb_fir_seq_accel_block_1024 \
//     -Ptb_fir_seq_accel_block_1024.LANES=32 \
//     -o results/rtl/tb_fir_seq_accel_block_1024_l32.vvp \
//     rtl/fir_q16_mac.sv rtl/fir_q16_postprocess.sv rtl/fir_seq_engine.sv \
//     rtl/fir_parallel_engine.sv rtl/fir_pipelined_engine.sv \
//     rtl/fir_arch_selector.sv rtl/fir_tap_bram.sv rtl/fir_seq_accel.sv \
//     rtl/nexus32_accel_bus.sv tests/rtl/tb_fir_seq_accel_block_1024.sv
//   vvp results/rtl/tb_fir_seq_accel_block_1024_l32.vvp
module tb_fir_seq_accel_block_1024 #(
    parameter int LANES = 32
);
    localparam int SAMPLE_COUNT_VALUE = 1024;
    localparam int TAP_COUNT_VALUE = 3;
    localparam int LONG_RUN_BOUND = 100000;
    localparam logic [31:0] CSR_BASE = 32'h1000_5000;
    localparam logic [31:0] COEFF_BASE = 32'h0002_0000;
    localparam logic [31:0] SAMPLE_BASE = 32'h0002_1000;
    localparam logic [31:0] RESULT_BASE = 32'h0002_2000;
    localparam logic [11:0] CTRL = 12'h000;
    localparam logic [11:0] STATUS = 12'h004;
    localparam logic [11:0] TAP_COUNT = 12'h008;
    localparam logic [11:0] COEFF_PTR = 12'h00c;
    localparam logic [11:0] INPUT_PTR = 12'h010;
    localparam logic [11:0] OUTPUT_PTR = 12'h014;
    localparam logic [11:0] CYCLES_TOTAL = 12'h018;
    localparam logic [11:0] SAMPLE_COUNT = 12'h01c;
    localparam logic [11:0] COMPUTE_CYCLES = 12'h020;
    localparam logic [11:0] DBG_STATUS = 12'h030;
    localparam logic [11:0] RESULT_COUNT = 12'h03c;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic req_valid = 1'b0;
    logic req_write = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [31:0] req_wdata = 32'd0;
    logic [3:0] req_wstrb = 4'hf;
    wire req_ready;
    wire rsp_valid;
    wire [31:0] rsp_rdata;
    wire rsp_error;
    wire bus_fault;
    wire busy;
    wire done;
    wire error_status;

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

    logic signed [31:0] samples [0:SAMPLE_COUNT_VALUE-1];
    logic signed [31:0] coefficients [0:TAP_COUNT_VALUE-1];
    logic signed [31:0] expected [0:SAMPLE_COUNT_VALUE-1];
    logic [31:0] result_before [0:SAMPLE_COUNT_VALUE-1];

    integer failures = 0;
    integer functional_failures = 0;
    integer counter_failures = 0;
    integer harness_errors = 0;
    integer edge_cycle = 0;
    integer start_cycle = -1;
    integer error_cycle = -1;
    integer first_input_cycle = -1;
    integer last_output_cycle = -1;
    integer final_commit_cycle = -1;
    integer sample_events = 0;
    integer input_events = 0;
    integer output_events = 0;
    integer commit_events = 0;
    integer active_architecture = 0;
    integer run_number = 0;
    integer run_sample_count = 0;
    logic monitor_run = 1'b0;
    logic fault_run = 1'b0;
    logic fault_injected = 1'b0;
    logic [31:0] expected_cycles_total = 32'd0;
    logic [31:0] expected_compute_cycles = 32'd0;

    integer sample_cycle [0:SAMPLE_COUNT_VALUE-1];
    integer input_cycle [0:SAMPLE_COUNT_VALUE-1];
    integer output_cycle [0:SAMPLE_COUNT_VALUE-1];
    integer commit_cycle [0:SAMPLE_COUNT_VALUE-1];

    task automatic fail_functional(input string message);
        begin
            failures = failures + 1;
            functional_failures = functional_failures + 1;
            $display("FUNCTIONAL_FAIL LANES=%0d arch=%0d run=%0d edge=%0d: %s",
                     LANES, active_architecture, run_number, edge_cycle, message);
        end
    endtask

    task automatic fail_counter(input string message);
        begin
            failures = failures + 1;
            counter_failures = counter_failures + 1;
            $display("COUNTER_FAIL LANES=%0d arch=%0d run=%0d edge=%0d: %s",
                     LANES, active_architecture, run_number, edge_cycle, message);
        end
    endtask

    task automatic fail_harness(input string message);
        begin
            failures = failures + 1;
            harness_errors = harness_errors + 1;
            $display("HARNESS_FAIL LANES=%0d arch=%0d run=%0d edge=%0d: %s",
                     LANES, active_architecture, run_number, edge_cycle, message);
        end
    endtask

    function automatic logic signed [31:0] deterministic_sample(
        input integer index, input integer architecture
    );
        integer magnitude;
        begin
            magnitude = ((index * 37 + (architecture + 1) * 17) % 257) - 128;
            if (((index + architecture) & 1) != 0)
                magnitude = -magnitude;
            deterministic_sample = magnitude * 32'sh0000_0080;
        end
    endfunction

    function automatic logic signed [31:0] deterministic_coefficient(input integer index);
        begin
            case (index)
                0: deterministic_coefficient = 32'sh0001_0000;
                1: deterministic_coefficient = 32'sh0000_6000;
                default: deterministic_coefficient = -32'sh0000_2000;
            endcase
        end
    endfunction

    task automatic build_reference(input integer architecture);
        integer n, k;
        logic signed [63:0] product;
        logic signed [71:0] accumulator;
        logic signed [71:0] term72;
        logic signed [71:0] shifted;
        logic signed [31:0] sample_value;
        begin
            for (k = 0; k < TAP_COUNT_VALUE; k = k + 1)
                coefficients[k] = deterministic_coefficient(k);
            for (n = 0; n < SAMPLE_COUNT_VALUE; n = n + 1)
                samples[n] = deterministic_sample(n, architecture);
            for (n = 0; n < SAMPLE_COUNT_VALUE; n = n + 1) begin
                accumulator = 72'sd0;
                for (k = 0; k < TAP_COUNT_VALUE; k = k + 1) begin
                    if (n >= k)
                        sample_value = samples[n-k];
                    else
                        sample_value = 32'sd0;
                    product = sample_value * coefficients[k];
                    term72 = $signed({{8{product[63]}}, product});
                    accumulator = accumulator + term72;
                end
                shifted = accumulator >>> 16;
                if (shifted > 72'sd2147483647)
                    expected[n] = 32'sh7fff_ffff;
                else if (shifted < -72'sd2147483648)
                    expected[n] = 32'sh8000_0000;
                else
                    expected[n] = shifted[31:0];
            end
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
            while (req_ready !== 1'b1 && waited < 100) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (req_ready !== 1'b1) begin
                fail_harness($sformatf("bus never became ready for %08x", address));
                read_data = 32'd0;
                transaction_error = 1'b1;
            end else begin
                req_valid = 1'b1;
                req_write = write_op;
                req_addr = address;
                req_wdata = data;
                req_wstrb = 4'hf;
                @(posedge clk);
                @(negedge clk);
                req_valid = 1'b0;
                req_write = 1'b0;
                req_addr = 32'd0;
                req_wdata = 32'd0;
                waited = 0;
                while (rsp_valid !== 1'b1 && waited < 100) begin
                    @(negedge clk);
                    waited = waited + 1;
                end
                if (rsp_valid !== 1'b1) begin
                    fail_harness($sformatf("missing response for %08x", address));
                    read_data = 32'd0;
                    transaction_error = 1'b1;
                end else begin
                    read_data = rsp_rdata;
                    transaction_error = rsp_error;
                end
            end
            @(negedge clk);
        end
    endtask

    task automatic csr_write(input logic [11:0] offset, input logic [31:0] data,
                             input logic expected_error);
        logic [31:0] read_data;
        logic transaction_error;
        begin
            bus_xfer(1'b1, CSR_BASE + {20'd0, offset}, data,
                     read_data, transaction_error);
            if (transaction_error !== expected_error || read_data !== 32'd0)
                fail_harness($sformatf("CSR write %03x got error=%b data=%08x expected_error=%b",
                                       offset, transaction_error, read_data, expected_error));
        end
    endtask

    task automatic csr_read(input logic [11:0] offset, output logic [31:0] value,
                            output logic transaction_error);
        bus_xfer(1'b0, CSR_BASE + {20'd0, offset}, 32'd0,
                 value, transaction_error);
    endtask

    // This monitor is intentionally independent of all published timing
    // counters.  Events are sampled before NBA updates at the active clock
    // edge; memory and sticky status are checked after NBA with #1 below.
    always @(posedge clk) begin : SCOREBOARD
        logic start_edge;
        logic sample_edge;
        logic input_edge;
        logic output_edge;
        logic commit_edge;
        logic error_edge;
        logic reset_edge;
        logic signed [31:0] wanted_window;
        logic signed [31:0] observed_window;
        integer k;
        integer sample_index_seen;
        integer input_index;
        integer output_index;
        integer commit_index;
        logic [31:0] written_address;
        logic [31:0] written_data;

        edge_cycle = edge_cycle + 1;
        if (!monitor_run)
            disable SCOREBOARD;

        reset_edge = rst || dut.u_accel.soft_reset_request_now;
        start_edge = dut.u_accel.reserve_banks_now && !reset_edge;
        sample_edge = (dut.u_accel.exec_state_q == 4'd4) &&
                      dut.u_accel.accelerator_sample_rvalid && !reset_edge;
        input_edge = dut.u_accel.u_arch_selector.in_valid_i &&
                     dut.u_accel.u_arch_selector.in_ready_o && !reset_edge;
        output_edge = dut.u_accel.u_arch_selector.out_valid_o &&
                      dut.u_accel.u_arch_selector.out_ready_i && !reset_edge;
        commit_edge = dut.result_mem_we && !reset_edge;
        error_edge = dut.u_accel.internal_fault_event_now &&
                     dut.u_accel.busy_q && !reset_edge;
        written_address = dut.result_commit_addr;
        written_data = dut.result_commit_data;

        if (start_edge) begin
            if (start_cycle >= 0)
                fail_harness("more than one accepted START edge in a run");
            else
                start_cycle = edge_cycle;
        end

        if (sample_edge) begin
            sample_index_seen = dut.u_accel.sample_index_q;
            if (sample_events >= run_sample_count)
                fail_functional("sample response after configured block length");
            else begin
                if (sample_index_seen !== sample_events)
                    fail_functional($sformatf("sample index %0d expected %0d",
                                              sample_index_seen, sample_events));
                if (dut.u_accel.accelerator_sample_rdata !== samples[sample_events])
                    fail_functional($sformatf("sample[%0d] response %08x expected %08x",
                                              sample_events,
                                              dut.u_accel.accelerator_sample_rdata,
                                              samples[sample_events]));
                sample_cycle[sample_events] = edge_cycle;
            end
            sample_events = sample_events + 1;
        end

        if (input_edge) begin
            input_index = input_events;
            if (input_index >= run_sample_count)
                fail_functional("engine input transfer after configured block length");
            else begin
                if (input_index == 0)
                    first_input_cycle = edge_cycle;
                for (k = 0; k < LANES; k = k + 1) begin
                    if (k < TAP_COUNT_VALUE && input_index >= k)
                        wanted_window = samples[input_index-k];
                    else
                        wanted_window = 32'sd0;
                    observed_window = $signed(
                        dut.u_accel.u_arch_selector.sample_vector_i[k*32 +: 32]);
                    if (observed_window !== wanted_window)
                        fail_functional($sformatf(
                            "window[%0d] lane %0d got %08x expected %08x",
                            input_index, k, observed_window, wanted_window));
                    if (k < TAP_COUNT_VALUE &&
                        dut.u_accel.u_arch_selector.coefficient_vector_i[k*32 +: 32] !==
                        coefficients[k])
                        fail_functional($sformatf(
                            "coefficient lane %0d changed at input %0d", k, input_index));
                    if (k >= TAP_COUNT_VALUE &&
                        dut.u_accel.u_arch_selector.sample_vector_i[k*32 +: 32] !== 32'd0)
                        fail_functional($sformatf(
                            "inactive sample lane %0d was not zero at input %0d", k, input_index));
                end
                input_cycle[input_index] = edge_cycle;
            end
            input_events = input_events + 1;
        end

        if (output_edge) begin
            output_index = output_events;
            if (output_index >= run_sample_count)
                fail_functional("engine output transfer after configured block length");
            else begin
                if (output_index >= input_events)
                    fail_functional("output transfer preceded its accepted input");
                if (dut.u_accel.u_arch_selector.out_error_o !== 1'b0)
                    fail_functional($sformatf("output[%0d] reported engine error", output_index));
                if (dut.u_accel.u_arch_selector.out_result_o !== expected[output_index])
                    fail_functional($sformatf("output[%0d] got %08x expected %08x",
                                              output_index,
                                              dut.u_accel.u_arch_selector.out_result_o,
                                              expected[output_index]));
                output_cycle[output_index] = edge_cycle;
                last_output_cycle = edge_cycle;
            end
            output_events = output_events + 1;
        end

        if (commit_edge) begin
            commit_index = commit_events;
            if (commit_index >= run_sample_count)
                fail_functional("physical commit after configured block length");
            else begin
                if (commit_index >= output_events)
                    fail_functional("physical commit preceded its output transfer");
                if (written_address !== RESULT_BASE + 32'(4*commit_index))
                    fail_functional($sformatf("commit[%0d] address %08x expected %08x",
                                              commit_index, written_address,
                                              RESULT_BASE + 32'(4*commit_index)));
                if (written_data !== expected[commit_index])
                    fail_functional($sformatf("commit[%0d] data %08x expected %08x",
                                              commit_index, written_data,
                                              expected[commit_index]));
                commit_cycle[commit_index] = edge_cycle;
                if (commit_index == run_sample_count-1)
                    final_commit_cycle = edge_cycle;
            end
            commit_events = commit_events + 1;
        end

        if (error_edge) begin
            if (error_cycle >= 0)
                fail_harness("more than one internal error termination edge");
            else
                error_cycle = edge_cycle;
        end

        #1;
        if (commit_edge) begin
            if (written_address[31:12] == RESULT_BASE[31:12] &&
                written_address[1:0] == 2'b00 &&
                dut.result_mem[written_address[11:2]] !== written_data)
                fail_functional($sformatf("physical result memory missed commit at %08x",
                                          written_address));
            if (commit_index < run_sample_count-1 &&
                (done || dut.u_accel.result_count_q == run_sample_count))
                fail_functional("DONE/result count became complete before final commit");
            if (commit_index == run_sample_count-1 &&
                (!done || error_status || busy ||
                 dut.u_accel.result_count_q != run_sample_count))
                fail_functional("final physical commit did not produce a valid complete block");
        end
        if (error_edge && (busy || done || !error_status))
            fail_functional("internal fault did not terminate with ERROR and no DONE");
    end

    task automatic hardware_reset;
        begin
            monitor_run = 1'b0;
            req_valid = 1'b0;
            req_write = 1'b0;
            @(negedge clk);
            rst = 1'b1;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);
        end
    endtask

    task automatic initialize_memories(input integer sample_count_to_write);
        integer k;
        logic [31:0] read_data;
        logic transaction_error;
        begin
            for (k = 0; k < TAP_COUNT_VALUE; k = k + 1)
                bus_xfer(1'b1, COEFF_BASE + 32'(4*k), coefficients[k],
                         read_data, transaction_error);
            for (k = 0; k < sample_count_to_write; k = k + 1)
                bus_xfer(1'b1, SAMPLE_BASE + 32'(4*k), samples[k],
                         read_data, transaction_error);
            if (bus_fault)
                fail_harness("memory initialization raised a sticky bus fault");
        end
    endtask

    task automatic configure_run(input integer sample_count_to_configure);
        begin
            csr_write(TAP_COUNT, 32'(TAP_COUNT_VALUE), 1'b0);
            csr_write(SAMPLE_COUNT, 32'(sample_count_to_configure), 1'b0);
            csr_write(COEFF_PTR, COEFF_BASE, 1'b0);
            csr_write(INPUT_PTR, SAMPLE_BASE, 1'b0);
            csr_write(OUTPUT_PTR, RESULT_BASE, 1'b0);
        end
    endtask

    task automatic reset_scoreboard(input integer sample_count_to_run,
                                    input logic is_fault_run);
        integer k;
        begin
            monitor_run = 1'b0;
            run_sample_count = sample_count_to_run;
            fault_run = is_fault_run;
            fault_injected = 1'b0;
            edge_cycle = 0;
            start_cycle = -1;
            error_cycle = -1;
            first_input_cycle = -1;
            last_output_cycle = -1;
            final_commit_cycle = -1;
            sample_events = 0;
            input_events = 0;
            output_events = 0;
            commit_events = 0;
            for (k = 0; k < SAMPLE_COUNT_VALUE; k = k + 1) begin
                sample_cycle[k] = -1;
                input_cycle[k] = -1;
                output_cycle[k] = -1;
                commit_cycle[k] = -1;
                result_before[k] = dut.result_mem[k];
            end
            monitor_run = 1'b1;
        end
    endtask

    task automatic run_full_block(input integer architecture);
        integer waited;
        integer k;
        logic [31:0] value;
        logic [31:0] status_value;
        logic transaction_error;
        begin
            active_architecture = architecture;
            run_number = run_number + 1;
            hardware_reset();
            build_reference(architecture);
            initialize_memories(SAMPLE_COUNT_VALUE);
            configure_run(SAMPLE_COUNT_VALUE);
            reset_scoreboard(SAMPLE_COUNT_VALUE, 1'b0);
            csr_write(CTRL, (32'(architecture) << 2) | 32'd1, 1'b0);

            waited = 0;
            while (commit_events < SAMPLE_COUNT_VALUE && waited < LONG_RUN_BOUND) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (commit_events != SAMPLE_COUNT_VALUE)
                fail_harness($sformatf("full block stopped at %0d commits", commit_events));
            repeat (4) @(negedge clk);
            monitor_run = 1'b0;

            if (start_cycle < 0 || final_commit_cycle < 0 || first_input_cycle < 0 ||
                last_output_cycle < 0)
                fail_counter("successful run did not record all contract event edges");
            else begin
                expected_cycles_total = final_commit_cycle - start_cycle;
                expected_compute_cycles = last_output_cycle - first_input_cycle;
            end

            csr_read(STATUS, value, transaction_error);
            status_value = value;
            if (transaction_error || value !== 32'd2)
                fail_functional($sformatf("full STATUS=%08x expected 00000002", value));
            csr_read(RESULT_COUNT, value, transaction_error);
            if (transaction_error || value !== 32'(SAMPLE_COUNT_VALUE))
                fail_counter($sformatf("full RESULT_COUNT=%08x expected %08x", value,
                                       SAMPLE_COUNT_VALUE));
            csr_read(SAMPLE_COUNT, value, transaction_error);
            if (transaction_error || value !== 32'(SAMPLE_COUNT_VALUE))
                fail_functional($sformatf("full SAMPLE_COUNT=%08x expected %08x", value,
                                          SAMPLE_COUNT_VALUE));
            csr_read(CYCLES_TOTAL, value, transaction_error);
            if (transaction_error || value !== expected_cycles_total)
                fail_counter($sformatf("full CYCLES_TOTAL=%08x expected %08x", value,
                                       expected_cycles_total));
            csr_read(COMPUTE_CYCLES, value, transaction_error);
            if (transaction_error || value !== expected_compute_cycles)
                fail_counter($sformatf("full COMPUTE_CYCLES=%08x expected %08x", value,
                                       expected_compute_cycles));

            if (commit_cycle[SAMPLE_COUNT_VALUE-1] !== final_commit_cycle)
                fail_counter("final physical commit edge was not retained independently");
            if (dut.result_commit_addr !== RESULT_BASE + 32'h0000_0ffc)
                fail_functional($sformatf("final commit request address=%08x expected 00022ffc",
                                          dut.result_commit_addr));
            for (k = 0; k < SAMPLE_COUNT_VALUE; k = k + 1)
                if (dut.result_mem[k] !== expected[k])
                    fail_functional($sformatf("result memory word %0d got %08x expected %08x",
                                              k, dut.result_mem[k], expected[k]));
            if (!(busy === 1'b0 && done === 1'b1 && error_status === 1'b0 &&
                  dut.u_accel.result_count_q === 32'(SAMPLE_COUNT_VALUE)))
                fail_functional("complete result-validity predicate was not true after final commit");

            $display("BLOCK_1024_RESULT lanes=%0d arch=%0d inputs=%0d outputs=%0d commits=%0d e_start=%0d e_in0=%0d e_out_last=%0d e_done=%0d cycles_total=%0d compute_cycles=%0d status=%08x",
                     LANES, architecture, input_events, output_events, commit_events,
                     start_cycle, first_input_cycle, last_output_cycle, final_commit_cycle,
                     expected_cycles_total, expected_compute_cycles, status_value);
        end
    endtask

    task automatic run_fault_block(input integer architecture);
        integer waited;
        integer k;
        logic [31:0] value;
        logic transaction_error;
        localparam integer FAULT_SAMPLE_COUNT = 16;
        localparam integer FAULT_COMMIT_TARGET = 8;
        begin
            active_architecture = architecture;
            run_number = run_number + 1;
            hardware_reset();
            build_reference(architecture);
            initialize_memories(FAULT_SAMPLE_COUNT);
            configure_run(FAULT_SAMPLE_COUNT);
            reset_scoreboard(FAULT_SAMPLE_COUNT, 1'b1);
            csr_write(CTRL, (32'(architecture) << 2) | 32'd1, 1'b0);

            waited = 0;
            while (commit_events < FAULT_COMMIT_TARGET &&
                   waited < LONG_RUN_BOUND && busy === 1'b1) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (commit_events < FAULT_COMMIT_TARGET)
                fail_harness($sformatf("fault precondition stopped at %0d commits",
                                       commit_events));

            @(negedge clk);
            force dut.u_accel.u_tap_bram.range_fault_q = 1'b1;
            fault_injected = 1'b1;
            waited = 0;
            while (error_cycle < 0 && waited < LONG_RUN_BOUND && busy === 1'b1) begin
                @(negedge clk);
                waited = waited + 1;
            end
            @(negedge clk);
            release dut.u_accel.u_tap_bram.range_fault_q;
            fault_injected = 1'b0;
            monitor_run = 1'b0;

            if (error_cycle < 0)
                fail_counter("internal fault run did not record e_error");
            if (commit_events != FAULT_COMMIT_TARGET)
                fail_functional($sformatf("fault RESULT_COUNT event count=%0d expected %0d",
                                          commit_events, FAULT_COMMIT_TARGET));
            if (first_input_cycle < 0 || last_output_cycle < 0)
                fail_counter("fault run did not retain prior input/output transfer span");
            else begin
                expected_cycles_total = error_cycle - start_cycle;
                expected_compute_cycles = last_output_cycle - first_input_cycle;
            end

            csr_read(STATUS, value, transaction_error);
            if (transaction_error || value !== 32'h0000_0004)
                fail_functional($sformatf("fault STATUS=%08x expected 00000004", value));
            csr_read(RESULT_COUNT, value, transaction_error);
            if (transaction_error || value !== 32'(FAULT_COMMIT_TARGET))
                fail_counter($sformatf("fault RESULT_COUNT=%08x expected %0d", value,
                                       FAULT_COMMIT_TARGET));
            csr_read(DBG_STATUS, value, transaction_error);
            if (transaction_error || (value & 32'h0000_0040) == 0)
                fail_functional($sformatf("fault DBG_STATUS=%08x lacks BRAM_FAULT", value));
            csr_read(CYCLES_TOTAL, value, transaction_error);
            if (transaction_error || value !== expected_cycles_total)
                fail_counter($sformatf("fault CYCLES_TOTAL=%08x expected %08x", value,
                                       expected_cycles_total));
            csr_read(COMPUTE_CYCLES, value, transaction_error);
            if (transaction_error || value !== expected_compute_cycles)
                fail_counter($sformatf("fault COMPUTE_CYCLES=%08x expected %08x", value,
                                       expected_compute_cycles));

            if (busy !== 1'b0 || done !== 1'b0 || error_status !== 1'b1)
                fail_functional("fault run did not leave ERROR=1, DONE=0, BUSY=0");
            for (k = 0; k < FAULT_COMMIT_TARGET; k = k + 1)
                if (dut.result_mem[k] !== expected[k])
                    fail_functional($sformatf("committed fault result[%0d] changed", k));
            for (k = FAULT_COMMIT_TARGET; k < SAMPLE_COUNT_VALUE; k = k + 1)
                if (dut.result_mem[k] !== result_before[k])
                    fail_functional($sformatf("uncommitted fault result[%0d] changed", k));

            csr_write(CTRL, 32'd2, 1'b0);
            csr_read(STATUS, value, transaction_error);
            if (transaction_error || value !== 32'd0)
                fail_functional("CTRL.RESET did not clear internal fault status");
            csr_read(RESULT_COUNT, value, transaction_error);
            if (transaction_error || value !== 32'd0)
                fail_counter("CTRL.RESET did not clear partial RESULT_COUNT");
            csr_read(CYCLES_TOTAL, value, transaction_error);
            if (transaction_error || value !== 32'd0)
                fail_counter("CTRL.RESET did not clear partial CYCLES_TOTAL");
            csr_read(COMPUTE_CYCLES, value, transaction_error);
            if (transaction_error || value !== 32'd0)
                fail_counter("CTRL.RESET did not clear partial COMPUTE_CYCLES");

            $display("BLOCK_FAULT_RESULT lanes=%0d arch=%0d commits=%0d e_start=%0d e_error=%0d e_in0=%0d e_out_last=%0d cycles_total=%0d compute_cycles=%0d",
                     LANES, architecture, commit_events, start_cycle, error_cycle,
                     first_input_cycle, last_output_cycle, expected_cycles_total,
                     expected_compute_cycles);
        end
    endtask

    initial begin : RUN_CLOSURE
        integer architecture;
        for (architecture = 0; architecture < 3; architecture = architecture + 1) begin
            run_full_block(architecture);
            run_fault_block(architecture);
        end
        $display("BLOCK_1024_SUMMARY lanes=%0d failures=%0d functional_failures=%0d counter_failures=%0d harness_errors=%0d",
                 LANES, failures, functional_failures, counter_failures, harness_errors);
        if (failures != 0)
            $fatal(1, "1024-sample block verification closure failed");
        $display("PASS: NEXUS-32 1024-sample block, timing scoreboard, and fault diagnostics");
        $finish;
    end

    initial begin
        #500000000;
        fail_harness("global watchdog expired");
        $fatal(1, "1024-sample verification closure watchdog expired");
    end
endmodule
