`timescale 1ns/1ps
// NEXUS-32 milestone 7: PicoRV32 + local IMEM/DMEM + accelerator bus.
// CPU native-memory requests are held by PicoRV32 until mem_ready. Local RAM
// responds after a registered wait cycle; MMIO waits for the accelerator
// bus's one-cycle response pulse. Bus faults are made sticky for observation.
module nexus32_soc #(
    parameter IMEM_INIT_FILE = "firmware/nexus32_smoke.hex",
    parameter integer IMEM_WORDS = 4096,
    parameter integer DMEM_WORDS = 4096
) (
    input  logic clk_i,
    input  logic rst_i,
    output logic trap_o,
    output logic cpu_bus_fault_o,
    output logic accelerator_busy_o,
    output logic accelerator_done_o,
    output logic accelerator_error_o
);
    localparam logic [17:0] IMEM_PAGE = 18'h00000; // 0x0000-0x3fff
    localparam logic [17:0] DMEM_PAGE = 18'h00004; // 0x10000-0x13fff

    logic [31:0] imem [0:IMEM_WORDS-1];
    logic [31:0] dmem [0:DMEM_WORDS-1];

    logic cpu_mem_valid;
    logic cpu_mem_instr;
    logic cpu_mem_ready;
    logic [31:0] cpu_mem_addr;
    logic [31:0] cpu_mem_wdata;
    logic [3:0] cpu_mem_wstrb;
    logic [31:0] cpu_mem_rdata;

    logic cpu_mem_is_imem;
    logic cpu_mem_is_dmem;
    logic cpu_mem_is_local;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_LOCAL_RESPONSE,
        ST_MMIO_WAIT
    } bridge_state_t;

    bridge_state_t bridge_state_q;
    logic [31:0] local_rdata_q;
    logic local_fault_sticky_q;
    integer byte_lane;

    logic accel_req_valid;
    logic accel_req_ready;
    logic accel_req_write;
    logic [31:0] accel_req_addr;
    logic [31:0] accel_req_wdata;
    logic [3:0] accel_req_wstrb;
    logic accel_rsp_valid;
    logic [31:0] accel_rsp_rdata;
    logic accel_rsp_error;
    logic accel_bus_fault_sticky;

    initial begin
        $readmemh(IMEM_INIT_FILE, imem);
    end

    assign cpu_mem_is_imem = (cpu_mem_addr[31:14] == IMEM_PAGE);
    assign cpu_mem_is_dmem = (cpu_mem_addr[31:14] == DMEM_PAGE);
    assign cpu_mem_is_local = cpu_mem_is_imem || cpu_mem_is_dmem;

    assign accel_req_valid = (bridge_state_q == ST_IDLE) &&
                             cpu_mem_valid && !cpu_mem_is_local &&
                             !cpu_mem_instr;
    assign accel_req_write = |cpu_mem_wstrb;
    assign accel_req_addr = cpu_mem_addr;
    assign accel_req_wdata = cpu_mem_wdata;
    assign accel_req_wstrb = cpu_mem_wstrb;

    always_comb begin
        cpu_mem_ready = 1'b0;
        cpu_mem_rdata = 32'd0;
        if (bridge_state_q == ST_LOCAL_RESPONSE) begin
            cpu_mem_ready = 1'b1;
            cpu_mem_rdata = local_rdata_q;
        end else if ((bridge_state_q == ST_MMIO_WAIT) && accel_rsp_valid) begin
            cpu_mem_ready = 1'b1;
            cpu_mem_rdata = accel_rsp_error ? 32'd0 : accel_rsp_rdata;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            bridge_state_q <= ST_IDLE;
            local_rdata_q <= 32'd0;
            local_fault_sticky_q <= 1'b0;
        end else begin
            case (bridge_state_q)
                ST_IDLE: begin
                    if (cpu_mem_valid) begin
                        // Instruction fetches may only access instruction
                        // memory. Reject fetches aimed at DMEM or MMIO.
                        if (cpu_mem_instr && !cpu_mem_is_imem) begin
                            local_fault_sticky_q <= 1'b1;
                            local_rdata_q <= 32'd0;
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (cpu_mem_is_imem) begin
                            if ((cpu_mem_addr[1:0] != 2'b00) || (|cpu_mem_wstrb)) begin
                                local_fault_sticky_q <= 1'b1;
                                local_rdata_q <= 32'd0;
                            end else begin
                                local_rdata_q <= imem[cpu_mem_addr[13:2]];
                            end
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (cpu_mem_is_dmem) begin
                            if (cpu_mem_addr[1:0] != 2'b00) begin
                                local_fault_sticky_q <= 1'b1;
                                local_rdata_q <= 32'd0;
                            end else if (|cpu_mem_wstrb) begin
                                for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                                    if (cpu_mem_wstrb[byte_lane]) begin
                                        dmem[cpu_mem_addr[13:2]][8*byte_lane +: 8] <=
                                            cpu_mem_wdata[8*byte_lane +: 8];
                                    end
                                end
                                local_rdata_q <= 32'd0;
                            end else begin
                                local_rdata_q <= dmem[cpu_mem_addr[13:2]];
                            end
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (accel_req_ready && accel_req_valid) begin
                            bridge_state_q <= ST_MMIO_WAIT;
                        end
                    end
                end

                ST_LOCAL_RESPONSE: begin
                    bridge_state_q <= ST_IDLE;
                end

                ST_MMIO_WAIT: begin
                    if (accel_rsp_valid) begin
                        if (accel_rsp_error)
                            local_fault_sticky_q <= 1'b1;
                        bridge_state_q <= ST_IDLE;
                    end
                end

                default: begin
                    bridge_state_q <= ST_IDLE;
                    local_fault_sticky_q <= 1'b1;
                end
            endcase
        end
    end

    assign cpu_bus_fault_o = local_fault_sticky_q | accel_bus_fault_sticky;

    picorv32 #(
        .ENABLE_COUNTERS(1'b1),
        .ENABLE_COUNTERS64(1'b1),
        .ENABLE_REGS_16_31(1'b1),
        .ENABLE_REGS_DUALPORT(1'b1),
        .LATCHED_MEM_RDATA(1'b0),
        .TWO_STAGE_SHIFT(1'b1),
        .BARREL_SHIFTER(1'b0),
        .TWO_CYCLE_COMPARE(1'b0),
        .TWO_CYCLE_ALU(1'b0),
        .COMPRESSED_ISA(1'b0),
        .CATCH_MISALIGN(1'b1),
        .CATCH_ILLINSN(1'b1),
        .ENABLE_PCPI(1'b0),
        .ENABLE_MUL(1'b0),
        .ENABLE_FAST_MUL(1'b0),
        .ENABLE_DIV(1'b0),
        .ENABLE_IRQ(1'b1),
        .ENABLE_IRQ_TIMER(1'b1),
        .REGS_INIT_ZERO(1'b1),
        .PROGADDR_RESET(32'h0000_0000),
        .PROGADDR_IRQ(32'h0000_0010),
        .STACKADDR(32'h0001_4000)
    ) u_cpu (
        .clk(clk_i),
        .resetn(~rst_i),
        .trap(trap_o),
        .mem_valid(cpu_mem_valid),
        .mem_instr(cpu_mem_instr),
        .mem_ready(cpu_mem_ready),
        .mem_addr(cpu_mem_addr),
        .mem_wdata(cpu_mem_wdata),
        .mem_wstrb(cpu_mem_wstrb),
        .mem_rdata(cpu_mem_rdata),
        .mem_la_read(),
        .mem_la_write(),
        .mem_la_addr(),
        .mem_la_wdata(),
        .mem_la_wstrb(),
        .pcpi_valid(),
        .pcpi_insn(),
        .pcpi_rs1(),
        .pcpi_rs2(),
        .pcpi_wr(1'b0),
        .pcpi_rd(32'd0),
        .pcpi_wait(1'b0),
        .pcpi_ready(1'b0),
        .irq(32'd0),
        .eoi(),
        .trace_valid(),
        .trace_data()
    );

    nexus32_accel_bus u_accel_bus (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .req_valid_i(accel_req_valid),
        .req_ready_o(accel_req_ready),
        .req_write_i(accel_req_write),
        .req_addr_i(accel_req_addr),
        .req_wdata_i(accel_req_wdata),
        .req_wstrb_i(accel_req_wstrb),
        .rsp_valid_o(accel_rsp_valid),
        .rsp_rdata_o(accel_rsp_rdata),
        .rsp_error_o(accel_rsp_error),
        .bus_fault_sticky_o(accel_bus_fault_sticky),
        .accelerator_busy_o(accelerator_busy_o),
        .accelerator_done_o(accelerator_done_o),
        .accelerator_error_o(accelerator_error_o)
    );
endmodule
