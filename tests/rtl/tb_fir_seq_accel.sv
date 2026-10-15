`timescale 1ns/1ps
module tb_fir_seq_accel;
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

    logic sample_re = 1'b0;
    logic [9:0] sample_raddr = 10'd0;
    wire sample_rvalid;
    wire signed [31:0] sample_rdata;
    logic sample_we = 1'b0;
    logic [9:0] sample_waddr = 10'd0;
    logic signed [31:0] sample_wdata = 32'sd0;
    logic coefficient_re = 1'b0;
    logic [9:0] coefficient_raddr = 10'd0;
    wire coefficient_rvalid;
    wire signed [31:0] coefficient_rdata;
    logic coefficient_we = 1'b0;
    logic [9:0] coefficient_waddr = 10'd0;
    logic signed [31:0] coefficient_wdata = 32'sd0;

    wire bank_owned;
    wire mem_write_rejected;
    wire result_commit;
    wire [31:0] result_commit_addr;
    wire signed [31:0] result_commit_data;
    wire busy;
    wire done_sticky;
    wire error_sticky;

    integer commit_count = 0;
    integer i;
    logic transaction_error;
    logic [31:0] read_value;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit)
            commit_count <= commit_count + 1;
    end

    fir_seq_accel dut (
        .clk_i(clk),
        .rst_i(rst),
        .req_valid_i(req_valid),
        .req_ready_o(req_ready),
        .req_write_i(req_write),
        .req_addr_i(req_addr),
        .req_wdata_i(req_wdata),
        .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid),
        .rsp_rdata_o(rsp_rdata),
        .rsp_error_o(rsp_error),
        .host_sample_re_i(sample_re),
        .host_sample_raddr_i(sample_raddr),
        .host_sample_rvalid_o(sample_rvalid),
        .host_sample_rdata_o(sample_rdata),
        .host_sample_we_i(sample_we),
        .host_sample_waddr_i(sample_waddr),
        .host_sample_wdata_i(sample_wdata),
        .host_coefficient_re_i(coefficient_re),
        .host_coefficient_raddr_i(coefficient_raddr),
        .host_coefficient_rvalid_o(coefficient_rvalid),
        .host_coefficient_rdata_o(coefficient_rdata),
        .host_coefficient_we_i(coefficient_we),
        .host_coefficient_waddr_i(coefficient_waddr),
        .host_coefficient_wdata_i(coefficient_wdata),
        .bank_owned_o(bank_owned),
        .mem_write_rejected_o(mem_write_rejected),
        .result_commit_o(result_commit),
        .result_commit_addr_o(result_commit_addr),
        .result_commit_data_o(result_commit_data),
        .busy_o(busy),
        .done_sticky_o(done_sticky),
        .error_sticky_o(error_sticky)
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
            @(posedge clk); // request accepted on this edge
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 12'd0;
            req_wdata = 32'd0;
            #1;
            if (!rsp_valid) begin
                $display("FAIL: CSR write response missing at addr %03x", address);
                $fatal(1);
            end
            error_out = rsp_error;
            @(negedge clk); // allow response pulse to clear
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
            @(posedge clk); // request accepted on this edge
            @(negedge clk);
            req_valid = 1'b0;
            req_addr = 12'd0;
            #1;
            if (!rsp_valid) begin
                $display("FAIL: CSR read response missing at addr %03x", address);
                $fatal(1);
            end
            data_out = rsp_rdata;
            error_out = rsp_error;
            @(negedge clk);
        end
    endtask

    task automatic write_sample(input logic [9:0] word_address,
                                input logic signed [31:0] data);
        begin
            @(negedge clk);
            sample_we = 1'b1;
            sample_waddr = word_address;
            sample_wdata = data;
            @(negedge clk);
            sample_we = 1'b0;
        end
    endtask

    task automatic write_coefficient(input logic [9:0] word_address,
                                     input logic signed [31:0] data);
        begin
            @(negedge clk);
            coefficient_we = 1'b1;
            coefficient_waddr = word_address;
            coefficient_wdata = data;
            @(negedge clk);
            coefficient_we = 1'b0;
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // Prefill enough words for both the four-tap numerical test and the
        // later 32-tap ownership-lock test. Q16.16 value 1.0 = 0x00010000.
        for (i = 0; i < 32; i = i + 1) begin
            write_sample(i[9:0], 32'sh0001_0000);
            write_coefficient(i[9:0], 32'sh0001_0000);
        end

        csr_write(12'h008, 32'd4, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT config write rejected");
        csr_write(12'h00c, 32'h0002_0000, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: COEFF_PTR config write rejected");
        csr_write(12'h010, 32'h0002_1002, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: INPUT_PTR config write unexpectedly rejected");
        csr_write(12'h014, 32'h0002_2000, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: OUTPUT_PTR config write rejected");

        // A misaligned pointer must fail before the engine is launched.
        csr_write(12'h000, 32'd1, transaction_error);
        if (!transaction_error || busy) $fatal(1, "FAIL: invalid pointer was not rejected");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: invalid-start STATUS mismatch: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: STATUS error W1C rejected");

        // Correct input pointer and run four unity products: 4.0 in Q16.16.
        csr_write(12'h010, 32'h0002_1000, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: valid INPUT_PTR write rejected");
        csr_write(12'h000, 32'd1, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: valid START rejected");
        wait (result_commit === 1'b1);
        #1;
        if (result_commit_addr !== 32'h0002_2000)
            $fatal(1, "FAIL: result address mismatch %08x", result_commit_addr);
        if (result_commit_data !== 32'sh0004_0000)
            $fatal(1, "FAIL: four-tap result mismatch %08x", result_commit_data);
        wait (busy === 1'b0);
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[1] || read_value[2] || read_value[0])
            $fatal(1, "FAIL: successful completion STATUS mismatch: %08x", read_value);
        csr_read(12'h018, read_value, transaction_error);
        if (transaction_error || read_value == 0)
            $fatal(1, "FAIL: total cycles should be nonzero");
        csr_read(12'h01c, read_value, transaction_error);
        if (transaction_error || read_value != 1)
            $fatal(1, "FAIL: sample count should be one, got %08x", read_value);
        csr_read(12'h020, read_value, transaction_error);
        if (transaction_error || read_value != 4)
            $fatal(1, "FAIL: compute count should be four, got %08x", read_value);

        // Reset clears sticky safety faults but does not clear BRAM contents.
        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        csr_write(12'h008, 32'd32, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: 32-tap config write rejected");
        csr_write(12'h00c, 32'h0002_0000, transaction_error);
        csr_write(12'h010, 32'h0002_1000, transaction_error);
        csr_write(12'h014, 32'h0002_2000, transaction_error);
        csr_write(12'h000, 32'd1, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: 32-tap START rejected");
        wait (busy === 1'b1);

        // Try to alter a sample while accelerator owns the bank; write must be
        // blocked and this job's result must not be committed.
        @(negedge clk);
        sample_we = 1'b1;
        sample_waddr = 10'd7;
        sample_wdata = 32'sh7fff_ffff;
        wait (mem_write_rejected === 1'b1);
        @(negedge clk);
        sample_we = 1'b0;
        wait (busy === 1'b0);
        #1;
        if (commit_count != 1)
            $fatal(1, "FAIL: result committed after active-bank write attempt");
        if (!error_sticky)
            $fatal(1, "FAIL: bank write rejection did not set sticky ERROR");

        $display("PASS: NEXUS-32 accelerator CSR validation, execution, and ownership tests");
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: accelerator testbench timeout");
        $fatal(1);
    end
endmodule
