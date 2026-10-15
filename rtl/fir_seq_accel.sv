`timescale 1ns/1ps
// NEXUS-32 integrated FIR accelerator shell with runtime architecture selection.
// req_addr_i is a byte offset within the accelerator MMIO window; the SoC bus
// adapter translates 0x10005000 + offset to this port. Responses are registered
// one-cycle pulses; req_ready_o deasserts while a response pulse is active.
// The wrapper accepts one job at a time and prefetches the full tap window.
//
// Address map used by this module:
//   0x00 CTRL       bit 0 START, bit 1 RESET (wins over START), bits 3:2 ARCH_SEL
//                              00=sequential, 01=parallel, 10=pipelined, 11=reserved/error
//   0x04 STATUS     bit 0 BUSY, bit 1 DONE sticky, bit 2 ERROR sticky
//                   write-one-to-clear bits 1/2 while idle
//   0x08 TAP_COUNT  tap count 1..32
//   0x0c COEFF_PTR  byte pointer in [0x20000,0x21000)
//   0x10 INPUT_PTR  byte pointer in [0x21000,0x22000)
//   0x14 OUTPUT_PTR byte pointer in [0x22000,0x23000)
//   0x18 CYCLES_TOTAL accepted START through selected-engine completion
//   0x1c SAMPLE_COUNT number of successful result commits
//   0x20 COMPUTE_CYCLES first tap transfer through selected-result transfer
//
// The host RAM write ports use local WORD offsets (0..1023), not system
// addresses. Writes are denied for the entire run, including the START edge.
// A denied write sets a sticky ownership fault and the current result is
// discarded. Hardware RESET or CTRL.RESET clears safety and BRAM sticky faults.
// All architectures share this prefetch and result-commit path. This remains a
// single-buffer design, not the planned full SoC bus/DMA/STREAM-DB subsystem.
module fir_seq_accel #(
    parameter int LANES = 32
) (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic                  req_valid_i,
    output logic                  req_ready_o,
    input  logic                  req_write_i,
    input  logic [11:0]            req_addr_i,
    input  logic [31:0]            req_wdata_i,
    input  logic [3:0]             req_wstrb_i,
    output logic                  rsp_valid_o,
    output logic [31:0]            rsp_rdata_o,
    output logic                  rsp_error_o,

    input  logic                  host_sample_re_i,
    input  logic [9:0]             host_sample_raddr_i,
    output logic                  host_sample_rvalid_o,
    output logic signed [31:0]     host_sample_rdata_o,
    input  logic                  host_sample_we_i,
    input  logic [9:0]             host_sample_waddr_i,
    input  logic signed [31:0]     host_sample_wdata_i,
    input  logic                  host_coefficient_re_i,
    input  logic [9:0]             host_coefficient_raddr_i,
    output logic                  host_coefficient_rvalid_o,
    output logic signed [31:0]     host_coefficient_rdata_o,
    input  logic                  host_coefficient_we_i,
    input  logic [9:0]             host_coefficient_waddr_i,
    input  logic signed [31:0]     host_coefficient_wdata_i,

    output logic                  bank_owned_o,
    output logic                  mem_write_rejected_o,
    output logic                  result_commit_o,
    output logic [31:0]            result_commit_addr_o,
    output logic signed [31:0]     result_commit_data_o,
    output logic                  busy_o,
    output logic                  done_sticky_o,
    output logic                  error_sticky_o
);
    generate
        if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32) begin : gen_illegal_lanes
            LANES_MUST_BE_4_8_16_OR_32 invalid();
        end
    endgenerate

    // synthesis translate_off
    initial begin
        if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32) begin
            $fatal(1, "ERROR: fir_seq_accel LANES=%0d is unsupported; must be 4, 8, 16, or 32", LANES);
        end
    end
    // synthesis translate_on

    localparam logic [11:0] REG_CTRL          = 12'h000;
    localparam logic [11:0] REG_STATUS        = 12'h004;
    localparam logic [11:0] REG_TAP_COUNT     = 12'h008;
    localparam logic [11:0] REG_COEFF_PTR     = 12'h00c;
    localparam logic [11:0] REG_INPUT_PTR     = 12'h010;
    localparam logic [11:0] REG_OUTPUT_PTR    = 12'h014;
    localparam logic [11:0] REG_CYCLES_TOTAL  = 12'h018;
    localparam logic [11:0] REG_SAMPLE_COUNT  = 12'h01c;
    localparam logic [11:0] REG_COMPUTE_CYCLES= 12'h020;

    localparam logic [31:0] COEFF_BASE  = 32'h0002_0000;
    localparam logic [31:0] COEFF_LIMIT = 32'h0002_1000;
    localparam logic [31:0] INPUT_BASE  = 32'h0002_1000;
    localparam logic [31:0] INPUT_LIMIT = 32'h0002_2000;
    localparam logic [31:0] OUTPUT_BASE = 32'h0002_2000;
    localparam logic [31:0] OUTPUT_LIMIT= 32'h0002_3000;

    logic rsp_valid_q;
    logic [31:0] rsp_rdata_q;
    logic rsp_error_q;

    logic [31:0] tap_count_reg_q;
    logic [31:0] coefficient_ptr_q;
    logic [31:0] input_ptr_q;
    logic [31:0] output_ptr_q;

    logic busy_q;
    logic done_sticky_q;
    logic error_sticky_q;
    logic ownership_fault_q;
    logic mem_write_rejected_q;
    logic result_commit_q;
    logic [31:0] result_commit_addr_q;
    logic signed [31:0] result_commit_data_q;
    logic [31:0] cycles_total_q;
    logic [31:0] sample_count_q;
    logic [31:0] compute_cycles_q;

    logic [32:0] span_bytes_ext;
    logic [32:0] input_end_ext;
    logic [32:0] coefficient_end_ext;
    logic config_valid;
    logic start_request_now;
    logic reserve_banks_now;
    logic mem_write_attempt_now;
    logic mem_write_rejected_now;
    logic busy_write_request_now;
    logic invalid_start_request_now;
    logic clear_done_request_now;
    logic clear_error_request_now;
    logic fatal_event_now;

    logic [31:0] sample_offset_bytes;
    logic [31:0] coefficient_offset_bytes;
    logic [9:0] sample_base_word;
    logic [9:0] coefficient_base_word;
    logic bram_cfg_valid;
    logic tap_valid;
    logic signed [31:0] sample_tap;
    logic signed [31:0] coefficient_tap;
    logic bram_range_fault;
    logic sample_we_to_bram;
    logic coefficient_we_to_bram;

    typedef enum logic [2:0] {
        EXEC_IDLE,
        EXEC_PREFETCH_REQUEST,
        EXEC_PREFETCH_WAIT,
        EXEC_SELECTOR_SUBMIT,
        EXEC_SELECTOR_WAIT
    } exec_state_t;

    exec_state_t exec_state_q;
    logic [4:0] prefetch_index_q;
    logic [1:0] run_arch_q;
    logic [LANES*32-1:0] sample_vector_q;
    logic [LANES*32-1:0] coefficient_vector_q;
    logic [31:0] elapsed_cycles_work_q;
    logic first_input_seen_q;
    logic [31:0] compute_elapsed_work_q;
    logic soft_reset_request_now;
    logic engine_reset;

    logic prefetch_req;
    logic [4:0] prefetch_addr;
    logic selector_in_valid;
    logic selector_in_ready;
    logic selector_out_valid;
    logic selector_out_ready;
    logic signed [31:0] selector_result;
    logic selector_out_error;
    logic [15:0] selector_cycles;
    logic [1:0] selector_active_arch;

    assign req_ready_o = ~rsp_valid_q;
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_rdata_o = rsp_rdata_q;
    assign rsp_error_o = rsp_error_q;
    assign busy_o = busy_q;
    assign bank_owned_o = busy_q;
    assign done_sticky_o = done_sticky_q;
    assign error_sticky_o = error_sticky_q;
    assign mem_write_rejected_o = mem_write_rejected_q;
    assign result_commit_o = result_commit_q;
    assign result_commit_addr_o = result_commit_addr_q;
    assign result_commit_data_o = result_commit_data_q;

    // Use only the low six bits to compute a candidate span, while separately
    // requiring the whole TAP_COUNT register to be in range.
    always_comb begin
        span_bytes_ext = {27'd0, tap_count_reg_q[5:0]} << 2;
        input_end_ext = {1'b0, input_ptr_q} + span_bytes_ext;
        coefficient_end_ext = {1'b0, coefficient_ptr_q} + span_bytes_ext;
        config_valid = (tap_count_reg_q >= 32'd1) &&
                       (tap_count_reg_q <= 32'(LANES)) &&
                       (input_ptr_q[1:0] == 2'b00) &&
                       (coefficient_ptr_q[1:0] == 2'b00) &&
                       (output_ptr_q[1:0] == 2'b00) &&
                       (input_ptr_q >= INPUT_BASE) &&
                       (input_ptr_q < INPUT_LIMIT) &&
                       (input_end_ext <= {1'b0, INPUT_LIMIT}) &&
                       (coefficient_ptr_q >= COEFF_BASE) &&
                       (coefficient_ptr_q < COEFF_LIMIT) &&
                       (coefficient_end_ext <= {1'b0, COEFF_LIMIT}) &&
                       (output_ptr_q >= OUTPUT_BASE) &&
                       (output_ptr_q < OUTPUT_LIMIT) && bram_cfg_valid;
    end

    assign sample_offset_bytes = input_ptr_q - INPUT_BASE;
    assign coefficient_offset_bytes = coefficient_ptr_q - COEFF_BASE;
    assign sample_base_word = sample_offset_bytes[11:2];
    assign coefficient_base_word = coefficient_offset_bytes[11:2];

    // Reserve both memory banks on the accepted START edge. This ensures a
    // concurrent host write is denied even though busy_q has not updated yet.
    // A complete CTRL write with RESET asserted performs a synchronous
    // accelerator-local reset. RESET takes priority when START is also set.
    assign soft_reset_request_now = req_valid_i && req_ready_o && req_write_i &&
                                    (req_addr_i == REG_CTRL) &&
                                    (req_wstrb_i == 4'hf) && req_wdata_i[1] &&
                                    (req_wdata_i[31:4] == 28'd0);
    assign engine_reset = rst_i || soft_reset_request_now;

    assign start_request_now = req_valid_i && req_ready_o && req_write_i &&
                               (req_addr_i == REG_CTRL) &&
                               (req_wstrb_i == 4'hf) && req_wdata_i[0] &&
                               !req_wdata_i[1] && (req_wdata_i[31:4] == 28'd0);
    assign reserve_banks_now = start_request_now && !busy_q && config_valid &&
                               !ownership_fault_q && !bram_range_fault &&
                               (req_wdata_i[3:2] != 2'b11);
    assign mem_write_attempt_now = host_sample_we_i || host_coefficient_we_i;
    assign mem_write_rejected_now = mem_write_attempt_now &&
                                    (busy_q || reserve_banks_now);
    assign sample_we_to_bram = host_sample_we_i && !busy_q && !reserve_banks_now;
    assign coefficient_we_to_bram = host_coefficient_we_i && !busy_q && !reserve_banks_now;
    assign busy_write_request_now = req_valid_i && req_ready_o && req_write_i &&
                                    busy_q;
    assign invalid_start_request_now = start_request_now && !busy_q &&
                                       (!config_valid || ownership_fault_q || bram_range_fault ||
                                        (req_wdata_i[3:2] == 2'b11));
    assign clear_done_request_now = req_valid_i && req_ready_o && req_write_i &&
                                    (req_addr_i == REG_STATUS) &&
                                    (req_wstrb_i == 4'hf) && req_wdata_i[1] &&
                                    ((req_wdata_i & 32'hffff_fff9) == 32'd0) && !busy_q;
    assign clear_error_request_now = req_valid_i && req_ready_o && req_write_i &&
                                     (req_addr_i == REG_STATUS) &&
                                     (req_wstrb_i == 4'hf) && req_wdata_i[2] &&
                                     ((req_wdata_i & 32'hffff_fff9) == 32'd0) && !busy_q;
    assign fatal_event_now = mem_write_rejected_now || busy_write_request_now ||
                             invalid_start_request_now ||
                             (selector_out_valid && selector_out_error) ||
                             bram_range_fault || ownership_fault_q;

    fir_tap_bram u_tap_bram (
        .clk_i(clk_i),
        .rst_i(engine_reset),
        .sample_base_word_i(sample_base_word),
        .coefficient_base_word_i(coefficient_base_word),
        .tap_count_i(tap_count_reg_q[5:0]),
        .cfg_valid_o(bram_cfg_valid),
        .tap_req_i(prefetch_req),
        .tap_index_i(prefetch_addr),
        .tap_valid_o(tap_valid),
        .sample_tap_o(sample_tap),
        .coefficient_tap_o(coefficient_tap),
        .range_fault_o(bram_range_fault),
        .host_sample_re_i(host_sample_re_i),
        .host_sample_raddr_i(host_sample_raddr_i),
        .host_sample_rvalid_o(host_sample_rvalid_o),
        .host_sample_rdata_o(host_sample_rdata_o),
        .host_coefficient_re_i(host_coefficient_re_i),
        .host_coefficient_raddr_i(host_coefficient_raddr_i),
        .host_coefficient_rvalid_o(host_coefficient_rvalid_o),
        .host_coefficient_rdata_o(host_coefficient_rdata_o),
        .sample_we_i(sample_we_to_bram),
        .sample_waddr_i(host_sample_waddr_i),
        .sample_wdata_i(host_sample_wdata_i),
        .coefficient_we_i(coefficient_we_to_bram),
        .coefficient_waddr_i(host_coefficient_waddr_i),
        .coefficient_wdata_i(host_coefficient_wdata_i)
    );

    // Synchronous BRAM is gathered into a complete, stable tap vector before
    // the selected engine accepts the operation. This adapter latency is
    // included in CYCLES_TOTAL; COMPUTE_CYCLES spans first tap data to result.
    assign prefetch_req = (exec_state_q == EXEC_PREFETCH_REQUEST) && busy_q;
    assign prefetch_addr = prefetch_index_q;
    assign selector_in_valid = (exec_state_q == EXEC_SELECTOR_SUBMIT) && busy_q;
    assign selector_out_ready = 1'b1; // result is committed immediately when valid

    fir_arch_selector #(
        .LANES(LANES)
    ) u_arch_selector (
        .clk_i(clk_i),
        .rst_i(engine_reset),
        .in_valid_i(selector_in_valid),
        .in_ready_o(selector_in_ready),
        .arch_select_i(run_arch_q),
        .tap_count_i(tap_count_reg_q[5:0]),
        .sample_vector_i(sample_vector_q),
        .coefficient_vector_i(coefficient_vector_q),
        .out_valid_o(selector_out_valid),
        .out_ready_i(selector_out_ready),
        .out_result_o(selector_result),
        .out_error_o(selector_out_error),
        .cycles_o(selector_cycles),
        .active_arch_o(selector_active_arch)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i || soft_reset_request_now) begin
            rsp_valid_q <= (!rst_i && soft_reset_request_now);
            rsp_rdata_q <= 32'd0;
            rsp_error_q <= 1'b0;
            tap_count_reg_q <= 32'd0;
            coefficient_ptr_q <= COEFF_BASE;
            input_ptr_q <= INPUT_BASE;
            output_ptr_q <= OUTPUT_BASE;
            busy_q <= 1'b0;
            done_sticky_q <= 1'b0;
            error_sticky_q <= 1'b0;
            exec_state_q <= EXEC_IDLE;
            prefetch_index_q <= 5'd0;
            run_arch_q <= 2'd0;
            sample_vector_q <= '0;
            coefficient_vector_q <= '0;
            ownership_fault_q <= 1'b0;
            mem_write_rejected_q <= 1'b0;
            result_commit_q <= 1'b0;
            result_commit_addr_q <= OUTPUT_BASE;
            result_commit_data_q <= 32'sd0;
            cycles_total_q <= 32'd0;
            elapsed_cycles_work_q <= 32'd0;
            first_input_seen_q <= 1'b0;
            compute_elapsed_work_q <= 32'd0;
            sample_count_q <= 32'd0;
            compute_cycles_q <= 32'd0;
        end else begin
            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;
            mem_write_rejected_q <= 1'b0;
            result_commit_q <= 1'b0;

            if (mem_write_rejected_now) begin
                mem_write_rejected_q <= 1'b1;
                ownership_fault_q <= 1'b1;
            end

            if (fatal_event_now)
                error_sticky_q <= 1'b1;
            else if (clear_error_request_now)
                error_sticky_q <= 1'b0;

            if (clear_done_request_now)
                done_sticky_q <= 1'b0;

            if (busy_q)
                elapsed_cycles_work_q <= elapsed_cycles_work_q + 32'd1;

            if (busy_q && (exec_state_q == EXEC_PREFETCH_WAIT) && tap_valid)
                first_input_seen_q <= 1'b1;
            if (busy_q && first_input_seen_q)
                compute_elapsed_work_q <= compute_elapsed_work_q + 32'd1;

            // Architecture-independent prefetch and dispatch state machine.
            case (exec_state_q)
                EXEC_IDLE: begin
                    // A START accepted below transitions to PREFETCH_REQUEST.
                end

                EXEC_PREFETCH_REQUEST: begin
                    // BRAM samples prefetch_req at this edge; wait for its
                    // registered tap_valid/data response on the next cycle.
                    exec_state_q <= EXEC_PREFETCH_WAIT;
                end

                EXEC_PREFETCH_WAIT: begin
                    if (tap_valid) begin
                        sample_vector_q[prefetch_index_q*32 +: 32] <= sample_tap;
                        coefficient_vector_q[prefetch_index_q*32 +: 32] <= coefficient_tap;
                        if (({1'b0, prefetch_index_q} + 6'd1) >= tap_count_reg_q[5:0]) begin
                            exec_state_q <= EXEC_SELECTOR_SUBMIT;
                        end else begin
                            prefetch_index_q <= prefetch_index_q + 5'd1;
                            exec_state_q <= EXEC_PREFETCH_REQUEST;
                        end
                    end
                end

                EXEC_SELECTOR_SUBMIT: begin
                    if (selector_in_valid && selector_in_ready)
                        exec_state_q <= EXEC_SELECTOR_WAIT;
                end

                EXEC_SELECTOR_WAIT: begin
                    if (selector_out_valid) begin
                        exec_state_q <= EXEC_IDLE;
                        busy_q <= 1'b0;
                        done_sticky_q <= 1'b1;
                        cycles_total_q <= elapsed_cycles_work_q + 32'd1;
                        compute_cycles_q <= first_input_seen_q ?
                                            (compute_elapsed_work_q + 32'd1) : 32'd0;
                        if (!bram_range_fault && !ownership_fault_q &&
                            !mem_write_rejected_now && !selector_out_error &&
                            (selector_active_arch == run_arch_q) && (selector_cycles != 16'd0)) begin
                            result_commit_q <= 1'b1;
                            result_commit_addr_q <= output_ptr_q;
                            result_commit_data_q <= selector_result;
                            sample_count_q <= sample_count_q + 32'd1;
                        end else begin
                            error_sticky_q <= 1'b1;
                        end
                    end
                end

                default: begin
                    exec_state_q <= EXEC_IDLE;
                    busy_q <= 1'b0;
                    error_sticky_q <= 1'b1;
                end
            endcase

            if (req_valid_i && req_ready_o) begin
                rsp_valid_q <= 1'b1;
                rsp_rdata_q <= 32'd0;
                rsp_error_q <= 1'b0;

                if (req_addr_i[1:0] != 2'b00) begin
                    rsp_error_q <= 1'b1;
                end else if (req_write_i) begin
                    if (req_wstrb_i != 4'hf) begin
                        rsp_error_q <= 1'b1;
                    end else if (busy_q) begin
                        rsp_error_q <= 1'b1;
                    end else begin
                        case (req_addr_i)
                            REG_CTRL: begin
                                if ((req_wdata_i & 32'hffff_fff0) != 32'd0) begin
                                    rsp_error_q <= 1'b1;
                                end else if (req_wdata_i[0]) begin
                                    if ((req_wdata_i[3:2] == 2'b11) ||
                                        !config_valid || ownership_fault_q || bram_range_fault) begin
                                        rsp_error_q <= 1'b1;
                                        error_sticky_q <= 1'b1;
                                    end else begin
                                        busy_q <= 1'b1;
                                        exec_state_q <= EXEC_PREFETCH_REQUEST;
                                        prefetch_index_q <= 5'd0;
                                        run_arch_q <= req_wdata_i[3:2];
                                        sample_vector_q <= '0;
                                        coefficient_vector_q <= '0;
                                        done_sticky_q <= 1'b0;
                                        elapsed_cycles_work_q <= 32'd0;
                                        first_input_seen_q <= 1'b0;
                                        compute_elapsed_work_q <= 32'd0;
                                    end
                                end
                            end
                            REG_STATUS: begin
                                if ((req_wdata_i & 32'hffff_fff9) != 32'd0) begin
                                    rsp_error_q <= 1'b1;
                                end else begin
                                    if (req_wdata_i[1]) done_sticky_q <= 1'b0;
                                    if (req_wdata_i[2] && !bram_range_fault && !ownership_fault_q)
                                        error_sticky_q <= 1'b0;
                                end
                            end
                            REG_TAP_COUNT: begin
                                tap_count_reg_q <= req_wdata_i;
                            end
                            REG_COEFF_PTR: begin
                                coefficient_ptr_q <= req_wdata_i;
                            end
                            REG_INPUT_PTR: begin
                                input_ptr_q <= req_wdata_i;
                            end
                            REG_OUTPUT_PTR: begin
                                output_ptr_q <= req_wdata_i;
                            end
                            default: rsp_error_q <= 1'b1;
                        endcase
                    end
                end else begin
                    case (req_addr_i)
                        REG_CTRL:           rsp_rdata_q <= 32'd0;
                        REG_STATUS:         rsp_rdata_q <= {29'd0, error_sticky_q, done_sticky_q, busy_q};
                        REG_TAP_COUNT:      rsp_rdata_q <= tap_count_reg_q;
                        REG_COEFF_PTR:      rsp_rdata_q <= coefficient_ptr_q;
                        REG_INPUT_PTR:      rsp_rdata_q <= input_ptr_q;
                        REG_OUTPUT_PTR:     rsp_rdata_q <= output_ptr_q;
                        REG_CYCLES_TOTAL:   rsp_rdata_q <= cycles_total_q;
                        REG_SAMPLE_COUNT:   rsp_rdata_q <= sample_count_q;
                        REG_COMPUTE_CYCLES: rsp_rdata_q <= compute_cycles_q;
                        default: rsp_error_q <= 1'b1;
                    endcase
                end
            end
        end
    end
endmodule
