// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/encoder_logarithmic.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Logarithmic Takum encoder: (sign, barred_logarithmic_value, is_zero, is_nar) -> takum
// The barred logarithmic value is c + m, split into characteristic and mantissa.

module encoder_logarithmic #(
    parameter int N = 16
) (
    input  logic            sign_bit,
    input  logic [N+3:0]   barred_logarithmic_value,  // 9 bits int + (N-5) bits frac
    input  logic            is_zero,
    input  logic            is_nar,
    output logic [N-1:0]   takum
);

    // Extract characteristic (top 9 bits) and mantissa (bottom N-5 bits)
    // barred_logarithmic_value[N+3 : N-5] = 9-bit signed characteristic
    // barred_logarithmic_value[N-6 : 0]   = (N-5) unsigned mantissa bits
    // Note: in SystemVerilog, the slice [N+3:N-5] has width N+3-(N-5)+1 = 9 bits. Correct.

    postencoder #(
        .N(N)
    ) u_postencoder (
        .sign_bit       (sign_bit),
        .characteristic (barred_logarithmic_value[N+3 -: 9]),  // 9-bit signed
        .mantissa_bits  (barred_logarithmic_value[N-6:0]),
        .is_zero        (is_zero),
        .is_nar         (is_nar),
        .takum          (takum)
    );

endmodule