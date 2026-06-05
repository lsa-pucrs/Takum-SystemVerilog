// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/decoder_logarithmic.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Logarithmic Takum decoder: takum -> (sign, barred_logarithmic_value, precision, is_zero, is_nar)
// The barred logarithmic value is c + m (characteristic concatenated with mantissa),
// as an (N+4)-bit fixed-point: 9 bits integer, (N-5) bits fractional.

module decoder_logarithmic #(
    parameter int N = 16
) (
    input  logic [N-1:0]  takum,
    output logic            sign_bit,
    output logic [N+3:0]   barred_logarithmic_value,  // 9 bits int + (N-5) bits frac
    output logic [$clog2(N-4)-1:0] precision,         // 0..N-5
    output logic            is_zero,
    output logic            is_nar
);

    logic signed [8:0] characteristic;
    logic [N-6:0]      mantissa_bits;

    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b0)    // output characteristic (not exponent)
    ) u_predecoder (
        .takum                    (takum),
        .sign_bit                 (sign_bit),
        .characteristic_or_exponent(characteristic),
        .mantissa_bits            (mantissa_bits),
        .precision                (precision),
        .is_zero                  (is_zero),
        .is_nar                   (is_nar)
    );

    // The barred logarithmic value is just c + m, i.e. the concatenation
    // of the characteristic signed integer bits and the mantissa bits
    assign barred_logarithmic_value = {characteristic, mantissa_bits};

endmodule