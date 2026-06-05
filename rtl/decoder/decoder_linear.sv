// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/decoder_linear.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Linear Takum decoder: takum -> (sign, exponent, fraction, precision, is_zero, is_nar)

module decoder_linear #(
    parameter int N = 16
) (
    input  logic [N-1:0]  takum,
    output logic            sign_bit,
    output logic signed [8:0] exponent,          // -255..254
    output logic [N-6:0]   fraction_bits,
    output logic [$clog2(N-4)-1:0] precision,    // 0..N-5
    output logic            is_zero,
    output logic            is_nar
);

    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b1)    // output exponent instead of characteristic
    ) u_predecoder (
        .takum                    (takum),
        .sign_bit                 (sign_bit),
        .characteristic_or_exponent(exponent),
        .mantissa_bits            (fraction_bits),
        .precision                (precision),
        .is_zero                  (is_zero),
        .is_nar                   (is_nar)
    );

endmodule