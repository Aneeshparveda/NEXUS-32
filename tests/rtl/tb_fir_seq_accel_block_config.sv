`timescale 1ns/1ps

// Red milestone for the Batch 3B block-configuration contract.  This bench
// intentionally exercises the old shell through its direct CSR and host-port
// interface.  It accumulates contract failures so one run reports the whole
// missing behavior set instead of stopping at the first assertion.
module tb_fir_seq_accel_block_config;
    localparam int LANES = 32;

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

    localparam logic [11:0] REG_CTRL           = 12'h000;
    localparam logic [11:0] REG_STATUS         = 12'h004;
    localparam logic [11:0] REG_TAP_COUNT      = 12'h008;
    localparam logic [11:0] REG_COEFF_PTR      = 12'h00c;
    localparam logic [11:0] REG_INPUT_PTR      = 12'h010;
    localparam logic [11:0] REG_OUTPUT_PTR     = 12'h014;
    localparam logic [11:0] REG_CYCLES_TOTAL   = 12'h018;
    localparam logic [11:0] REG_SAMPLE_COUNT   = 12'h01c;
    localparam logic [11:0] REG_COMPUTE_CYCLES = 12'h020;
    localparam logic [11:0] REG_DBG_STATUS     = 12'h030;
    localparam logic [11:0] REG_RESULT_COUNT   = 12'h03c;

    localparam logic [31:0] COEFF_BASE  = 32'h0002_0000;
    localparam logic [31:0] COEFF_LIMIT = 32'h0002_1000;
    localparam logic [31:0] SAMPLE_BASE = 32'h0002_1000;
    localparam logic [31:0] SAMPLE_LIMIT = 32'h0002_2000;
    localparam logic [31:0] RESULT_BASE = 32'h0002_2000;
    localparam logic [31:0] RESULT_LIMIT = 32'h0002_3000;
    localparam logic [31:0] DBG_INVALID_CONFIG = 32'h0000_0020;

    integer failures = 0;
    integer legacy_tap_read_count = 0;
    integer accelerator_sample_read_count = 0;
    integer accelerator_coefficient_read_count = 0;
    logic ownership_seen = 1'b0;
    integer i;
    integer poll;

    always #5 clk = ~clk;

    // These are the actual accelerator request paths in the current hierarchy:
    // the legacy paired request is driven by dut.prefetch_req, while the
    // independent Port-B inputs are on dut.u_tap_bram. Invalid configuration
    // must not assert any of them for one clock. Valid block starts use the
    // independent Port-B paths.
    always @(posedge clk) begin
        if (dut.prefetch_req === 1'b1)
            legacy_tap_read_count <= legacy_tap_read_count + 1;
        if (dut.u_tap_bram.accelerator_sample_re_i === 1'b1)
            accelerator_sample_read_count <= accelerator_sample_read_count + 1;
        if (dut.u_tap_bram.accelerator_coefficient_re_i === 1'b1)
            accelerator_coefficient_read_count <= accelerator_coefficient_read_count + 1;
        if (bank_owned === 1'b1)
            ownership_seen <= 1'b1;
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

    task automatic report_failure(input string requirement);
        begin
            failures = failures + 1;
            $display("FAIL: %s", requirement);
        end
    endtask

    task automatic expect_true(input logic condition, input string requirement);
        begin
            if (condition !== 1'b1)
                report_failure(requirement);
        end
    endtask

    task automatic expect_equal32(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string requirement
    );
        begin
            if (actual !== expected)
                report_failure($sformatf("%s (got %08x expected %08x)",
                                         requirement, actual, expected));
        end
    endtask

    task automatic expect_write_error(
        input logic [11:0] address,
        input logic [31:0] data,
        input logic expected_error,
        input string requirement
    );
        logic transaction_error;
        begin
            csr_write(address, data, transaction_error);
            if (transaction_error !== expected_error)
                report_failure($sformatf("%s (rsp_error=%b expected=%b)",
                                         requirement, transaction_error, expected_error));
        end
    endtask

    task automatic expect_read_value(
        input logic [11:0] address,
        input logic [31:0] expected,
        input string requirement
    );
        logic [31:0] actual;
        logic transaction_error;
        begin
            csr_read(address, actual, transaction_error);
            if (transaction_error)
                report_failure($sformatf("%s (read rsp_error=1)", requirement));
            else if (actual !== expected)
                report_failure($sformatf("%s (got %08x expected %08x)",
                                         requirement, actual, expected));
        end
    endtask

    task automatic csr_write(
        input logic [11:0] address,
        input logic [31:0] data,
        output logic error_out
    );
        begin
            error_out = 1'b1;
            @(negedge clk);
            while (req_ready !== 1'b1)
                @(negedge clk);
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
            req_wstrb = 4'hf;
            #1;
            if (rsp_valid !== 1'b1) begin
                report_failure($sformatf("CSR write response missing for %03x", address));
            end else begin
                error_out = rsp_error;
            end
            @(negedge clk);
        end
    endtask

    task automatic csr_read(
        input logic [11:0] address,
        output logic [31:0] data_out,
        output logic error_out
    );
        begin
            data_out = 32'hxxxx_xxxx;
            error_out = 1'b1;
            @(negedge clk);
            while (req_ready !== 1'b1)
                @(negedge clk);
            req_valid = 1'b1;
            req_write = 1'b0;
            req_addr = address;
            req_wdata = 32'd0;
            req_wstrb = 4'hf;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 12'd0;
            req_wdata = 32'd0;
            req_wstrb = 4'hf;
            #1;
            if (rsp_valid !== 1'b1) begin
                report_failure($sformatf("CSR read response missing for %03x", address));
            end else begin
                data_out = rsp_rdata;
                error_out = rsp_error;
            end
            @(negedge clk);
        end
    endtask

    task automatic hardware_reset;
        begin
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 12'd0;
            req_wdata = 32'd0;
            req_wstrb = 4'hf;
            sample_re = 1'b0;
            sample_we = 1'b0;
            coefficient_re = 1'b0;
            coefficient_we = 1'b0;
            host_event_set = 8'd0;
            host_event_addr = 32'd0;
            host_event_info = 32'd0;
            rst = 1'b1;
            repeat (3) @(negedge clk);
            rst = 1'b0;
            repeat (2) @(negedge clk);
            reset_read_monitors();
        end
    endtask

    task automatic reset_read_monitors;
        begin
            legacy_tap_read_count = 0;
            accelerator_sample_read_count = 0;
            accelerator_coefficient_read_count = 0;
            ownership_seen = 1'b0;
        end
    endtask

    task automatic soft_reset(input string case_name);
        logic transaction_error;
        begin
            csr_write(REG_CTRL, 32'd2, transaction_error);
            if (transaction_error)
                report_failure($sformatf("CTRL.RESET accepted while idle/busy, case %s", case_name));
            repeat (2) @(negedge clk);
            if (busy !== 1'b0)
                report_failure($sformatf("CTRL.RESET released BUSY, case %s", case_name));
            reset_read_monitors();
        end
    endtask

    task automatic write_sample(
        input logic [9:0] word_address,
        input logic signed [31:0] data
    );
        begin
            @(negedge clk);
            sample_we = 1'b1;
            sample_waddr = word_address;
            sample_wdata = data;
            @(negedge clk);
            sample_we = 1'b0;
        end
    endtask

    task automatic write_coefficient(
        input logic [9:0] word_address,
        input logic signed [31:0] data
    );
        begin
            @(negedge clk);
            coefficient_we = 1'b1;
            coefficient_waddr = word_address;
            coefficient_wdata = data;
            @(negedge clk);
            coefficient_we = 1'b0;
        end
    endtask

    task automatic program_config(
        input string case_name,
        input logic [31:0] tap_count,
        input logic [31:0] coefficient_ptr,
        input logic [31:0] sample_count,
        input logic [31:0] input_ptr,
        input logic [31:0] output_ptr
    );
        begin
            expect_write_error(REG_TAP_COUNT, tap_count, 1'b0,
                               $sformatf("idle TAP_COUNT write accepted, case %s", case_name));
            expect_write_error(REG_COEFF_PTR, coefficient_ptr, 1'b0,
                               $sformatf("idle COEFF_PTR write accepted, case %s", case_name));
            expect_write_error(REG_SAMPLE_COUNT, sample_count, 1'b0,
                               $sformatf("idle SAMPLE_COUNT write accepted, case %s", case_name));
            expect_read_value(REG_SAMPLE_COUNT, sample_count,
                              $sformatf("idle SAMPLE_COUNT readback, case %s", case_name));
            expect_write_error(REG_INPUT_PTR, input_ptr, 1'b0,
                               $sformatf("idle INPUT_PTR write accepted, case %s", case_name));
            expect_write_error(REG_OUTPUT_PTR, output_ptr, 1'b0,
                               $sformatf("idle OUTPUT_PTR write accepted, case %s", case_name));
        end
    endtask

    task automatic verify_no_invalid_access(input string case_name);
        begin
            if (busy !== 1'b0 || bank_owned !== 1'b0)
                report_failure($sformatf("invalid config acquired BUSY/bank ownership, case %s", case_name));
            if (legacy_tap_read_count != 0)
                report_failure($sformatf("invalid config issued legacy paired tap request dut.prefetch_req (%0d), case %s",
                                         legacy_tap_read_count, case_name));
            if (accelerator_sample_read_count != 0)
                report_failure($sformatf("invalid config issued independent sample read dut.u_tap_bram.accelerator_sample_re_i (%0d), case %s",
                                         accelerator_sample_read_count, case_name));
            if (accelerator_coefficient_read_count != 0)
                report_failure($sformatf("invalid config issued independent coefficient read dut.u_tap_bram.accelerator_coefficient_re_i (%0d), case %s",
                                         accelerator_coefficient_read_count, case_name));
            repeat (6) @(negedge clk);
            if (busy !== 1'b0 || bank_owned !== 1'b0 || ownership_seen === 1'b1)
                report_failure($sformatf("invalid config acquired bank ownership after rejection, case %s", case_name));
            if (legacy_tap_read_count != 0)
                report_failure($sformatf("invalid config accessed legacy paired tap Port-B path after rejection (%0d), case %s",
                                         legacy_tap_read_count, case_name));
            if (accelerator_sample_read_count != 0)
                report_failure($sformatf("invalid config accessed independent sample Port-B path after rejection (%0d), case %s",
                                         accelerator_sample_read_count, case_name));
            if (accelerator_coefficient_read_count != 0)
                report_failure($sformatf("invalid config accessed independent coefficient Port-B path after rejection (%0d), case %s",
                                         accelerator_coefficient_read_count, case_name));
        end
    endtask

    task automatic invalid_config_case(
        input string case_name,
        input logic [31:0] tap_count,
        input logic [31:0] coefficient_ptr,
        input logic [31:0] sample_count,
        input logic [31:0] input_ptr,
        input logic [31:0] output_ptr
    );
        logic transaction_error;
        begin
            hardware_reset();
            program_config(case_name, tap_count, coefficient_ptr, sample_count,
                           input_ptr, output_ptr);
            reset_read_monitors();

            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure($sformatf("well-formed invalid START returned rsp_error=1, case %s", case_name));
            expect_read_value(REG_STATUS, 32'h0000_0004,
                              $sformatf("invalid START STATUS BUSY=0 DONE=0 ERROR=1, case %s", case_name));
            begin : CHECK_INVALID_DEBUG
                logic [31:0] debug_value;
                logic debug_error;
                csr_read(REG_DBG_STATUS, debug_value, debug_error);
                if (debug_error)
                    report_failure($sformatf("invalid START DBG_STATUS read errored, case %s", case_name));
                else if ((debug_value & DBG_INVALID_CONFIG) == 0)
                    report_failure($sformatf("invalid START did not set DBG_STATUS.INVALID_CONFIG, case %s", case_name));
            end
            expect_read_value(REG_CYCLES_TOTAL, 32'd0,
                              $sformatf("invalid START CYCLES_TOTAL remains zero, case %s", case_name));
            expect_read_value(REG_COMPUTE_CYCLES, 32'd0,
                              $sformatf("invalid START COMPUTE_CYCLES remains zero, case %s", case_name));
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              $sformatf("invalid START RESULT_COUNT remains zero, case %s", case_name));
            verify_no_invalid_access(case_name);
        end
    endtask

    task automatic valid_start_case(
        input string case_name,
        input logic [31:0] tap_count,
        input logic [31:0] coefficient_ptr,
        input logic [31:0] sample_count,
        input logic [31:0] input_ptr,
        input logic [31:0] output_ptr
    );
        logic transaction_error;
        begin
            hardware_reset();
            program_config(case_name, tap_count, coefficient_ptr, sample_count,
                           input_ptr, output_ptr);
            reset_read_monitors();

            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure($sformatf("valid START returned rsp_error=1, case %s", case_name));
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                report_failure($sformatf("valid START did not acquire BUSY/bank ownership, case %s", case_name));
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              $sformatf("valid START clears RESULT_COUNT for configured M, case %s", case_name));
            // Coefficients are now read through the independent Port-B path,
            // one synchronous word at a time, before the first sample read.
            repeat (80) @(negedge clk);
            if (legacy_tap_read_count != 0)
                report_failure($sformatf("valid START unexpectedly issued legacy paired tap request dut.prefetch_req, case %s", case_name));
            if (accelerator_sample_read_count == 0)
                report_failure($sformatf("valid START did not issue independent sample Port-B request, case %s", case_name));
            if (accelerator_coefficient_read_count == 0)
                report_failure($sformatf("valid START did not issue independent coefficient Port-B request, case %s", case_name));
            soft_reset(case_name);
        end
    endtask

    task automatic sample_count_value_case(input integer sample_count_value);
        string case_name;
        logic transaction_error;
        begin
            case_name = $sformatf("SAMPLE_COUNT=%0d", sample_count_value);
            hardware_reset();
            expect_write_error(REG_SAMPLE_COUNT, sample_count_value, 1'b0,
                               $sformatf("idle-writable SAMPLE_COUNT value, case %s", case_name));
            expect_read_value(REG_SAMPLE_COUNT, sample_count_value,
                              $sformatf("SAMPLE_COUNT readback, case %s", case_name));
            expect_write_error(REG_TAP_COUNT, 32'd32, 1'b0,
                               $sformatf("TAP_COUNT setup for valid START, case %s", case_name));
            expect_write_error(REG_COEFF_PTR, COEFF_BASE, 1'b0,
                               $sformatf("COEFF_PTR setup for valid START, case %s", case_name));
            expect_write_error(REG_INPUT_PTR, SAMPLE_BASE, 1'b0,
                               $sformatf("INPUT_PTR setup for valid START, case %s", case_name));
            expect_write_error(REG_OUTPUT_PTR, RESULT_BASE, 1'b0,
                               $sformatf("OUTPUT_PTR setup for valid START, case %s", case_name));
            reset_read_monitors();
            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure($sformatf("valid START accepted configured M, case %s", case_name));
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                report_failure($sformatf("valid START ownership for configured M, case %s", case_name));
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              $sformatf("valid START clears result count, case %s", case_name));
            soft_reset(case_name);
        end
    endtask

    task automatic result_count_read_only_case;
        logic transaction_error;
        begin
            hardware_reset();
            expect_write_error(REG_SAMPLE_COUNT, 32'd4, 1'b0,
                               "RESULT_COUNT independence: SAMPLE_COUNT=4 idle write");
            expect_read_value(REG_SAMPLE_COUNT, 32'd4,
                              "RESULT_COUNT independence: SAMPLE_COUNT=4 readback");
            expect_write_error(REG_RESULT_COUNT, 32'h0000_0099, 1'b1,
                               "RESULT_COUNT is read-only while SAMPLE_COUNT is configured");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT remains independent and zero after rejected write");
            expect_write_error(REG_TAP_COUNT, 32'd1, 1'b0,
                               "RESULT_COUNT independence: TAP_COUNT setup");
            expect_write_error(REG_COEFF_PTR, COEFF_BASE, 1'b0,
                               "RESULT_COUNT independence: COEFF_PTR setup");
            expect_write_error(REG_INPUT_PTR, SAMPLE_BASE, 1'b0,
                               "RESULT_COUNT independence: INPUT_PTR setup");
            expect_write_error(REG_OUTPUT_PTR, RESULT_BASE, 1'b0,
                               "RESULT_COUNT independence: OUTPUT_PTR setup");
            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure("RESULT_COUNT independence: valid START rsp_error must be zero");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT independence: accepted START begins at zero");
            soft_reset("RESULT_COUNT read-only/independence");
        end
    endtask

    task automatic clear_result_count_on_start_case;
        logic transaction_error;
        logic done_seen;
        begin
            hardware_reset();
            write_sample(10'd0, 32'sh0001_0000);
            write_coefficient(10'd0, 32'sh0001_0000);
            program_config("result-count clear seed run", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE);
            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure("RESULT_COUNT clear: seed START returned rsp_error=1");
            wait_for_done("RESULT_COUNT clear: seed run", 200, done_seen);
            if (done_seen)
                expect_read_value(REG_RESULT_COUNT, 32'd1,
                                  "RESULT_COUNT clear: seed run committed one result");

            expect_write_error(REG_SAMPLE_COUNT, 32'd4, 1'b0,
                               "RESULT_COUNT clear: reconfigure M=4 while idle");
            expect_read_value(REG_SAMPLE_COUNT, 32'd4,
                              "RESULT_COUNT clear: M=4 readback before second START");
            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure("RESULT_COUNT clear: second valid START returned rsp_error=1");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT clear: valid START clears prior result count");
            soft_reset("RESULT_COUNT clear on valid START");
        end
    endtask

    task automatic busy_configuration_case;
        logic transaction_error;
        logic [31:0] status_value;
        logic status_error;
        logic [31:0] debug_before_busy_start;
        logic [31:0] debug_after_busy_start;
        logic debug_error;
        begin
            hardware_reset();
            program_config("BUSY configuration rejection", 32'd32, COEFF_BASE, 32'd1024,
                           SAMPLE_BASE, RESULT_BASE);
            reset_read_monitors();
            csr_write(REG_CTRL, 32'd1, transaction_error);
            if (transaction_error)
                report_failure("START before BUSY configuration tests returned rsp_error=1");
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                report_failure("BUSY configuration tests did not begin with active ownership");

            csr_read(REG_DBG_STATUS, debug_before_busy_start, debug_error);
            if (debug_error)
                report_failure("case BUSY configuration rejection: START while BUSY precondition DBG_STATUS read errored");
            expect_write_error(REG_CTRL, 32'd1, 1'b0,
                               "case BUSY configuration rejection: START while BUSY is a no-op with rsp_error=0");
            csr_read(REG_STATUS, status_value, status_error);
            if (status_error || status_value[0] !== 1'b1 || status_value[2] !== 1'b0)
                report_failure($sformatf("case BUSY configuration rejection: START while BUSY preserved operation/status (status=%08x)", status_value));
            csr_read(REG_DBG_STATUS, debug_after_busy_start, debug_error);
            if (debug_error || debug_after_busy_start !== debug_before_busy_start)
                report_failure($sformatf("case BUSY configuration rejection: START while BUSY changed debug events (before=%08x after=%08x)",
                                         debug_before_busy_start, debug_after_busy_start));

            expect_write_error(REG_TAP_COUNT, 32'd1, 1'b1,
                               "case BUSY configuration rejection: TAP_COUNT write while BUSY rejected");
            expect_read_value(REG_TAP_COUNT, 32'd32,
                              "case BUSY configuration rejection: TAP_COUNT unchanged after BUSY write rejection");
            expect_write_error(REG_COEFF_PTR, COEFF_BASE + 32'd4, 1'b1,
                               "case BUSY configuration rejection: COEFF_PTR write while BUSY rejected");
            expect_read_value(REG_COEFF_PTR, COEFF_BASE,
                              "case BUSY configuration rejection: COEFF_PTR unchanged after BUSY write rejection");
            expect_write_error(REG_SAMPLE_COUNT, 32'd4, 1'b1,
                               "case BUSY configuration rejection: SAMPLE_COUNT write while BUSY rejected");
            expect_read_value(REG_SAMPLE_COUNT, 32'd1024,
                              "case BUSY configuration rejection: SAMPLE_COUNT unchanged after BUSY write rejection");
            expect_write_error(REG_INPUT_PTR, SAMPLE_BASE + 32'd4, 1'b1,
                               "case BUSY configuration rejection: INPUT_PTR write while BUSY rejected");
            expect_read_value(REG_INPUT_PTR, SAMPLE_BASE,
                              "case BUSY configuration rejection: INPUT_PTR write while BUSY rejected");
            expect_write_error(REG_OUTPUT_PTR, RESULT_BASE + 32'd4, 1'b1,
                               "case BUSY configuration rejection: OUTPUT_PTR write while BUSY rejected");
            expect_read_value(REG_OUTPUT_PTR, RESULT_BASE,
                              "case BUSY configuration rejection: OUTPUT_PTR unchanged after BUSY write rejection");

            csr_read(REG_DBG_STATUS, status_value, status_error);
            if (status_error || (status_value & 32'h0000_0010) == 0)
                report_failure($sformatf("case BUSY configuration rejection: writes set DBG_STATUS.CONFIG_WHILE_BUSY (debug=%08x)", status_value));
            csr_read(REG_STATUS, status_value, status_error);
            if (status_error || status_value[2] !== 1'b0)
                report_failure($sformatf("case BUSY configuration rejection: writes did not preserve STATUS.ERROR=0 (status=%08x)", status_value));
            if (ownership_seen !== 1'b1)
                report_failure("case BUSY configuration rejection: writes released the original bank ownership");
            soft_reset("BUSY configuration rejection");
        end
    endtask

    task automatic wait_for_done(
        input string case_name,
        input integer max_polls,
        output logic done_seen
    );
        logic [31:0] status_value;
        logic status_error;
        begin : WAIT_DONE_LOOP
            done_seen = 1'b0;
            for (poll = 0; poll < max_polls; poll = poll + 1) begin
                csr_read(REG_STATUS, status_value, status_error);
                if (!status_error && status_value[1]) begin
                    done_seen = 1'b1;
                    disable WAIT_DONE_LOOP;
                end
            end
            if (!done_seen)
                report_failure($sformatf("run did not reach DONE within polling bound, case %s", case_name));
        end
    endtask

    initial begin
        // Initial reset is held long enough for every BRAM/controller state to
        // settle before the first direct CSR transaction.
        hardware_reset();

        // Idle-writable block lengths and immediate readback.  A 32-tap
        // configuration keeps the active window alive while RESULT_COUNT is
        // sampled immediately after START.
        sample_count_value_case(1);
        sample_count_value_case(2);
        sample_count_value_case(4);
        sample_count_value_case(1024);

        result_count_read_only_case();
        clear_result_count_on_start_case();

        // Semantic invalid M values are accepted as configuration and rejected
        // only by START, before ownership or any old Port-B prefetch request.
        invalid_config_case("invalid M=0", 32'd1, COEFF_BASE, 32'd0,
                            SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("invalid M=1025", 32'd1, COEFF_BASE, 32'd1025,
                            SAMPLE_BASE, RESULT_BASE);

        // Valid region-span boundaries.  M spans sample/result banks while T
        // spans the coefficient bank.
        valid_start_case("1024-word spans from all region bases", 32'd1, COEFF_BASE,
                         32'd1024, SAMPLE_BASE, RESULT_BASE);
        valid_start_case("one-word spans from final words, TAP_COUNT=1", 32'd1,
                         COEFF_LIMIT - 32'd4, 32'd1, SAMPLE_LIMIT - 32'd4,
                         RESULT_LIMIT - 32'd4);
        valid_start_case("full 32-word coefficient span at COEFF_BASE", 32'd32,
                         COEFF_BASE, 32'd1, SAMPLE_BASE, RESULT_BASE);

        // Two-word spans beginning at the final word are invalid in each
        // physical region and must be rejected before Port-B access.
        invalid_config_case("invalid two-word coefficient span from final word", 32'd2,
                            COEFF_LIMIT - 32'd4, 32'd1, SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("invalid two-word input span from final word", 32'd1,
                            COEFF_BASE, 32'd2, SAMPLE_LIMIT - 32'd4, RESULT_BASE);
        invalid_config_case("invalid two-word output span from final word", 32'd1,
                            COEFF_BASE, 32'd2, SAMPLE_BASE, RESULT_LIMIT - 32'd4);

        // Every pointer class is checked independently so one missing range
        // comparator cannot be masked by another invalid pointer.
        invalid_config_case("unaligned COEFF_PTR", 32'd1, COEFF_BASE + 32'd1,
                            32'd1, SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("unaligned INPUT_PTR", 32'd1, COEFF_BASE, 32'd1,
                            SAMPLE_BASE + 32'd1, RESULT_BASE);
        invalid_config_case("unaligned OUTPUT_PTR", 32'd1, COEFF_BASE, 32'd1,
                            SAMPLE_BASE, RESULT_BASE + 32'd1);
        invalid_config_case("COEFF_PTR below coefficient region", 32'd1,
                            COEFF_BASE - 32'd4, 32'd1, SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("INPUT_PTR below sample region", 32'd1, COEFF_BASE,
                            32'd1, SAMPLE_BASE - 32'd4, RESULT_BASE);
        invalid_config_case("OUTPUT_PTR below result region", 32'd1, COEFF_BASE,
                            32'd1, SAMPLE_BASE, RESULT_BASE - 32'd4);
        invalid_config_case("COEFF_PTR equal to COEFF_LIMIT", 32'd1, COEFF_LIMIT,
                            32'd1, SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("INPUT_PTR equal to SAMPLE_LIMIT", 32'd1, COEFF_BASE,
                            32'd1, SAMPLE_LIMIT, RESULT_BASE);
        invalid_config_case("OUTPUT_PTR equal to RESULT_LIMIT", 32'd1, COEFF_BASE,
                            32'd1, SAMPLE_BASE, RESULT_LIMIT);

        // Overflow cases use aligned high addresses whose widened end address
        // would exceed 32 bits.  The out-of-region value must not be allowed to
        // reach the accelerator Port-B interface or ownership state.
        invalid_config_case("32-bit coefficient pointer arithmetic overflow", 32'd2,
                            32'hffff_fffc, 32'd1, SAMPLE_BASE, RESULT_BASE);
        invalid_config_case("32-bit input pointer arithmetic overflow", 32'd1,
                            COEFF_BASE, 32'd2, 32'hffff_fffc, RESULT_BASE);
        invalid_config_case("32-bit output pointer arithmetic overflow", 32'd1,
                            COEFF_BASE, 32'd2, SAMPLE_BASE, 32'hffff_fffc);

        busy_configuration_case();

        $display("BLOCK-CONFIG red milestone complete: failures=%0d", failures);
        if (failures > 0)
            $fatal(1, "Batch 3B block-configuration contract failures=%0d", failures);
        $display("PASS: Batch 3B block-configuration contract");
        $finish;
    end

    initial begin
        #500000;
        report_failure("testbench timeout before accumulated-failure termination");
        $fatal(1, "Batch 3B block-configuration testbench timeout");
    end
endmodule
