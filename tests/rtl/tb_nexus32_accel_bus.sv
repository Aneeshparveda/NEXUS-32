`timescale 1ns/1ps
module tb_nexus32_accel_bus #(
    parameter int LANES = 32
);
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
    wire bus_fault_sticky;
    wire accelerator_busy;
    wire accelerator_done;
    wire accelerator_error;

    integer commit_count = 0;
    integer i;
    integer poll;
    logic [31:0] rd;
    logic err;
    logic done_seen;

    localparam logic [31:0] COEFF_BASE = 32'h0002_0000;
    localparam logic [31:0] SAMPLE_BASE = 32'h0002_1000;
    localparam logic [31:0] RESULT_BASE = 32'h0002_2000;
    localparam logic [31:0] CTRL_ADDR = 32'h1000_5000;
    localparam logic [31:0] STATUS_ADDR = 32'h1000_5004;
    localparam logic [31:0] TAP_COUNT_ADDR = 32'h1000_5008;
    localparam logic [31:0] COEFF_PTR_ADDR = 32'h1000_500c;
    localparam logic [31:0] INPUT_PTR_ADDR = 32'h1000_5010;
    localparam logic [31:0] OUTPUT_PTR_ADDR = 32'h1000_5014;
    localparam logic [31:0] SAMPLE_COUNT_ADDR = 32'h1000_501c;
    localparam logic [31:0] RESULT_COUNT_ADDR = 32'h1000_503c;
    localparam logic [31:0] DBG_STATUS_ADDR = 32'h1000_5030;
    localparam logic [31:0] DBG_ADDR_ADDR = 32'h1000_5034;
    localparam logic [31:0] DBG_INFO_ADDR = 32'h1000_5038;

    wire result_commit_mon;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit_mon)
            commit_count <= commit_count + 1;
    end

    // Expose internal commit pulse only for the testbench scoreboard.
    nexus32_accel_bus #(
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
        .bus_fault_sticky_o(bus_fault_sticky),
        .accelerator_busy_o(accelerator_busy),
        .accelerator_done_o(accelerator_done),
        .accelerator_error_o(accelerator_error)
    );
    assign result_commit_mon = dut.result_commit;

    task automatic bus_xfer(
        input logic is_write,
        input logic [31:0] address,
        input logic [31:0] write_data,
        input logic [3:0] byte_strobes,
        output logic [31:0] read_data,
        output logic error_out
    );
        begin
            @(negedge clk);
            while (req_ready !== 1'b1) @(negedge clk);
            req_valid = 1'b1;
            req_write = is_write;
            req_addr = address;
            req_wdata = write_data;
            req_wstrb = byte_strobes;
            @(posedge clk); // request accepted
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 32'd0;
            req_wdata = 32'd0;
            req_wstrb = 4'hf;
            while (rsp_valid !== 1'b1) @(negedge clk);
            #1;
            read_data = rsp_rdata;
            error_out = rsp_error;
            @(negedge clk); // response is a one-cycle pulse
        end
    endtask

    task automatic wait_for_done(input integer max_polls, output logic found);
        begin
            found = 1'b0;
            begin : POLL_LOOP
                for (poll = 0; poll < max_polls; poll = poll + 1) begin
                    bus_xfer(1'b0, STATUS_ADDR, 32'd0, 4'hf, rd, err);
                    if (!err && rd[1]) begin
                        found = 1'b1;
                        disable POLL_LOOP;
                    end
                end
            end
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        // A well-formed START with reset defaults is a semantic preflight
        // rejection, not a malformed bus transaction. It must complete
        // normally while reporting INVALID_CONFIG through the CSRs.
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err || rd !== 32'd0)
            $fatal(1, "invalid START bus response mismatch: err=%b data=%08x", err, rd);
        bus_xfer(1'b0, STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || !rd[2] || rd[0] || rd[1])
            $fatal(1, "invalid START STATUS mismatch: err=%b status=%08x", err, rd);
        bus_xfer(1'b0, DBG_STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || !(rd & 32'h0000_0020))
            $fatal(1, "INVALID_CONFIG debug event missing: err=%b debug=%08x", err, rd);
        bus_xfer(1'b1, DBG_STATUS_ADDR, 32'h0000_0020, 4'hf, rd, err);
        if (err) $fatal(1, "idle INVALID_CONFIG debug W1C failed");
        bus_xfer(1'b0, STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || !rd[2])
            $fatal(1, "debug W1C incorrectly cleared STATUS.ERROR: %08x", rd);
        bus_xfer(1'b1, STATUS_ADDR, 32'h0000_0004, 4'hf, rd, err);
        if (err) $fatal(1, "recoverable STATUS.ERROR W1C failed");
        bus_xfer(1'b0, STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || rd[2])
            $fatal(1, "STATUS.ERROR did not clear after W1C: %08x", rd);
        if (bus_fault_sticky)
            $fatal(1, "well-formed invalid START set bus fault sticky");

        // Initialize all words before starting the accelerator. Q16.16 1.0.
        for (i = 0; i < 32; i = i + 1) begin
            bus_xfer(1'b1, COEFF_BASE + (i * 4), 32'h0001_0000, 4'hf, rd, err);
            if (err) $fatal(1, "coefficient write failed at word %0d", i);
            bus_xfer(1'b1, SAMPLE_BASE + (i * 4), 32'h0001_0000, 4'hf, rd, err);
            if (err) $fatal(1, "sample write failed at word %0d", i);
        end

        // Four-tap vector: 2*1 + 4*0.5 + 2*(-0.5) + (-1)*1 = 2.
        bus_xfer(1'b1, SAMPLE_BASE + 0, 32'h0002_0000, 4'hf, rd, err);
        if (err) $fatal(1, "sample[0] override failed");
        bus_xfer(1'b1, SAMPLE_BASE + 4, 32'h0004_0000, 4'hf, rd, err);
        if (err) $fatal(1, "sample[1] override failed");
        bus_xfer(1'b1, SAMPLE_BASE + 8, 32'h0002_0000, 4'hf, rd, err);
        if (err) $fatal(1, "sample[2] override failed");
        bus_xfer(1'b1, SAMPLE_BASE + 12, 32'hffff_0000, 4'hf, rd, err);
        if (err) $fatal(1, "sample[3] override failed");
        bus_xfer(1'b1, COEFF_BASE + 4, 32'h0000_8000, 4'hf, rd, err);
        if (err) $fatal(1, "coefficient[1] override failed");
        bus_xfer(1'b1, COEFF_BASE + 8, 32'hffff_8000, 4'hf, rd, err);
        if (err) $fatal(1, "coefficient[2] override failed");

        bus_xfer(1'b0, SAMPLE_BASE + 4, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'h0004_0000)
            $fatal(1, "sample RAM readback mismatch: err=%b data=%08x", err, rd);
        bus_xfer(1'b0, COEFF_BASE + 8, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'hffff_8000)
            $fatal(1, "coefficient RAM readback mismatch: err=%b data=%08x", err, rd);

        bus_xfer(1'b1, TAP_COUNT_ADDR, 32'd4, 4'hf, rd, err);
        if (err) $fatal(1, "TAP_COUNT CSR write failed");
        bus_xfer(1'b1, COEFF_PTR_ADDR, COEFF_BASE, 4'hf, rd, err);
        if (err) $fatal(1, "COEFF_PTR CSR write failed");
        bus_xfer(1'b1, INPUT_PTR_ADDR, SAMPLE_BASE, 4'hf, rd, err);
        if (err) $fatal(1, "INPUT_PTR CSR write failed");
        bus_xfer(1'b1, OUTPUT_PTR_ADDR, RESULT_BASE, 4'hf, rd, err);
        if (err) $fatal(1, "OUTPUT_PTR CSR write failed");
        bus_xfer(1'b1, SAMPLE_COUNT_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "SAMPLE_COUNT CSR write failed");
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "START CSR write failed");

        wait_for_done(60, done_seen);
        if (!done_seen) $fatal(1, "four-tap accelerator did not complete");
        bus_xfer(1'b0, RESULT_BASE, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'h0002_0000)
            $fatal(1, "result read mismatch: err=%b data=%08x expected=00020000", err, rd);
        bus_xfer(1'b0, SAMPLE_COUNT_ADDR, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'd1)
            $fatal(1, "configured sample count mismatch: err=%b data=%0d", err, rd);
        bus_xfer(1'b0, RESULT_COUNT_ADDR, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'd1)
            $fatal(1, "result count mismatch: err=%b data=%0d", err, rd);
        if (commit_count != 1)
            $fatal(1, "expected exactly one result commit, saw %0d", commit_count);

        // Error paths: mapped malformed, unmapped, and result-write priority.
        bus_xfer(1'b0, SAMPLE_BASE + 1, 32'd0, 4'hf, rd, err);
        if (!err || rd !== 32'd0) $fatal(1, "mapped malformed read response mismatch");
        bus_xfer(1'b0, 32'h0003_0001, 32'd0, 4'hf, rd, err);
        if (!err || rd !== 32'hdead_beef)
            $fatal(1, "unmapped malformed read response mismatch: err=%b data=%08x", err, rd);
        bus_xfer(1'b1, RESULT_BASE, 32'hdead_beef, 4'hf, rd, err);
        if (!err || rd !== 32'd0) $fatal(1, "host result write response mismatch");
        bus_xfer(1'b1, RESULT_BASE + 1, 32'hdead_beef, 4'h1, rd, err);
        if (!err || rd !== 32'd0) $fatal(1, "misaligned result write response mismatch");
        bus_xfer(1'b0, DBG_STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || !(rd & 32'h0000_000b) || (rd & 32'h0000_0004))
            $fatal(1, "debug classification mismatch: err=%b debug=%08x", err, rd);
        bus_xfer(1'b0, DBG_ADDR_ADDR, 32'd0, 4'hf, rd, err);
        if (err || rd !== RESULT_BASE + 1)
            $fatal(1, "result-write debug address mismatch: %08x", rd);
        bus_xfer(1'b0, CTRL_ADDR + 32'h24, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'd0)
            $fatal(1, "AUTO_CFG reserved read mismatch: err=%b data=%08x", err, rd);
        bus_xfer(1'b1, CTRL_ADDR + 32'h24, 32'h1, 4'hf, rd, err);
        if (!err || rd !== 32'd0)
            $fatal(1, "AUTO_CFG reserved write response mismatch");
        bus_xfer(1'b0, CTRL_ADDR + 32'h48, 32'd0, 4'hf, rd, err);
        if (!err || rd !== 32'd0)
            $fatal(1, "unlisted CSR read response mismatch");
        if (!bus_fault_sticky) $fatal(1, "bus fault sticky bit did not set");

        // Accelerator/debug W1C operations do not clear the external sticky
        // CPU/bus diagnostic; only rst_i clears it.
        bus_xfer(1'b1, CTRL_ADDR, 32'd2, 4'hf, rd, err);
        if (err) $fatal(1, "CTRL.RESET failed after host bus errors");
        bus_xfer(1'b1, DBG_STATUS_ADDR, 32'h0000_003f, 4'hf, rd, err);
        if (err) $fatal(1, "debug W1C failed after CTRL.RESET");
        if (!bus_fault_sticky)
            $fatal(1, "CTRL.RESET/debug W1C incorrectly cleared bus fault sticky");
        bus_xfer(1'b0, CTRL_ADDR + 32'h48, 32'd0, 4'hf, rd, err);
        if (!err || rd !== 32'd0)
            $fatal(1, "unlisted CSR read after reset response mismatch");
        bus_xfer(1'b0, DBG_STATUS_ADDR, 32'd0, 4'hf, rd, err);
        if (err || !(rd & 32'h0000_0002))
            $fatal(1, "reserved CSR read did not set BUS_ACCESS: %08x", rd);
        bus_xfer(1'b1, SAMPLE_COUNT_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "SAMPLE_COUNT write failed before invalid-tap test");

        // Test invalid tap count rejection (> LANES) through the bus interface
        bus_xfer(1'b1, TAP_COUNT_ADDR, 32'(LANES + 1), 4'hf, rd, err);
        if (err) $fatal(1, "invalid tap count CSR write failed to accept cycle");
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "invalid tap count START should complete normally");
        if (accelerator_busy)
            $fatal(1, "accelerator entered busy on invalid tap count");
        if (!accelerator_error)
            $fatal(1, "accelerator error bit not set on invalid tap count start");
        // Clear sticky error with soft reset before next test
        bus_xfer(1'b1, CTRL_ADDR, 32'd2, 4'hf, rd, err);
        if (err) $fatal(1, "soft reset write failed");
        if (accelerator_error)
            $fatal(1, "accelerator error bit not cleared by soft reset");
        bus_xfer(1'b1, SAMPLE_COUNT_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "SAMPLE_COUNT write failed before max-tap run");

        // Set a clearable event before the next run, then verify that a debug
        // W1C while busy is rejected without clearing it.
        bus_xfer(1'b1, RESULT_BASE, 32'hdead_beef, 4'hf, rd, err);
        if (!err) $fatal(1, "result write did not set a clearable debug event");

        // Now launch a max-tap block and try to write the owned sample bank.
        // The attempted write must be rejected, but host protection must not
        // invalidate the active run or suppress its result commit.
        bus_xfer(1'b1, TAP_COUNT_ADDR, 32'(LANES), 4'hf, rd, err);
        if (err) $fatal(1, "max-tap configuration write failed");
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "max-tap START failed");
        // The four-lane engine can retire the entire transaction before a
        // second bus request is issued. The direct shell test covers the
        // simultaneous busy/debug case; use the bus-level ownership sequence
        // where the 32-lane run remains active long enough for both requests.
        if (LANES == 32) begin
            if (!accelerator_busy)
                $fatal(1, "accelerator completed unexpectedly before ownership test");
            bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
            if (err || !accelerator_busy)
                $fatal(1, "START while BUSY was not a normal no-op");
            bus_xfer(1'b0, SAMPLE_BASE + 0, 32'd0, 4'hf, rd, err);
            if (!err || rd !== 32'hbad0_0001)
                $fatal(1, "owned sample read sentinel mismatch: err=%b data=%08x", err, rd);
            bus_xfer(1'b1, DBG_STATUS_ADDR, 32'h0000_0008, 4'hf, rd, err);
            if (!err) $fatal(1, "debug W1C while busy was not rejected");
            bus_xfer(1'b0, DBG_STATUS_ADDR, 32'd0, 4'hf, rd, err);
            if (err || !(rd & 32'h0000_0008) || !(rd & 32'h0000_0002))
                $fatal(1, "busy debug W1C classification mismatch: %08x", rd);
            bus_xfer(1'b1, SAMPLE_BASE + 0, 32'hdead_beef, 4'hf, rd, err);
            if (!err) $fatal(1, "sample write during ownership was not rejected");
            bus_xfer(1'b1, COEFF_BASE + 0, 32'hdead_beef, 4'hf, rd, err);
            if (!err) $fatal(1, "coefficient write during ownership was not rejected");
        end
        wait_for_done(100, done_seen);
        if (!done_seen) $fatal(1, "max-tap accelerator did not complete");
        repeat (3) @(negedge clk);
        bus_xfer(1'b0, SAMPLE_BASE + 0, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'h0002_0000)
            $fatal(1, "protected sample write changed BRAM contents: %08x", rd);
        bus_xfer(1'b0, COEFF_BASE + 0, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'h0001_0000)
            $fatal(1, "protected coefficient write changed BRAM contents: %08x", rd);
        if (commit_count != 2)
            $fatal(1, "ownership violation should not suppress result commit; count=%0d", commit_count);
        if (accelerator_error)
            $fatal(1, "ownership violation incorrectly set accelerator ERROR");

        $display("PASS: NEXUS-32 system bus, RAM mapping, result commit, errors, and ownership tests");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: bus integration test timed out");
        $fatal(1);
    end
endmodule
