`timescale 1ns/1ps
module tb_fir_seq_accel #(
    parameter int LANES = 32
);
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
    logic [7:0] host_event_set = 8'd0;
    logic [31:0] host_event_addr = 32'd0;
    logic [31:0] host_event_info = 32'd0;

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
    logic [31:0] total_cycles_value;

    localparam logic [11:0] REG_CTRL = 12'h000;
    localparam logic [11:0] REG_STATUS = 12'h004;
    localparam logic [11:0] REG_DBG_STATUS = 12'h030;
    localparam logic [11:0] REG_DBG_ADDR = 12'h034;
    localparam logic [11:0] REG_DBG_INFO = 12'h038;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit)
            commit_count <= commit_count + 1;
    end

    fir_seq_accel #(
        .LANES(LANES)
    ) dut (
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
        .host_event_set_i(host_event_set),
        .host_event_addr_i(host_event_addr),
        .host_event_info_i(host_event_info),
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

    task automatic csr_write_with_memory_events(
        input logic [11:0] address,
        input logic [31:0] data,
        input logic [9:0] sample_word_address,
        input logic [9:0] coefficient_word_address,
        output logic error_out
    );
        begin
            @(negedge clk);
            while (!req_ready) @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b1;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 4'hf;
            sample_we = 1'b1;
            sample_waddr = sample_word_address;
            sample_wdata = 32'sh7fff_ffff;
            coefficient_we = 1'b1;
            coefficient_waddr = coefficient_word_address;
            coefficient_wdata = 32'sh7fff_ffff;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 12'd0;
            req_wdata = 32'd0;
            sample_we = 1'b0;
            coefficient_we = 1'b0;
            // host_event_set_i models a one-cycle bus-side event pulse.
            host_event_set = 8'd0;
            #1;
            if (!rsp_valid) begin
                $display("FAIL: simultaneous CSR/host response missing");
                $fatal(1);
            end
            error_out = rsp_error;
            @(negedge clk);
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
        csr_write(REG_CTRL, 32'd1, transaction_error);
        if (transaction_error || busy) $fatal(1, "FAIL: invalid pointer bus response/state");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: invalid-start STATUS mismatch: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: STATUS error W1C rejected");

        // Correct input pointer and run four unity products: 4.0 in Q16.16.
        csr_write(12'h010, 32'h0002_1000, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: valid INPUT_PTR write rejected");
        csr_write(REG_CTRL, 32'd1, transaction_error);
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
        total_cycles_value = read_value;
        csr_read(12'h01c, read_value, transaction_error);
        if (transaction_error || read_value != 1)
            $fatal(1, "FAIL: sample count should be one, got %08x", read_value);
        csr_read(12'h020, read_value, transaction_error);
        if (transaction_error || read_value == 0 || read_value >= total_cycles_value)
            $fatal(1, "FAIL: compute interval should be nonzero and shorter than total, compute=%0d total=%0d", read_value, total_cycles_value);

        // Reset clears sticky safety faults but does not clear BRAM contents.
        @(negedge clk);
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        csr_write(12'h008, 32'(LANES), transaction_error);
        if (transaction_error) $fatal(1, "FAIL: %0d-tap config write rejected", LANES);
        csr_write(12'h00c, 32'h0002_0000, transaction_error);
        csr_write(12'h010, 32'h0002_1000, transaction_error);
        csr_write(12'h014, 32'h0002_2000, transaction_error);
        csr_write(REG_CTRL, 32'd1, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: %0d-tap START rejected", LANES);
        wait (busy === 1'b1);

        // A simultaneous configuration write and two owned-bank writes must
        // preserve both event bits. MEM_OWNERSHIP has higher metadata priority
        // than CONFIG_WHILE_BUSY, and the lower coefficient address wins the
        // same-class address tie.
        csr_write_with_memory_events(12'h008, 32'(LANES), 10'd7, 10'd1, transaction_error);
        if (!transaction_error)
            $fatal(1, "FAIL: busy configuration write was not rejected");
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || (read_value & 32'h0000_0014) != 32'h0000_0014)
            $fatal(1, "FAIL: simultaneous debug bits missing: %08x", read_value);
        csr_read(REG_DBG_ADDR, read_value, transaction_error);
        if (transaction_error || read_value !== 32'h0002_0004)
            $fatal(1, "FAIL: debug address priority mismatch: %08x", read_value);
        csr_read(REG_DBG_INFO, read_value, transaction_error);
        if (transaction_error || read_value[2:0] !== 3'd2 || read_value[4:3] !== 2'd1 || read_value[6:5] !== 2'd0)
            $fatal(1, "FAIL: debug info priority mismatch: %08x", read_value);

        // Same-class metadata ties use the documented direction/master rules.
        // An external read at the same address must lose to the local write.
        host_event_set = 8'h04;
        host_event_addr = 32'h0002_0004;
        host_event_info = 32'h0000_0022; // MEM_OWNERSHIP, read, master 1
        csr_write_with_memory_events(12'h008, 32'(LANES), 10'd7, 10'd1, transaction_error);
        host_event_set = 8'd0;
        if (!transaction_error) $fatal(1, "FAIL: equal-address read/write tie was not rejected");
        csr_read(REG_DBG_INFO, read_value, transaction_error);
        if (transaction_error || read_value[4:3] !== 2'd1 || read_value[6:5] !== 2'd0)
            $fatal(1, "FAIL: write-over-read metadata tie mismatch: %08x", read_value);

        // With equal address and direction, the lower master ID wins.
        host_event_set = 8'h04;
        host_event_info = 32'h0000_002a; // MEM_OWNERSHIP, write, master 1
        csr_write_with_memory_events(12'h008, 32'(LANES), 10'd7, 10'd1, transaction_error);
        host_event_set = 8'd0;
        if (!transaction_error) $fatal(1, "FAIL: equal-address master tie was not rejected");
        csr_read(REG_DBG_INFO, read_value, transaction_error);
        if (transaction_error || read_value[4:3] !== 2'd1 || read_value[6:5] !== 2'd0)
            $fatal(1, "FAIL: lower-master metadata tie mismatch: %08x", read_value);

        // Try to alter a sample while accelerator owns the bank; write must be
        // blocked without invalidating this job's result.
        @(negedge clk);
        sample_we = 1'b1;
        sample_waddr = 10'd7;
        sample_wdata = 32'sh7fff_ffff;
        wait (mem_write_rejected === 1'b1);
        @(negedge clk);
        sample_we = 1'b0;
        wait (busy === 1'b0);
        repeat (2) @(negedge clk);
        if (commit_count != 2)
            $fatal(1, "FAIL: ownership write suppressed result commit count=%0d", commit_count);
        if (error_sticky)
            $fatal(1, "FAIL: bank write rejection set sticky ERROR");

        // RESET-only BRAM and engine events terminate an active run and
        // cannot be cleared by W1C.
        csr_write(REG_CTRL, 32'd1, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: active BRAM-fault run START failed");
        wait (busy === 1'b1);
        force dut.bram_range_fault = 1'b1;
        @(posedge clk);
        #1;
        release dut.bram_range_fault;
        wait (busy === 1'b0);
        repeat (2) @(negedge clk);
        csr_read(REG_STATUS, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0] || read_value[1])
            $fatal(1, "FAIL: active BRAM fault did not terminate run: %08x", read_value);
        if (commit_count != 2)
            $fatal(1, "FAIL: active BRAM fault produced a result commit: %0d", commit_count);
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || !(read_value & 32'h0000_0040))
            $fatal(1, "FAIL: BRAM_FAULT debug bit missing: %08x", read_value);
        csr_write(REG_DBG_STATUS, 32'h0000_0040, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: BRAM_FAULT W1C transaction failed");
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || !(read_value & 32'h0000_0040))
            $fatal(1, "FAIL: BRAM_FAULT cleared by W1C: %08x", read_value);
        csr_write(REG_STATUS, 32'h0000_0004, transaction_error);
        csr_read(REG_STATUS, read_value, transaction_error);
        if (transaction_error || !read_value[2])
            $fatal(1, "FAIL: RESET-only STATUS.ERROR cleared by W1C: %08x", read_value);
        csr_write(REG_CTRL, 32'd2, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: soft reset did not clear BRAM fault");

        force dut.selector_out_valid = 1'b1;
        force dut.selector_out_error = 1'b1;
        @(posedge clk);
        #1;
        release dut.selector_out_error;
        release dut.selector_out_valid;
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || !(read_value & 32'h0000_0080))
            $fatal(1, "FAIL: ENGINE_ERROR debug bit missing: %08x", read_value);
        csr_write(REG_DBG_STATUS, 32'h0000_0080, transaction_error);
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || !(read_value & 32'h0000_0080))
            $fatal(1, "FAIL: ENGINE_ERROR cleared by W1C: %08x", read_value);
        csr_write(REG_CTRL, 32'd2, transaction_error);
        csr_read(REG_DBG_STATUS, read_value, transaction_error);
        if (transaction_error || read_value != 0)
            $fatal(1, "FAIL: soft reset did not clear debug events: %08x", read_value);

        $display("PASS: NEXUS-32 accelerator CSR validation, execution, and ownership tests (LANES=%0d)", LANES);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: accelerator testbench timeout");
        $fatal(1);
    end
endmodule
