`timescale 1ns/1ps
// NEXUS-32 common one-outstanding FIR architecture selector.
// ARCH 0=sequential, 1=parallel, 2=pipelined, 3=invalid.
//
// This wrapper deliberately serializes transactions across all architectures
// so that a runtime architecture change can never reorder responses. The
// underlying pipelined engine retains 1/cycle throughput when used directly;
// throughput through this first selector shell is limited to one outstanding
// request and is not a performance result.
module fir_arch_selector (
    input  logic                    clk_i,
    input  logic                    rst_i,
    input  logic                    in_valid_i,
    output logic                    in_ready_o,
    input  logic [1:0]              arch_select_i,
    input  logic [5:0]              tap_count_i,
    input  logic [1023:0]           sample_vector_i,
    input  logic [1023:0]           coefficient_vector_i,
    output logic                    out_valid_o,
    input  logic                    out_ready_i,
    output logic signed [31:0]      out_result_o,
    output logic                    out_error_o,
    output logic [15:0]             cycles_o,
    output logic [1:0]              active_arch_o
);
    localparam logic [1:0] ARCH_SEQ  = 2'd0;
    localparam logic [1:0] ARCH_PAR  = 2'd1;
    localparam logic [1:0] ARCH_PIPE = 2'd2;

    logic active_q;
    logic [1:0] active_arch_q;
    logic local_response_q;
    logic [1023:0] sample_vector_q;
    logic [1023:0] coefficient_vector_q;

    logic seq_start;
    logic seq_tap_req;
    logic [4:0] seq_tap_addr;
    logic signed [31:0] seq_sample_tap;
    logic signed [31:0] seq_coefficient_tap;
    logic seq_busy, seq_done, seq_error;
    logic signed [31:0] seq_result;
    logic [15:0] seq_cycles;
    logic seq_response_valid_q;
    logic seq_response_error_q;
    logic signed [31:0] seq_response_result_q;
    logic [15:0] seq_response_cycles_q;

    logic par_in_valid, par_in_ready;
    logic par_out_valid, par_out_ready, par_error;
    logic signed [31:0] par_result;
    logic [15:0] par_cycles;

    logic pipe_in_valid, pipe_in_ready;
    logic pipe_out_valid, pipe_out_ready, pipe_error;
    logic signed [31:0] pipe_result;
    logic [15:0] pipe_cycles;

    logic invalid_request;

    assign invalid_request = (tap_count_i == 6'd0) ||
                             (tap_count_i > 6'd32) ||
                             (arch_select_i == 2'd3);

    // Do not accept another request until the prior response is consumed.
    // Respect the selected engine's ready indication even though this shell
    // only allows one request in flight.
    always_comb begin
        in_ready_o = 1'b0;
        if (!active_q) begin
            case (arch_select_i)
                ARCH_SEQ:  in_ready_o = !seq_busy;
                ARCH_PAR:  in_ready_o = par_in_ready;
                ARCH_PIPE: in_ready_o = pipe_in_ready;
                default:   in_ready_o = 1'b1; // accepted as a local error response
            endcase
        end
    end

    assign seq_start = in_valid_i && in_ready_o && !invalid_request &&
                       (arch_select_i == ARCH_SEQ);
    assign par_in_valid = in_valid_i && in_ready_o && !invalid_request &&
                          (arch_select_i == ARCH_PAR);
    assign pipe_in_valid = in_valid_i && in_ready_o && !invalid_request &&
                           (arch_select_i == ARCH_PIPE);

    // A captured full vector is the sequential engine's zero-wait ordered tap
    // source. Vector registers are written on the same edge that accepts start;
    // the engine issues its first tap request in the following cycle.
    assign seq_sample_tap = $signed(sample_vector_q[seq_tap_addr*32 +: 32]);
    assign seq_coefficient_tap = $signed(coefficient_vector_q[seq_tap_addr*32 +: 32]);

    fir_seq_engine u_seq_engine (
        .clk_i(clk_i), .rst_i(rst_i), .start_i(seq_start),
        .tap_count_i(tap_count_i), .tap_req_o(seq_tap_req),
        .tap_addr_o(seq_tap_addr), .tap_valid_i(seq_tap_req),
        .sample_tap_i(seq_sample_tap), .coefficient_tap_i(seq_coefficient_tap),
        .busy_o(seq_busy), .done_o(seq_done), .error_o(seq_error),
        .result_o(seq_result), .cycles_o(seq_cycles)
    );

    fir_parallel_engine u_parallel_engine (
        .clk_i(clk_i), .rst_i(rst_i),
        .in_valid_i(par_in_valid), .in_ready_o(par_in_ready),
        .tap_count_i(tap_count_i), .sample_vector_i(sample_vector_i),
        .coefficient_vector_i(coefficient_vector_i),
        .out_valid_o(par_out_valid), .out_ready_i(par_out_ready),
        .out_result_o(par_result), .error_o(par_error), .cycles_o(par_cycles)
    );

    fir_pipelined_engine u_pipelined_engine (
        .clk_i(clk_i), .rst_i(rst_i),
        .in_valid_i(pipe_in_valid), .in_ready_o(pipe_in_ready),
        .tap_count_i(tap_count_i), .sample_vector_i(sample_vector_i),
        .coefficient_vector_i(coefficient_vector_i),
        .out_valid_o(pipe_out_valid), .out_ready_i(pipe_out_ready),
        .out_result_o(pipe_result), .out_error_o(pipe_error), .cycles_o(pipe_cycles)
    );

    // Each non-sequential engine is held stalled unless it owns the active
    // transaction. Its output registers therefore cannot be consumed by a
    // different architecture's response path.
    assign par_out_ready = active_q && !local_response_q &&
                           (active_arch_q == ARCH_PAR) && out_ready_i;
    assign pipe_out_ready = active_q && !local_response_q &&
                            (active_arch_q == ARCH_PIPE) && out_ready_i;

    assign active_arch_o = active_arch_q;

    always_comb begin
        out_valid_o  = 1'b0;
        out_result_o = 32'sd0;
        out_error_o  = 1'b0;
        cycles_o     = 16'd0;

        if (active_q) begin
            if (local_response_q) begin
                out_valid_o  = 1'b1;
                out_result_o = 32'sd0;
                out_error_o  = 1'b1;
                cycles_o     = 16'd0;
            end else begin
                case (active_arch_q)
                    ARCH_SEQ: begin
                        out_valid_o  = seq_response_valid_q;
                        out_result_o = seq_response_result_q;
                        out_error_o  = seq_response_error_q;
                        cycles_o     = seq_response_cycles_q;
                    end
                    ARCH_PAR: begin
                        out_valid_o  = par_out_valid;
                        out_result_o = par_result;
                        out_error_o  = par_error;
                        cycles_o     = par_cycles;
                    end
                    ARCH_PIPE: begin
                        out_valid_o  = pipe_out_valid;
                        out_result_o = pipe_result;
                        out_error_o  = pipe_error;
                        cycles_o     = pipe_cycles;
                    end
                    default: begin
                        out_valid_o  = 1'b1;
                        out_result_o = 32'sd0;
                        out_error_o  = 1'b1;
                        cycles_o     = 16'd0;
                    end
                endcase
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            active_q               <= 1'b0;
            active_arch_q          <= ARCH_SEQ;
            local_response_q       <= 1'b0;
            sample_vector_q        <= '0;
            coefficient_vector_q   <= '0;
            seq_response_valid_q   <= 1'b0;
            seq_response_error_q   <= 1'b0;
            seq_response_result_q  <= 32'sd0;
            seq_response_cycles_q  <= 16'd0;
        end else begin
            if (!active_q && in_valid_i && in_ready_o) begin
                active_q               <= 1'b1;
                active_arch_q          <= arch_select_i;
                seq_response_valid_q   <= 1'b0;
                seq_response_error_q   <= 1'b0;
                sample_vector_q        <= sample_vector_i;
                coefficient_vector_q   <= coefficient_vector_i;
                if (invalid_request)
                    local_response_q <= 1'b1;
                else
                    local_response_q <= 1'b0;
            end else if (active_q) begin
                if (local_response_q) begin
                    if (out_ready_i) begin
                        active_q         <= 1'b0;
                        local_response_q <= 1'b0;
                    end
                end else begin
                    case (active_arch_q)
                        ARCH_SEQ: begin
                            if ((seq_done || seq_error) && !seq_response_valid_q) begin
                                seq_response_valid_q  <= 1'b1;
                                seq_response_error_q  <= seq_error;
                                seq_response_result_q <= seq_error ? 32'sd0 : seq_result;
                                seq_response_cycles_q <= seq_cycles;
                            end else if (seq_response_valid_q && out_ready_i) begin
                                active_q             <= 1'b0;
                                seq_response_valid_q <= 1'b0;
                            end
                        end
                        ARCH_PAR: begin
                            if (par_out_valid && out_ready_i)
                                active_q <= 1'b0;
                        end
                        ARCH_PIPE: begin
                            if (pipe_out_valid && out_ready_i)
                                active_q <= 1'b0;
                        end
                        default: begin
                            if (out_ready_i) begin
                                active_q         <= 1'b0;
                                local_response_q <= 1'b0;
                            end
                        end
                    endcase
                end
            end
        end
    end
endmodule
