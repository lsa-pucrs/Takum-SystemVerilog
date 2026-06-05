// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/encoder_linear.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// =============================================================================
// TAKUM FORMAT OVERVIEW
// =============================================================================
//
// Takum is a tapered-precision number format proposed by Laslo Hunhold
// (paper: arXiv 2408.10594).  Unlike fixed-precision formats such as
// IEEE 754 floating point, takum allocates variable-length fields for
// the characteristic and mantissa so that large exponents still leave
// meaningful precision for the significand — this is "tapered" precision.
//
// An N-bit takum has this bit layout:
//
//   +------+------+-----------+==================+===================+
//   | sign | dir  | regime(3) | characteristic   | mantissa + padding |
//   |  1b  |  1b  |    3b     | (variable width)  | (variable width)   |
//   +------+------+-----------+==================+===================+
//    N-1   N-2    N-3..N-5     ...                 ...                0
//
// Fields:
//   sign         – Sign bit: 0 = positive, 1 = negative.
//   direction(D) – Direction bit: D=1 means positive characteristic,
//                  D=0 means negative characteristic.
//   regime(R)    – 3-bit unsigned field (0..7) that sets the exponential
//                  scale.  Larger R = larger magnitude scale.
//   characteristic – Variable-width signed integer encoding the exponent
//                  offset within the regime.  Computed as:
//                    D=1: c = 2^R - 1 + c_explicit
//                    D=0: c = -(2^(R+1)) + 1 + c_explicit
//   mantissa     – Variable-width fraction.  Precision = (N-5) - R bits.
//
// Special values:
//   Zero: all N bits are 0.
//   NaR (Not a Real): bit N-1 = 1, bits N-2..0 all zero.
//
// =============================================================================
// LINEAR ENCODER MODULE
// =============================================================================
//
// The linear encoder takes a sign bit, a base-2 exponent, a fraction
// (mantissa), and special-case flags, and produces an N-bit takum word.
//
// The key conversion is from exponent to characteristic:
//   - The exponent e represents the scale in a linear (sign-magnitude)
//     representation: value = sign * 2^e * (1 + fraction)
//   - The characteristic c is the takum-internal encoding of the scale.
//   - For positive values (sign=0): c = e
//   - For negative values (sign=1): c = ~e (bitwise complement = -e-1)
//
// This is the inverse of the relationship in the linear decoder:
//   - decoder: if sign=1, exponent = ~characteristic
//   - encoder: if sign=1, characteristic = ~exponent
//
// After computing the characteristic, the postencoder handles regime
// detection, bit assembly, and round-to-nearest-even rounding.
// =============================================================================

module encoder_linear #(
    parameter int N = 16      // Bit width of the takum word (>= 2)
) (
    // Sign bit: 0 = positive, 1 = negative
    input  logic            sign_bit,

    // Base-2 exponent (signed, 9-bit, range -255..254).
    // For positive values (sign=0): this equals the characteristic.
    // For negative values (sign=1): characteristic = ~(exponent) = -exponent - 1.
    // This ensures the represented value is sign * 2^e * (1 + fraction).
    input  logic signed [8:0] exponent,

    // Fraction (mantissa) bits, left-aligned.  These represent the
    // fractional part of the significand in the value:
    //   value = sign * 2^e * (1 + fraction)
    // Width = N-5 bits.
    input  logic [N-6:0]   fraction_bits,

    // Special-case flag: when true, output is the zero pattern
    input  logic            is_zero,

    // Special-case flag: when true, output is the NaR pattern
    input  logic            is_nar,

    // The encoded N-bit takum word
    output logic [N-1:0]   takum
);

    // The characteristic is the takum-internal representation of the scale.
    // It is derived from the exponent by a conditional negation:
    //   - Positive values (sign_bit=0): characteristic = exponent
    //     (the exponent already equals the characteristic for positive numbers)
    //   - Negative values (sign_bit=1): characteristic = ~exponent
    //     (bitwise complement, which equals -exponent-1 in two's complement;
    //      this is the correct characteristic for negative values because
    //      the takum format encodes negative characteristics differently)
    logic signed [8:0] characteristic;

    // Negate the exponent depending on sign_bit to obtain the characteristic.
    // This is the exact inverse of the linear decoder's exponent computation:
    //   decoder: exponent = ~characteristic when direction_bit == OUTPUT_EXPONENT
    //   encoder: characteristic = ~exponent when sign_bit == 1
    always_comb begin
        if (sign_bit == 1'b0) begin
            characteristic = exponent;      // Positive: c = e
        end else begin
            characteristic = ~exponent;      // Negative: c = ~e = -e-1
        end
    end

    // Instantiate the postencoder, which handles regime detection,
    // bit assembly, round-to-nearest-even rounding, and special cases.
    postencoder #(
        .N(N)
    ) u_postencoder (
        .sign_bit       (sign_bit),
        .characteristic (characteristic),
        .mantissa_bits  (fraction_bits),
        .is_zero        (is_zero),
        .is_nar         (is_nar),
        .takum          (takum)
    );

endmodule