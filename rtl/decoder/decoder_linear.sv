// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/decoder_linear.vhd
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
// LINEAR DECODER MODULE
// =============================================================================
//
// The linear decoder converts a takum word into a representation suited
// for linear (sign-magnitude) arithmetic:
//   - sign_bit:        Sign (0 = positive, 1 = negative)
//   - exponent:        Base-2 exponent e such that value = sign * 2^e * (1 + fraction)
//   - fraction_bits:   Left-aligned mantissa bits (the fractional part)
//   - precision:       Number of valid fraction bits
//   - is_zero / is_nar: Special-case flags
//
// The key difference from the logarithmic decoder is that this module
// outputs the base-2 EXPONENT rather than the raw characteristic.
// For linear arithmetic, we need:
//   - Positive values: exponent e = characteristic c
//   - Negative values: exponent e = -c - 1
// The predecoder handles this by setting OUTPUT_EXPONENT = 1, which
// conditionally negates the characteristic depending on the direction
// bit, producing the exponent at zero additional hardware cost.
// =============================================================================

module decoder_linear #(
    parameter int N = 16      // Bit width of the takum word (>= 2)
) (
    // The N-bit takum word to decode
    input  logic [N-1:0]  takum,

    // Sign bit: 0 = positive, 1 = negative
    output logic            sign_bit,

    // Base-2 exponent (signed, 9-bit, range -255..254).
    // For positive values: e = c (the characteristic).
    // For negative values: e = -c - 1 (bitwise complement of c).
    // This is the exponent such that value = sign * 2^e * (1 + fraction).
    output logic signed [8:0] exponent,

    // Mantissa bits, left-aligned.  The top 'precision' bits are valid;
    // the remaining bits are zero.  Width = N-5 bits.
    output logic [N-6:0]   fraction_bits,

    // Number of valid mantissa bits: max(0, (N-5) - R)
    output logic [$clog2(N-4)-1:0] precision,

    // True when all bits of the takum word are zero
    output logic            is_zero,

    // True when bit [N-1]=1 and all other bits are zero (Not a Real)
    output logic            is_nar
);

    // Instantiate the predecoder with OUTPUT_EXPONENT = 1 so that it
    // produces the base-2 exponent instead of the raw characteristic.
    // When OUTPUT_EXPONENT=1 and direction_bit=0 (negative characteristic),
    // the predecoder outputs ~c = -c-1, which is exactly the exponent
    // e needed for linear arithmetic on negative values.
    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b1)    // 1 = output exponent (not characteristic)
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