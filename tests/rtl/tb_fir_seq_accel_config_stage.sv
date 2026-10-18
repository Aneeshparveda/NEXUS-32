`timescale 1ns/1ps

// Batch 3B-2 configuration/validation stage test.  This bench intentionally
// stops at START acceptance or preflight rejection; it does not assert block
// traversal, result completion, history, or run-level timing semantics.
module tb_fir_seq_accel_config_stage;
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

    localparam logic [11:0] REG_CTRL            = 12'h000;
    localparam logic [11:0] REG_STATUS          = 12'h004;
    localparam logic [11:0] REG_TAP_COUNT       = 12'h008;
    localparam logic [11:0] REG_COEFF_PTR       = 12'h00c;
    localparam logic [11:0] REG_INPUT_PTR       = 12'h010;
    localparam logic [11:0] REG_OUTPUT_PTR      = 12'h014;
    localparam logic [11:0] REG_CYCLES_TOTAL    = 12'h018;
    localparam logic [11:0] REG_SAMPLE_COUNT    = 12'h01c;
    localparam logic [11:0] REG_COMPUTE_CYCLES  = 12'h020;
    localparam logic [11:0] REG_DBG_STATUS      = 12'h030;
    localparam logic [11:0] REG_RESULT_COUNT    = 12'h03c;

    localparam logic [31:0] COEFF_BASE   = 32'h0002_0000;
    localparam logic [31:0] COEFF_LIMIT  = 32'h0002_1000;
    localparam logic [31:0] SAMPLE_BASE  = 32'h0002_1000;
    localparam logic [31:0] SAMPLE_LIMIT = 32'h0002_2000;
    localparam logic [31:0] RESULT_BASE  = 32'h0002_2000;
    localparam logic [31:0] RESULT_LIMIT = 32'h0002_3000;
    localparam logic [31:0] DBG_INVALID_CONFIG = 32'h0000_0020;
    localparam logic [31:0] DBG_CONFIG_WHILE_BUSY = 32'h0000_0010;

    integer legacy_tap_read_count = 0;
    integer accelerator_sample_read_count = 0;
    integer accelerator_coefficient_read_count = 0;
    logic ownership_seen = 1'b0;

    always #5 clk = ~clk;

    // These are the actual request paths in the current hierarchy.  A
    // preflight-invalid START must not assert any of them, even briefly.
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
            if (rsp_valid !== 1'b1)
                $fatal(1, "Batch 3B-2: CSR write response missing at %03x", address);
            error_out = rsp_error;
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
            if (rsp_valid !== 1'b1)
                $fatal(1, "Batch 3B-2: CSR read response missing at %03x", address);
            data_out = rsp_rdata;
            error_out = rsp_error;
            @(negedge clk);
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
                $fatal(1, "Batch 3B-2: %s (rsp_error=%b expected=%b)",
                       requirement, transaction_error, expected_error);
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
                $fatal(1, "Batch 3B-2: %s (read rsp_error=1)", requirement);
            if (actual !== expected)
                $fatal(1, "Batch 3B-2: %s (got %08x expected %08x)",
                       requirement, actual, expected);
        end
    endtask

    task automatic expect_status_bits(
        input logic [31:0] expected,
        input string requirement
    );
        logic [31:0] actual;
        logic transaction_error;
        begin
            csr_read(REG_STATUS, actual, transaction_error);
            if (transaction_error)
                $fatal(1, "Batch 3B-2: %s (STATUS read rsp_error=1)", requirement);
            if (actual !== expected)
                $fatal(1, "Batch 3B-2: %s (STATUS=%08x expected=%08x)",
                       requirement, actual, expected);
        end
    endtask

    task automatic reset_request_monitors;
        begin
            legacy_tap_read_count = 0;
            accelerator_sample_read_count = 0;
            accelerator_coefficient_read_count = 0;
            ownership_seen = 1'b0;
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
            reset_request_monitors();
        end
    endtask

    task automatic soft_reset(input string case_name);
        logic transaction_error;
        begin
            csr_write(REG_CTRL, 32'd2, transaction_error);
            if (transaction_error)
                $fatal(1, "Batch 3B-2: CTRL.RESET failed for %s", case_name);
            repeat (2) @(negedge clk);
            if (busy !== 1'b0 || bank_owned !== 1'b0)
                $fatal(1, "Batch 3B-2: CTRL.RESET did not release ownership for %s", case_name);
            reset_request_monitors();
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
                               $sformatf("%s: idle TAP_COUNT write", case_name));
            expect_write_error(REG_COEFF_PTR, coefficient_ptr, 1'b0,
                               $sformatf("%s: idle COEFF_PTR write", case_name));
            expect_write_error(REG_SAMPLE_COUNT, sample_count, 1'b0,
                               $sformatf("%s: idle SAMPLE_COUNT write", case_name));
            expect_write_error(REG_INPUT_PTR, input_ptr, 1'b0,
                               $sformatf("%s: idle INPUT_PTR write", case_name));
            expect_write_error(REG_OUTPUT_PTR, output_ptr, 1'b0,
                               $sformatf("%s: idle OUTPUT_PTR write", case_name));

            expect_read_value(REG_TAP_COUNT, tap_count,
                              $sformatf("%s: TAP_COUNT readback", case_name));
            expect_read_value(REG_COEFF_PTR, coefficient_ptr,
                              $sformatf("%s: COEFF_PTR readback", case_name));
            expect_read_value(REG_SAMPLE_COUNT, sample_count,
                              $sformatf("%s: SAMPLE_COUNT readback", case_name));
            expect_read_value(REG_INPUT_PTR, input_ptr,
                              $sformatf("%s: INPUT_PTR readback", case_name));
            expect_read_value(REG_OUTPUT_PTR, output_ptr,
                              $sformatf("%s: OUTPUT_PTR readback", case_name));
        end
    endtask

    task automatic verify_no_invalid_access(input string case_name);
        begin
            if (busy !== 1'b0 || bank_owned !== 1'b0)
                $fatal(1, "Batch 3B-2: %s acquired BUSY/ownership", case_name);
            if (ownership_seen === 1'b1)
                $fatal(1, "Batch 3B-2: %s observed ownership before Port-B suppression", case_name);
            if (legacy_tap_read_count != 0)
                $fatal(1, "Batch 3B-2: %s asserted dut.prefetch_req %0d time(s)",
                       case_name, legacy_tap_read_count);
            if (accelerator_sample_read_count != 0)
                $fatal(1, "Batch 3B-2: %s asserted dut.u_tap_bram.accelerator_sample_re_i %0d time(s)",
                       case_name, accelerator_sample_read_count);
            if (accelerator_coefficient_read_count != 0)
                $fatal(1, "Batch 3B-2: %s asserted dut.u_tap_bram.accelerator_coefficient_re_i %0d time(s)",
                       case_name, accelerator_coefficient_read_count);

            repeat (6) @(negedge clk);
            if (busy !== 1'b0 || bank_owned !== 1'b0 || ownership_seen === 1'b1)
                $fatal(1, "Batch 3B-2: %s acquired ownership after rejection", case_name);
            if (legacy_tap_read_count != 0 ||
                accelerator_sample_read_count != 0 ||
                accelerator_coefficient_read_count != 0)
                $fatal(1, "Batch 3B-2: %s issued a delayed Port-B request after rejection",
                       case_name);
        end
    endtask

    task automatic invalid_start_case(
        input string case_name,
        input logic [31:0] tap_count,
        input logic [31:0] coefficient_ptr,
        input logic [31:0] sample_count,
        input logic [31:0] input_ptr,
        input logic [31:0] output_ptr,
        input logic [31:0] ctrl_word
    );
        logic transaction_error;
        logic [31:0] debug_value;
        logic debug_error;
        begin
            hardware_reset();
            program_config(case_name, tap_count, coefficient_ptr, sample_count,
                           input_ptr, output_ptr);
            reset_request_monitors();

            csr_write(REG_CTRL, ctrl_word, transaction_error);
            if (transaction_error)
                $fatal(1, "Batch 3B-2: %s returned rsp_error on well-formed invalid START", case_name);
            expect_status_bits(32'h0000_0004,
                               $sformatf("%s: STATUS BUSY=0 DONE=0 ERROR=1", case_name));

            csr_read(REG_DBG_STATUS, debug_value, debug_error);
            if (debug_error)
                $fatal(1, "Batch 3B-2: %s DBG_STATUS read errored", case_name);
            if (debug_value !== DBG_INVALID_CONFIG)
                $fatal(1, "Batch 3B-2: %s DBG_STATUS=%08x expected INVALID_CONFIG=%08x",
                       case_name, debug_value, DBG_INVALID_CONFIG);
            expect_read_value(REG_CYCLES_TOTAL, 32'd0,
                              $sformatf("%s: CYCLES_TOTAL remains zero", case_name));
            expect_read_value(REG_COMPUTE_CYCLES, 32'd0,
                              $sformatf("%s: COMPUTE_CYCLES remains zero", case_name));
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              $sformatf("%s: RESULT_COUNT remains zero", case_name));
            verify_no_invalid_access(case_name);
        end
    endtask

    task automatic valid_start_case(
        input string case_name,
        input logic [1:0] arch_sel,
        input logic [31:0] tap_count,
        input logic [31:0] coefficient_ptr,
        input logic [31:0] sample_count,
        input logic [31:0] input_ptr,
        input logic [31:0] output_ptr
    );
        logic transaction_error;
        logic [31:0] ctrl_word;
        begin
            hardware_reset();
            program_config(case_name, tap_count, coefficient_ptr, sample_count,
                           input_ptr, output_ptr);
            reset_request_monitors();
            ctrl_word = {28'd0, arch_sel, 1'b0, 1'b1};
            csr_write(REG_CTRL, ctrl_word, transaction_error);
            if (transaction_error)
                $fatal(1, "Batch 3B-2: %s valid START returned rsp_error=1", case_name);
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                $fatal(1, "Batch 3B-2: %s valid START did not reserve ownership", case_name);

            // Read RESULT_COUNT first, while this accepted START is still at
            // the immediate post-command observation point.  No completion or
            // timing behavior is required for this stage.
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              $sformatf("%s: valid START clears RESULT_COUNT", case_name));
            expect_read_value(REG_TAP_COUNT, tap_count,
                              $sformatf("%s: TAP_COUNT snapshot/readback", case_name));
            expect_read_value(REG_COEFF_PTR, coefficient_ptr,
                              $sformatf("%s: COEFF_PTR snapshot/readback", case_name));
            expect_read_value(REG_SAMPLE_COUNT, sample_count,
                              $sformatf("%s: SAMPLE_COUNT snapshot/readback", case_name));
            expect_read_value(REG_INPUT_PTR, input_ptr,
                              $sformatf("%s: INPUT_PTR snapshot/readback", case_name));
            expect_read_value(REG_OUTPUT_PTR, output_ptr,
                              $sformatf("%s: OUTPUT_PTR snapshot/readback", case_name));
            soft_reset(case_name);
        end
    endtask

    task automatic sample_count_case(input logic [31:0] sample_count);
        string case_name;
        begin
            case_name = $sformatf("SAMPLE_COUNT=%0d", sample_count);
            valid_start_case(case_name, 2'b00, 32'd1, COEFF_BASE, sample_count,
                             SAMPLE_BASE, RESULT_BASE);
        end
    endtask

    task automatic result_count_read_only_case;
        logic transaction_error;
        begin
            hardware_reset();
            expect_write_error(REG_SAMPLE_COUNT, 32'd4, 1'b0,
                               "RESULT_COUNT independence: SAMPLE_COUNT=4 idle write");
            expect_read_value(REG_SAMPLE_COUNT, 32'd4,
                              "RESULT_COUNT independence: SAMPLE_COUNT readback is 4");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT independence: SAMPLE_COUNT does not alias RESULT_COUNT");
            expect_write_error(REG_RESULT_COUNT, 32'h0000_0099, 1'b1,
                               "RESULT_COUNT is read-only");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT remains zero after rejected write");
            expect_write_error(REG_TAP_COUNT, 32'd1, 1'b0,
                               "RESULT_COUNT independence: TAP_COUNT setup");
            expect_write_error(REG_COEFF_PTR, COEFF_BASE, 1'b0,
                               "RESULT_COUNT independence: COEFF_PTR setup");
            expect_write_error(REG_INPUT_PTR, SAMPLE_BASE, 1'b0,
                               "RESULT_COUNT independence: INPUT_PTR setup");
            expect_write_error(REG_OUTPUT_PTR, RESULT_BASE, 1'b0,
                               "RESULT_COUNT independence: OUTPUT_PTR setup");
            csr_write(REG_CTRL, 32'h0000_0001, transaction_error);
            if (transaction_error)
                $fatal(1, "Batch 3B-2: RESULT_COUNT independence valid START rejected");
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                $fatal(1, "Batch 3B-2: RESULT_COUNT independence START did not acquire ownership");
            expect_read_value(REG_RESULT_COUNT, 32'd0,
                              "RESULT_COUNT is zero after valid START");
            soft_reset("RESULT_COUNT read-only/independence");
        end
    endtask

    task automatic busy_configuration_case;
        logic transaction_error;
        logic [31:0] debug_before_start;
        logic [31:0] debug_after_start;
        logic debug_error;
        begin
            hardware_reset();
            program_config("BUSY configuration rejection", 32'd32, COEFF_BASE,
                           32'd1024, SAMPLE_BASE, RESULT_BASE);
            reset_request_monitors();
            csr_write(REG_CTRL, 32'h0000_0005, transaction_error);
            if (transaction_error || busy !== 1'b1 || bank_owned !== 1'b1)
                $fatal(1, "Batch 3B-2: BUSY configuration precondition START failed");

            csr_read(REG_DBG_STATUS, debug_before_start, debug_error);
            if (debug_error)
                $fatal(1, "Batch 3B-2: BUSY precondition DBG_STATUS read errored");
            expect_write_error(REG_CTRL, 32'h0000_0005, 1'b0,
                               "START while BUSY is a normal no-op");
            csr_read(REG_DBG_STATUS, debug_after_start, debug_error);
            if (debug_error || debug_after_start !== debug_before_start)
                $fatal(1, "Batch 3B-2: START while BUSY changed debug state (before=%08x after=%08x)",
                       debug_before_start, debug_after_start);
            if (busy !== 1'b1 || bank_owned !== 1'b1)
                $fatal(1, "Batch 3B-2: START while BUSY changed active ownership");

            expect_write_error(REG_TAP_COUNT, 32'd1, 1'b1,
                               "TAP_COUNT write while BUSY is rejected");
            expect_read_value(REG_TAP_COUNT, 32'd32,
                              "TAP_COUNT remains unchanged while BUSY");
            expect_write_error(REG_COEFF_PTR, COEFF_BASE + 32'd4, 1'b1,
                               "COEFF_PTR write while BUSY is rejected");
            expect_read_value(REG_COEFF_PTR, COEFF_BASE,
                              "COEFF_PTR remains unchanged while BUSY");
            expect_write_error(REG_SAMPLE_COUNT, 32'd4, 1'b1,
                               "SAMPLE_COUNT write while BUSY is rejected");
            expect_read_value(REG_SAMPLE_COUNT, 32'd1024,
                              "SAMPLE_COUNT remains unchanged while BUSY");
            expect_write_error(REG_INPUT_PTR, SAMPLE_BASE + 32'd4, 1'b1,
                               "INPUT_PTR write while BUSY is rejected");
            expect_read_value(REG_INPUT_PTR, SAMPLE_BASE,
                              "INPUT_PTR remains unchanged while BUSY");
            expect_write_error(REG_OUTPUT_PTR, RESULT_BASE + 32'd4, 1'b1,
                               "OUTPUT_PTR write while BUSY is rejected");
            expect_read_value(REG_OUTPUT_PTR, RESULT_BASE,
                              "OUTPUT_PTR remains unchanged while BUSY");

            csr_read(REG_DBG_STATUS, debug_after_start, debug_error);
            if (debug_error || (debug_after_start & DBG_CONFIG_WHILE_BUSY) == 0)
                $fatal(1, "Batch 3B-2: BUSY writes did not set CONFIG_WHILE_BUSY (debug=%08x)",
                       debug_after_start);
            expect_status_bits(32'h0000_0001,
                               "BUSY configuration writes preserve STATUS.ERROR=0");
            if (ownership_seen !== 1'b1)
                $fatal(1, "Batch 3B-2: BUSY configuration writes released ownership");
            soft_reset("BUSY configuration rejection");
        end
    endtask

    initial begin
        hardware_reset();

        // SAMPLE_COUNT is an idle-writable configured block length.  These
        // starts only check acceptance/snapshot state and are reset before any
        // completion or block traversal can become relevant.
        sample_count_case(32'd1);
        sample_count_case(32'd2);
        sample_count_case(32'd4);
        sample_count_case(32'd1024);

        result_count_read_only_case();

        // Legal fixed architectures are accepted at LANES=32.  ARCH_SEL=11 is
        // rejected by the same preflight path as other invalid configuration.
        valid_start_case("ARCH_SEL=00 sequential", 2'b00, 32'd32, COEFF_BASE,
                         32'd1024, SAMPLE_BASE, RESULT_BASE);
        valid_start_case("ARCH_SEL=01 parallel", 2'b01, 32'd32, COEFF_BASE,
                         32'd1024, SAMPLE_BASE, RESULT_BASE);
        valid_start_case("ARCH_SEL=10 pipelined", 2'b10, 32'd32, COEFF_BASE,
                         32'd1024, SAMPLE_BASE, RESULT_BASE);

        invalid_start_case("ARCH_SEL=11 reserved", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_000d);
        invalid_start_case("TAP_COUNT=0", 32'd0, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("TAP_COUNT=33 above LANES", 32'd33, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);

        // SAMPLE_COUNT semantic bounds are checked at START, not at the idle
        // configuration write, and must reject before ownership or Port-B.
        invalid_start_case("SAMPLE_COUNT=0", 32'd1, COEFF_BASE, 32'd0,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("SAMPLE_COUNT=1025", 32'd1, COEFF_BASE, 32'd1025,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);

        // Aligned base/full-span and final-word one-word boundaries are valid.
        valid_start_case("aligned base and maximum configured spans", 2'b00,
                         32'd32, COEFF_BASE, 32'd1024, SAMPLE_BASE, RESULT_BASE);
        valid_start_case("final-word one-word spans", 2'b00, 32'd1,
                         COEFF_LIMIT - 32'd4, 32'd1, SAMPLE_LIMIT - 32'd4,
                         RESULT_LIMIT - 32'd4);

        // A two-word window beginning at each physical region's final word is
        // invalid.  The other two regions remain deliberately well formed.
        invalid_start_case("two-word coefficient span from final word", 32'd2,
                           COEFF_LIMIT - 32'd4, 32'd1, SAMPLE_BASE, RESULT_BASE,
                           32'h0000_0001);
        invalid_start_case("two-word input span from final word", 32'd1,
                           COEFF_BASE, 32'd2, SAMPLE_LIMIT - 32'd4, RESULT_BASE,
                           32'h0000_0001);
        invalid_start_case("two-word output span from final word", 32'd1,
                           COEFF_BASE, 32'd2, SAMPLE_BASE, RESULT_LIMIT - 32'd4,
                           32'h0000_0001);

        // Each pointer class is invalidated independently.
        invalid_start_case("unaligned COEFF_PTR", 32'd1, COEFF_BASE + 32'd1,
                           32'd1, SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("unaligned INPUT_PTR", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE + 32'd1, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("unaligned OUTPUT_PTR", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE + 32'd1, 32'h0000_0001);
        invalid_start_case("COEFF_PTR below region", 32'd1, COEFF_BASE - 32'd4,
                           32'd1, SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("INPUT_PTR below region", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE - 32'd4, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("OUTPUT_PTR below region", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_BASE - 32'd4, 32'h0000_0001);
        invalid_start_case("COEFF_PTR at limit", 32'd1, COEFF_LIMIT, 32'd1,
                           SAMPLE_BASE, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("INPUT_PTR at limit", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_LIMIT, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("OUTPUT_PTR at limit", 32'd1, COEFF_BASE, 32'd1,
                           SAMPLE_BASE, RESULT_LIMIT, 32'h0000_0001);
        invalid_start_case("COEFF_PTR arithmetic overflow", 32'd2,
                           32'hffff_fffc, 32'd1, SAMPLE_BASE, RESULT_BASE,
                           32'h0000_0001);
        invalid_start_case("INPUT_PTR arithmetic overflow", 32'd1, COEFF_BASE,
                           32'd2, 32'hffff_fffc, RESULT_BASE, 32'h0000_0001);
        invalid_start_case("OUTPUT_PTR arithmetic overflow", 32'd1, COEFF_BASE,
                           32'd2, SAMPLE_BASE, 32'hffff_fffc, 32'h0000_0001);

        busy_configuration_case();

        $display("PASS: Batch 3B-2 configuration/validation stage");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "Batch 3B-2: configuration/validation testbench timeout");
    end
endmodule
