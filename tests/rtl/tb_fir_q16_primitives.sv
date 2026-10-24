`timescale 1ns/1ps

module tb_fir_q16_primitives;
    logic signed [31:0] sample_i;
    logic signed [31:0] coefficient_i;
    logic signed [71:0] accumulator_i;

    logic signed [63:0] product_o;
    logic signed [71:0] accumulator_o;
    logic signed [31:0] result_o;

    fir_q16_mac u_mac (
        .sample_i(sample_i),
        .coefficient_i(coefficient_i),
        .accumulator_i(accumulator_i),
        .product_o(product_o),
        .accumulator_o(accumulator_o)
    );

    fir_q16_postprocess u_postprocess (
        .accumulator_i(accumulator_i),
        .result_o(result_o)
    );

    initial begin
        sample_i = 0;
        coefficient_i = 0;
        accumulator_i = 0;
        #1;

        // 1.0 * 0.5 in raw Q16.16 representation.
        sample_i = 32'sd65536;
        coefficient_i = 32'sd32768;
        accumulator_i = 72'sd0;
        #1;
        if (product_o !== 64'sd2147483648)
            $fatal(1, "positive product mismatch: %0d", product_o);
        if (accumulator_o !== 72'sd2147483648)
            $fatal(1, "positive accumulator mismatch: %0d", accumulator_o);

        // Sign handling: (-1 raw) * (0.5 raw) = -32768 raw-product units.
        sample_i = -32'sd1;
        coefficient_i = 32'sd32768;
        accumulator_i = 72'sd7;
        #1;
        if (product_o !== -64'sd32768)
            $fatal(1, "negative product mismatch: %0d", product_o);
        if (accumulator_o !== -72'sd32761)
            $fatal(1, "negative accumulation mismatch: %0d", accumulator_o);

        // Signed minimum multiplied by signed minimum must produce +2^62.
        sample_i = 32'sh8000_0000;
        coefficient_i = 32'sh8000_0000;
        accumulator_i = 72'sd0;
        #1;
        if (product_o !== 64'sd4611686018427387904)
            $fatal(1, "INT32_MIN product mismatch: %0d", product_o);

        // Floor toward -infinity: -32768 >>> 16 == -1, not zero.
        accumulator_i = -72'sd32768;
        #1;
        if (result_o !== -32'sd1)
            $fatal(1, "negative arithmetic shift mismatch: %0d", result_o);

        // Positive truncation boundary: values below one output LSB remain 0.
        accumulator_i = 72'sd65535;
        #1;
        if (result_o !== 32'sd0)
            $fatal(1, "positive truncation boundary mismatch: %0d", result_o);

        // The first positive output LSB appears exactly at 1 << 16.
        accumulator_i = 72'sd65536;
        #1;
        if (result_o !== 32'sd1)
            $fatal(1, "positive first-LSB boundary mismatch: %0d", result_o);

        // Negative arithmetic-floor boundaries: -1 and -1.0 both map to -1,
        // while the first value below -1.0 maps to -2.
        accumulator_i = -72'sd1;
        #1;
        if (result_o !== -32'sd1)
            $fatal(1, "negative -1 raw-unit boundary mismatch: %0d", result_o);
        accumulator_i = -72'sd65536;
        #1;
        if (result_o !== -32'sd1)
            $fatal(1, "negative exact-LSB boundary mismatch: %0d", result_o);
        accumulator_i = -72'sd65537;
        #1;
        if (result_o !== -32'sd2)
            $fatal(1, "negative below-LSB boundary mismatch: %0d", result_o);

        // Exact signed-int32 maximum should remain unchanged.
        accumulator_i = (72'sd2147483647 <<< 16);
        #1;
        if (result_o !== 32'sh7fff_ffff)
            $fatal(1, "INT32_MAX boundary mismatch: %0d", result_o);

        // Value just above INT32_MAX after shifting must saturate.
        accumulator_i = (72'sd2147483648 <<< 16);
        #1;
        if (result_o !== 32'sh7fff_ffff)
            $fatal(1, "positive saturation mismatch: %0d", result_o);

        // Value below INT32_MIN after shifting must saturate.
        accumulator_i = -((72'sd2147483648 <<< 16) + 72'sd65536);
        #1;
        if (result_o !== 32'sh8000_0000)
            $fatal(1, "negative saturation mismatch: %0d", result_o);

        // Exact INT32_MIN boundary is representable and remains unchanged.
        accumulator_i = -(72'sd2147483648 <<< 16);
        #1;
        if (result_o !== 32'sh8000_0000)
            $fatal(1, "INT32_MIN boundary mismatch: %0d", result_o);

        $display("PASS: NEXUS-32 Q16.16 MAC and postprocess directed tests");
        $finish;
    end
endmodule
