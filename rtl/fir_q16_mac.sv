`timescale 1ns/1ps
// NEXUS-32: one signed Q16.16 product plus a wide accumulator.
// Combinational primitive. No rounding or saturation occurs here.
module fir_q16_mac (
    input  logic signed [31:0] sample_i,
    input  logic signed [31:0] coefficient_i,
    input  logic signed [71:0] accumulator_i,
    output logic signed [63:0] product_o,
    output logic signed [71:0] accumulator_o
);
    logic signed [63:0] sample_ext;
    logic signed [63:0] coefficient_ext;

    // The sign-extended operands preserve the exact signed 32x32 result in
    // the low 64 product bits. Product width is therefore explicit.
    assign sample_ext      = {{32{sample_i[31]}}, sample_i};
    assign coefficient_ext = {{32{coefficient_i[31]}}, coefficient_i};
    assign product_o       = sample_ext * coefficient_ext;
    assign accumulator_o   = accumulator_i +
                             $signed({{8{product_o[63]}}, product_o});
endmodule
