`timescale 1ns/1ps
// NEXUS-32: final Q16.16 scaling and signed-int32 saturation.
// The 72-bit accumulator is Q40.32. Shift first, then saturate.
module fir_q16_postprocess (
    input  logic signed [71:0] accumulator_i,
    output logic signed [31:0] result_o
);
    localparam logic signed [71:0] MAX_INT32 = {{40{1'b0}}, 32'h7fff_ffff};
    localparam logic signed [71:0] MIN_INT32 = {{40{1'b1}}, 32'h8000_0000};

    logic signed [71:0] shifted;

    assign shifted = accumulator_i >>> 16;
    assign result_o = (shifted > MAX_INT32) ? 32'sh7fff_ffff :
                      (shifted < MIN_INT32) ? 32'sh8000_0000 :
                      shifted[31:0];
endmodule
