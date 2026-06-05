// See LICENSE file for copyright and license details
// Takum-Codec-RTL - Takum Codec SystemVerilog implementation
// Converted from VHDL by Laslo Hunhold's original design
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
//                  where c_explicit is the explicit bits decoded from
//                  the characteristic field (up to 7 bits).
//   mantissa     – Variable-width fraction.  Precision = (N-5) - R bits.
//
// Special values:
//   Zero: all N bits are 0.
//   NaR (Not a Real): bit N-1 = 1, bits N-2..0 all zero.
//
// This package defines shared constants used by the codec modules.
// =============================================================================

package takum_pkg;

    // Width (in bits) of the signed characteristic / exponent field.
    // The characteristic ranges from -255 to +254, requiring 9 bits in
    // two's-complement.  This width is independent of N; it covers
    // the full dynamic range of the takum format.
    localparam int CHAR_EXP_WIDTH = 9;

    // Minimum representable characteristic value (-255).
    // Occurs when D=0, R=7, and c_explicit=0:
    //   c = -(2^(7+1)) + 1 + 0 = -255
    localparam int CHAR_EXP_MIN = -255;

    // Maximum representable characteristic value (+254).
    // Occurs when D=1, R=7, and c_explicit=127:
    //   c = 2^7 - 1 + 127 = 254
    localparam int CHAR_EXP_MAX = 254;

    // Maximum regime value.  The regime field is 3 bits wide, so R
    // ranges from 0 to 7.  R determines how many explicit characteristic
    // bits are "active" — larger R means fewer mantissa bits but a
    // larger exponent step.
    localparam int REGIME_MAX = 7;

endpackage: takum_pkg