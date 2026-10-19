`timescale 1ns/1ps
// Basys-3 board wrapper for the NEXUS-32 SoC.
//
// LED mapping (active high):
//   led[0] = firmware boot signature observed in DMEM[0]
//   led[1] = accelerator busy
//   led[2] = accelerator DONE or firmware PASS signature observed in DMEM[2]
//   led[3] = trap, CPU/system bus fault, or accelerator error
module top_basys3 #(
    parameter int LANES = 16,
    parameter IMEM_INIT_FILE = "firmware/nexus32_smoke.hex"
) (
    input  logic       clk_100mhz,
    input  logic       btn_center,
    output logic [3:0] led
);
    // The center button is asynchronous to the system clock.  Assertion is
    // immediate, while release propagates through two clocked stages so the
    // SoC still receives its active-high, synchronously sampled reset.
    (* ASYNC_REG = "TRUE" *) logic [1:0] reset_sync_q;

    logic rst_i;
    logic trap;
    logic cpu_bus_fault;
    logic accelerator_busy;
    logic accelerator_done;
    logic accelerator_error;
    logic firmware_booted;
    logic firmware_pass;

    always_ff @(posedge clk_100mhz or posedge btn_center) begin
        if (btn_center)
            reset_sync_q <= 2'b11;
        else
            reset_sync_q <= {reset_sync_q[0], 1'b0};
    end

    assign rst_i = reset_sync_q[1];

    nexus32_soc #(
        .IMEM_INIT_FILE(IMEM_INIT_FILE),
        .LANES(LANES)
    ) u_soc (
        .clk_i(clk_100mhz),
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
