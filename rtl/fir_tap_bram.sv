`timescale 1ns/1ps
// NEXUS-32 synchronous sample/coefficient tap storage.
//
// Each memory is 1024 x 32 bits (4 KiB), matching the local word capacity of
// one sample bank and the coefficient bank. Addresses are WORD OFFSETS within
// their respective bank; the SoC/controller must validate full byte pointers
// and pass (pointer - bank_base) >> 2 here.
//
// Read contract:
// - tap_req_i sampled high at clock edge E produces tap_valid_o/data after E.
// - An independent accelerator sample/coefficient request sampled high at
//   clock edge E produces its corresponding valid/data response after E.
// - The sample and coefficient accelerator requests address separate physical
//   memories and may both be accepted on the same edge.
// - One accelerator read may be issued per physical memory per cycle. The
//   legacy paired tap request has priority over a same-cycle independent read
//   to either bank; the independent response valid is suppressed in that
//   overlap case. The existing shell never overlaps those interfaces.
// - The engine/controller must keep base/tap_count stable for the whole run.
// - No same-address read/write collision is permitted; such a request is
//   returned as zero and sets the sticky range_fault_o instead of relying on
//   FPGA-specific read-during-write behavior.
// - range_fault_o is sticky until reset. The controller must never start the
//   FIR engine when cfg_valid_o is low, and must treat a fault as failed work.
//
// This module does not arbitrate CPU/DMA ownership. The system controller must
// prevent writes to a bank while that bank is owned by an accelerator run.
module fir_tap_bram (
    input  logic                  clk_i,
    input  logic                  rst_i,

    input  logic [9:0]            sample_base_word_i,
    input  logic [9:0]            coefficient_base_word_i,
    input  logic [5:0]            tap_count_i,
    output logic                  cfg_valid_o,

    input  logic                  tap_req_i,
    input  logic [4:0]            tap_index_i,
    output logic                  tap_valid_o,
    output logic signed [31:0]    sample_tap_o,
    output logic signed [31:0]    coefficient_tap_o,
    output logic                  range_fault_o,

    // Accelerator Port B: one independently addressed synchronous read per
    // physical memory. Addresses are local 10-bit word indices (0..1023).
    input  logic                  accelerator_sample_re_i,
    input  logic [9:0]            accelerator_sample_raddr_i,
    output logic                  accelerator_sample_rvalid_o,
    output logic signed [31:0]    accelerator_sample_rdata_o,
    input  logic                  accelerator_coefficient_re_i,
    input  logic [9:0]            accelerator_coefficient_raddr_i,
    output logic                  accelerator_coefficient_rvalid_o,
    output logic signed [31:0]    accelerator_coefficient_rdata_o,

    // Host port A: one synchronous read OR one write per cycle.
    input  logic                  host_sample_re_i,
    input  logic [9:0]            host_sample_raddr_i,
    output logic                  host_sample_rvalid_o,
    output logic signed [31:0]    host_sample_rdata_o,
    input  logic                  sample_we_i,
    input  logic [9:0]            sample_waddr_i,
    input  logic signed [31:0]    sample_wdata_i,

    input  logic                  host_coefficient_re_i,
    input  logic [9:0]            host_coefficient_raddr_i,
    output logic                  host_coefficient_rvalid_o,
    output logic signed [31:0]    host_coefficient_rdata_o,
    input  logic                  coefficient_we_i,
    input  logic [9:0]            coefficient_waddr_i,
    input  logic signed [31:0]    coefficient_wdata_i
);
    logic signed [31:0] sample_mem [0:1023];
    logic signed [31:0] coefficient_mem [0:1023];

    logic [10:0] sample_end_word;
    logic [10:0] coefficient_end_word;
    logic [10:0] sample_read_word;
    logic [10:0] coefficient_read_word;
    logic tap_index_in_range;
    logic tap_sample_write_collision;
    logic tap_coefficient_write_collision;
    logic tap_read_ok;
    logic sample_accelerator_read_accept;
    logic coefficient_accelerator_read_accept;
    logic sample_accelerator_write_collision;
    logic coefficient_accelerator_write_collision;
    logic range_fault_q;
    logic tap_valid_q;
    logic accelerator_sample_rvalid_q;
    logic accelerator_coefficient_rvalid_q;
    logic host_sample_rvalid_q;
    logic signed [31:0] host_sample_rdata_q;
    logic host_coefficient_rvalid_q;
    logic signed [31:0] host_coefficient_rdata_q;
    logic signed [31:0] sample_tap_q;
    logic signed [31:0] coefficient_tap_q;
    logic signed [31:0] accelerator_sample_rdata_q;
    logic signed [31:0] accelerator_coefficient_rdata_q;

    assign sample_end_word = {1'b0, sample_base_word_i} + {5'd0, tap_count_i};
    assign coefficient_end_word = {1'b0, coefficient_base_word_i} + {5'd0, tap_count_i};
    assign sample_read_word = {1'b0, sample_base_word_i} + {6'd0, tap_index_i};
    assign coefficient_read_word = {1'b0, coefficient_base_word_i} + {6'd0, tap_index_i};

    // The legacy tap interface is a paired accelerator read. Give it priority
    // so its existing one-response-per-request behavior is unchanged.
    assign sample_accelerator_read_accept = accelerator_sample_re_i && !tap_req_i;
    assign coefficient_accelerator_read_accept = accelerator_coefficient_re_i && !tap_req_i;

    // end_word == 1024 is legal: the final addressed word is 1023.
    assign cfg_valid_o = (tap_count_i >= 6'd1) && (tap_count_i <= 6'd32) &&
                         (sample_end_word <= 11'd1024) &&
                         (coefficient_end_word <= 11'd1024);

    assign tap_index_in_range = ({1'b0, tap_index_i} < tap_count_i);
    assign tap_sample_write_collision = sample_we_i && tap_req_i &&
                                        !sample_read_word[10] &&
                                        (sample_waddr_i == sample_read_word[9:0]);
    assign tap_coefficient_write_collision = coefficient_we_i && tap_req_i &&
                                             !coefficient_read_word[10] &&
                                             (coefficient_waddr_i == coefficient_read_word[9:0]);
    assign sample_accelerator_write_collision = sample_we_i &&
                                                sample_accelerator_read_accept &&
                                                (sample_waddr_i == accelerator_sample_raddr_i);
    assign coefficient_accelerator_write_collision = coefficient_we_i &&
                                                     coefficient_accelerator_read_accept &&
                                                     (coefficient_waddr_i == accelerator_coefficient_raddr_i);
    assign tap_read_ok = cfg_valid_o && tap_index_in_range &&
                         !sample_read_word[10] && !coefficient_read_word[10] &&
                         !tap_sample_write_collision && !tap_coefficient_write_collision;

    assign tap_valid_o = tap_valid_q;
    assign sample_tap_o = sample_tap_q;
    assign coefficient_tap_o = coefficient_tap_q;
    assign range_fault_o = range_fault_q;
    assign accelerator_sample_rvalid_o = accelerator_sample_rvalid_q;
    assign accelerator_sample_rdata_o = accelerator_sample_rdata_q;
    assign accelerator_coefficient_rvalid_o = accelerator_coefficient_rvalid_q;
    assign accelerator_coefficient_rdata_o = accelerator_coefficient_rdata_q;
    assign host_sample_rvalid_o = host_sample_rvalid_q;
    assign host_sample_rdata_o = host_sample_rdata_q;
    assign host_coefficient_rvalid_o = host_coefficient_rvalid_q;
    assign host_coefficient_rdata_o = host_coefficient_rdata_q;

    // Port A is the host's synchronous read/write port. Port B is the
    // accelerator's synchronous read ports below. The legacy paired tap
    // request and the independent requests share one accelerator read port per
    // physical memory; the request-priority logic above prevents a same-bank
    // double-read. Memory contents are not reset so the arrays remain eligible
    // for BRAM inference.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            host_sample_rvalid_q <= 1'b0;
            host_sample_rdata_q <= 32'sd0;
        end else begin
            host_sample_rvalid_q <= host_sample_re_i;
            if (sample_we_i && host_sample_re_i) begin
                // The bus adapter must never issue read and write together.
                // Do not rely on device-specific read-during-write behavior.
                host_sample_rdata_q <= 32'sd0;
            end else if (sample_we_i) begin
                sample_mem[sample_waddr_i] <= sample_wdata_i;
            end else if (host_sample_re_i) begin
                host_sample_rdata_q <= sample_mem[host_sample_raddr_i];
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            host_coefficient_rvalid_q <= 1'b0;
            host_coefficient_rdata_q <= 32'sd0;
        end else begin
            host_coefficient_rvalid_q <= host_coefficient_re_i;
            if (coefficient_we_i && host_coefficient_re_i) begin
                host_coefficient_rdata_q <= 32'sd0;
            end else if (coefficient_we_i) begin
                coefficient_mem[coefficient_waddr_i] <= coefficient_wdata_i;
            end else if (host_coefficient_re_i) begin
                host_coefficient_rdata_q <= coefficient_mem[host_coefficient_raddr_i];
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            tap_valid_q <= 1'b0;
            sample_tap_q <= 32'sd0;
            coefficient_tap_q <= 32'sd0;
            accelerator_sample_rvalid_q <= 1'b0;
            accelerator_sample_rdata_q <= 32'sd0;
            accelerator_coefficient_rvalid_q <= 1'b0;
            accelerator_coefficient_rdata_q <= 32'sd0;
            range_fault_q <= 1'b0;
        end else begin
            tap_valid_q <= tap_req_i;
            accelerator_sample_rvalid_q <= sample_accelerator_read_accept;
            accelerator_coefficient_rvalid_q <= coefficient_accelerator_read_accept;

            if (tap_req_i) begin
                if (tap_read_ok) begin
                    sample_tap_q <= sample_mem[sample_read_word[9:0]];
                    coefficient_tap_q <= coefficient_mem[coefficient_read_word[9:0]];
                end else begin
                    // Respond rather than deadlocking a requester, but expose a
                    // sticky fault so the controller can discard the result.
                    sample_tap_q <= 32'sd0;
                    coefficient_tap_q <= 32'sd0;
                    range_fault_q <= 1'b1;
                end
            end

            if (sample_accelerator_read_accept) begin
                if (!sample_accelerator_write_collision) begin
                    accelerator_sample_rdata_q <= sample_mem[accelerator_sample_raddr_i];
                end else begin
                    // Do not rely on device-specific read-during-write
                    // behavior for the independent accelerator port.
                    accelerator_sample_rdata_q <= 32'sd0;
                    range_fault_q <= 1'b1;
                end
            end

            if (coefficient_accelerator_read_accept) begin
                if (!coefficient_accelerator_write_collision) begin
                    accelerator_coefficient_rdata_q <= coefficient_mem[accelerator_coefficient_raddr_i];
                end else begin
                    // Do not rely on device-specific read-during-write
                    // behavior for the independent accelerator port.
                    accelerator_coefficient_rdata_q <= 32'sd0;
                    range_fault_q <= 1'b1;
                end
            end
        end
    end
endmodule
