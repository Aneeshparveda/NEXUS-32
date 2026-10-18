`timescale 1ns/1ps

module tb_fir_tap_bram;
    logic clk_i = 1'b0;
    logic rst_i = 1'b1;
    logic [9:0] sample_base_word_i = 10'd0;
    logic [9:0] coefficient_base_word_i = 10'd0;
    logic [5:0] tap_count_i = 6'd0;
    logic cfg_valid_o;
    logic tap_req_i = 1'b0;
    logic [4:0] tap_index_i = 5'd0;
    logic tap_valid_o;
    logic signed [31:0] sample_tap_o;
    logic signed [31:0] coefficient_tap_o;
    logic range_fault_o;
    logic host_sample_re_i = 1'b0;
    logic [9:0] host_sample_raddr_i = 10'd0;
    logic host_sample_rvalid_o;
    logic signed [31:0] host_sample_rdata_o;
    logic host_coefficient_re_i = 1'b0;
    logic [9:0] host_coefficient_raddr_i = 10'd0;
    logic host_coefficient_rvalid_o;
    logic signed [31:0] host_coefficient_rdata_o;
    logic accelerator_sample_re_i = 1'b0;
    logic [9:0] accelerator_sample_raddr_i = 10'd0;
    logic accelerator_sample_rvalid_o;
    logic signed [31:0] accelerator_sample_rdata_o;
    logic accelerator_coefficient_re_i = 1'b0;
    logic [9:0] accelerator_coefficient_raddr_i = 10'd0;
    logic accelerator_coefficient_rvalid_o;
    logic signed [31:0] accelerator_coefficient_rdata_o;
    logic sample_we_i = 1'b0;
    logic [9:0] sample_waddr_i = 10'd0;
    logic signed [31:0] sample_wdata_i = 32'sd0;
    logic coefficient_we_i = 1'b0;
    logic [9:0] coefficient_waddr_i = 10'd0;
    logic signed [31:0] coefficient_wdata_i = 32'sd0;

    always #5 clk_i = ~clk_i;

    fir_tap_bram dut (.*);

    task automatic write_sample(input logic [9:0] address, input logic signed [31:0] data);
        begin
            @(negedge clk_i);
            sample_we_i = 1'b1;
            sample_waddr_i = address;
            sample_wdata_i = data;
            @(negedge clk_i);
            sample_we_i = 1'b0;
        end
    endtask

    task automatic write_coefficient(input logic [9:0] address, input logic signed [31:0] data);
        begin
            @(negedge clk_i);
            coefficient_we_i = 1'b1;
            coefficient_waddr_i = address;
            coefficient_wdata_i = data;
            @(negedge clk_i);
            coefficient_we_i = 1'b0;
        end
    endtask

    task automatic check_accelerator_sample_read(
        input logic [9:0] address,
        input logic signed [31:0] expected_data
    );
        begin
            @(negedge clk_i);
            accelerator_sample_raddr_i = address;
            accelerator_sample_re_i = 1'b1;
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "accelerator sample response arrived before synchronous read edge");
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "coefficient response asserted for sample-only request");
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b1)
                $fatal(1, "accelerator sample response missing one cycle after request");
            if (accelerator_sample_rdata_o !== expected_data)
                $fatal(1, "accelerator sample mismatch at address %0d: got %0d expected %0d",
                       address, accelerator_sample_rdata_o, expected_data);
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "coefficient response asserted for sample-only request");
            @(negedge clk_i);
            accelerator_sample_re_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "accelerator sample response did not drop after request ended");
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "coefficient response remained high after sample request ended");
        end
    endtask

    task automatic check_accelerator_coefficient_read(
        input logic [9:0] address,
        input logic signed [31:0] expected_data
    );
        begin
            @(negedge clk_i);
            accelerator_coefficient_raddr_i = address;
            accelerator_coefficient_re_i = 1'b1;
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "accelerator coefficient response arrived before synchronous read edge");
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "sample response asserted for coefficient-only request");
            @(posedge clk_i);
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b1)
                $fatal(1, "accelerator coefficient response missing one cycle after request");
            if (accelerator_coefficient_rdata_o !== expected_data)
                $fatal(1, "accelerator coefficient mismatch at address %0d: got %0d expected %0d",
                       address, accelerator_coefficient_rdata_o, expected_data);
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "sample response asserted for coefficient-only request");
            @(negedge clk_i);
            accelerator_coefficient_re_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "accelerator coefficient response did not drop after request ended");
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "sample response remained high after coefficient request ended");
        end
    endtask

    task automatic check_accelerator_pair_read(
        input logic [9:0] sample_address,
        input logic signed [31:0] expected_sample,
        input logic [9:0] coefficient_address,
        input logic signed [31:0] expected_coefficient
    );
        begin
            @(negedge clk_i);
            accelerator_sample_raddr_i = sample_address;
            accelerator_coefficient_raddr_i = coefficient_address;
            accelerator_sample_re_i = 1'b1;
            accelerator_coefficient_re_i = 1'b1;
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0 ||
                accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "accelerator pair response arrived before synchronous read edge");
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b1 ||
                accelerator_coefficient_rvalid_o !== 1'b1)
                $fatal(1, "simultaneous accelerator responses were not both one-cycle valid");
            if (accelerator_sample_rdata_o !== expected_sample)
                $fatal(1, "simultaneous sample mismatch at address %0d: got %0d expected %0d",
                       sample_address, accelerator_sample_rdata_o, expected_sample);
            if (accelerator_coefficient_rdata_o !== expected_coefficient)
                $fatal(1, "simultaneous coefficient mismatch at address %0d: got %0d expected %0d",
                       coefficient_address, accelerator_coefficient_rdata_o, expected_coefficient);
            @(negedge clk_i);
            accelerator_sample_re_i = 1'b0;
            accelerator_coefficient_re_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0 ||
                accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "simultaneous accelerator responses did not drop after requests ended");
        end
    endtask

    task automatic check_sample_accelerator_collision(
        input logic [9:0] address,
        input logic signed [31:0] write_data
    );
        begin
            @(negedge clk_i);
            sample_we_i = 1'b1;
            sample_waddr_i = address;
            sample_wdata_i = write_data;
            accelerator_sample_re_i = 1'b1;
            accelerator_sample_raddr_i = address;
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "sample collision response arrived before synchronous read edge");
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b1)
                $fatal(1, "sample collision response missing one cycle after request");
            if (accelerator_sample_rdata_o !== 32'sd0)
                $fatal(1, "sample collision did not return zero data");
            if (range_fault_o !== 1'b1)
                $fatal(1, "sample collision did not set sticky range fault");
            @(negedge clk_i);
            sample_we_i = 1'b0;
            accelerator_sample_re_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (accelerator_sample_rvalid_o !== 1'b0)
                $fatal(1, "sample collision response did not drop after request ended");
            if (range_fault_o !== 1'b1)
                $fatal(1, "sample collision fault was not sticky");
        end
    endtask

    task automatic check_coefficient_accelerator_collision(
        input logic [9:0] address,
        input logic signed [31:0] write_data
    );
        begin
            @(negedge clk_i);
            coefficient_we_i = 1'b1;
            coefficient_waddr_i = address;
            coefficient_wdata_i = write_data;
            accelerator_coefficient_re_i = 1'b1;
            accelerator_coefficient_raddr_i = address;
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "coefficient collision response arrived before synchronous read edge");
            @(posedge clk_i);
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b1)
                $fatal(1, "coefficient collision response missing one cycle after request");
            if (accelerator_coefficient_rdata_o !== 32'sd0)
                $fatal(1, "coefficient collision did not return zero data");
            if (range_fault_o !== 1'b1)
                $fatal(1, "coefficient collision did not set sticky range fault");
            @(negedge clk_i);
            coefficient_we_i = 1'b0;
            accelerator_coefficient_re_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (accelerator_coefficient_rvalid_o !== 1'b0)
                $fatal(1, "coefficient collision response did not drop after request ended");
            if (range_fault_o !== 1'b1)
                $fatal(1, "coefficient collision fault was not sticky");
        end
    endtask

    task automatic check_one_request(
        input logic [4:0] index,
        input logic signed [31:0] expected_sample,
        input logic signed [31:0] expected_coefficient,
        input logic expected_fault
    );
        begin
            @(negedge clk_i);
            tap_index_i = index;
            tap_req_i = 1'b1;
            #1;
            if (tap_valid_o !== 1'b0)
                $fatal(1, "tap_valid asserted before synchronous read edge");
            @(posedge clk_i);
            #1;
            if (tap_valid_o !== 1'b1)
                $fatal(1, "tap_valid missing one cycle after request");
            if (sample_tap_o !== expected_sample)
                $fatal(1, "sample mismatch at index %0d: got %0d expected %0d",
                       index, sample_tap_o, expected_sample);
            if (coefficient_tap_o !== expected_coefficient)
                $fatal(1, "coefficient mismatch at index %0d: got %0d expected %0d",
                       index, coefficient_tap_o, expected_coefficient);
            if (range_fault_o !== expected_fault)
                $fatal(1, "fault mismatch at index %0d: got %b expected %b",
                       index, range_fault_o, expected_fault);
            @(negedge clk_i);
            tap_req_i = 1'b0;
            @(posedge clk_i);
            #1;
            if (tap_valid_o !== 1'b0)
                $fatal(1, "tap_valid did not drop after request ended");
        end
    endtask

    initial begin
        repeat (2) @(negedge clk_i);
        rst_i = 1'b0;

        // Preload ordinary words through the independent write ports.
        write_sample(10'd10, 32'sd101);
        write_sample(10'd11, -32'sd202);
        write_sample(10'd12, 32'sd303);
        write_coefficient(10'd20, 32'sd1001);
        write_coefficient(10'd21, -32'sd2002);
        write_coefficient(10'd22, 32'sd3003);

        // The accelerator ports are independent from the host ports and each
        // has one registered response cycle.  Exercise each port alone and
        // then issue different sample/coefficient addresses together.
        if (range_fault_o !== 1'b0)
            $fatal(1, "unexpected fault before accelerator read tests");
        check_accelerator_sample_read(10'd10, 32'sd101);
        check_accelerator_coefficient_read(10'd21, -32'sd2002);
        check_accelerator_pair_read(10'd11, -32'sd202, 10'd22, 32'sd3003);
        if (range_fault_o !== 1'b0)
            $fatal(1, "valid accelerator reads set range fault");

        sample_base_word_i = 10'd10;
        coefficient_base_word_i = 10'd20;
        tap_count_i = 6'd3;
        #1;
        if (cfg_valid_o !== 1'b1)
            $fatal(1, "valid 3-tap configuration rejected");

        // Consecutive requests exercise one-read-per-cycle throughput and order.
        @(negedge clk_i);
        tap_req_i = 1'b1;
        tap_index_i = 5'd0;
        @(posedge clk_i); #1;
        if (tap_valid_o !== 1'b1 || sample_tap_o !== 32'sd101 || coefficient_tap_o !== 32'sd1001)
            $fatal(1, "tap 0 response mismatch");
        @(negedge clk_i); tap_index_i = 5'd1;
        @(posedge clk_i); #1;
        if (tap_valid_o !== 1'b1 || sample_tap_o !== -32'sd202 || coefficient_tap_o !== -32'sd2002)
            $fatal(1, "tap 1 response mismatch");
        @(negedge clk_i); tap_index_i = 5'd2;
        @(posedge clk_i); #1;
        if (tap_valid_o !== 1'b1 || sample_tap_o !== 32'sd303 || coefficient_tap_o !== 32'sd3003)
            $fatal(1, "tap 2 response mismatch");
        @(negedge clk_i); tap_req_i = 1'b0;
        @(posedge clk_i); #1;
        if (tap_valid_o !== 1'b0)
            $fatal(1, "valid remained high after final request");

        // End-exclusive boundary at 1024 is legal: base 1022 with two taps.
        write_sample(10'd1022, -32'sd22);
        write_sample(10'd1023, 32'sd23);
        write_coefficient(10'd1022, -32'sd222);
        write_coefficient(10'd1023, 32'sd223);
        sample_base_word_i = 10'd1022;
        coefficient_base_word_i = 10'd1022;
        tap_count_i = 6'd2;
        #1;
        if (cfg_valid_o !== 1'b1)
            $fatal(1, "boundary configuration ending at word 1023 rejected");
        check_one_request(5'd1, 32'sd23, 32'sd223, 1'b0);
        check_accelerator_pair_read(10'd1023, 32'sd23, 10'd1023, 32'sd223);
        if (range_fault_o !== 1'b0)
            $fatal(1, "boundary accelerator reads set range fault");

        // Crossing the 4 KiB bank boundary must be rejected before START.
        sample_base_word_i = 10'd1023;
        coefficient_base_word_i = 10'd1022;
        tap_count_i = 6'd2;
        #1;
        if (cfg_valid_o !== 1'b0)
            $fatal(1, "out-of-range sample configuration accepted");
        check_one_request(5'd0, 32'sd0, 32'sd0, 1'b1);

        // Reset clears the sticky fault without resetting the BRAM contents.
        @(negedge clk_i); rst_i = 1'b1;
        @(negedge clk_i); rst_i = 1'b0;
        #1;
        if (range_fault_o !== 1'b0)
            $fatal(1, "reset did not clear sticky range fault");

        // Reset clears control/fault state but must preserve BRAM contents.
        check_accelerator_pair_read(10'd1023, 32'sd23, 10'd1023, 32'sd223);
        if (range_fault_o !== 1'b0)
            $fatal(1, "valid post-reset accelerator reads set range fault");

        sample_base_word_i = 10'd10;
        coefficient_base_word_i = 10'd20;
        tap_count_i = 6'd3;
        #1;
        if (cfg_valid_o !== 1'b1)
            $fatal(1, "valid configuration rejected before collision checks");

        // A host write colliding with an accelerator read must return zero
        // data and set the sticky fault rather than exposing read-during-write
        // behavior.  Check both independent banks and that the fault remains
        // asserted after the request has ended.
        check_sample_accelerator_collision(10'd10, 32'sd404);
        check_coefficient_accelerator_collision(10'd20, 32'sd505);

        // Reset must clear a collision fault too, while retaining the words
        // written before the reset.
        @(negedge clk_i); rst_i = 1'b1;
        @(negedge clk_i); rst_i = 1'b0;
        #1;
        if (range_fault_o !== 1'b0)
            $fatal(1, "reset did not clear collision sticky range fault");
        check_accelerator_pair_read(10'd1023, 32'sd23, 10'd1023, 32'sd223);
        if (range_fault_o !== 1'b0)
            $fatal(1, "valid second post-reset accelerator reads set range fault");

        sample_base_word_i = 10'd10;
        coefficient_base_word_i = 10'd20;
        tap_count_i = 6'd3;
        check_one_request(5'd3, 32'sd0, 32'sd0, 1'b1);

        $display("PASS: NEXUS-32 synchronous sample/coefficient BRAM tests");
        $finish;
    end
endmodule
