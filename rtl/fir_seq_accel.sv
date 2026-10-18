`timescale 1ns/1ps
// NEXUS-32 integrated FIR accelerator shell with runtime architecture selection.
// req_addr_i is a byte offset within the accelerator MMIO window; the SoC bus
// adapter translates 0x10005000 + offset to this port. Responses are registered
// one-cycle pulses; req_ready_o deasserts while a response pulse is active.
// The wrapper accepts one job at a time and serializes one block window at a time.
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
//   0x18 CYCLES_TOTAL accepted START through final physical result commit
//   0x1c SAMPLE_COUNT configured block length (validated at START)
//   0x20 COMPUTE_CYCLES first engine input transfer through last output transfer
//   0x3c RESULT_COUNT successful result commits in the current run
//
// The host RAM write ports use local WORD offsets (0..1023), not system
// addresses. Writes are denied for the entire run, including the START edge.
// A denied write sets a sticky ownership debug event without corrupting BRAM
// or invalidating the active result. Hardware RESET or CTRL.RESET clears safety
// and BRAM sticky faults.
// All architectures share this serialized block/history and result-commit path.
// This remains a single-buffer design, not the planned full SoC bus/DMA/STREAM-DB
// subsystem.
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

     input  logic [7:0]             host_event_set_i,
     input  logic [31:0]            host_event_addr_i,
     input  logic [31:0]            host_event_info_i,

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
     localparam logic [11:0] REG_AUTO_CFG      = 12'h024;
     localparam logic [11:0] REG_AUTO_SELECTED = 12'h028;
     localparam logic [11:0] REG_AUTO_MODEL_ID = 12'h02c;
     localparam logic [11:0] REG_DBG_STATUS    = 12'h030;
     localparam logic [11:0] REG_DBG_ADDR      = 12'h034;
     localparam logic [11:0] REG_DBG_INFO      = 12'h038;
     localparam logic [11:0] REG_RESULT_COUNT  = 12'h03c;
     localparam logic [11:0] REG_CONTRACT_VERSION = 12'h040;
     localparam logic [11:0] REG_BUILD_ID      = 12'h044;

     localparam int DBG_BUS_UNMAPPED = 0;
     localparam int DBG_BUS_ACCESS = 1;
     localparam int DBG_MEM_OWNERSHIP = 2;
     localparam int DBG_RESULT_WRITE_FORBIDDEN = 3;
     localparam int DBG_CONFIG_WHILE_BUSY = 4;
     localparam int DBG_INVALID_CONFIG = 5;
     localparam int DBG_BRAM_FAULT = 6;
     localparam int DBG_ENGINE_ERROR = 7;
     localparam logic [7:0] DBG_CLEARABLE_MASK = 8'h3f;
     localparam logic [1:0] DBG_DIR_READ = 2'd0;
     localparam logic [1:0] DBG_DIR_WRITE = 2'd1;
     localparam logic [1:0] DBG_DIR_INTERNAL = 2'd2;
     localparam logic [1:0] DBG_MASTER_CPU = 2'd0;
     localparam logic [1:0] DBG_MASTER_INTERNAL = 2'd1;

       function automatic logic [31:0] make_debug_info(
           input logic [2:0] event_code,
           input logic [1:0] direction,
           input logic [1:0] master
     );
         begin
             make_debug_info = 32'd0;
             make_debug_info[2:0] = event_code;
             make_debug_info[4:3] = direction;
             make_debug_info[6:5] = master;
           end
       endfunction

       function automatic logic [9:0] local_word_index(
           input logic [31:0] pointer,
           input logic [31:0] base
       );
           begin
               local_word_index = 10'((pointer - base) >> 2);
           end
       endfunction

      // Select one metadata candidate for a single event class. Address is
      // the primary key; at an equal address writes beat reads, then the
      // lowest encoded master ID wins. Other directions (for example the
      // internal-fault direction) participate only in the master tie-break.
      function automatic logic debug_candidate_wins(
          input logic        candidate_valid,
          input logic [31:0] candidate_addr,
          input logic [31:0] candidate_info,
          input logic        current_valid,
          input logic [31:0] current_addr,
          input logic [31:0] current_info
      );
          begin
              debug_candidate_wins = 1'b0;
              if (!current_valid)
                  debug_candidate_wins = candidate_valid;
              else if (!candidate_valid)
                  debug_candidate_wins = 1'b0;
              else if (candidate_addr < current_addr)
                  debug_candidate_wins = 1'b1;
              else if (candidate_addr > current_addr)
                  debug_candidate_wins = 1'b0;
              else if ((candidate_info[4:3] == DBG_DIR_WRITE) &&
                       (current_info[4:3] != DBG_DIR_WRITE))
                  debug_candidate_wins = 1'b1;
              else if ((candidate_info[4:3] != DBG_DIR_WRITE) &&
                       (current_info[4:3] == DBG_DIR_WRITE))
                  debug_candidate_wins = 1'b0;
              else
                  debug_candidate_wins = candidate_info[6:5] < current_info[6:5];
          end
      endfunction

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
    logic [31:0] sample_count_cfg_q;

    // Configuration captured on the accepting START edge. All Port-B inputs,
    // history formation, and result addresses use these active snapshots rather
    // than mutable CSR state.
    logic [5:0] tap_count_active_q;
    logic [31:0] sample_count_active_q;
    logic [31:0] coefficient_ptr_active_q;
    logic [31:0] input_ptr_active_q;
    logic [31:0] output_ptr_active_q;

    logic busy_q;
    logic done_sticky_q;
    logic error_sticky_q;
    logic mem_write_rejected_q;
    logic result_commit_q;
    logic [31:0] result_commit_addr_q;
    logic signed [31:0] result_commit_data_q;
    logic [31:0] cycles_total_q;
    logic [31:0] result_count_q;
    logic [31:0] compute_cycles_q;
    logic [7:0] debug_status_q;
    logic [31:0] debug_addr_q;
    logic [31:0] debug_info_q;
    logic internal_fault_q;
    logic bram_fault_seen_q;

    logic signed [31:0] pending_sample_q;
    logic pending_valid_q;
    logic signed [31:0] history_q [0:LANES-2];
    logic [5:0] coefficient_index_q;
    logic [10:0] sample_index_q;

    logic [33:0] tap_span_bytes_ext;
    logic [33:0] sample_span_bytes_ext;
    logic [35:0] input_end_ext;
    logic [35:0] coefficient_end_ext;
    logic [35:0] output_end_ext;
    logic config_valid;
    logic start_request_now;
    logic reserve_banks_now;
    logic mem_write_attempt_now;
    logic mem_write_rejected_now;
     logic invalid_start_request_now;
     logic clear_done_request_now;
     logic clear_error_request_now;
     logic clear_debug_request_now;
     logic [7:0] debug_clear_mask_now;
     logic csr_bus_access_event_now;
     logic busy_config_write_now;
     logic busy_start_noop_now;
     logic internal_fault_event_now;
     logic invalid_config_event_now;
     logic host_mem_ownership_event_now;
     logic [31:0] host_mem_event_addr_now;
     logic [31:0] host_mem_event_info_now;
     logic bram_fault_event_now;
     logic [7:0] debug_event_set_now;
     logic [31:0] debug_event_addr_now;
     logic [31:0] debug_event_info_now;
     logic debug_event_valid [0:7];
     logic [31:0] debug_event_addr_candidate [0:7];
     logic [31:0] debug_event_info_candidate [0:7];
     integer debug_index;
     logic req_accept_now;

     logic [9:0] active_sample_base_word;
    logic [9:0] active_coefficient_base_word;
    logic bram_cfg_valid;
    logic bram_range_fault;
    logic sample_we_to_bram;
    logic coefficient_we_to_bram;
    logic accelerator_sample_re;
    logic [9:0] accelerator_sample_raddr;
    logic accelerator_sample_rvalid;
    logic signed [31:0] accelerator_sample_rdata;
    logic accelerator_coefficient_re;
    logic [9:0] accelerator_coefficient_raddr;
    logic accelerator_coefficient_rvalid;
    logic signed [31:0] accelerator_coefficient_rdata;
    logic physical_result_commit_now;
    integer history_index;

     typedef enum logic [3:0] {
         EXEC_IDLE,
         EXEC_COEFF_REQUEST,
         EXEC_COEFF_WAIT,
         EXEC_SAMPLE_REQUEST,
         EXEC_SAMPLE_WAIT,
         EXEC_SELECTOR_SUBMIT,
         EXEC_SELECTOR_WAIT,
         EXEC_COMMIT_WAIT
     } exec_state_t;

     exec_state_t exec_state_q;
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

    // Compute all configured spans in widened representations. The full
    // register values are retained until START validation so semantic errors
    // are reported at the command, not at the configuration write.
    always_comb begin
        tap_span_bytes_ext = {2'd0, tap_count_reg_q} << 2;
        sample_span_bytes_ext = {2'd0, sample_count_cfg_q} << 2;
        input_end_ext = {4'd0, input_ptr_q} + {2'd0, sample_span_bytes_ext};
        coefficient_end_ext = {4'd0, coefficient_ptr_q} + {2'd0, tap_span_bytes_ext};
        output_end_ext = {4'd0, output_ptr_q} + {2'd0, sample_span_bytes_ext};
        config_valid = (tap_count_reg_q >= 32'd1) &&
                       (tap_count_reg_q <= 32'(LANES)) &&
                       (sample_count_cfg_q >= 32'd1) &&
                       (sample_count_cfg_q <= 32'd1024) &&
                       (input_ptr_q[1:0] == 2'b00) &&
                       (coefficient_ptr_q[1:0] == 2'b00) &&
                       (output_ptr_q[1:0] == 2'b00) &&
                       (input_ptr_q >= INPUT_BASE) &&
                       (input_ptr_q < INPUT_LIMIT) &&
                       (input_end_ext <= {4'd0, INPUT_LIMIT}) &&
                       (coefficient_ptr_q >= COEFF_BASE) &&
                       (coefficient_ptr_q < COEFF_LIMIT) &&
                       (coefficient_end_ext <= {4'd0, COEFF_LIMIT}) &&
                       (output_ptr_q >= OUTPUT_BASE) &&
                       (output_ptr_q < OUTPUT_LIMIT) &&
                       (output_end_ext <= {4'd0, OUTPUT_LIMIT});
    end

    assign active_sample_base_word = local_word_index(input_ptr_active_q, INPUT_BASE);
    assign active_coefficient_base_word = local_word_index(coefficient_ptr_active_q, COEFF_BASE);

    assign accelerator_sample_re = (exec_state_q == EXEC_SAMPLE_REQUEST) && busy_q;
    assign accelerator_sample_raddr = active_sample_base_word + sample_index_q[9:0];
    assign accelerator_coefficient_re = (exec_state_q == EXEC_COEFF_REQUEST) && busy_q;
    assign accelerator_coefficient_raddr = active_coefficient_base_word + {4'd0, coefficient_index_q};
    assign physical_result_commit_now = result_commit_q && !soft_reset_request_now && !rst_i;

    assign req_accept_now = req_valid_i && req_ready_o;

    // Reserve both memory banks on the accepted START edge. This ensures a
    // concurrent host write is denied even though busy_q has not updated yet.
    // A complete CTRL write with RESET asserted performs a synchronous
    // accelerator-local reset. RESET takes priority when START is also set.
    assign soft_reset_request_now = req_accept_now && req_write_i &&
                                    (req_addr_i == REG_CTRL) &&
                                    (req_wstrb_i == 4'hf) && req_wdata_i[1] &&
                                    (req_wdata_i[31:4] == 28'd0);
    assign engine_reset = rst_i || soft_reset_request_now;

    assign start_request_now = req_accept_now && req_write_i &&
                               (req_addr_i == REG_CTRL) &&
                               (req_wstrb_i == 4'hf) && req_wdata_i[0] &&
                               !req_wdata_i[1] && (req_wdata_i[31:4] == 28'd0);
    assign reserve_banks_now = start_request_now && !busy_q && !error_sticky_q && config_valid &&
                               !bram_range_fault &&
                               (req_wdata_i[3:2] != 2'b11);
    assign mem_write_attempt_now = host_sample_we_i || host_coefficient_we_i;
    assign mem_write_rejected_now = mem_write_attempt_now &&
                                    (busy_q || reserve_banks_now);
    assign sample_we_to_bram = host_sample_we_i && !busy_q && !reserve_banks_now;
    assign coefficient_we_to_bram = host_coefficient_we_i && !busy_q && !reserve_banks_now;
    assign busy_start_noop_now = req_accept_now && req_write_i && busy_q &&
                                 (req_addr_i == REG_CTRL) && (req_wstrb_i == 4'hf) &&
                                 req_wdata_i[0] && !req_wdata_i[1] &&
                                 (req_wdata_i[31:4] == 28'd0);
    assign clear_done_request_now = req_accept_now && req_write_i &&
                                    (req_addr_i == REG_STATUS) &&
                                    (req_wstrb_i == 4'hf) && req_wdata_i[1] &&
                                    ((req_wdata_i & 32'hffff_fff9) == 32'd0) && !busy_q;
    assign clear_error_request_now = req_accept_now && req_write_i &&
                                     (req_addr_i == REG_STATUS) &&
                                     (req_wstrb_i == 4'hf) && req_wdata_i[2] &&
                                     ((req_wdata_i & 32'hffff_fff9) == 32'd0) && !busy_q;
    assign clear_debug_request_now = req_accept_now && req_write_i &&
                                     (req_addr_i == REG_DBG_STATUS) &&
                                     (req_wstrb_i == 4'hf) && !busy_q &&
                                     (req_wdata_i[31:8] == 24'd0);
    assign debug_clear_mask_now = req_wdata_i[7:0] & DBG_CLEARABLE_MASK;
    assign invalid_start_request_now = start_request_now && !busy_q && !error_sticky_q &&
                                       (!config_valid || (req_wdata_i[3:2] == 2'b11));
    assign internal_fault_event_now = bram_range_fault ||
                                      (selector_out_valid && selector_out_error);
    // bram_range_fault is a persistent BRAM-side status output. It contributes
    // to internal-fault handling while high, but contributes to debug metadata
    // only on the first edge on which the fault is observed.
    assign bram_fault_event_now = bram_range_fault && !bram_fault_seen_q;
    assign invalid_config_event_now = invalid_start_request_now;

    always_comb begin
        csr_bus_access_event_now = 1'b0;
        if (req_accept_now) begin
            if (req_addr_i[1:0] != 2'b00) begin
                csr_bus_access_event_now = 1'b1;
            end else if (req_write_i) begin
                if (req_wstrb_i != 4'hf) begin
                    csr_bus_access_event_now = 1'b1;
                end else if ((req_addr_i == REG_CTRL) && (req_wdata_i[31:4] != 28'd0)) begin
                    csr_bus_access_event_now = 1'b1;
                end else if ((req_addr_i == REG_STATUS) && ((req_wdata_i & 32'hffff_fff9) != 32'd0)) begin
                    csr_bus_access_event_now = 1'b1;
                end else if ((req_addr_i == REG_DBG_STATUS) && (req_wdata_i[31:8] != 24'd0)) begin
                    csr_bus_access_event_now = 1'b1;
                end else if ((req_addr_i == REG_DBG_STATUS || req_addr_i == REG_STATUS) && busy_q) begin
                    csr_bus_access_event_now = 1'b1;
                end else begin
                    case (req_addr_i)
                        REG_CTRL, REG_STATUS, REG_TAP_COUNT, REG_COEFF_PTR,
                        REG_INPUT_PTR, REG_OUTPUT_PTR, REG_SAMPLE_COUNT,
                        REG_DBG_STATUS: begin end
                        default: csr_bus_access_event_now = 1'b1;
                    endcase
                end
            end else begin
                case (req_addr_i)
                    REG_CTRL, REG_STATUS, REG_TAP_COUNT, REG_COEFF_PTR,
                    REG_INPUT_PTR, REG_OUTPUT_PTR, REG_CYCLES_TOTAL,
                    REG_SAMPLE_COUNT, REG_COMPUTE_CYCLES, REG_AUTO_CFG,
                    REG_AUTO_SELECTED, REG_AUTO_MODEL_ID, REG_DBG_STATUS,
                    REG_DBG_ADDR, REG_DBG_INFO, REG_RESULT_COUNT,
                    REG_CONTRACT_VERSION, REG_BUILD_ID: begin end
                    default: csr_bus_access_event_now = 1'b1;
                endcase
            end
        end
    end

    assign busy_config_write_now = req_accept_now && req_write_i && busy_q &&
                                   (req_wstrb_i == 4'hf) && !csr_bus_access_event_now &&
                                   !busy_start_noop_now && !soft_reset_request_now &&
                                   ((req_addr_i == REG_CTRL) ||
                                    (req_addr_i == REG_TAP_COUNT) ||
                                    (req_addr_i == REG_COEFF_PTR) ||
                                    (req_addr_i == REG_INPUT_PTR) ||
                                    (req_addr_i == REG_OUTPUT_PTR) ||
                                    (req_addr_i == REG_SAMPLE_COUNT));

    always_comb begin
        host_mem_ownership_event_now = 1'b0;
        host_mem_event_addr_now = 32'd0;
        host_mem_event_info_now = 32'd0;
        if ((host_sample_re_i || host_sample_we_i || host_coefficient_re_i || host_coefficient_we_i) &&
            (busy_q || reserve_banks_now)) begin
            host_mem_ownership_event_now = 1'b1;
            host_mem_event_info_now = make_debug_info(
                DBG_MEM_OWNERSHIP[2:0],
                (host_sample_we_i || host_coefficient_we_i) ? DBG_DIR_WRITE : DBG_DIR_READ,
                DBG_MASTER_CPU);
            if (host_sample_re_i || host_sample_we_i)
                host_mem_event_addr_now = INPUT_BASE +
                                          ({22'd0, (host_sample_we_i ? host_sample_waddr_i : host_sample_raddr_i)} << 2);
            if (host_coefficient_re_i || host_coefficient_we_i) begin
                if (!(host_sample_re_i || host_sample_we_i) ||
                    (COEFF_BASE + ({22'd0, (host_coefficient_we_i ? host_coefficient_waddr_i : host_coefficient_raddr_i)} << 2) <
                     host_mem_event_addr_now)) begin
                    host_mem_event_addr_now = COEFF_BASE +
                                              ({22'd0, (host_coefficient_we_i ? host_coefficient_waddr_i : host_coefficient_raddr_i)} << 2);
                end
            end
        end
    end

    always_comb begin
        debug_event_set_now = 8'd0;
        debug_event_addr_now = 32'd0;
        debug_event_info_now = 32'd0;
        for (debug_index = 0; debug_index < 8; debug_index = debug_index + 1) begin
            debug_event_valid[debug_index] = 1'b0;
            debug_event_addr_candidate[debug_index] = 32'd0;
            debug_event_info_candidate[debug_index] = 32'd0;
        end

        for (debug_index = 0; debug_index < 8; debug_index = debug_index + 1) begin
            if (host_event_set_i[debug_index]) begin
                debug_event_valid[debug_index] = 1'b1;
                debug_event_addr_candidate[debug_index] = host_event_addr_i;
                debug_event_info_candidate[debug_index] = host_event_info_i;
            end
        end

        if (host_mem_ownership_event_now) begin
            debug_event_valid[DBG_MEM_OWNERSHIP] = 1'b1;
            if (debug_candidate_wins(
                    1'b1, host_mem_event_addr_now, host_mem_event_info_now,
                    host_event_set_i[DBG_MEM_OWNERSHIP],
                    debug_event_addr_candidate[DBG_MEM_OWNERSHIP],
                    debug_event_info_candidate[DBG_MEM_OWNERSHIP])) begin
                debug_event_addr_candidate[DBG_MEM_OWNERSHIP] = host_mem_event_addr_now;
                debug_event_info_candidate[DBG_MEM_OWNERSHIP] = host_mem_event_info_now;
            end
        end

        if (csr_bus_access_event_now) begin
            debug_event_valid[DBG_BUS_ACCESS] = 1'b1;
            if (debug_candidate_wins(
                    1'b1, 32'h1000_5000 + {20'd0, req_addr_i},
                    make_debug_info(3'd1, req_write_i ? DBG_DIR_WRITE : DBG_DIR_READ,
                                    DBG_MASTER_CPU),
                    host_event_set_i[DBG_BUS_ACCESS],
                    debug_event_addr_candidate[DBG_BUS_ACCESS],
                    debug_event_info_candidate[DBG_BUS_ACCESS])) begin
                debug_event_addr_candidate[DBG_BUS_ACCESS] = 32'h1000_5000 + {20'd0, req_addr_i};
                debug_event_info_candidate[DBG_BUS_ACCESS] = make_debug_info(
                    3'd1, req_write_i ? DBG_DIR_WRITE : DBG_DIR_READ, DBG_MASTER_CPU);
            end
        end

        if (busy_config_write_now) begin
            debug_event_valid[DBG_CONFIG_WHILE_BUSY] = 1'b1;
            debug_event_addr_candidate[DBG_CONFIG_WHILE_BUSY] = 32'h1000_5000 + {20'd0, req_addr_i};
            debug_event_info_candidate[DBG_CONFIG_WHILE_BUSY] = make_debug_info(
                3'd4, DBG_DIR_WRITE, DBG_MASTER_CPU);
        end

        if (invalid_config_event_now) begin
            debug_event_valid[DBG_INVALID_CONFIG] = 1'b1;
            debug_event_addr_candidate[DBG_INVALID_CONFIG] = 32'h1000_5000 + {20'd0, req_addr_i};
            debug_event_info_candidate[DBG_INVALID_CONFIG] = make_debug_info(
                3'd5, DBG_DIR_WRITE, DBG_MASTER_CPU);
        end

        if (bram_fault_event_now) begin
            debug_event_valid[DBG_BRAM_FAULT] = 1'b1;
            debug_event_addr_candidate[DBG_BRAM_FAULT] = input_ptr_active_q;
            debug_event_info_candidate[DBG_BRAM_FAULT] = make_debug_info(
                3'd6, DBG_DIR_INTERNAL, DBG_MASTER_INTERNAL);
        end

        if (selector_out_valid && selector_out_error) begin
            debug_event_valid[DBG_ENGINE_ERROR] = 1'b1;
            debug_event_addr_candidate[DBG_ENGINE_ERROR] = output_ptr_active_q;
            debug_event_info_candidate[DBG_ENGINE_ERROR] = make_debug_info(
                3'd7, DBG_DIR_INTERNAL, DBG_MASTER_INTERNAL);
        end

        for (debug_index = 0; debug_index < 8; debug_index = debug_index + 1)
            debug_event_set_now[debug_index] = debug_event_valid[debug_index];

        if (debug_event_valid[DBG_ENGINE_ERROR]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_ENGINE_ERROR];
            debug_event_info_now = debug_event_info_candidate[DBG_ENGINE_ERROR];
        end else if (debug_event_valid[DBG_BRAM_FAULT]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_BRAM_FAULT];
            debug_event_info_now = debug_event_info_candidate[DBG_BRAM_FAULT];
        end else if (debug_event_valid[DBG_INVALID_CONFIG]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_INVALID_CONFIG];
            debug_event_info_now = debug_event_info_candidate[DBG_INVALID_CONFIG];
        end else if (debug_event_valid[DBG_RESULT_WRITE_FORBIDDEN]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_RESULT_WRITE_FORBIDDEN];
            debug_event_info_now = debug_event_info_candidate[DBG_RESULT_WRITE_FORBIDDEN];
        end else if (debug_event_valid[DBG_MEM_OWNERSHIP]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_MEM_OWNERSHIP];
            debug_event_info_now = debug_event_info_candidate[DBG_MEM_OWNERSHIP];
        end else if (debug_event_valid[DBG_CONFIG_WHILE_BUSY]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_CONFIG_WHILE_BUSY];
            debug_event_info_now = debug_event_info_candidate[DBG_CONFIG_WHILE_BUSY];
        end else if (debug_event_valid[DBG_BUS_UNMAPPED]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_BUS_UNMAPPED];
            debug_event_info_now = debug_event_info_candidate[DBG_BUS_UNMAPPED];
        end else if (debug_event_valid[DBG_BUS_ACCESS]) begin
            debug_event_addr_now = debug_event_addr_candidate[DBG_BUS_ACCESS];
            debug_event_info_now = debug_event_info_candidate[DBG_BUS_ACCESS];
        end
    end

     fir_tap_bram u_tap_bram (
         .clk_i(clk_i),
         .rst_i(engine_reset),
         .sample_base_word_i(active_sample_base_word),
         .coefficient_base_word_i(active_coefficient_base_word),
         .tap_count_i(tap_count_active_q[5:0]),
         .cfg_valid_o(bram_cfg_valid),
         .tap_req_i(prefetch_req),
         .tap_index_i(prefetch_addr),
         .tap_valid_o(),
         .sample_tap_o(),
         .coefficient_tap_o(),
         .range_fault_o(bram_range_fault),
         .accelerator_sample_re_i(accelerator_sample_re),
         .accelerator_sample_raddr_i(accelerator_sample_raddr),
         .accelerator_sample_rvalid_o(accelerator_sample_rvalid),
         .accelerator_sample_rdata_o(accelerator_sample_rdata),
         .accelerator_coefficient_re_i(accelerator_coefficient_re),
         .accelerator_coefficient_raddr_i(accelerator_coefficient_raddr),
         .accelerator_coefficient_rvalid_o(accelerator_coefficient_rvalid),
         .accelerator_coefficient_rdata_o(accelerator_coefficient_rdata),
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

    // Coefficients and one current sample are read through independent BRAM
    // ports. The sample window is completed from the pending sample plus the
    // accepted-input history before the selector sees it.
    assign prefetch_req = 1'b0;
    assign prefetch_addr = 5'd0;
    assign selector_in_valid = (exec_state_q == EXEC_SELECTOR_SUBMIT) &&
                               busy_q && pending_valid_q;
    assign selector_out_ready = 1'b1; // result is committed immediately when valid

    fir_arch_selector #(
        .LANES(LANES)
    ) u_arch_selector (
        .clk_i(clk_i),
        .rst_i(engine_reset),
        .in_valid_i(selector_in_valid),
        .in_ready_o(selector_in_ready),
        .arch_select_i(run_arch_q),
        .tap_count_i(tap_count_active_q[5:0]),
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
            sample_count_cfg_q <= 32'd0;
            tap_count_active_q <= 6'd0;
            sample_count_active_q <= 32'd0;
            coefficient_ptr_active_q <= COEFF_BASE;
            input_ptr_active_q <= INPUT_BASE;
            output_ptr_active_q <= OUTPUT_BASE;
            busy_q <= 1'b0;
            done_sticky_q <= 1'b0;
            error_sticky_q <= 1'b0;
            exec_state_q <= EXEC_IDLE;
            run_arch_q <= 2'd0;
            sample_vector_q <= '0;
            coefficient_vector_q <= '0;
            pending_sample_q <= 32'sd0;
            pending_valid_q <= 1'b0;
            coefficient_index_q <= 6'd0;
            sample_index_q <= 11'd0;
            for (history_index = 0; history_index < LANES-1; history_index = history_index + 1)
                history_q[history_index] <= 32'sd0;
            mem_write_rejected_q <= 1'b0;
            result_commit_q <= 1'b0;
            result_commit_addr_q <= OUTPUT_BASE;
            result_commit_data_q <= 32'sd0;
            cycles_total_q <= 32'd0;
            elapsed_cycles_work_q <= 32'd0;
            first_input_seen_q <= 1'b0;
            compute_elapsed_work_q <= 32'd0;
            result_count_q <= 32'd0;
            compute_cycles_q <= 32'd0;
            debug_status_q <= 8'd0;
            debug_addr_q <= 32'd0;
            debug_info_q <= 32'd0;
            internal_fault_q <= 1'b0;
            bram_fault_seen_q <= 1'b0;
         end else begin
            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;
             mem_write_rejected_q <= 1'b0;
             result_commit_q <= 1'b0;

             if (mem_write_rejected_now)
                 mem_write_rejected_q <= 1'b1;

              if (bram_range_fault)
                  bram_fault_seen_q <= 1'b1;

              if (internal_fault_event_now) begin
                  internal_fault_q <= 1'b1;
                  error_sticky_q <= 1'b1;
                end else if (invalid_config_event_now) begin
                    error_sticky_q <= 1'b1;
                    done_sticky_q <= 1'b0;
                    cycles_total_q <= 32'd0;
                    compute_cycles_q <= 32'd0;
                    result_count_q <= 32'd0;
               end else if (clear_error_request_now && !internal_fault_q)
                 error_sticky_q <= 1'b0;

             debug_status_q <= (debug_status_q & ~(clear_debug_request_now ? debug_clear_mask_now : 8'd0)) |
                               debug_event_set_now;
             if (debug_event_set_now != 8'd0) begin
                 debug_addr_q <= debug_event_addr_now;
                 debug_info_q <= debug_event_info_now;
             end

            if (clear_done_request_now)
                done_sticky_q <= 1'b0;

            if (busy_q)
                elapsed_cycles_work_q <= elapsed_cycles_work_q + 32'd1;

            if (busy_q && selector_in_valid && selector_in_ready)
                first_input_seen_q <= 1'b1;
            if (busy_q && first_input_seen_q)
                compute_elapsed_work_q <= compute_elapsed_work_q + 32'd1;
            if (busy_q && selector_out_valid && selector_out_ready && first_input_seen_q)
                compute_cycles_q <= compute_elapsed_work_q + 32'd1;

            // Architecture-independent serialized block controller.
            // An internal BRAM/engine fault terminates an active run on the
            // first observed fault edge; host/debug errors never take this
            // path and therefore cannot invalidate an otherwise valid run.
            if (internal_fault_event_now && busy_q) begin
                exec_state_q <= EXEC_IDLE;
                busy_q <= 1'b0;
                done_sticky_q <= 1'b0;
                cycles_total_q <= elapsed_cycles_work_q + 32'd1;
                pending_valid_q <= 1'b0;
                pending_sample_q <= 32'sd0;
                sample_vector_q <= '0;
            end else begin
                case (exec_state_q)
                    EXEC_IDLE: begin
                        // A START accepted below transitions to COEFF_REQUEST.
                    end

                    EXEC_COEFF_REQUEST: begin
                        // fir_tap_bram samples the independent coefficient read
                        // request at this edge; consume its registered response
                        // in the following state.
                        exec_state_q <= EXEC_COEFF_WAIT;
                    end

                    EXEC_COEFF_WAIT: begin
                        if (accelerator_coefficient_rvalid) begin
                            coefficient_vector_q[coefficient_index_q*32 +: 32] <=
                                accelerator_coefficient_rdata;
                            if ((coefficient_index_q + 6'd1) >= tap_count_active_q) begin
                                exec_state_q <= EXEC_SAMPLE_REQUEST;
                            end else begin
                                coefficient_index_q <= coefficient_index_q + 6'd1;
                                exec_state_q <= EXEC_COEFF_REQUEST;
                            end
                        end
                    end

                    EXEC_SAMPLE_REQUEST: begin
                        // Read exactly one new sample for the next output. Older
                        // samples come from history, never from future BRAM words.
                        exec_state_q <= EXEC_SAMPLE_WAIT;
                    end

                    EXEC_SAMPLE_WAIT: begin
                        if (accelerator_sample_rvalid) begin
                            pending_sample_q <= accelerator_sample_rdata;
                            pending_valid_q <= 1'b1;
                            sample_vector_q[0 +: 32] <= accelerator_sample_rdata;
                            for (history_index = 0; history_index < LANES-1; history_index = history_index + 1) begin
                                if ((tap_count_active_q > 6'd1) &&
                                    (history_index < (32'(tap_count_active_q) - 32'd1)))
                                    sample_vector_q[(history_index+1)*32 +: 32] <=
                                        history_q[history_index];
                                else
                                    sample_vector_q[(history_index+1)*32 +: 32] <= 32'sd0;
                            end
                            exec_state_q <= EXEC_SELECTOR_SUBMIT;
                        end
                    end

                    EXEC_SELECTOR_SUBMIT: begin
                        if (selector_in_valid && selector_in_ready) begin
                            pending_valid_q <= 1'b0;
                            if (tap_count_active_q > 6'd1) begin
                                for (history_index = LANES-2; history_index > 0; history_index = history_index - 1)
                                    history_q[history_index] <= history_q[history_index-1];
                                history_q[0] <= pending_sample_q;
                            end
                            exec_state_q <= EXEC_SELECTOR_WAIT;
                        end
                    end

                    EXEC_SELECTOR_WAIT: begin
                        if (selector_out_valid && selector_out_ready) begin
                            if (!bram_range_fault && !selector_out_error &&
                                (selector_active_arch == run_arch_q) && (selector_cycles != 16'd0)) begin
                                result_commit_q <= 1'b1;
                                result_commit_addr_q <= output_ptr_active_q +
                                                        ({21'd0, sample_index_q} << 2);
                                result_commit_data_q <= selector_result;
                                exec_state_q <= EXEC_COMMIT_WAIT;
                            end else begin
                                exec_state_q <= EXEC_IDLE;
                                busy_q <= 1'b0;
                                done_sticky_q <= 1'b0;
                                error_sticky_q <= 1'b1;
                                internal_fault_q <= 1'b1;
                                pending_valid_q <= 1'b0;
                            end
                        end
                    end

                    EXEC_COMMIT_WAIT: begin
                        // result_commit_q is the registered request presented
                        // to nexus32_accel_bus. Its high level on this edge is
                        // the physical result-memory commit event. RESET wins
                        // through the enclosing synchronous reset branch and the
                        // bus-side result_mem_we gate.
                        if (physical_result_commit_now) begin
                            result_count_q <= result_count_q + 32'd1;
                            if (({21'd0, sample_index_q} + 32'd1) >= sample_count_active_q) begin
                                exec_state_q <= EXEC_IDLE;
                                busy_q <= 1'b0;
                                done_sticky_q <= 1'b1;
                                cycles_total_q <= elapsed_cycles_work_q + 32'd1;
                            end else begin
                                sample_index_q <= sample_index_q + 11'd1;
                                exec_state_q <= EXEC_SAMPLE_REQUEST;
                            end
                        end
                    end

                    default: begin
                        exec_state_q <= EXEC_IDLE;
                        busy_q <= 1'b0;
                        error_sticky_q <= 1'b1;
                        pending_valid_q <= 1'b0;
                    end
                endcase
            end

            if (req_accept_now) begin
                rsp_valid_q <= 1'b1;
                rsp_rdata_q <= 32'd0;
                rsp_error_q <= 1'b0;

                if (req_addr_i[1:0] != 2'b00) begin
                    rsp_error_q <= 1'b1;
                end else if (req_write_i) begin
                    if (req_wstrb_i != 4'hf) begin
                        rsp_error_q <= 1'b1;
                    end else if (csr_bus_access_event_now) begin
                        rsp_error_q <= 1'b1;
                    end else if (busy_q) begin
                        if (busy_start_noop_now) begin
                            // V1.0: START while BUSY is a normal no-op.
                        end else begin
                            rsp_error_q <= 1'b1;
                        end
                    end else begin
                        case (req_addr_i)
                            REG_CTRL: begin
                                if (req_wdata_i[0] && !error_sticky_q && !invalid_config_event_now) begin
                                    busy_q <= 1'b1;
                                    exec_state_q <= EXEC_COEFF_REQUEST;
                                    coefficient_index_q <= 6'd0;
                                    sample_index_q <= 11'd0;
                                    run_arch_q <= req_wdata_i[3:2];
                                    tap_count_active_q <= tap_count_reg_q[5:0];
                                    sample_count_active_q <= sample_count_cfg_q;
                                    coefficient_ptr_active_q <= coefficient_ptr_q;
                                    input_ptr_active_q <= input_ptr_q;
                                    output_ptr_active_q <= output_ptr_q;
                                    sample_vector_q <= '0;
                                    coefficient_vector_q <= '0;
                                    pending_sample_q <= 32'sd0;
                                    pending_valid_q <= 1'b0;
                                    for (history_index = 0; history_index < LANES-1; history_index = history_index + 1)
                                        history_q[history_index] <= 32'sd0;
                                    done_sticky_q <= 1'b0;
                                    result_count_q <= 32'd0;
                                    cycles_total_q <= 32'd0;
                                    compute_cycles_q <= 32'd0;
                                    elapsed_cycles_work_q <= 32'd0;
                                    first_input_seen_q <= 1'b0;
                                    compute_elapsed_work_q <= 32'd0;
                                end
                            end
                            REG_STATUS: begin
                                // W1C state changes are handled by the
                                // clear_*_request_now paths above.
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
                            REG_SAMPLE_COUNT: begin
                                sample_count_cfg_q <= req_wdata_i;
                            end
                            REG_DBG_STATUS: begin
                                // Debug W1C state changes are handled by the
                                // clear_debug_request_now path above.
                            end
                            default: begin
                                rsp_error_q <= 1'b1;
                            end
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
                        REG_SAMPLE_COUNT:   rsp_rdata_q <= sample_count_cfg_q;
                        REG_COMPUTE_CYCLES: rsp_rdata_q <= compute_cycles_q;
                        REG_AUTO_CFG:       rsp_rdata_q <= 32'd0;
                        REG_AUTO_SELECTED:  rsp_rdata_q <= 32'd0;
                        REG_AUTO_MODEL_ID:  rsp_rdata_q <= 32'd0;
                        REG_DBG_STATUS:     rsp_rdata_q <= {24'd0, debug_status_q};
                        REG_DBG_ADDR:       rsp_rdata_q <= debug_addr_q;
                        REG_DBG_INFO:       rsp_rdata_q <= debug_info_q;
                        REG_RESULT_COUNT:   rsp_rdata_q <= result_count_q;
                        REG_CONTRACT_VERSION: rsp_rdata_q <= 32'd0;
                        REG_BUILD_ID:       rsp_rdata_q <= 32'd0;
                        default: rsp_error_q <= 1'b1;
                    endcase
                end
            end
        end
    end
endmodule
