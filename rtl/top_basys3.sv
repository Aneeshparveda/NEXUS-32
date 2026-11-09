`timescale 1ns/1ps
// Basys-3 board wrapper for the NEXUS-32 SoC.
//
// LED mapping (active high):
//   led[0] = firmware boot signature observed in DMEM[0]
//   led[1] = accelerator busy
//   led[2] = accelerator DONE or firmware PASS signature observed in DMEM[2]
//   led[3] = trap, CPU/system bus fault, or accelerator error
//
// LANES defaults to 8: the runtime selector instantiates all three engines,
// and 16/32-lane builds are expected to exceed the XC7A35T's 90 DSP48E1
// slices (pre-Vivado estimate; the utilization report is authoritative).
//
// SYS_CLK_MHZ selects the SoC clock:
//   100 - the board oscillator drives the SoC directly (default).
//   50 / 25 - an MMCME2_BASE derives a slower clock from the 100 MHz input
//             (VCO 1000 MHz). Vivado derives the generated clock from the
//             create_clock on clk_100mhz, so timing is checked at the slower
//             period. Use this when the 100 MHz build misses timing.
// The MMCM branch is only elaborated for 50/25, so simulation of the default
// build needs no Xilinx primitive models.
module top_basys3 #(
    parameter int LANES = 8,
    parameter int SYS_CLK_MHZ = 100,
    parameter IMEM_INIT_FILE = "firmware/nexus32_smoke.hex"
) (
    input  logic       clk_100mhz,
    input  logic       btn_center,
    output logic [3:0] led
);
    logic sys_clk;
    logic clk_locked;

    if (SYS_CLK_MHZ == 100) begin : gen_clk_direct
        assign sys_clk = clk_100mhz;
        assign clk_locked = 1'b1;
    end else if (SYS_CLK_MHZ == 50 || SYS_CLK_MHZ == 25) begin : gen_clk_mmcm
        logic clk_feedback;
        logic clk_mmcm_out;

        MMCME2_BASE #(
            .BANDWIDTH("OPTIMIZED"),
            .CLKIN1_PERIOD(10.0),
            .DIVCLK_DIVIDE(1),
            .CLKFBOUT_MULT_F(10.0),
            .CLKFBOUT_PHASE(0.0),
            .CLKOUT0_DIVIDE_F(1000.0 / SYS_CLK_MHZ),
            .CLKOUT0_DUTY_CYCLE(0.5),
            .CLKOUT0_PHASE(0.0),
            .REF_JITTER1(0.010),
            .STARTUP_WAIT("FALSE")
        ) u_mmcm (
            .CLKIN1(clk_100mhz),
            .CLKFBIN(clk_feedback),
            .CLKFBOUT(clk_feedback),
            .CLKFBOUTB(),
            .CLKOUT0(clk_mmcm_out),
            .CLKOUT0B(),
            .CLKOUT1(),
            .CLKOUT1B(),
            .CLKOUT2(),
            .CLKOUT2B(),
            .CLKOUT3(),
            .CLKOUT3B(),
            .CLKOUT4(),
            .CLKOUT5(),
            .CLKOUT6(),
            .LOCKED(clk_locked),
            .PWRDWN(1'b0),
            .RST(1'b0)
        );

        BUFG u_sys_clk_bufg (
            .I(clk_mmcm_out),
            .O(sys_clk)
        );
    end else begin : gen_clk_illegal
        SYS_CLK_MHZ_MUST_BE_100_50_OR_25 invalid();
    end

    // The center button (and, with the MMCM, loss of lock) is asynchronous to
    // the SoC clock. Assertion is immediate, while release propagates through
    // two clocked stages so the SoC still receives its active-high,
    // synchronously sampled reset.
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_q;

    logic reset_request;
    logic rst_i;
    logic trap;
    logic cpu_bus_fault;
    logic accelerator_busy;
    logic accelerator_done;
    logic accelerator_error;
    logic firmware_booted;
    logic firmware_pass;

    assign reset_request = btn_center || !clk_locked;

    always_ff @(posedge sys_clk or posedge reset_request) begin
        if (reset_request)
            reset_sync_q <= 2'b11;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b0};
    end

    assign rst_i = reset_sync_q[1];

    nexus32_soc #(
        .IMEM_INIT_FILE(IMEM_INIT_FILE),
        .LANES(LANES)
    ) u_soc (
        .clk_i(sys_clk),
        .rst_i(rst_i),
        .trap_o(trap),
        .cpu_bus_fault_o(cpu_bus_fault),
        .accelerator_busy_o(accelerator_busy),
        .accelerator_done_o(accelerator_done),
        .accelerator_error_o(accelerator_error),
        .firmware_booted_o(firmware_booted),
        .firmware_pass_o(firmware_pass)
    );

    // Keep the indicators tied to architectural events rather than a free-
    // running heartbeat, so a stopped board remains diagnostically useful.
    assign led[0] = firmware_booted;
    assign led[1] = accelerator_busy;
    assign led[2] = firmware_pass | accelerator_done;
    assign led[3] = trap | cpu_bus_fault | accelerator_error;
endmodule
