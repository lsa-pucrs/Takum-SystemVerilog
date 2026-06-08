// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/predecoder.vhd
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
//                  where c_explicit is the decoded bits from the
//                  characteristic field (MSB-first, up to 7 bits).
//   mantissa     – Variable-width fraction (precision = (N-5) - R).
//
// Special values:
//   Zero: all N bits are 0.
//   NaR (Not a Real): bit N-1 = 1, bits N-2..0 all zero.
//
// =============================================================================
// PREDECODER MODULE
// =============================================================================
//
// The predecoder extracts the fundamental components from an N-bit takum
// word: sign, characteristic (or base-2 exponent), mantissa bits,
// mantissa precision, and special-case flags (is_zero, is_nar).
//
// It is the shared front-end used by both the linear and logarithmic
// decoder variants.  The parameter OUTPUT_EXPONENT selects whether the
// output is the *characteristic* (c) or the *base-2 exponent* (e).
// The only difference is a conditional negation of the result, which
// costs zero additional hardware — explained in detail below.
//
// Characteristic vs. exponent:
//   characteristic c : the signed integer directly encoded in the takum
//                      word, as decoded above.
//   exponent e       : the base-2 exponent such that the represented
//                      value = sign * 2^e * (1 + mantissa).
//                      For positive numbers (sign=0): e = c
//                      For negative numbers (sign=1): e = -c - 1
//                      In other words, e = (-1)^(1-sign) * (c + sign).
//                      However, a simpler hardware formulation is:
//                        e = c when direction_bit == OUTPUT_EXPONENT
//                        e = ~c otherwise (bitwise complement = negation-1)
// =============================================================================

module predecoder #(
    parameter int N               = 16,     // Bit width of the takum word (>= 2)
    parameter bit OUTPUT_EXPONENT = 1'b0    // 0: output characteristic; 1: output exponent
) (
    // The N-bit takum word to decode
    input  logic [N-1:0]  takum,

    // Sign bit (1 = negative, 0 = positive) — directly extracted from takum[N-1]
    output logic            sign_bit,

    // Characteristic or base-2 exponent (signed, 9-bit, range -255..254).
    // See OUTPUT_EXPONENT: 0 => signed characteristic c; 1 => base-2 exponent e.
    // Formulas:
    //   D=1: c = 2^R - 1 + c_explicit    (positive characteristic)
    //   D=0: c = -(2^(R+1)) + 1 + c_explicit  (negative characteristic)
    //   e = c  if direction_bit == OUTPUT_EXPONENT, else e = ~c
    output logic signed [8:0] characteristic_or_exponent,

    // Mantissa bits, left-aligned (shifted left by R positions so the
    // MSB of the significand field is at bit N-6).  Width = N-5 bits
    // (= (N-5) - 0, the full precision slot before regime trimming).
    output logic [N-6:0]   mantissa_bits,

    // Number of valid mantissa bits: precision = max(0, (N-5) - R).
    // This tells the consumer how many low-order bits of mantissa_bits
    // are meaningful; the rest are zero-padded due to the left-shift.
    output logic [$clog2(N-4)-1:0] precision,

    // Special-case flags
    output logic            is_zero,   // All bits of takum are zero
    output logic            is_nar     // MSB=1, all other bits zero (Not a Real)
);

    // ── Internal signals ─────────────────────────────────────────────

    // Direction bit: the second-most-significant bit of the takum word.
    // D=1 indicates a non-negative characteristic; D=0 indicates a
    // negative characteristic.  This bit controls whether the regime and
    // characteristic bits are interpreted directly or inverted.
    logic       direction_bit;

    // The 10-bit segment containing regime (3 bits) + characteristic (7 bits).
    // For N>=12 this is bits [N-3:N-12].  For N<12, the takum word is
    // shorter than 10 bits after sign+direction, so we zero-pad on the
    // right ("ghost bits"); these ghost bits behave as if the
    // characteristic field were all zeros.
    logic [9:0] regime_characteristic_segment;

    // Raw regime field bits (3 bits) extracted from the MSBs of the
    // regime+characteristic segment.  These may be inverted depending
    // on the direction bit to obtain the actual regime value.
    logic [2:0] regime_bits;

    // The decoded regime value R (0..7).  When D=0, the raw bits are
    // inverted (antiregime becomes the regime).  R controls how many
    // explicit characteristic bits are active and how many mantissa
    // bits are shifted away.
    logic [2:0] regime;

    // The antiregime = 7 - R.  This is used as the arithmetic right-shift
    // amount for decoding the characteristic: lower regime values mean
    // more explicit characteristic bits are significant, so we shift
    // right by more positions (antiregime) to discard the inactive
    // low-order bits.
    logic [2:0] antiregime;

    // The 7 explicit characteristic bits from the bit stream.  Only the
    // top (7 - antiregime) = R of these carry meaningful information;
    // the rest are inactive "don't care" bits that will be shifted away.
    logic [6:0] characteristic_raw_bits;

    // Step 1 of characteristic decoding: the raw (or complemented) bits
    // are prepended with "10" (binary) to form a 9-bit signed value.
    // The "10" prefix ensures that the arithmetic right-shift in step 2
    // correctly sign-extends the result.  This works because:
    //   - For D=1 (positive): we use raw bits as-is, "10" provides
    //     a leading 1 so the shift preserves the value.
    //   - For D=0 (negative): we use ~raw_bits (one's complement of
    //     the explicit bits), and "10" again provides the sign bit.
    logic signed [8:0] characteristic_raw_normal_s;

    // Step 2 result: the 9-bit signed value from step 1, arithmetically
    // right-shifted by antiregime.  This isolates the R active
    // characteristic bits and discards the inactive low-order bits.
    logic signed [8:0] characteristic_precursor_s;

    // Unsigned view of the precursor, needed for the increment step.
    logic [8:0] characteristic_precursor;

    // Step 3 result: after shifting, we increment the low 8 bits and
    // prepend a 1.  This produces the "normal form" of the characteristic.
    // The +1 compensates for the fact that the "10" prefix contributed
    // a value of 2^(7+1) = 256 during the shift, and the true
    // characteristic formula has a -1 offset (for D=1) or an offset
    // that varies (for D=0).  The net effect: characteristic_normal
    // already encodes the correct value.
    logic [8:0] characteristic_normal_9bit;

    // Signed version of characteristic_normal, for the final conditional
    // negation step that selects characteristic vs. exponent output.
    logic signed [8:0] characteristic_normal_signed9;

    // ── Sign bit ──────────────────────────────────────────────────────
    // The sign bit is simply the MSB of the takum word.
    // 0 = positive value, 1 = negative value.
    assign sign_bit = takum[N-1];

    // ── Direction bit ─────────────────────────────────────────────────
    // The direction bit is the second-most-significant bit.
    // D=1: characteristic is non-negative (regime bits used directly).
    // D=0: characteristic is negative (regime bits are inverted).
    assign direction_bit = takum[N-2];

    // ── Extract 10-bit regime + characteristic segment ────────────────
    // The top 10 bits after sign+direction contain the regime (3 bits)
    // and the explicit characteristic (7 bits).  For small N (<12),
    // the characteristic field is shorter than 7 bits; missing bits
    // are "ghost bits" that are zero, so we zero-pad on the right.
    generate
        if (N >= 12) begin : gen_segment_full
            // Full extraction: bits [N-3 : N-12] give us 10 bits
            assign regime_characteristic_segment = takum[N-3 -: 10];
        end else begin : gen_segment_padded
            // Short takum (N<12): the regime+characteristic field is shorter
            // than 10 bits.  The takum bits are MSB-aligned at the top of the
            // segment and the missing low bits are ghost zeros, exactly as the
            // VHDL: takum(n-3 downto 0) & (11-n downto 0 => '0').
            //   width = (N-2) takum bits + (12-N) zero bits = 10 bits.
            assign regime_characteristic_segment = { takum[N-3:0], {(12-N){1'b0}} };
        end
    endgenerate

    // ── Regime bits and regime/antiregime ─────────────────────────────
    // The regime is encoded in the top 3 bits of the segment.  When D=0
    // (negative characteristic), the bits are stored inverted; we
    // complement them to recover the true regime R.  When D=1, the
    // bits are used directly.  The antiregime is always 7-R.
    assign regime_bits = regime_characteristic_segment[9:7];

    always_comb begin : determine_regime_antiregime
        if (direction_bit == 1'b0) begin
            // Negative direction: regime bits are inverted in the encoding
            regime     = ~regime_bits;
            antiregime = regime_bits;   // = 7 - (~regime_bits) = regime_bits
        end else begin
            // Positive direction: regime bits are direct
            regime     = regime_bits;
            antiregime = ~regime_bits;  // = 7 - regime_bits
        end
    end

    // ── Characteristic raw bits ───────────────────────────────────────
    // The 7 explicit characteristic bits sit in positions [6:0] of the
    // 10-bit regime+characteristic segment.  Only R of these are
    // "active" (meaningful); the lower (7-R) = antiregime bits are
    // inactive and will be removed by the arithmetic right-shift below.
    assign characteristic_raw_bits = regime_characteristic_segment[6:0];

    // ── Determine characteristic or exponent ───────────────────────────
    //
    // The characteristic is decoded in four steps:
    //
    // Step 1: Prepend "10" and optionally complement.
    //   For D=1: we form {2'b10, characteristic_raw_bits} = a 9-bit
    //            value where the "10" acts as a sign/normalization prefix.
    //   For D=0: we form {2'b10, ~characteristic_raw_bits} because the
    //            negative direction stores the characteristic bits inverted.
    //
    //   The "10" prefix ensures the arithmetic right-shift in step 2
    //   correctly preserves the value structure (it provides a leading 1
    //   so that sign-extension during the shift maintains the proper
    //   magnitude).
    //
    always_comb begin
        if (direction_bit == 1'b0) begin
            characteristic_raw_normal_s = $signed({2'b10, characteristic_raw_bits});
        end else begin
            characteristic_raw_normal_s = $signed({2'b10, ~characteristic_raw_bits});
        end
    end

    // Step 2: Arithmetic right-shift by antiregime.
    //   This discards the inactive low-order bits, leaving only the
    //   R active characteristic bits in the correct position.  An
    //   arithmetic shift is essential to preserve the sign established
    //   by the "10" prefix.
    assign characteristic_precursor_s = characteristic_raw_normal_s >>> antiregime;
    assign characteristic_precursor = unsigned'(characteristic_precursor_s);

    // Step 3: Increment and prepend leading 1.
    //   After the shift, we add 1 to the low 8 bits and prepend a 1.
    //   This completes the characteristic decoding.  The +1 compensates
    //   for the implicit offset in the takum encoding:
    //     D=1: c = 2^R - 1 + c_explicit  (the "-1" is absorbed here)
    //     D=0: c = -(2^(R+1)) + 1 + c_explicit
    //   The "1" prepended to the incremented value encodes the 2^R (for
    //   D=1) or 2^(R+1) (for D=0) term from the characteristic formula.
    wire [7:0] precursor_low_plus1 = unsigned'(characteristic_precursor[7:0]) + 8'd1;
    assign characteristic_normal_9bit = {1'b1, precursor_low_plus1};
    assign characteristic_normal_signed9 = $signed(characteristic_normal_9bit);

    // Step 4: Conditional negation for characteristic vs. exponent.
    //   The predecoder can output either the characteristic (c) or the
    //   base-2 exponent (e).  The relationship is:
    //     e = c  when direction_bit != OUTPUT_EXPONENT
    //     e = ~c when direction_bit == OUTPUT_EXPONENT
    //   (where ~c is bitwise complement, equivalent to -c-1 in two's
    //   complement, which gives the correct exponent mapping).
    //
    //   For the LINEAR decoder (OUTPUT_EXPONENT=1):
    //     - Positive values (sign=0): e = c (direction_bit=1, so
    //       direction_bit != OUTPUT_EXPONENT → output = c)
    //     - Negative values (sign=1): e = ~c (direction_bit=0, so
    //       direction_bit == OUTPUT_EXPONENT → output = ~c)
    //     This yields the base-2 exponent needed for linear arithmetic.
    //
    //   For the LOGARITHMIC decoder (OUTPUT_EXPONENT=0):
    //     - Output is always the characteristic c, with no negation
    //       applied (since OUTPUT_EXPONENT=0 and direction_bit may be
    //       0 or 1, the condition only inverts when D=1).
    always_comb begin
        characteristic_or_exponent = characteristic_normal_signed9;
        if (direction_bit != OUTPUT_EXPONENT) begin
            characteristic_or_exponent = ~characteristic_normal_signed9;
        end
    end

    // ── Mantissa bits ──────────────────────────────────────────────────
    // The mantissa field occupies bits [N-6 : 0] of the takum word.
    // However, regime R bits of this field are "consumed" by the
    // explicit characteristic.  We left-shift by R to align the
    // mantissa to the top of the field, pushing out the regime-worth
    // of characteristic bits on the left and zero-filling from the
    // right.  The result is a left-aligned mantissa with
    // precision = (N-5) - R meaningful bits.
    always_comb begin
        mantissa_bits = unsigned'(takum[N-6:0]) << regime;
    end

    // ── Precision ─────────────────────────────────────────────────────
    // Precision = number of valid mantissa bits = max(0, (N-5) - R).
    // When R >= N-5, the mantissa has been entirely consumed by the
    // characteristic, so precision is 0 (the value is an exact power of
    // two — no fractional bits remain).
    /* verilator lint_off WIDTHEXPAND */
    /* verilator lint_off WIDTHTRUNC */
    always_comb begin
        if (regime < N - 5)
            precision = N - 5 - $unsigned(regime);
        else
            precision = '0;
    end
    /* verilator lint_on WIDTHEXPAND */
    /* verilator lint_on WIDTHTRUNC */

    // ── Special case detection ─────────────────────────────────────────
    // Zero:  all N bits are 0.
    // NaR:   bit [N-1] = 1 and bits [N-2:0] are all 0.
    // These are the two reserved bit patterns in the takum format.
    always_comb begin : detect_special_cases
        is_zero = 1'b0;
        is_nar  = 1'b0;
        if (takum == '0) begin
            is_zero = 1'b1;
        end else if (takum[N-1] == 1'b1 && takum[N-2:0] == '0) begin
            is_nar = 1'b1;
        end
    end

endmodule