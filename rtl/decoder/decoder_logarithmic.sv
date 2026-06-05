// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/decoder_logarithmic.vhd
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
// LOGARITHMIC DECODER MODULE
// =============================================================================
//
// The logarithmic decoder converts a takum word into a fixed-point
// "barred logarithmic value" representation, which is simply the
// characteristic c concatenated with the mantissa m:
//
//   barred_logarithmic_value = c + m   (in fixed-point)
//
// This is useful for logarithmic-domain arithmetic (addition becomes
// multiplication, etc.).  The output format is:
//
//   barred_logarithmic_value [N+3:0]:
//     Bits [N+3 : N-5]  = 9-bit signed characteristic c
//     Bits [N-6 : 0]    = (N-5)-bit unsigned mantissa m
//
// The "bar" in "barred logarithmic value" refers to the use of the
// characteristic (with its direction-dependent sign) rather than a
// plain base-2 exponent.  This preserves the tapered-precision
// structure of the takum format in a fixed-point representation.
//
// OUTPUT_EXPONENT is set to 0 so the predecoder outputs the raw
// characteristic c (not the base-2 exponent e).  This is essential
// because the logarithmic domain works directly with c, not e.
// =============================================================================

module decoder_logarithmic #(
    parameter int N = 16      // Bit width of the takum word (>= 2)
) (
    // The N-bit takum word to decode
    input  logic [N-1:0]  takum,

    // Sign bit: 0 = positive, 1 = negative
    output logic            sign_bit,

    // Barred logarithmic value: fixed-point representation of c + m,
    // where c is the 9-bit signed characteristic and m is the
    // (N-5)-bit mantissa fraction.  Format: 9 integer bits + (N-5) fractional bits.
    // Total width = 9 + (N-5) = N+4 bits.
    output logic [N+3:0]   barred_logarithmic_value,

    // Number of valid mantissa bits: max(0, (N-5) - R)
    output logic [$clog2(N-4)-1:0] precision,

    // True when all bits of the takum word are zero
    output logic            is_zero,

    // True when bit [N-1]=1 and all other bits are zero (Not a Real)
    output logic            is_nar
);

    // Characteristic c: the signed 9-bit value decoded from the takum word.
    // This is the integer part of the barred logarithmic value.
    logic signed [8:0] characteristic;

    // Mantissa bits m: the (N-5)-bit left-aligned fractional part.
    // This is the fractional part of the barred logarithmic value.
    logic [N-6:0]      mantissa_bits;

    // Instantiate the predecoder with OUTPUT_EXPONENT = 0 so that it
    // outputs the raw characteristic c (not the base-2 exponent e).
    // The logarithmic domain needs c directly because the representation
    // is c.m (characteristic dot mantissa) as a fixed-point number.
    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b0)    // 0 = output characteristic (not exponent)
    ) u_predecoder (
        .takum                    (takum),
        .sign_bit                 (sign_bit),
        .characteristic_or_exponent(characteristic),
        .mantissa_bits            (mantissa_bits),
        .precision                (precision),
        .is_zero                  (is_zero),
        .is_nar                   (is_nar)
    );

    // The barred logarithmic value is simply c + m in fixed-point:
    // concatenate the 9-bit signed characteristic with the (N-5)-bit
    // mantissa to form an (N+4)-bit fixed-point number.
    //   Bits [N+3 : N-5] = characteristic (9 bits, integer part)
    //   Bits [N-6 : 0]   = mantissa_bits  (N-5 bits, fractional part)
    // The precision field indicates how many mantissa bits are valid.
    assign barred_logarithmic_value = {characteristic, mantissa_bits};

endmodule