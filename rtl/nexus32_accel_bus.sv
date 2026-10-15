`timescale 1ns/1ps
// NEXUS-32 milestone 6: one-master valid/ready bus adapter for the
// sequential FIR accelerator's memory and CSR window.
//
// Request contract:
// - A transfer is accepted at posedge when req_valid_i && req_ready_o.
// - While req_valid_i && !req_ready_o, the master must hold request fields.
// - Each accepted transfer produces exactly one one-cycle rsp_valid_o pulse.
// - There is no response backpressure; the master must observe every pulse.
// - All transfers are 32-bit word accesses. Misaligned and partial writes error.
//
// Supported map:
//   0x00020000..0x00020fff coefficient RAM (read/write)
//   0x00021000..0x00021fff sample A RAM (read/write)
//   0x00022000..0x00022fff result RAM (read-only to host; accelerator writes)
//   0x10005000..0x10005fff accelerator CSRs
// Other pages, including sample B at 0x00023000 in the planned map, return an
// error until their implementation is added. This is not yet the full SoC bus.
module nexus32_accel_bus (
    input  logic              clk_i,
    input  logic              rst_i,

    input  logic              req_valid_i,
    output logic              req_ready_o,
    input  logic              req_write_i,
    input  logic [31:0]       req_addr_i,
    input  logic [31:0]       req_wdata_i,
    input  logic [3:0]        req_wstrb_i,

    output logic              rsp_valid_o,
    output logic [31:0]       rsp_rdata_o,
    output logic              rsp_error_o,
    output logic              bus_fault_sticky_o,

    output logic              accelerator_busy_o,
    output logic              accelerator_done_o,
    output logic              accelerator_error_o
);
    localparam logic [19:0] PAGE_COEFF  = 20'h00020;
    localparam logic [19:0] PAGE_SAMPLE = 20'h00021;
    localparam logic [19:0] PAGE_RESULT = 20'h00022;
    localparam logic [19:0] PAGE_ACCEL  = 20'h10005;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_CSR_REQUEST,
        ST_CSR_WAIT,
        ST_MEMORY_WAIT,
        ST_RESPOND
    } state_t;

    typedef enum logic [1:0] {
        MEM_NONE,
        MEM_SAMPLE,
        MEM_COEFF,
        MEM_RESULT
    } memory_target_t;

    state_t state_q;
    memory_target_t memory_target_q;

    logic [11:0] csr_addr_q;
    logic csr_write_q;
    logic [31:0] csr_wdata_q;
    logic [3:0] csr_wstrb_q;

    logic [31:0] pending_rdata_q;
    logic pending_error_q;
    logic rsp_valid_q;
    logic [31:0] rsp_rdata_q;
    logic rsp_error_q;
    logic bus_fault_sticky_q;

    logic accept_now;
    logic page_coeff_now;
    logic page_sample_now;
    logic page_result_now;
    logic page_accel_now;

    logic host_sample_re;
    logic [9:0] host_sample_raddr;
    logic host_sample_rvalid;
    logic signed [31:0] host_sample_rdata;
    logic host_sample_we;
    logic [9:0] host_sample_waddr;
    logic signed [31:0] host_sample_wdata;

    logic host_coefficient_re;
    logic [9:0] host_coefficient_raddr;
    logic host_coefficient_rvalid;
    logic signed [31:0] host_coefficient_rdata;
    logic host_coefficient_we;
    logic [9:0] host_coefficient_waddr;
    logic signed [31:0] host_coefficient_wdata;

    logic csr_req_valid;
    logic csr_req_ready;
    logic csr_req_write;
    logic [11:0] csr_req_addr;
    logic [31:0] csr_req_wdata;
    logic [3:0] csr_req_wstrb;
    logic csr_rsp_valid;
    logic [31:0] csr_rsp_rdata;
    logic csr_rsp_error;

    logic bank_owned;
    logic mem_write_rejected;
    logic result_commit;
    logic [31:0] result_commit_addr;
    logic signed [31:0] result_commit_data;

    logic [31:0] result_mem [0:1023];
    logic result_read_en;
    logic result_read_valid_q;
    logic [31:0] result_read_data_q;
    logic result_addr_matches_commit;

    assign req_ready_o = (state_q == ST_IDLE);
    assign rsp_valid_o = rsp_valid_q;
    assign rsp_rdata_o = rsp_rdata_q;
    assign rsp_error_o = rsp_error_q;
    assign bus_fault_sticky_o = bus_fault_sticky_q;

    assign accept_now = req_valid_i && req_ready_o;
    assign page_coeff_now = (req_addr_i[31:12] == PAGE_COEFF);
    assign page_sample_now = (req_addr_i[31:12] == PAGE_SAMPLE);
    assign page_result_now = (req_addr_i[31:12] == PAGE_RESULT);
    assign page_accel_now = (req_addr_i[31:12] == PAGE_ACCEL);

    // Host RAM operations are driven only on the accepted request edge.
    // Writes during accelerator ownership deliberately reach the accelerator
    // shell's write-denial logic, but the bus reports an error to the master.
    always_comb begin
        host_sample_re = 1'b0;
        host_sample_raddr = req_addr_i[11:2];
        host_sample_we = 1'b0;
        host_sample_waddr = req_addr_i[11:2];
        host_sample_wdata = $signed(req_wdata_i);

        host_coefficient_re = 1'b0;
        host_coefficient_raddr = req_addr_i[11:2];
        host_coefficient_we = 1'b0;
        host_coefficient_waddr = req_addr_i[11:2];
        host_coefficient_wdata = $signed(req_wdata_i);

        if (accept_now && (req_addr_i[1:0] == 2'b00) && !req_write_i) begin
            if (page_sample_now)
                host_sample_re = 1'b1;
            else if (page_coeff_now)
                host_coefficient_re = 1'b1;
        end

        if (accept_now && (req_addr_i[1:0] == 2'b00) && req_write_i &&
            (req_wstrb_i == 4'hf)) begin
            if (page_sample_now)
                host_sample_we = 1'b1;
            else if (page_coeff_now)
                host_coefficient_we = 1'b1;
        end
    end

    assign result_read_en = accept_now && page_result_now && !req_write_i &&
                            (req_addr_i[1:0] == 2'b00);
    assign result_addr_matches_commit = result_commit &&
                                        (result_commit_addr[31:12] == PAGE_RESULT) &&
                                        (result_commit_addr[11:2] == req_addr_i[11:2]);

    // A registered result-memory port with write-through for a same-cycle
    // result commit. The host has read-only access to this region.
    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            result_read_valid_q <= 1'b0;
            result_read_data_q <= 32'd0;
        end else begin
            result_read_valid_q <= result_read_en;
            if (result_read_en) begin
                if (result_addr_matches_commit)
                    result_read_data_q <= result_commit_data;
                else
                    result_read_data_q <= result_mem[req_addr_i[11:2]];
            end
            if (result_commit && (result_commit_addr[31:12] == PAGE_RESULT) &&
                (result_commit_addr[1:0] == 2'b00)) begin
                result_mem[result_commit_addr[11:2]] <= result_commit_data;
            end
        end
    end

    assign csr_req_valid = (state_q == ST_CSR_REQUEST);
    assign csr_req_write = csr_write_q;
    assign csr_req_addr = csr_addr_q;
    assign csr_req_wdata = csr_wdata_q;
    assign csr_req_wstrb = csr_wstrb_q;

    fir_seq_accel u_accel (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .req_valid_i(csr_req_valid),
        .req_ready_o(csr_req_ready),
        .req_write_i(csr_req_write),
        .req_addr_i(csr_req_addr),
        .req_wdata_i(csr_req_wdata),
        .req_wstrb_i(csr_req_wstrb),
        .rsp_valid_o(csr_rsp_valid),
        .rsp_rdata_o(csr_rsp_rdata),
        .rsp_error_o(csr_rsp_error),
        .host_sample_re_i(host_sample_re),
        .host_sample_raddr_i(host_sample_raddr),
        .host_sample_rvalid_o(host_sample_rvalid),
        .host_sample_rdata_o(host_sample_rdata),
        .host_sample_we_i(host_sample_we),
        .host_sample_waddr_i(host_sample_waddr),
        .host_sample_wdata_i(host_sample_wdata),
        .host_coefficient_re_i(host_coefficient_re),
        .host_coefficient_raddr_i(host_coefficient_raddr),
        .host_coefficient_rvalid_o(host_coefficient_rvalid),
        .host_coefficient_rdata_o(host_coefficient_rdata),
        .host_coefficient_we_i(host_coefficient_we),
        .host_coefficient_waddr_i(host_coefficient_waddr),
        .host_coefficient_wdata_i(host_coefficient_wdata),
        .bank_owned_o(bank_owned),
        .mem_write_rejected_o(mem_write_rejected),
        .result_commit_o(result_commit),
        .result_commit_addr_o(result_commit_addr),
        .result_commit_data_o(result_commit_data),
        .busy_o(accelerator_busy_o),
        .done_sticky_o(accelerator_done_o),
        .error_sticky_o(accelerator_error_o)
    );

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            state_q <= ST_IDLE;
            memory_target_q <= MEM_NONE;
            csr_addr_q <= 12'd0;
            csr_write_q <= 1'b0;
            csr_wdata_q <= 32'd0;
            csr_wstrb_q <= 4'd0;
            pending_rdata_q <= 32'd0;
            pending_error_q <= 1'b0;
            rsp_valid_q <= 1'b0;
            rsp_rdata_q <= 32'd0;
            rsp_error_q <= 1'b0;
            bus_fault_sticky_q <= 1'b0;
        end else begin
            rsp_valid_q <= 1'b0;
            rsp_error_q <= 1'b0;

            case (state_q)
                ST_IDLE: begin
                    if (accept_now) begin
                        pending_rdata_q <= 32'd0;
                        pending_error_q <= 1'b0;
                        memory_target_q <= MEM_NONE;

                        if (req_addr_i[1:0] != 2'b00) begin
                            pending_error_q <= 1'b1;
                            state_q <= ST_RESPOND;
                        end else if (page_accel_now) begin
                            csr_addr_q <= req_addr_i[11:0];
                            csr_write_q <= req_write_i;
                            csr_wdata_q <= req_wdata_i;
                            csr_wstrb_q <= req_wstrb_i;
                            state_q <= ST_CSR_REQUEST;
                        end else if (page_sample_now || page_coeff_now) begin
                            if (req_write_i && (req_wstrb_i != 4'hf)) begin
                                pending_error_q <= 1'b1;
                                state_q <= ST_RESPOND;
                            end else if (req_write_i && bank_owned) begin
                                pending_error_q <= 1'b1;
                                state_q <= ST_RESPOND;
                            end else if (req_write_i) begin
                                state_q <= ST_RESPOND;
                            end else begin
                                if (page_sample_now)
                                    memory_target_q <= MEM_SAMPLE;
                                else
                                    memory_target_q <= MEM_COEFF;
                                state_q <= ST_MEMORY_WAIT;
                            end
                        end else if (page_result_now) begin
                            if (req_write_i) begin
                                pending_error_q <= 1'b1;
                                state_q <= ST_RESPOND;
                            end else begin
                                memory_target_q <= MEM_RESULT;
                                state_q <= ST_MEMORY_WAIT;
                            end
                        end else begin
                            pending_error_q <= 1'b1;
                            state_q <= ST_RESPOND;
                        end
                    end
                end

                ST_CSR_REQUEST: begin
                    if (csr_req_ready)
                        state_q <= ST_CSR_WAIT;
                end

                ST_CSR_WAIT: begin
                    if (csr_rsp_valid) begin
                        pending_rdata_q <= csr_rsp_rdata;
                        pending_error_q <= csr_rsp_error;
                        state_q <= ST_RESPOND;
                    end
                end

                ST_MEMORY_WAIT: begin
                    case (memory_target_q)
                        MEM_SAMPLE: begin
                            if (host_sample_rvalid) begin
                                pending_rdata_q <= host_sample_rdata;
                                state_q <= ST_RESPOND;
                            end
                        end
                        MEM_COEFF: begin
                            if (host_coefficient_rvalid) begin
                                pending_rdata_q <= host_coefficient_rdata;
                                state_q <= ST_RESPOND;
                            end
                        end
                        MEM_RESULT: begin
                            if (result_read_valid_q) begin
                                pending_rdata_q <= result_read_data_q;
                                state_q <= ST_RESPOND;
                            end
                        end
                        default: begin
                            pending_error_q <= 1'b1;
                            state_q <= ST_RESPOND;
                        end
                    endcase
                end

                ST_RESPOND: begin
                    rsp_valid_q <= 1'b1;
                    rsp_rdata_q <= pending_rdata_q;
                    rsp_error_q <= pending_error_q;
                    if (pending_error_q)
                        bus_fault_sticky_q <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: begin
                    pending_error_q <= 1'b1;
                    state_q <= ST_RESPOND;
                end
            endcase
        end
    end
endmodule
