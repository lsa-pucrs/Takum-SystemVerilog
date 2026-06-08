// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/postencoder.vhd
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
// POSTENCODER MODULE
// =============================================================================
//
// The postencoder is the core encoding engine for the takum format.  It
// takes a sign bit, a signed characteristic, a mantissa, and special-
// case flags, and produces an N-bit takum word.
//
// The encoding process involves:
//   1. Determine the direction bit from the sign of the characteristic.
//   2. Compute the characteristic precursor (invert if D=0, then +1).
//   3. Find the regime R by detecting the leading one in the precursor.
//   4. Encode regime bits (invert if D=0) and explicit characteristic bits.
//   5. Assemble an extended takum word with rounding metadata.
//   6. Apply round-to-nearest-even with underflow/overflow prediction.
//   7. Handle special cases (zero, NaR).
//
// ROUND-TO-NEAREST-EVEN EXPLANATION:
//   The extended takum word has extra low-order bits beyond the N bits
//   that will form the final encoding.  The rounding process considers:
//
//     extended_takum[N+6:7]  – The N-bit "truncated" (rounded-down) value
//     extended_takum[6]      – The "guard bit" (first bit beyond truncation)
//     extended_takum[5:0]    – The "sticky bits" (remaining bits)
//
//   Rounding decision:
//     - If guard=0: round down (take truncated value).  No tie, nearest
//       is clearly the truncated value.
//     - If guard=1 and sticky bits are nonzero: round up.  The value is
//       closer to the rounded-up value.
//     - If guard=1 and sticky bits are zero (a tie): round to even.
//       Check extended_takum[7] (the LSB of the truncated value):
//         - If it's 1: round up (making the LSB 0 = even).
//         - If it's 0: round down (already even).
//
//   However, we must also handle boundary conditions:
//     - round_down_underflows: Rounding down would produce a value
//       outside the representable range (too small / too negative).
//       In this case, we force round up.
//     - round_up_overflows: Rounding up would produce a value outside
//       the representable range (too large / too positive).
//       In this case, we force round down.
// =============================================================================

module postencoder #(
    parameter int N = 16      // Bit width of the takum word (>= 2)
) (
    // Sign bit: 0 = positive, 1 = negative
    input  logic            sign_bit,

    // Signed characteristic (9-bit, range -255..254).
    // This is the decoded characteristic value c; the postencoder
    // will re-encode it into direction bit, regime, and explicit
    // characteristic bits according to the takum format.
    input  logic signed [8:0] characteristic,

    // Mantissa bits (N-5 bits, left-aligned).  These represent the
    // fractional part of the value.  During encoding, they will be
    // right-shifted by the regime amount and combined with the
    // explicit characteristic bits.
    input  logic [N-6:0]   mantissa_bits,

    // Special-case flag: when true, the output is the zero pattern
    // (all bits zero).
    input  logic            is_zero,

    // Special-case flag: when true, the output is the NaR pattern
    // (MSB=1, all other bits zero).
    input  logic            is_nar,

    // The encoded N-bit takum word
    output logic [N-1:0]   takum
);

    // ── Internal signals ─────────────────────────────────────────────

    // Direction bit: derived from the sign of the characteristic.
    // D=1 when characteristic >= 0 (positive or zero characteristic).
    // D=0 when characteristic < 0 (negative characteristic).
    // Since characteristic is 9-bit two's complement, bit [8] is the
    // sign bit.  We invert it to get D.
    logic       direction_bit;

    // Characteristic precursor: an unsigned 8-bit value derived from
    // the low 8 bits of the characteristic (possibly inverted) plus 1.
    // This value encodes the regime and explicit characteristic bits
    // in a normalized form where the leading one's position determines
    // the regime R.
    logic [7:0] characteristic_precursor;

    // Regime R (0..7), found by detecting the leading one in the
    // characteristic precursor.  R determines how many explicit
    // characteristic bits are active and how many mantissa bits remain.
    logic [2:0] regime;

    // Extended takum: an (N+7)-bit intermediate value that contains
    // the N-bit encoded word at bits [N+6:7], the guard bit at [6],
    // and sticky bits at [5:0].  Used for round-to-nearest-even.
    logic [N+6:0] extended_takum;

    // The N-bit takum word after rounding (before special-case override).
    logic [N-1:0] takum_rounded;

    // True if rounding down would underflow past the minimum representable
    // characteristic value for this N-bit format.  When set, we force
    // an upward round regardless of the guard/sticky bits.
    logic       round_up_overflows;

    // True if rounding up would overflow past the maximum representable
    // characteristic value for this N-bit format.  When set, we force
    // a downward round regardless of the guard/sticky bits.
    logic       round_down_underflows;

    // ── Direction bit: 1 when characteristic >= 0 ─────────────────────
    // In two's complement, bit[8]=1 means negative.  We invert it to
    // get the direction bit: D=1 for non-negative, D=0 for negative.
    assign direction_bit = ~characteristic[8];

    // ── Predict underflow/overflow ────────────────────────────────────
    // Before rounding, we need to know whether rounding up or down
    // would push the characteristic outside the representable range.
    // These bounds depend on N because the number of mantissa bits
    // affects how many characteristic values can actually be encoded
    // (for small N, some characteristic values consume all the bits,
    // leaving no room for mantissa, which changes the rounding behavior).
    //
    // For N <= 11 (small formats), the bounds are precomputed constants.
    // For N >= 12, we check whether the characteristic is at an extreme
    // value AND all the mantissa bits in the "crop region" are at their
    // respective limits (all zeros for underflow, all ones for overflow).
    //
    // Underflow bound: the most negative characteristic that can be
    //   encoded.  If characteristic <= this bound, rounding down would
    //   produce an underflow (value too small to represent).
    // Overflow bound: the most positive characteristic that can be
    //   encoded.  If characteristic >= this bound, rounding up would
    //   produce an overflow (value too large to represent).
    function automatic int get_underflow_bound(input int n);
        case (n)
            2:  get_underflow_bound = -1;    // N=2: only sign+direction+regime, min char is -1
            3:  get_underflow_bound = -16;
            4:  get_underflow_bound = -64;
            5:  get_underflow_bound = -128;
            6:  get_underflow_bound = -192;
            7:  get_underflow_bound = -224;
            8:  get_underflow_bound = -240;
            9:  get_underflow_bound = -248;
            10: get_underflow_bound = -252;
            11: get_underflow_bound = -254;
            default: get_underflow_bound = 0; // N>=12: handled differently below
        endcase
    endfunction

    function automatic int get_overflow_bound(input int n);
        case (n)
            2:  get_overflow_bound = 0;     // N=2: no room for positive characteristic
            3:  get_overflow_bound = 15;
            4:  get_overflow_bound = 63;
            5:  get_overflow_bound = 127;
            6:  get_overflow_bound = 191;
            7:  get_overflow_bound = 223;
            8:  get_overflow_bound = 239;
            9:  get_overflow_bound = 247;
            10: get_overflow_bound = 251;
            11: get_overflow_bound = 253;
            default: get_overflow_bound = 0; // N>=12: handled differently below
        endcase
    endfunction

    // Mantissa crop signals for N > 11.
    // For large N, the mantissa has more bits than the minimum 6 needed
    // for rounding, so we check the extra "crop" bits to determine
    // boundary conditions.  If the crop region is all zeros, the
    // mantissa is at its minimum; if all ones, it's at its maximum.
    logic [N-12:0] mantissa_bits_crop;       // Top (N-11) bits of mantissa
    logic [N-12:0] mantissa_bits_crop_zero;  // All-zero reference
    logic [N-12:0] mantissa_bits_crop_one;   // All-one reference

    always_comb begin : check_characteristic
        if (N <= 11) begin
            // Small N: use precomputed bounds.  If the characteristic
            // is at or beyond the bound, the corresponding rounding
            // direction would escape the representable range.
            if ($signed(characteristic) <= $signed(9'(get_underflow_bound(N))))
                round_down_underflows = 1'b1;  // Characteristic too negative; can't round down
            else
                round_down_underflows = 1'b0;

            if ($signed(characteristic) >= $signed(9'(get_overflow_bound(N))))
                round_up_overflows = 1'b1;     // Characteristic too positive; can't round up
            else
                round_up_overflows = 1'b0;
        end else begin
            // Large N (>=12): check whether the mantissa crop region
            // (the top bits beyond the minimum 6 mantissa positions)
            // is at its limits combined with the characteristic extremes.
            //
            // The mantissa_bits field is (N-5) bits wide.  The bottom 6
            // bits are always used for rounding (guard + sticky).  The
            // remaining (N-5-6) = (N-11) top bits form the "crop" region.
            //
            // Underflow: characteristic = -255 AND crop region all zeros.
            //   Since -255 is the minimum characteristic (D=0, R=7,
            //   c_explicit=0), rounding down would require an even
            //   more negative characteristic, which is impossible.
            // Overflow: characteristic = +254 AND crop region all ones.
            //   Since +254 is the maximum characteristic (D=1, R=7,
            //   c_explicit=127), rounding up would need +255, which
            //   is outside the representable range.
            mantissa_bits_crop      = mantissa_bits[N-6 -: (N-11)];
            mantissa_bits_crop_zero = '0;
            mantissa_bits_crop_one  = {(N-11){1'b1}};

            if (mantissa_bits_crop == mantissa_bits_crop_zero) begin
                if (characteristic == -9'sd255)  // -255 = 9-bit two's complement 0b100000001
                    round_down_underflows = 1'b1;  // Can't go lower than -255
                else
                    round_down_underflows = 1'b0;
            end else begin
                round_down_underflows = 1'b0;
            end

            if (mantissa_bits_crop == mantissa_bits_crop_one) begin
                if (characteristic == 9'sd254)
                    round_up_overflows = 1'b1;    // Can't go higher than +254
                else
                    round_up_overflows = 1'b0;
            end else begin
                round_up_overflows = 1'b0;
            end
        end
    end

    // ── Determine characteristic precursor ─────────────────────────────
    // The precursor is derived from the low 8 bits of the characteristic:
    //   - If D=1 (positive characteristic): use low 8 bits directly.
    //   - If D=0 (negative characteristic): invert low 8 bits (one's
    //     complement, since the encoding stores inverted bits for D=0).
    //   Then add 1 to get the precursor.
    //
    // The precursor is an unsigned value whose leading-one position
    // determines the regime R.  This is the "normal form" of the
    // characteristic in the takum encoding: R = position of the leading
    // one (0-indexed from the MSB of the 8-bit value).
    logic [8:0] characteristic_bits;
    logic [7:0] characteristic_normal_bits;

    // Reinterpret the 9-bit signed characteristic as a 9-bit unsigned vector
    assign characteristic_bits = characteristic;

    // Invert the low 8 bits when D=0 (negative characteristic)
    always_comb begin
        if (direction_bit == 1'b1) begin
            characteristic_normal_bits = characteristic_bits[7:0];   // Positive: use as-is
        end else begin
            characteristic_normal_bits = ~characteristic_bits[7:0];  // Negative: invert
        end
        characteristic_precursor = characteristic_normal_bits + 8'd1;  // +1 to normalize
    end

    // ── Detect leading one (LOD) ───────────────────────────────────────
    // The regime R is determined by the position of the leading (leftmost)
    // one bit in the 8-bit characteristic precursor.  This is a leading-
    // one detector (LOD) implemented as a two-stage LUT approach for
    // efficient hardware:
    //   1. Split the 8-bit input into two 4-bit nibbles.
    //   2. Find the leading-one position within each nibble using lod4.
    //   3. If the high nibble is nonzero, R = 4 + leading_one_high_nibble.
    //      If the high nibble is zero, R = leading_one_low_nibble.
    //
    // This yields R in the range 0..7, matching the 3-bit regime field.
    logic [7:0] lod_input;
    logic [2:0] leading_one_offset;
    logic [1:0] lod4_low;
    logic [1:0] lod4_high;

    // 4-bit leading-one position detector.
    // Returns the bit index (0..3) of the leftmost set bit.
    // If no bit is set (0000), returns 0 (which will be corrected
    // by the outer logic since the precursor is always nonzero).
    function automatic logic [1:0] lod4(input logic [3:0] v);
        casez (v)
            4'b1???:  lod4 = 2'd3;   // Bit 3 is the leading one
            4'b01??:  lod4 = 2'd2;   // Bit 2 is the leading one
            4'b001?:  lod4 = 2'd1;   // Bit 1 is the leading one
            4'b0001:  lod4 = 2'd0;   // Bit 0 is the leading one
            default:  lod4 = 2'd0;   // Should not occur for valid precursor
        endcase
    endfunction

    assign lod_input = characteristic_precursor;

    always_comb begin : detect_leading_one
        lod4_low  = lod4(lod_input[3:0]);    // Leading-one position in low nibble
        lod4_high = lod4(lod_input[7:4]);    // Leading-one position in high nibble

        if (lod_input[7:4] == 4'b0000)
            // High nibble zero: leading one is in the low nibble
            leading_one_offset = {1'b0, lod4_low};
        else
            // High nibble nonzero: leading one is in the high nibble,
            // offset by 4 positions
            leading_one_offset = {1'b1, lod4_high};
    end

    // The regime is the leading-one offset: R = position of leading one
    assign regime = leading_one_offset;

    // ── Generate extended takum ────────────────────────────────────────
    // Now we assemble the takum bit pattern.  The regime bits and
    // explicit characteristic bits are conditionally inverted based on
    // the direction bit D, then combined with the mantissa and shifted.
    //
    // The encoding rules:
    //   - If D=0 (negative): regime bits are inverted (~R), and
    //     the explicit characteristic bits are inverted (~precursor[6:0]).
    //   - If D=1 (positive): regime bits are R, and the explicit
    //     characteristic bits are precursor[6:0] directly.
    //
    // The assembled bit stream is:
    //   characteristic_bits_out(7) mantissa_bits(N-5) 7_zeros
    // then right-shifted by R to align the regime and characteristic
    // into the correct positions within the N-bit takum word.
    logic [2:0] regime_bits;
    logic [6:0] characteristic_bits_out;

    always_comb begin : set_regime_and_characteristic_raw_bits
        if (direction_bit == 1'b0) begin
            // Negative direction: invert both regime and characteristic bits
            regime_bits             = ~regime;
            characteristic_bits_out = ~characteristic_precursor[6:0];
        end else begin
            // Positive direction: use regime and characteristic directly
            regime_bits             = regime;
            characteristic_bits_out = characteristic_precursor[6:0];
        end
    end

    // Concatenate characteristic bits, mantissa bits, and 7 zero-padding
    // bits, then right-shift by regime to place the bits in their final
    // positions.  The 7 zero-padding bits serve as "rounding room" for
    // the round-to-nearest-even logic.
    //
    // Total concat width: 7 (characteristic) + (N-5) (mantissa) + 7 (zeros) = N+9 bits.
    // After shifting right by R, the N-bit result sits at positions [N+6:7]
    // of the (N+7)-bit extended_takum, with positions [6:0] providing
    // the guard bit and sticky bits for rounding.
    /* verilator lint_off WIDTHEXPAND */
    logic [N+8:0] concat_bits;
    logic [N+8:0] characteristic_mantissa_bits_shifted;

    always_comb begin
        concat_bits = {characteristic_bits_out, mantissa_bits, 7'b0};
        characteristic_mantissa_bits_shifted = concat_bits >> regime;
    end
    /* verilator lint_on WIDTHEXPAND */

    // Assemble extended takum: sign(1) + direction(1) + regime_bits(3) +
    // shifted result.  The shifted result contributes bits [N+1:0] which
    // contain the N-bit encoded word at [N+6:7] after assembly (the
    // top bits of extended_takum come from sign, direction, regime).
    assign extended_takum = {sign_bit, direction_bit, regime_bits,
                              characteristic_mantissa_bits_shifted[N+1:0]};

    // ── Round to nearest even ──────────────────────────────────────────
    //
    // ROUND-TO-NEAREST-EVEN ALGORITHM:
    //
    // The extended_takum word has more bits than the final N-bit takum.
    // We extract:
    //   - takum_rounded_down = extended_takum[N+6:7]   (truncated N-bit value)
    //   - guard bit          = extended_takum[6]        (first bit beyond N)
    //   - sticky bits        = extended_takum[5:0]      (remaining bits)
    //   - LSB of result      = extended_takum[7]        (ties: round to even)
    //
    // Decision table:
    //   guard=0:  round DOWN (truncated value is closest)
    //   guard=1, sticky!=0:  round UP (next value is closest)
    //   guard=1, sticky=0, LSB=1: round UP (tie, make LSB even)
    //   guard=1, sticky=0, LSB=0: round DOWN (tie, already even)
    //
    // Exceptions:
    //   - If round_down_underflows: force round UP (can't go lower)
    //   - If round_up_overflows: force round DOWN (can't go higher)
    //
    logic [N-1:0] takum_rounded_up;
    logic [N-1:0] takum_rounded_down;
    logic       is_rest_zero;

    // The truncated (rounded-down) value: the N most significant bits
    // of the extended takum, excluding the guard and sticky bits.
    assign takum_rounded_down = extended_takum[N+6:7];

    // The rounded-up value: truncated value + 1.  This may overflow if
    // the truncated value is already at its maximum, but that case
    // is caught by round_up_overflows.
    assign takum_rounded_up = unsigned'(extended_takum[N+6:7]) + 1'b1;

    // Check whether all sticky bits are zero.  When guard=1 and sticky=0,
    // we have a tie (exactly halfway), and we round to even (check LSB).
    assign is_rest_zero = (extended_takum[5:0] == 6'b000000);

    // Round-to-nearest-even decision:
    //   Round UP when:
    //     1. Rounding down would underflow (round_down_underflows), OR
    //     2. Guard bit is set AND (sticky bits are nonzero OR LSB is 1),
    //        AND rounding up does not overflow.
    //   Otherwise, round DOWN.
    //
    //   In other words:
    //     guard=0 → round down (nearest is the truncated value)
    //     guard=1, sticky≠0 → round up (next value is strictly closer)
    //     guard=1, sticky=0, LSB=1 → round up (tie, round to even)
    //     guard=1, sticky=0, LSB=0 → round down (tie, already even)
    //     Exception: if rounding down underflows, force round up
    //     Exception: if rounding up overflows, force round down
    always_comb begin : round
        if (round_down_underflows ||
            (!round_up_overflows && extended_takum[6] && (!is_rest_zero || extended_takum[7]))) begin
            takum_rounded = takum_rounded_up;
        end else begin
            takum_rounded = takum_rounded_down;
        end
    end

    // ── Drive output ──────────────────────────────────────────────────
    // Special cases override the rounded value:
    //   - Zero: all bits zero (this is the bit pattern 0...0)
    //   - NaR: MSB=1, all other bits zero (bit pattern 10...0)
    // These are the two reserved bit patterns in the takum format.
    always_comb begin : drive_output
        if (is_zero || is_nar) begin
            takum = '0;
            takum[N-1] = is_nar;  // NaR: MSB=1, rest=0; Zero: all zeros
        end else begin
            takum = takum_rounded;
        end
    end

endmodule