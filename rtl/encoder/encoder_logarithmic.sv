// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/encoder_logarithmic.vhd
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
// LOGARITHMIC ENCODER MODULE
// =============================================================================
//
// The logarithmic encoder takes a sign bit and a "barred logarithmic
// value" and produces an N-bit takum word.
//
// The barred logarithmic value is a fixed-point representation of c + m,
// where c is the 9-bit signed characteristic and m is the (N-5)-bit
// mantissa.  It is the same format produced by the logarithmic decoder:
//
//   barred_logarithmic_value [N+3:0]:
//     Bits [N+3 : N-5]  = 9-bit signed characteristic c
//     Bits [N-6 : 0]    = (N-5)-bit unsigned mantissa m
//
// The logarithmic encoder simply splits this fixed-point value into its
// characteristic and mantissa components and passes them to the
// postencoder.  No arithmetic transformation is needed because the
// barred logarithmic value already contains the characteristic in the
// format that the postencoder expects.
//
// This is the simplest encoder variant: the input is already in the
// takum's internal domain (characteristic + mantissa), so the only
// work is field extraction.
// =============================================================================

module encoder_logarithmic #(
    parameter int N = 16      // Bit width of the takum word (>= 2)
) (
    // Sign bit: 0 = positive, 1 = negative
    input  logic            sign_bit,

    // Barred logarithmic value: fixed-point representation of c + m,
    // where c is the 9-bit signed characteristic and m is the
    // (N-5)-bit mantissa fraction.
    //
    // Format:
    //   Bits [N+3 : N-5] = characteristic c (9-bit signed, range -255..254)
    //   Bits [N-6  : 0]   = mantissa m (N-5 bits, left-aligned)
    //
    // Total width = 9 + (N-5) = N+4 bits.
    // The "bar" in "barred" refers to the use of the takum's own
    // characteristic format (with its direction-dependent sign),
    // not a plain base-2 exponent.
    input  logic [N+3:0]   barred_logarithmic_value,

    // Special-case flag: when true, output is the zero pattern
    input  logic            is_zero,

    // Special-case flag: when true, output is the NaR pattern
    input  logic            is_nar,

    // The encoded N-bit takum word
    output logic [N-1:0]   takum
);

    // Extract the characteristic (top 9 bits) and mantissa (bottom N-5 bits)
    // from the barred logarithmic value.
    //
    // The characteristic is in the takum's internal signed format:
    //   D=1 (positive): c = 2^R - 1 + c_explicit
    //   D=0 (negative): c = -(2^(R+1)) + 1 + c_explicit
    //
    // The mantissa bits are left-aligned; the postencoder will right-shift
    // them by the regime amount during encoding.
    //
    // Note: barred_logarithmic_value[N+3 -: 9] extracts bits
    // [N+3 : N-5] (9 bits) as the signed characteristic.
    // barred_logarithmic_value[N-6 : 0] extracts the remaining
    // (N-5) bits as the unsigned mantissa.

    postencoder #(
        .N(N)
    ) u_postencoder (
        .sign_bit       (sign_bit),
        .characteristic (barred_logarithmic_value[N+3 -: 9]),  // 9-bit signed characteristic
        .mantissa_bits  (barred_logarithmic_value[N-6:0]),     // (N-5)-bit mantissa
        .is_zero        (is_zero),
        .is_nar         (is_nar),
        .takum          (takum)
    );

endmodule