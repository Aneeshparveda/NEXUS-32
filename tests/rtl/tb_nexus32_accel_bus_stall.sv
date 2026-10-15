`timescale 1ns/1ps
module tb_nexus32_accel_bus_stall;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic req_valid = 1'b0;
    wire req_ready;
    logic req_write = 1'b0;
    logic [31:0] req_addr = 32'd0;
    logic [31:0] req_wdata = 32'd0;
    logic [3:0] req_wstrb = 4'd0;
    wire rsp_valid;
    wire [31:0] rsp_rdata;
    wire rsp_error;
    wire bus_fault_sticky;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;
    integer stalled_cycles;
    logic [31:0] held_addr;
    logic [31:0] held_wdata;
    logic [3:0] held_wstrb;
    logic held_write;
    logic [31:0] read_data;
    logic read_error;

    always #5 clk = ~clk;

    nexus32_accel_bus dut (
        .clk_i(clk), .rst_i(rst),
        .req_valid_i(req_valid), .req_ready_o(req_ready),
        .req_write_i(req_write), .req_addr_i(req_addr),
        .req_wdata_i(req_wdata), .req_wstrb_i(req_wstrb),
        .rsp_valid_o(rsp_valid), .rsp_rdata_o(rsp_rdata),
        .rsp_error_o(rsp_error), .bus_fault_sticky_o(bus_fault_sticky),
        .accelerator_busy_o(accel_busy), .accelerator_done_o(accel_done),
        .accelerator_error_o(accel_error)
    );

    task automatic transact(
        input logic write,
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0] strobes,
        output logic [31:0] response_data,
        output logic response_error
    );
        integer wait_cycles;
        begin
            @(negedge clk);
            req_valid = 1'b1;
            req_write = write;
            req_addr = address;
            req_wdata = data;
            req_wstrb = strobes;
            wait_cycles = 0;
            begin : WAIT_FOR_ACCEPT
                forever begin
                    @(posedge clk);
                    if (req_ready === 1'b1) disable WAIT_FOR_ACCEPT;
                    wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 100) $fatal(1, "request acceptance timeout");
                end
            end
            @(negedge clk);
            req_valid = 1'b0;
            req_write = 1'b0;
            req_addr = 32'd0;
            req_wdata = 32'd0;
            req_wstrb = 4'd0;
            wait_cycles = 0;
            begin : WAIT_FOR_RESPONSE
                forever begin
                    @(negedge clk);
                    if (rsp_valid === 1'b1) disable WAIT_FOR_RESPONSE;
                    wait_cycles = wait_cycles + 1;
                    if (wait_cycles > 100) $fatal(1, "response timeout for %08x", address);
                end
            end
            response_data = rsp_rdata;
            response_error = rsp_error;
        end
    endtask

    initial begin : RUN_TEST
        repeat (5) @(negedge clk);
        rst = 1'b0;

        transact(1'b1, 32'h0002_0000, 32'h1234_5678, 4'hf, read_data, read_error);
        if (read_error !== 1'b0) $fatal(1, "coefficient setup write failed");
        transact(1'b1, 32'h0002_1000, 32'h8765_4321, 4'hf, read_data, read_error);
        if (read_error !== 1'b0) $fatal(1, "sample setup write failed");

        // Start a multi-cycle coefficient read.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr = 32'h0002_0000;
        req_wdata = 32'd0;
        req_wstrb = 4'd0;
        @(posedge clk);
        if (req_ready !== 1'b1) $fatal(1, "first read was not accepted from idle");

        // Present the next request while the first request is still pending.
        // The requester must preserve every field until ready returns.
        @(negedge clk);
        req_valid = 1'b1;
        req_write = 1'b0;
        req_addr = 32'h0002_1000;
        req_wdata = 32'd0;
        req_wstrb = 4'd0;
        held_addr = req_addr;
        held_wdata = req_wdata;
        held_wstrb = req_wstrb;
        held_write = req_write;
        stalled_cycles = 0;
        cycle = 0;

        while (req_ready !== 1'b1 && cycle < 100) begin
            @(negedge clk);
            if (req_valid && !req_ready) begin
                if (req_addr !== held_addr || req_wdata !== held_wdata ||
                    req_wstrb !== held_wstrb || req_write !== held_write)
                    $fatal(1, "request payload changed while valid and not ready");
                stalled_cycles = stalled_cycles + 1;
            end
            cycle = cycle + 1;
        end
        if (req_ready !== 1'b1) $fatal(1, "second request never became ready");
        if (stalled_cycles < 1) $fatal(1, "test did not observe a stalled request");
        if (rsp_valid !== 1'b1) $fatal(1, "first response missing when bus became ready");
        if (rsp_error !== 1'b0 || rsp_rdata !== 32'h1234_5678)
            $fatal(1, "first response mismatch: error=%b data=%08x", rsp_error, rsp_rdata);

        // The second request is accepted on the next rising edge.
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        req_addr = 32'd0;
        begin : WAIT_FOR_SECOND_RESPONSE
            cycle = 0;
            forever begin
                @(negedge clk);
                if (rsp_valid === 1'b1) disable WAIT_FOR_SECOND_RESPONSE;
                cycle = cycle + 1;
                if (cycle > 100) $fatal(1, "second response timeout");
            end
        end
        if (rsp_error !== 1'b0 || rsp_rdata !== 32'h8765_4321)
            $fatal(1, "second response mismatch: error=%b data=%08x", rsp_error, rsp_rdata);
        if (bus_fault_sticky !== 1'b0) $fatal(1, "unexpected sticky bus fault");

        $display("PASS: accelerator bus holds requests stable through backpressure and returns ordered responses");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "global testbench timeout");
    end
endmodule
