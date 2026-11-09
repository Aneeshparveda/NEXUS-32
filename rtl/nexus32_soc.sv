`timescale 1ns/1ps
// NEXUS-32 milestone 7: PicoRV32 + local IMEM/DMEM + accelerator bus.
// CPU native-memory requests are held by PicoRV32 until mem_ready. Local RAM
// responds after a registered wait cycle; MMIO waits for the accelerator
// bus's one-cycle response pulse. Bus faults are made sticky for observation.
//
// System page 0x1000_6000..0x1000_6FFF (local, answered like RAM):
//   0x00 UART_TXDATA  W: bits 7:0 start one 8N1 frame (full-word store only).
//                     A store while the transmitter is busy is dropped and
//                     sets UART_STATUS.TX_OVERRUN. Reads return zero.
//   0x04 UART_STATUS  R: bit 0 TX_READY, bit 1 TX_OVERRUN (sticky until reset).
//                     Writes are ignored.
//   0x08 SYS_INFO     R: bits 7:0 LANES, bits 15:8 CLK_MHZ, bits 31:16 0x4E58.
//                     Writes are ignored.
// Other offsets, misaligned accesses and partial TXDATA stores set the
// sticky CPU bus fault and return zero, like other malformed local accesses.
module nexus32_soc #(
    parameter IMEM_INIT_FILE = "firmware/nexus32_smoke.hex",
    parameter integer IMEM_WORDS = 4096,
    parameter integer DMEM_WORDS = 4096,
    parameter int LANES = 32,
    parameter int CLK_MHZ = 100,
    parameter int UART_CLKS_PER_BIT = (CLK_MHZ * 1000000) / 115200
) (
    input  logic clk_i,
    input  logic rst_i,
    output logic trap_o,
    output logic cpu_bus_fault_o,
    output logic accelerator_busy_o,
    output logic accelerator_done_o,
    output logic accelerator_error_o,
    output logic firmware_booted_o,
    output logic firmware_pass_o,
    output logic uart_tx_o
);
    generate
        if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32) begin : gen_illegal_lanes
            LANES_MUST_BE_4_8_16_OR_32 invalid();
        end
    endgenerate

    // synthesis translate_off
    initial begin
        if (LANES != 4 && LANES != 8 && LANES != 16 && LANES != 32) begin
            $fatal(1, "ERROR: nexus32_soc LANES=%0d is unsupported; must be 4, 8, 16, or 32", LANES);
        end
    end
    // synthesis translate_on

    localparam logic [17:0] IMEM_PAGE = 18'h00000; // 0x0000-0x3fff
    localparam logic [17:0] DMEM_PAGE = 18'h00004; // 0x10000-0x13fff
    localparam logic [19:0] SYS_PAGE  = 20'h10006; // 0x10006000-0x10006fff
    localparam logic [11:0] SYS_UART_TXDATA = 12'h000;
    localparam logic [11:0] SYS_UART_STATUS = 12'h004;
    localparam logic [11:0] SYS_INFO        = 12'h008;
    localparam logic [31:0] SYS_INFO_VALUE  = {16'h4e58, 8'(CLK_MHZ), 8'(LANES)};
    localparam logic [31:0] FIRMWARE_BOOT_SIGNATURE = 32'h4e58_3332;
    localparam logic [31:0] FIRMWARE_PASS_SIGNATURE = 32'h600d_600d;

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
    logic cpu_mem_is_sys;
    logic cpu_mem_is_local;

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_LOCAL_RESPONSE,
        ST_MMIO_WAIT
    } bridge_state_t;

    bridge_state_t bridge_state_q;
    logic local_fault_sticky_q;
    integer byte_lane;

    // Local response source, registered alongside the memory reads. Each
    // memory has its own registered read port fed directly from the array so
    // synthesis can map IMEM and DMEM onto block RAM; the response mux sits
    // after those registers.
    typedef enum logic [1:0] {
        LOCAL_ZERO,
        LOCAL_IMEM,
        LOCAL_DMEM,
        LOCAL_SYS
    } local_source_t;

    local_source_t local_source_q;
    logic imem_read_now;
    logic dmem_access_now;
    logic dmem_read_now;
    logic dmem_write_now;
    logic [31:0] imem_rdata_q;
    logic [31:0] dmem_rdata_q;
    logic [31:0] sys_rdata_q;
    logic [31:0] local_rdata;

    logic sys_access_now;
    logic sys_txdata_store_now;
    logic uart_tx_valid;
    logic uart_tx_ready;
    logic uart_overrun_q;

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
    assign cpu_mem_is_sys = (cpu_mem_addr[31:12] == SYS_PAGE);
    assign cpu_mem_is_local = cpu_mem_is_imem || cpu_mem_is_dmem || cpu_mem_is_sys;

    // A well-formed data access to the system page: aligned, not a fetch.
    assign sys_access_now = (bridge_state_q == ST_IDLE) && !rst_i && cpu_mem_valid &&
                            !cpu_mem_instr && cpu_mem_is_sys &&
                            (cpu_mem_addr[1:0] == 2'b00);
    assign sys_txdata_store_now = sys_access_now && (cpu_mem_wstrb == 4'b1111) &&
                                  (cpu_mem_addr[11:0] == SYS_UART_TXDATA);
    assign uart_tx_valid = sys_txdata_store_now && uart_tx_ready;

    nexus32_uart_tx #(
        .CLKS_PER_BIT(UART_CLKS_PER_BIT)
    ) u_uart_tx (
        .clk_i(clk_i),
        .rst_i(rst_i),
        .valid_i(uart_tx_valid),
        .data_i(cpu_mem_wdata[7:0]),
        .ready_o(uart_tx_ready),
        .tx_o(uart_tx_o)
    );

    assign accel_req_valid = (bridge_state_q == ST_IDLE) &&
                             cpu_mem_valid && !cpu_mem_is_local &&
                             !cpu_mem_instr;
    assign accel_req_write = |cpu_mem_wstrb;
    assign accel_req_addr = cpu_mem_addr;
    assign accel_req_wdata = cpu_mem_wdata;
    assign accel_req_wstrb = cpu_mem_wstrb;

    // Same access decode as the ST_IDLE branch below: instruction fetches may
    // only read aligned IMEM words; data accesses may use aligned DMEM words.
    assign imem_read_now = (bridge_state_q == ST_IDLE) && !rst_i && cpu_mem_valid &&
                           cpu_mem_is_imem && (cpu_mem_addr[1:0] == 2'b00) &&
                           !(|cpu_mem_wstrb);
    assign dmem_access_now = (bridge_state_q == ST_IDLE) && !rst_i && cpu_mem_valid &&
                             !cpu_mem_instr && cpu_mem_is_dmem &&
                             (cpu_mem_addr[1:0] == 2'b00);
    assign dmem_write_now = dmem_access_now && (|cpu_mem_wstrb);
    assign dmem_read_now = dmem_access_now && !(|cpu_mem_wstrb);

    always_ff @(posedge clk_i) begin
        if (imem_read_now)
            imem_rdata_q <= imem[cpu_mem_addr[13:2]];
    end

    always_ff @(posedge clk_i) begin
        if (dmem_write_now) begin
            for (byte_lane = 0; byte_lane < 4; byte_lane = byte_lane + 1) begin
                if (cpu_mem_wstrb[byte_lane])
                    dmem[cpu_mem_addr[13:2]][8*byte_lane +: 8] <=
                        cpu_mem_wdata[8*byte_lane +: 8];
            end
        end
        if (dmem_read_now)
            dmem_rdata_q <= dmem[cpu_mem_addr[13:2]];
    end

    always_comb begin
        case (local_source_q)
            LOCAL_IMEM: local_rdata = imem_rdata_q;
            LOCAL_DMEM: local_rdata = dmem_rdata_q;
            LOCAL_SYS:  local_rdata = sys_rdata_q;
            default:    local_rdata = 32'd0;
        endcase
    end

    always_comb begin
        cpu_mem_ready = 1'b0;
        cpu_mem_rdata = 32'd0;
        if (bridge_state_q == ST_LOCAL_RESPONSE) begin
            cpu_mem_ready = 1'b1;
            cpu_mem_rdata = local_rdata;
        end else if ((bridge_state_q == ST_MMIO_WAIT) && accel_rsp_valid) begin
            cpu_mem_ready = 1'b1;
            // Preserve accelerator diagnostic response data, including the
            // protected-memory sentinel, while reporting the error separately
            // through the sticky external bus-fault diagnostic.
            cpu_mem_rdata = accel_rsp_rdata;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            bridge_state_q <= ST_IDLE;
            local_source_q <= LOCAL_ZERO;
            local_fault_sticky_q <= 1'b0;
            firmware_booted_o <= 1'b0;
            firmware_pass_o <= 1'b0;
            sys_rdata_q <= 32'd0;
            uart_overrun_q <= 1'b0;
        end else begin
            case (bridge_state_q)
                ST_IDLE: begin
                    if (cpu_mem_valid) begin
                        // Instruction fetches may only access instruction
                        // memory. Reject fetches aimed at DMEM or MMIO.
                        // The memory arrays themselves are read/written by
                        // the dedicated processes above using the same decode.
                        if (cpu_mem_instr && !cpu_mem_is_imem) begin
                            local_fault_sticky_q <= 1'b1;
                            local_source_q <= LOCAL_ZERO;
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (cpu_mem_is_imem) begin
                            if ((cpu_mem_addr[1:0] != 2'b00) || (|cpu_mem_wstrb)) begin
                                local_fault_sticky_q <= 1'b1;
                                local_source_q <= LOCAL_ZERO;
                            end else begin
                                local_source_q <= LOCAL_IMEM;
                            end
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (cpu_mem_is_dmem) begin
                            if (cpu_mem_addr[1:0] != 2'b00) begin
                                local_fault_sticky_q <= 1'b1;
                                local_source_q <= LOCAL_ZERO;
                            end else if (|cpu_mem_wstrb) begin
                                // Capture the firmware's existing DMEM signatures
                                // as sticky board-visible status.  The firmware
                                // uses full-word stores, so no extra RAM read port
                                // is needed for these indicators.
                                if (cpu_mem_wstrb == 4'b1111) begin
                                    if ((cpu_mem_addr[13:2] == 12'd0) &&
                                        (cpu_mem_wdata == FIRMWARE_BOOT_SIGNATURE))
                                        firmware_booted_o <= 1'b1;
                                    if ((cpu_mem_addr[13:2] == 12'd2) &&
                                        (cpu_mem_wdata == FIRMWARE_PASS_SIGNATURE))
                                        firmware_pass_o <= 1'b1;
                                end
                                local_source_q <= LOCAL_ZERO;
                            end else begin
                                local_source_q <= LOCAL_DMEM;
                            end
                            bridge_state_q <= ST_LOCAL_RESPONSE;
                        end else if (cpu_mem_is_sys) begin
                            // Fetches never reach here (rejected above).
                            local_source_q <= LOCAL_ZERO;
                            sys_rdata_q <= 32'd0;
                            if (cpu_mem_addr[1:0] != 2'b00) begin
                                local_fault_sticky_q <= 1'b1;
                            end else if (|cpu_mem_wstrb) begin
                                if (cpu_mem_addr[11:0] == SYS_UART_TXDATA) begin
                                    if (cpu_mem_wstrb != 4'b1111)
                                        local_fault_sticky_q <= 1'b1;
                                    else if (!uart_tx_ready)
                                        uart_overrun_q <= 1'b1;
                                end else if ((cpu_mem_addr[11:0] != SYS_UART_STATUS) &&
                                             (cpu_mem_addr[11:0] != SYS_INFO)) begin
                                    local_fault_sticky_q <= 1'b1;
                                end
                            end else begin
                                local_source_q <= LOCAL_SYS;
                                case (cpu_mem_addr[11:0])
                                    SYS_UART_TXDATA: sys_rdata_q <= 32'd0;
                                    SYS_UART_STATUS: sys_rdata_q <= {30'd0, uart_overrun_q, uart_tx_ready};
                                    SYS_INFO:        sys_rdata_q <= SYS_INFO_VALUE;
                                    default:         local_fault_sticky_q <= 1'b1;
                                endcase
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
        // 32-bit cycle/instret counters stay available for firmware timing;
        // the 64-bit halves, IRQ controller and IRQ timer are unused (no
        // firmware reads them and irq is tied low), so they are disabled to
        // save area.
        .ENABLE_COUNTERS(1'b1),
        .ENABLE_COUNTERS64(1'b0),
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
        .ENABLE_IRQ(1'b0),
        .ENABLE_IRQ_TIMER(1'b0),
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

    nexus32_accel_bus #(
        .LANES(LANES)
    ) u_accel_bus (
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
