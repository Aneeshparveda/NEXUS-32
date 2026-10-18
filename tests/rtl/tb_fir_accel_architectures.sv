`timescale 1ns/1ps
module tb_fir_accel_architectures #(
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

    logic sample_we = 1'b0;
    logic [9:0] sample_waddr = 10'd0;
    logic signed [31:0] sample_wdata = 32'sd0;
    logic coefficient_we = 1'b0;
    logic [9:0] coefficient_waddr = 10'd0;
    logic signed [31:0] coefficient_wdata = 32'sd0;
    logic [7:0] host_event_set = 8'd0;
    logic [31:0] host_event_addr = 32'd0;
    logic [31:0] host_event_info = 32'd0;

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
    logic signed [31:0] expected_1tap;
    logic signed [31:0] expected_lanes_tap;

    function automatic logic signed [31:0] compute_expected_fir(
        input logic [5:0] tap_count_in
    );
        logic signed [31:0] s, c;
        logic signed [63:0] p;
        logic signed [71:0] acc, shifted;
        integer idx;
        begin
            acc = 72'sd0;
            for (idx = 0; idx < 32; idx = idx + 1) begin
                if (idx < tap_count_in) begin
                    s = (idx % 2 == 0) ?
                        $signed(32'sh0001_0000 + (idx * 32'sh0000_1200)) :
                        $signed(-32'sh0000_8000 - (idx * 32'sh0000_0a00));
                    c = $signed(32'sh0000_6000 + (idx * 32'sh0000_0c00));
                    p = s * c;
                    acc = acc + $signed({{8{p[63]}}, p});
                end
            end
            shifted = acc >>> 16;
            if (shifted > 72'sd2147483647)
                compute_expected_fir = 32'sh7fff_ffff;
            else if (shifted < -72'sd2147483648)
                compute_expected_fir = 32'sh8000_0000;
            else
                compute_expected_fir = shifted[31:0];
        end
    endfunction

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit)
            commit_count <= commit_count + 1;
    end

    fir_seq_accel #(
        .LANES(LANES)
    ) dut (
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
        .host_event_set_i(host_event_set),
        .host_event_addr_i(host_event_addr),
        .host_event_info_i(host_event_info),
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

        // Prefill memory with deterministic, nonuniform samples and coefficients.
        for (i = 0; i < 32; i = i + 1) begin
            logic signed [31:0] s_val, c_val;
            s_val = (i % 2 == 0) ?
                    $signed(32'sh0001_0000 + (i * 32'sh0000_1200)) :
                    $signed(-32'sh0000_8000 - (i * 32'sh0000_0a00));
            c_val = $signed(32'sh0000_6000 + (i * 32'sh0000_0c00));
            write_taps(i[9:0], s_val, 1'b1);
            write_taps(i[9:0], c_val, 1'b0);
        end

        expected_1tap = compute_expected_fir(6'd1);
        expected_lanes_tap = compute_expected_fir(6'(LANES));

        // Base pointer setup
        csr_write(12'h00c, 32'h0002_0000, transaction_error); // COEFF_PTR
        if (transaction_error) $fatal(1, "FAIL: COEFF_PTR write rejected");
        csr_write(12'h010, 32'h0002_1000, transaction_error); // INPUT_PTR
        if (transaction_error) $fatal(1, "FAIL: INPUT_PTR write rejected");
        csr_write(12'h014, 32'h0002_2000, transaction_error); // OUTPUT_PTR
        if (transaction_error) $fatal(1, "FAIL: OUTPUT_PTR write rejected");
        // ------------------------------------------------------------------
        // Test 1: First valid tap (tap_count = 1) across all three architectures
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'd1, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT=1 configuration rejected");

        for (arch = 0; arch < 3; arch = arch + 1) begin
            // CTRL[3:2]: 0=SEQ, 1=PAR, 2=PIPE; bit 0 starts.
            csr_write(12'h000, ((arch << 2) | 1), transaction_error);
            if (transaction_error || !busy)
                $fatal(1, "FAIL: 1-tap arch %0d START rejected or did not become busy", arch);
            wait (result_commit === 1'b1);
            #1;
            if (result_commit_addr !== 32'h0002_2000)
                $fatal(1, "FAIL: 1-tap arch %0d result address mismatch %08x", arch, result_commit_addr);
            if (result_commit_data !== expected_1tap)
                $fatal(1, "FAIL: 1-tap arch %0d result mismatch %08x expected %08x", arch, result_commit_data, expected_1tap);
            wait (busy === 1'b0);

            csr_read(12'h004, read_value, transaction_error);
            if (transaction_error || !read_value[1] || read_value[2] || read_value[0])
                $fatal(1, "FAIL: 1-tap arch %0d status mismatch %08x", arch, read_value);
            csr_read(12'h018, total_cycles_value, transaction_error);
            if (transaction_error || total_cycles_value == 0)
                $fatal(1, "FAIL: 1-tap arch %0d total cycles invalid", arch);
            csr_read(12'h020, read_value, transaction_error);
            if (transaction_error || read_value == 0 || read_value >= total_cycles_value)
                $fatal(1, "FAIL: 1-tap arch %0d compute interval invalid compute=%0d total=%0d", arch, read_value, total_cycles_value);
            csr_read(12'h01c, read_value, transaction_error);
            if (transaction_error || read_value != (arch + 1))
                $fatal(1, "FAIL: sample count after 1-tap arch %0d was %0d", arch, read_value);
        end

        // ------------------------------------------------------------------
        // Test 2: Last valid tap (tap_count = LANES) across all three architectures
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'(LANES), transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT=LANES (%0d) configuration rejected", LANES);

        for (arch = 0; arch < 3; arch = arch + 1) begin
            csr_write(12'h000, ((arch << 2) | 1), transaction_error);
            if (transaction_error || !busy)
                $fatal(1, "FAIL: %0d-tap arch %0d START rejected or did not become busy", LANES, arch);
            wait (result_commit === 1'b1);
            #1;
            if (result_commit_addr !== 32'h0002_2000)
                $fatal(1, "FAIL: %0d-tap arch %0d result address mismatch %08x", LANES, arch, result_commit_addr);
            if (result_commit_data !== expected_lanes_tap)
                $fatal(1, "FAIL: %0d-tap arch %0d result mismatch %08x expected %08x",
                       LANES, arch, result_commit_data, expected_lanes_tap);
            wait (busy === 1'b0);

            csr_read(12'h004, read_value, transaction_error);
            if (transaction_error || !read_value[1] || read_value[2] || read_value[0])
                $fatal(1, "FAIL: %0d-tap arch %0d status mismatch %08x", LANES, arch, read_value);
            csr_read(12'h018, total_cycles_value, transaction_error);
            if (transaction_error || total_cycles_value == 0)
                $fatal(1, "FAIL: %0d-tap arch %0d total cycles invalid", LANES, arch);
            csr_read(12'h020, read_value, transaction_error);
            if (transaction_error || read_value == 0 || read_value >= total_cycles_value)
                $fatal(1, "FAIL: %0d-tap arch %0d compute interval invalid compute=%0d total=%0d", LANES, arch, read_value, total_cycles_value);
            csr_read(12'h01c, read_value, transaction_error);
            if (transaction_error || read_value != (3 + arch + 1))
                $fatal(1, "FAIL: sample count after %0d-tap arch %0d was %0d", LANES, arch, read_value);
        end

        // ------------------------------------------------------------------
        // Test 3: Invalid tap counts (0 and LANES + 1)
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'd0, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT=0 write rejected at CSR layer");
        csr_write(12'h000, 32'd1, transaction_error);
        if (transaction_error || busy)
            $fatal(1, "FAIL: START with TAP_COUNT=0 bus response/state mismatch");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: TAP_COUNT=0 did not set ERROR sticky: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: ERROR W1C rejected");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || read_value[2])
            $fatal(1, "FAIL: ERROR sticky not cleared after W1C: %08x", read_value);

        csr_write(12'h008, 32'(LANES + 1), transaction_error);
        if (transaction_error) $fatal(1, "FAIL: TAP_COUNT=LANES+1 write rejected at CSR layer");
        csr_write(12'h000, 32'd1, transaction_error);
        if (transaction_error || busy)
            $fatal(1, "FAIL: START with TAP_COUNT=%0d bus response/state mismatch for LANES=%0d", LANES + 1, LANES);
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: TAP_COUNT=LANES+1 did not set ERROR sticky: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: ERROR W1C rejected");

        // ------------------------------------------------------------------
        // Test 4: Invalid architecture selection (ARCH_SEL = 3)
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'(LANES), transaction_error);
        csr_write(12'h000, 32'h0000_000d, transaction_error);
        if (transaction_error || busy)
            $fatal(1, "FAIL: reserved/AUTO architecture selection bus response/state mismatch");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || !read_value[2] || read_value[0])
            $fatal(1, "FAIL: invalid architecture did not set ERROR: %08x", read_value);
        csr_write(12'h004, 32'h0000_0004, transaction_error);
        if (transaction_error) $fatal(1, "FAIL: ERROR W1C rejected");

        // ------------------------------------------------------------------
        // Test 5: Stalls / Active memory write rejection during busy
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'(LANES), transaction_error);
        csr_write(12'h000, 32'd1, transaction_error); // Sequential start
        if (transaction_error || !busy) $fatal(1, "FAIL: valid START rejected");
        @(negedge clk);
        sample_we = 1'b1;
        sample_waddr = 10'd0;
        sample_wdata = 32'sh7fff_ffff;
        wait (mem_write_rejected === 1'b1);
        @(negedge clk);
        sample_we = 1'b0;
        wait (busy === 1'b0);
        repeat (2) @(negedge clk);
        if (commit_count != 7)
            $fatal(1, "FAIL: ownership write suppressed result commit, count=%0d", commit_count);
        if (error_sticky)
            $fatal(1, "FAIL: bank write rejection set sticky ERROR");
        // Soft RESET to clear debug state
        csr_write(12'h000, 32'h0000_0002, transaction_error);
        if (transaction_error || busy) $fatal(1, "FAIL: soft RESET failed after ownership fault");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || read_value[2:0] != 3'b000)
            $fatal(1, "FAIL: soft RESET did not clear STATUS: %08x", read_value);

        // ------------------------------------------------------------------
        // Test 6: Soft reset recovery while busy
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'(LANES), transaction_error);
        csr_write(12'h000, 32'h0000_0009, transaction_error); // pipeline START
        if (transaction_error || !busy) $fatal(1, "FAIL: pipeline START for soft reset test rejected");
        repeat (3) @(negedge clk);
        csr_write(12'h000, 32'h0000_0002, transaction_error);
        if (transaction_error || busy)
            $fatal(1, "FAIL: soft RESET failed to abort the active operation");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || read_value[2:0] != 3'b000)
            $fatal(1, "FAIL: soft RESET did not clear status: %08x", read_value);

        // ------------------------------------------------------------------
        // Test 7: Hard reset recovery while busy
        // ------------------------------------------------------------------
        csr_write(12'h008, 32'(LANES), transaction_error);
        csr_write(12'h000, 32'h0000_0005, transaction_error); // parallel START
        if (transaction_error || !busy) $fatal(1, "FAIL: parallel START for hard reset test rejected");
        repeat (2) @(negedge clk);
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);
        if (busy) $fatal(1, "FAIL: hard RESET did not clear busy");
        csr_read(12'h004, read_value, transaction_error);
        if (transaction_error || read_value[2:0] != 3'b000)
            $fatal(1, "FAIL: hard RESET did not clear status: %08x", read_value);
        csr_read(12'h008, read_value, transaction_error);
        if (transaction_error || read_value != 32'd0)
            $fatal(1, "FAIL: hard RESET did not clear TAP_COUNT: %08x", read_value);

        repeat (2) @(negedge clk);
        if (commit_count != 7)
            $fatal(1, "FAIL: expected exactly seven commits before finish, got %0d", commit_count);
        $display("PASS: CSR-driven sequential/parallel/pipelined execution, common results, ARCH_SEL validation, stalls, and resets (LANES=%0d)", LANES);
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "FAIL: architecture integration test timeout");
    end
endmodule
