`timescale 1ns/1ps
module tb_nexus32_accel_bus;
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

    wire result_commit_mon;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (result_commit_mon)
            commit_count <= commit_count + 1;
    end

    // Expose internal commit pulse only for the testbench scoreboard.
    nexus32_accel_bus dut (
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
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "START CSR write failed");

        wait_for_done(60, done_seen);
        if (!done_seen) $fatal(1, "four-tap accelerator did not complete");
        bus_xfer(1'b0, RESULT_BASE, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'h0002_0000)
            $fatal(1, "result read mismatch: err=%b data=%08x expected=00020000", err, rd);
        bus_xfer(1'b0, SAMPLE_COUNT_ADDR, 32'd0, 4'hf, rd, err);
        if (err || rd !== 32'd1)
            $fatal(1, "sample count mismatch: err=%b data=%0d", err, rd);
        if (commit_count != 1)
            $fatal(1, "expected exactly one result commit, saw %0d", commit_count);

        // Error paths: misaligned, unmapped, and host write to read-only result.
        bus_xfer(1'b0, SAMPLE_BASE + 1, 32'd0, 4'hf, rd, err);
        if (!err) $fatal(1, "misaligned read was not rejected");
        bus_xfer(1'b0, 32'h0003_0000, 32'd0, 4'hf, rd, err);
        if (!err) $fatal(1, "unmapped read was not rejected");
        bus_xfer(1'b1, RESULT_BASE, 32'hdead_beef, 4'hf, rd, err);
        if (!err) $fatal(1, "host write to result RAM was not rejected");
        if (!bus_fault_sticky) $fatal(1, "bus fault sticky bit did not set");

        // Now launch a longer block and try to write the owned sample bank.
        // The attempted write must be rejected and the failed run must not
        // produce another result commit.
        bus_xfer(1'b1, TAP_COUNT_ADDR, 32'd32, 4'hf, rd, err);
        if (err) $fatal(1, "32-tap configuration write failed");
        bus_xfer(1'b1, CTRL_ADDR, 32'd1, 4'hf, rd, err);
        if (err) $fatal(1, "32-tap START failed");
        if (!accelerator_busy)
            $fatal(1, "accelerator completed unexpectedly before ownership test");
        bus_xfer(1'b1, SAMPLE_BASE + 20, 32'hdead_beef, 4'hf, rd, err);
        if (!err) $fatal(1, "sample write during ownership was not rejected");
        wait_for_done(100, done_seen);
        if (!done_seen) $fatal(1, "32-tap accelerator did not complete after rejected write");
        repeat (3) @(negedge clk);
        if (commit_count != 1)
            $fatal(1, "ownership fault should suppress second result commit; count=%0d", commit_count);
        if (!accelerator_error)
            $fatal(1, "accelerator error sticky bit did not report ownership violation");

        $display("PASS: NEXUS-32 system bus, RAM mapping, result commit, errors, and ownership tests");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: bus integration test timed out");
        $fatal(1);
    end
endmodule
