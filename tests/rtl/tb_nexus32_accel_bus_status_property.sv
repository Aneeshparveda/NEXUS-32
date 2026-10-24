`timescale 1ns/1ps
module tb_nexus32_accel_bus_status_property #(
    parameter int LANES = 32
);
    localparam logic [31:0] CSR_BASE = 32'h1000_5000;
    localparam logic [31:0] COEFF_BASE = 32'h0002_0000;
    localparam logic [31:0] SAMPLE_BASE = 32'h0002_1000;
    localparam logic [31:0] RESULT_BASE = 32'h0002_2000;
    localparam logic [11:0] CTRL = 12'h000;
    localparam logic [11:0] STATUS = 12'h004;
    localparam logic [11:0] TAP_COUNT = 12'h008;
    localparam logic [11:0] COEFF_PTR = 12'h00c;
    localparam logic [11:0] INPUT_PTR = 12'h010;
    localparam logic [11:0] OUTPUT_PTR = 12'h014;
    localparam logic [11:0] SAMPLE_COUNT = 12'h01c;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic req_valid = 1'b0;
    logic req_write = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [31:0] req_wdata = 32'd0;
    logic [3:0] req_wstrb = 4'hf;
    wire req_ready;
    wire rsp_valid;
    wire [31:0] rsp_rdata;
    wire rsp_error;
    wire bus_fault;
    wire busy;
    wire done;
    wire error_status;
    integer status_reads = 0;
    logic saw_valid_done = 1'b0;
    logic saw_second_valid_done = 1'b0;
    logic saw_done_clear = 1'b0;
    logic saw_invalid_error = 1'b0;
    logic saw_error_clear = 1'b0;
    logic saw_idle_bank_access = 1'b0;

    always #5 clk = ~clk;

    nexus32_accel_bus #(.LANES(LANES)) dut (
        .clk_i(clk), .rst_i(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .req_write_i(req_write), .req_addr_i(req_addr),
        .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_rdata_o(rsp_rdata),
        .rsp_error_o(rsp_error), .bus_fault_sticky_o(bus_fault),
        .accelerator_busy_o(busy), .accelerator_done_o(done),
        .accelerator_error_o(error_status)
    );

    // Legal traffic must not produce the unreachable DONE+ERROR combination.
    // The explicit non-vacuity checks below prove that this monitor observed
    // both a real DONE state and a real recoverable ERROR state.
    always @(posedge clk) begin
        if (!rst && busy === 1'b0 && done === 1'b1 && error_status === 1'b1)
            $fatal(1, "observed illegal legal-traffic STATUS=0b110");
    end

    task automatic bus_xfer(
        input logic write_op,
        input logic [31:0] address,
        input logic [31:0] data,
        output logic [31:0] read_data,
        output logic transaction_error
    );
        integer waited;
        begin
            @(negedge clk);
            waited = 0;
            while (req_ready !== 1'b1 && waited < 100) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (req_ready !== 1'b1)
                $fatal(1, "bus never became ready for %08x", address);
            req_valid = 1'b1;
            req_write = write_op;
            req_addr = address;
            req_wdata = data;
            req_wstrb = 4'hf;
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 32'd0;
            req_wdata = 32'd0;
            waited = 0;
            while (rsp_valid !== 1'b1 && waited < 100) begin
                @(negedge clk);
                waited = waited + 1;
            end
            if (rsp_valid !== 1'b1)
                $fatal(1, "missing response for %08x", address);
            read_data = rsp_rdata;
            transaction_error = rsp_error;
            @(negedge clk);
        end
    endtask

    task automatic csr_write(input logic [11:0] offset, input logic [31:0] data);
        logic [31:0] value;
        logic transaction_error;
        begin
            bus_xfer(1'b1, CSR_BASE + {20'd0, offset}, data, value, transaction_error);
            if (transaction_error || value !== 32'd0)
                $fatal(1, "CSR write %03x failed: error=%b data=%08x",
                       offset, transaction_error, value);
        end
    endtask

    task automatic csr_read(input logic [11:0] offset, output logic [31:0] value);
        logic transaction_error;
        begin
            bus_xfer(1'b0, CSR_BASE + {20'd0, offset}, 32'd0, value, transaction_error);
            if (transaction_error)
                $fatal(1, "CSR read %03x failed", offset);
        end
    endtask

    task automatic expect_status(
        input logic [31:0] expected,
        input logic expected_busy,
        input logic expected_done,
        input logic expected_error,
        input string label
    );
        logic [31:0] value;
        begin
            csr_read(STATUS, value);
            status_reads = status_reads + 1;
            if (value !== expected)
                $fatal(1, "%s STATUS=%08x expected %08x", label, value, expected);
            if (value[0] !== expected_busy || value[1] !== expected_done ||
                value[2] !== expected_error)
                $fatal(1, "%s STATUS bits=%b%b%b expected %b%b%b",
                       label, value[2], value[1], value[0],
                       expected_error, expected_done, expected_busy);
            if (busy !== expected_busy || done !== expected_done ||
                error_status !== expected_error)
                $fatal(1, "%s bits BUSY=%b DONE=%b ERROR=%b expected %b %b %b",
                       label, busy, done, error_status,
                       expected_busy, expected_done, expected_error);
            $display("STATUS_PROPERTY_CHECK %s STATUS=%08x BUSY=%b DONE=%b ERROR=%b",
                     label, value, busy, done, error_status);
        end
    endtask

    initial begin : RUN_TEST
        logic [31:0] value;
        logic transaction_error;
        integer waited;
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Valid one-sample run: non-vacuity requires genuine DONE=1.
        csr_write(TAP_COUNT, 32'd1);
        csr_write(SAMPLE_COUNT, 32'd1);
        csr_write(COEFF_PTR, COEFF_BASE);
        csr_write(INPUT_PTR, SAMPLE_BASE);
        csr_write(OUTPUT_PTR, RESULT_BASE);
        bus_xfer(1'b1, COEFF_BASE, 32'h0001_0000, value, transaction_error);
        if (transaction_error)
            $fatal(1, "coefficient initialization failed");
        bus_xfer(1'b1, SAMPLE_BASE, 32'h0001_0000, value, transaction_error);
        if (transaction_error)
            $fatal(1, "sample initialization failed");
        csr_write(CTRL, 32'd1);
        waited = 0;
        while (!saw_valid_done && waited < 10000) begin
            csr_read(STATUS, value);
            status_reads = status_reads + 1;
            if (value[2] !== 1'b0)
                $fatal(1, "valid run unexpectedly entered ERROR: STATUS=%08x", value);
            if (busy === 1'b0 && done === 1'b1 && error_status === 1'b0)
                saw_valid_done = 1'b1;
            waited = waited + 1;
        end
        if (!saw_valid_done)
            $fatal(1, "valid run did not reach genuine DONE=1");
        expect_status(32'd2, 1'b0, 1'b1, 1'b0, "completed first valid run");
        $display("STATUS_PROPERTY_DONE_BEFORE_INVALID STATUS=00000002 BUSY=0 DONE=1 ERROR=0");

        // Invalid START is issued without clearing DONE.  The transition from
        // DONE-only to ERROR-only is the proof that invalid START clears the
        // stale DONE flag; the sampled DONE && ERROR monitor above is not that
        // proof.
        csr_write(TAP_COUNT, 32'd0);
        csr_write(CTRL, 32'd1);
        expect_status(32'd4, 1'b0, 1'b0, 1'b1,
                      "invalid TAP_COUNT START DONE-to-ERROR");
        saw_invalid_error = 1'b1;

        // Recoverable ERROR W1C is also legal while idle.
        csr_write(STATUS, 32'd4);
        expect_status(32'd0, 1'b0, 1'b0, 1'b0, "ERROR W1C after DONE-to-ERROR");
        saw_error_clear = 1'b1;

        // A separate valid run proves that DONE can still be reached after
        // the invalid-start recovery, and that DONE W1C is tested
        // independently of the DONE-to-ERROR transition above.
        csr_write(TAP_COUNT, 32'd1);
        csr_write(CTRL, 32'd1);
        waited = 0;
        while (!saw_second_valid_done && waited < 10000) begin
            csr_read(STATUS, value);
            status_reads = status_reads + 1;
            if (value[2] !== 1'b0)
                $fatal(1, "second valid run unexpectedly entered ERROR: STATUS=%08x", value);
            if (busy === 1'b0 && done === 1'b1 && error_status === 1'b0)
                saw_second_valid_done = 1'b1;
            waited = waited + 1;
        end
        if (!saw_second_valid_done)
            $fatal(1, "second valid run did not reach genuine DONE=1");
        expect_status(32'd2, 1'b0, 1'b1, 1'b0, "completed second valid run");

        // DONE W1C is tested independently after the second valid run.
        csr_write(STATUS, 32'd2);
        expect_status(32'd0, 1'b0, 1'b0, 1'b0, "DONE W1C after second valid run");
        saw_done_clear = 1'b1;

        // Legal idle bank traffic must leave status clear.
        csr_write(TAP_COUNT, 32'd1);
        bus_xfer(1'b1, COEFF_BASE, 32'h0000_1234, value, transaction_error);
        if (transaction_error)
            $fatal(1, "legal idle coefficient write failed");
        bus_xfer(1'b0, COEFF_BASE, 32'd0, value, transaction_error);
        if (transaction_error || value !== 32'h0000_1234)
            $fatal(1, "legal idle coefficient read mismatch: error=%b data=%08x",
                   transaction_error, value);
        bus_xfer(1'b1, SAMPLE_BASE, 32'h0000_5678, value, transaction_error);
        if (transaction_error)
            $fatal(1, "legal idle sample write failed");
        bus_xfer(1'b0, SAMPLE_BASE, 32'd0, value, transaction_error);
        if (transaction_error || value !== 32'h0000_5678)
            $fatal(1, "legal idle sample read mismatch: error=%b data=%08x",
                   transaction_error, value);
        expect_status(32'd0, 1'b0, 1'b0, 1'b0, "legal idle bank traffic");
        saw_idle_bank_access = 1'b1;

        if (!saw_valid_done || !saw_second_valid_done || !saw_done_clear || !saw_invalid_error ||
            !saw_error_clear || !saw_idle_bank_access || status_reads < 5)
            $fatal(1, "status-property test was vacuous: done=%b second_done=%b done_clear=%b invalid_error=%b error_clear=%b idle=%b reads=%0d",
                   saw_valid_done, saw_second_valid_done, saw_done_clear, saw_invalid_error,
                   saw_error_clear, saw_idle_bank_access, status_reads);
        if (bus_fault)
            $fatal(1, "legal status-property traffic raised a bus fault");
        $display("PASS: legal STATUS property observed DONE, ERROR, both W1C transitions, idle bank traffic, and no STATUS=0b110");
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "STATUS property testbench timeout");
    end
endmodule
