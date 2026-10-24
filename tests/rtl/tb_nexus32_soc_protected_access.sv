`timescale 1ns/1ps
module tb_nexus32_soc_protected_access #(
    parameter int LANES = 32
);
    logic clk = 1'b0;
    logic rst = 1'b1;
    wire trap;
    wire cpu_bus_fault;
    wire accel_busy;
    wire accel_done;
    wire accel_error;
    integer cycle;
    logic observed_protected_read = 1'b0;
    logic observed_protected_write = 1'b0;
    logic clean_start_baseline_seen = 1'b0;
    integer physical_write_count = 0;
    integer result_commit_count = 0;
    logic [31:0] physical_write_addr = 32'd0;
    logic [31:0] physical_write_data = 32'd0;
    logic [31:0] result_commit_addr_seen = 32'd0;
    logic [31:0] result_commit_data_seen = 32'd0;

    always #5 clk = ~clk;

    // Confirm the firmware's two protected accesses are accepted by the CPU
    // bridge while the accelerator actually owns the banks, not merely after
    // a guessed delay following START.
    always @(posedge clk) begin
        if (rst) begin
            observed_protected_read <= 1'b0;
            observed_protected_write <= 1'b0;
        end else if (dut.accel_req_valid && dut.accel_req_ready) begin
            if (!dut.accel_req_write && dut.accel_req_addr == 32'h0002_1000) begin
                if (!dut.u_accel_bus.bank_owned)
                    $fatal(1, "protected sample read was not accepted while accelerator-owned");
                observed_protected_read <= 1'b1;
            end
            if (dut.accel_req_write && dut.accel_req_addr == 32'h0002_2000) begin
                if (!dut.u_accel_bus.bank_owned)
                    $fatal(1, "protected result write was not accepted while accelerator-owned");
                observed_protected_write <= 1'b1;
            end
        end
    end

    // Sample pre-NBA values: nexus32_accel_bus uses result_mem_we in its
    // posedge block to perform the physical result-memory write on this edge.
    // result_commit is the accelerator's registered commit indication presented
    // to that write port. Counting both independently prevents a later valid
    // commit from hiding an earlier unauthorized physical write.
    always @(posedge clk) begin
        if (rst) begin
            clean_start_baseline_seen = 1'b0;
            physical_write_count = 0;
            result_commit_count = 0;
            physical_write_addr = 32'd0;
            physical_write_data = 32'd0;
            result_commit_addr_seen = 32'd0;
            result_commit_data_seen = 32'd0;
        end else begin
            if (dut.u_accel_bus.csr_req_valid && dut.u_accel_bus.csr_req_ready &&
                dut.u_accel_bus.csr_req_write && dut.u_accel_bus.csr_req_addr == 12'h000 &&
                dut.u_accel_bus.csr_req_wstrb == 4'hf &&
                dut.u_accel_bus.csr_req_wdata[0] && !dut.u_accel_bus.csr_req_wdata[1] &&
                dut.u_accel_bus.csr_req_wdata[31:4] == 28'd0) begin
                if (dut.u_accel_bus.u_accel.debug_status_q !== 8'd0)
                    $fatal(1, "accelerator debug status was not clear at START: %02x",
                           dut.u_accel_bus.u_accel.debug_status_q);
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "CPU bus fault was not clear at START: %b", cpu_bus_fault);
                clean_start_baseline_seen = 1'b1;
            end

            if (dut.u_accel_bus.result_commit === 1'b1) begin
                result_commit_count = result_commit_count + 1;
                result_commit_addr_seen = dut.u_accel_bus.result_commit_addr;
                result_commit_data_seen = dut.u_accel_bus.result_commit_data;
                if (dut.u_accel_bus.result_commit_addr !== 32'h0002_2000)
                    $fatal(1, "accelerator commit address mismatch: %08x",
                           dut.u_accel_bus.result_commit_addr);
                if (dut.u_accel_bus.result_commit_data !== 32'h0001_0000)
                    $fatal(1, "accelerator commit data mismatch: %08x",
                           dut.u_accel_bus.result_commit_data);
            end

            if (dut.u_accel_bus.result_mem_we === 1'b1) begin
                if (dut.u_accel_bus.result_commit !== 1'b1)
                    $fatal(1, "physical result write occurred without accelerator commit");
                physical_write_count = physical_write_count + 1;
                physical_write_addr = dut.u_accel_bus.result_commit_addr;
                physical_write_data = dut.u_accel_bus.result_commit_data;
                if (physical_write_count > 1)
                    $fatal(1, "unexpected extra physical result write: count=%0d",
                           physical_write_count);
                if (physical_write_addr !== 32'h0002_2000)
                    $fatal(1, "physical result write address mismatch: %08x",
                           physical_write_addr);
                if (physical_write_data !== 32'h0001_0000)
                    $fatal(1, "physical result write data mismatch: %08x",
                           physical_write_data);
            end
        end
    end

    nexus32_soc #(
        .IMEM_INIT_FILE("build/nexus32_protected_access.hex"),
        .LANES(LANES)
    ) dut (
        .clk_i(clk), .rst_i(rst), .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault), .accelerator_busy_o(accel_busy),
        .accelerator_done_o(accel_done), .accelerator_error_o(accel_error)
    );

    initial begin : RUN_TEST
        repeat (6) @(negedge clk);
        rst = 1'b0;
        for (cycle = 0; cycle < 300000; cycle = cycle + 1) begin
            @(negedge clk);
            if (dut.dmem[2] === 32'hdead0001)
                $fatal(1, "protected-access firmware failed; detail=%08x debug=%08x",
                       dut.dmem[1], dut.dmem[4]);
            if (trap === 1'b1)
                $fatal(1, "PicoRV32 trapped during protected-access test; dmem[0..5]=%08x %08x %08x %08x %08x %08x",
                       dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
                       dut.dmem[4], dut.dmem[5]);
            if (dut.dmem[2] === 32'h600d600d) begin
                if (dut.dmem[0] !== 32'h4e583332)
                    $fatal(1, "boot signature mismatch: %08x", dut.dmem[0]);
                if (dut.dmem[1] !== 32'h00010000)
                    $fatal(1, "protected-access result mismatch: %08x", dut.dmem[1]);
                if (dut.dmem[3] !== 32'hbad00001)
                    $fatal(1, "CPU did not observe protected-read sentinel: %08x", dut.dmem[3]);
                if ((dut.dmem[4] & 32'h0000000c) !== 32'h0000000c)
                    $fatal(1, "firmware did not observe both debug events: %08x", dut.dmem[4]);
                if (dut.dmem[5] !== 32'd1)
                    $fatal(1, "firmware result-count mismatch: %0d", dut.dmem[5]);
                if (!observed_protected_read || !observed_protected_write)
                    $fatal(1, "CPU bridge did not issue both protected accesses while owned: read=%b write=%b",
                           observed_protected_read, observed_protected_write);
                if (!clean_start_baseline_seen)
                    $fatal(1, "accelerator transaction did not observe a clean START baseline");
                if (!cpu_bus_fault)
                    $fatal(1, "CPU-side sticky bus fault was not asserted");
                if (accel_busy || !accel_done || accel_error)
                    $fatal(1, "accelerator status invalid after protected accesses: busy=%b done=%b error=%b",
                           accel_busy, accel_done, accel_error);
                if (dut.u_accel_bus.result_mem[0] !== 32'h00010000)
                    $fatal(1, "protected access changed committed result memory: %08x",
                           dut.u_accel_bus.result_mem[0]);
                if (dut.u_accel_bus.u_accel.result_count_q !== 32'd1)
                    $fatal(1, "physical commit count mismatch: %0d",
                           dut.u_accel_bus.u_accel.result_count_q);
                if (result_commit_count != 1)
                    $fatal(1, "accelerator result-commit count mismatch: %0d",
                           result_commit_count);
                if (physical_write_count != 1)
                    $fatal(1, "physical result-write count mismatch: %0d",
                           physical_write_count);
                if (result_commit_addr_seen !== 32'h0002_2000 ||
                    result_commit_data_seen !== 32'h0001_0000)
                    $fatal(1, "recorded accelerator commit mismatch: addr=%08x data=%08x",
                           result_commit_addr_seen, result_commit_data_seen);
                if (physical_write_addr !== 32'h0002_2000 ||
                    physical_write_data !== 32'h0001_0000)
                    $fatal(1, "recorded physical result write mismatch: addr=%08x data=%08x",
                           physical_write_addr, physical_write_data);

                rst = 1'b1;
                repeat (3) @(negedge clk);
                if (cpu_bus_fault !== 1'b0)
                    $fatal(1, "hardware reset did not clear CPU-side sticky bus fault");
                $display("PASS: PicoRV32 observed protected-read sentinel, preserved the active run, and reported CPU fault diagnostics");
                $finish;
            end
        end
        $fatal(1, "timeout waiting for protected-access PASS; trap=%b fault=%b busy=%b done=%b error=%b dmem[0..5]=%08x %08x %08x %08x %08x %08x",
               trap, cpu_bus_fault, accel_busy, accel_done, accel_error,
               dut.dmem[0], dut.dmem[1], dut.dmem[2], dut.dmem[3],
               dut.dmem[4], dut.dmem[5]);
    end

    initial begin
        #3000000;
        $fatal(1, "global protected-access testbench timeout");
    end
endmodule
