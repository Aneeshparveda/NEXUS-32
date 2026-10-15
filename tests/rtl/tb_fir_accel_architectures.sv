`timescale 1ns/1ps
module tb_fir_accel_architectures;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic req_valid = 1'b0;
    logic req_write = 1'b0;
    logic [11:0] req_addr = 12'd0;
    logic [31:0] req_wdata = 32'd0;
    logic [3:0] req_wstrb = 4'hf;
    wire req_ready;
    wire rsp_valid;
    wire [31:0] rsp_rdata;
    wire rsp_error;

    logic sample_we = 1'b0;
    logic [9:0] sample_waddr = 10'd0;
    logic signed [31:0] sample_wdata = 32'sd0;
    logic coefficient_we = 1'b0;
    logic [9:0] coefficient_waddr = 10'd0;
    logic signed [31:0] coefficient_wdata = 32'sd0;

    wire sample_rvalid;
    wire signed [31:0] sample_rdata;
    wire coefficient_rvalid;
    wire signed [31:0] coefficient_rdata;
    wire bank_owned;
    wire mem_write_rejected;
    wire result_commit;
    wire [31:0] result_commit_addr;
    wire signed [31:0] result_commit_data;
    wire busy;
    wire done_sticky;
    wire error_sticky;

    integer i;
    integer arch;
    integer commit_count = 0;
    logic transaction_error;
    logic [31:0] read_value;
    logic [31:0] total_cycles_value;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit)
            commit_count <= commit_count + 1;
    end

    fir_seq_accel dut (
        .clk_i(clk), .rst_i(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .req_write_i(req_write), .req_addr_i(req_addr),
        .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_rdata_o(rsp_rdata), .rsp_error_o(rsp_error),
        .host_sample_re_i(1'b0), .host_sample_raddr_i(10'd0),
        .host_sample_rvalid_o(sample_rvalid), .host_sample_rdata_o(sample_rdata),
        .host_sample_we_i(sample_we), .host_sample_waddr_i(sample_waddr),
        .host_sample_wdata_i(sample_wdata),
        .host_coefficient_re_i(1'b0), .host_coefficient_raddr_i(10'd0),
        .host_coefficient_rvalid_o(coefficient_rvalid),
        .host_coefficient_rdata_o(coefficient_rdata),
        .host_coefficient_we_i(coefficient_we),
        .host_coefficient_waddr_i(coefficient_waddr),
        .host_coefficient_wdata_i(coefficient_wdata),
        .bank_owned_o(bank_owned), .mem_write_rejected_o(mem_write_rejected),
        .result_commit_o(result_commit), .result_commit_addr_o(result_commit_addr),
        .result_commit_data_o(result_commit_data), .busy_o(busy),
        .done_sticky_o(done_sticky), .error_sticky_o(error_sticky)
    );

    task automatic csr_write(input logic [11:0] address,
                             input logic [31:0] data,
                             output logic error_out);
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 4'hf;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 12'd0;
            req_wdata = 32'd0;
            #1;
            if (!rsp_valid)
                $fatal(1, "FAIL: missing CSR write response addr=%03x data=%08x", address, data);
            error_out = rsp_error;
            @(negedge clk);
        end
    endtask

    task automatic csr_read(input logic [11:0] address,
                            output logic [31:0] data_out,
                            output logic error_out);
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr = address;
            req_wdata = 32'd0;
            req_wstrb = 4'hf;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 12'd0;
            #1;
            if (!rsp_valid)
                $fatal(1, "FAIL: missing CSR read response addr=%03x", address);
            data_out = rsp_rdata;
            error_out = rsp_error;
            @(negedge clk);
        end
    endtask

    task automatic write_taps(input logic [9:0] address,
                              input logic signed [31:0] data,
                              input logic is_sample);
        begin
            @(negedge clk);
            if (is_sample) begin
                sample_we = 1'b1;
                sample_waddr = address;
                sample_wdata = data;
            end else begin
                coefficient_we = 1'b1;
                coefficient_waddr = address;
                coefficient_wdata = data;
            end
            @(negedge clk);
            sample_we = 1'b0;
            coefficient_we = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Unity samples and coefficients produce exactly 4.0 for four taps.
        for (i = 0; i < 32; i = i + 1) begin
            write_taps(i[9:0], 32'sh0001_0000, 1'b1);
            write_taps(i[9:0], 32'sh0001_0000, 1'b0);
        end
        csr_write(12'h008, 32'd4, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT configuration rejected");

        for (arch = 0; arch < 3; arch = arch + 1) begin
            // CTRL[3:2]: 0=SEQ, 1=PAR, 2=PIPE; bit 0 starts.
            csr_write(12'h000, ((arch << 2) | 1), transaction_error);
            if (transaction_error || !busy)
                $fatal(1, "FAIL: architecture %0d START rejected or did not become busy", arch);
            wait (result_commit === 1'b1);
            #1;
            if (result_commit_addr !== 32'h0002_2000)
                $fatal(1, "FAIL: arch %0d result address mismatch %08x", arch, result_commit_addr);
            if (result_commit_data !== 32'sh0004_0000)
                $fatal(1, "FAIL: arch %0d result mismatch %08x expected 00040000", arch, result_commit_data);
            wait (busy === 1'b0);

            csr_read(12'h004, read_value, transaction_error);
            if (transaction_error || !read_value[1] || read_value[2] || read_value[0])
                $fatal(1, "FAIL: arch %0d status mismatch %08x", arch, read_value);
            csr_read(12'h018, total_cycles_value, transaction_error);
            if (transaction_error || total_cycles_value == 0)
                $fatal(1, "FAIL: arch %0d total cycles invalid", arch);
            csr_read(12'h020, read_value, transaction_error);
            if (transaction_error || read_value == 0 || read_value >= total_cycles_value)
                $fatal(1, "FAIL: arch %0d compute interval invalid compute=%0d total=%0d", arch, read_value, total_cycles_value);
            csr_read(12'h01c, read_value, transaction_error);
            if (transaction_error || read_value != (arch + 1))
                $fatal(1, "FAIL: sample count after arch %0d was %0d", arch, read_value);
        end

        // ARCH_SEL=3 is not implemented as AUTO in this build; reject it.
        csr_write(12'h000, 32'h0000_000d, transaction_error);
        if (!transaction_error || busy)
            $fatal(1, "FAIL: reserved/AUTO architecture selection was not rejected");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: invalid architecture did not set ERROR: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: ERROR W1C rejected");

        // Soft RESET is allowed while busy and takes priority over START.
        csr_write(12'h008, 32'd32, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: 32-tap configuration rejected");
        csr_write(12'h000, 32'h0000_0009, transaction_error); // pipeline START
        if (transaction_error || !busy) $fatal(1, "FAIL: pipeline START for reset test rejected");
        repeat (3) @(negedge clk);
        csr_write(12'h000, 32'h0000_0002, transaction_error);
        if (transaction_error || busy)
            $fatal(1, "FAIL: soft RESET failed to abort the active operation");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || read_value[2:0] != 3'b000)
            $fatal(1, "FAIL: soft RESET did not clear status: %08x", read_value);

        repeat (2) @(negedge clk);
        if (commit_count != 3)
            $fatal(1, "FAIL: expected exactly three commits before reset, got %0d", commit_count);
        $display("PASS: CSR-driven sequential/parallel/pipelined execution, common results, ARCH_SEL validation, and soft reset");
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "FAIL: architecture integration test timeout");
    end
endmodule
