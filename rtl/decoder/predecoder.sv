// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/decoder/predecoder.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Predecoder: extracts sign, characteristic/exponent, mantissa, precision,
// and special-case flags from an n-bit takum word.
//
// Parameters:
//   N               - bit width of the takum word (>=2)
//   OUTPUT_EXPONENT - 0: output characteristic; 1: output exponent
//                      The difference is only a conditional negation,
//                      at zero hardware cost.

module predecoder #(
    parameter int N               = 16,
    parameter bit OUTPUT_EXPONENT = 1'b0
) (
    input  logic [N-1:0]  takum,
    output logic            sign_bit,
    output logic signed [8:0] characteristic_or_exponent,  // range -255..254
    output logic [N-6:0]   mantissa_bits,
    output logic [$clog2(N-4)-1:0] precision,              // 0..N-5
    output logic            is_zero,
    output logic            is_nar
);

    // ── Internal signals ─────────────────────────────────────────────
    logic       direction_bit;
    logic [9:0] regime_characteristic_segment;
    logic [2:0] regime_bits;
    logic [2:0] regime;        // unsigned 0..7
    logic [2:0] antiregime;    // = 7 - regime
    logic [6:0] characteristic_raw_bits;

    logic signed [8:0] characteristic_raw_normal_s;  // "10" prepended to raw (signed, for arith shift)
    logic signed [8:0] characteristic_precursor_s;   // signed, shifted right by antiregime
    logic [8:0] characteristic_precursor;             // unsigned view of precursor
    logic [8:0] characteristic_normal_9bit;           // {1'b1, precursor[7:0]+1}
    logic signed [8:0] characteristic_normal_signed9;

    // ── Sign bit ──────────────────────────────────────────────────────
    assign sign_bit = takum[N-1];

    // ── Direction bit ─────────────────────────────────────────────────
    assign direction_bit = takum[N-2];

    // ── Extract 10-bit regime + characteristic segment ────────────────
    // For N >= 12: bits [N-3 : N-12] (10 bits)
    // For N <  12: take available bits, zero-pad on the right (ghost bits)
    generate
        if (N >= 12) begin : gen_segment_full
            assign regime_characteristic_segment = takum[N-3 -: 10];
        end else begin : gen_segment_padded
            logic [9:0] padded;
            always_comb begin
                padded = '0;
                padded[N-3:0] = takum[N-3:0];
            end
            assign regime_characteristic_segment = padded;
        end
    endgenerate

    // ── Regime bits and regime/antiregime ─────────────────────────────
    assign regime_bits = regime_characteristic_segment[9:7];

    always_comb begin : determine_regime_antiregime
        if (direction_bit == 1'b0) begin
            regime     = ~regime_bits;
            antiregime = regime_bits;
        end else begin
            regime     = regime_bits;
            antiregime = ~regime_bits;
        end
    end

    // ── Characteristic raw bits ───────────────────────────────────────
    assign characteristic_raw_bits = regime_characteristic_segment[6:0];

    // ── Determine characteristic or exponent ───────────────────────────
    // Step 1: conditionally invert raw bits based on direction_bit
    // VHDL uses signed shift_right, so we must work with signed values
    always_comb begin
        if (direction_bit == 1'b0) begin
            characteristic_raw_normal_s = $signed({2'b10, characteristic_raw_bits});
        end else begin
            characteristic_raw_normal_s = $signed({2'b10, ~characteristic_raw_bits});
        end
    end

    // Step 2: arithmetic right shift by antiregime (matches VHDL shift_right(signed(...)))
    assign characteristic_precursor_s = characteristic_raw_normal_s >>> antiregime;
    assign characteristic_precursor = unsigned'(characteristic_precursor_s);

    // Step 3: increment first 8 bits and prepend leading 1
    // VHDL: characteristic_normal <= "1" & std_ulogic_vector(unsigned(characteristic_precursor(7 downto 0)) + 1)
    wire [7:0] precursor_low_plus1 = unsigned'(characteristic_precursor[7:0]) + 8'd1;
    assign characteristic_normal_9bit = {1'b1, precursor_low_plus1};
    assign characteristic_normal_signed9 = $signed(characteristic_normal_9bit);

    // Step 4: conditional negation based on direction_bit vs OUTPUT_EXPONENT
    // VHDL rtl arch line 115-116:
    //   characteristic_or_exponent <= to_integer(signed(characteristic_normal))
    //     when direction_bit = output_exponent else
    //     to_integer(signed(not characteristic_normal));
    always_comb begin
        characteristic_or_exponent = characteristic_normal_signed9;
        if (direction_bit != OUTPUT_EXPONENT) begin
            characteristic_or_exponent = ~characteristic_normal_signed9;
        end
    end

    // ── Mantissa bits ──────────────────────────────────────────────────
    // VHDL: std_ulogic_vector(shift_left(unsigned(takum(n - 6 downto 0)), regime))
    always_comb begin
        mantissa_bits = unsigned'(takum[N-6:0]) << regime;
    end

    // ── Precision ─────────────────────────────────────────────────────
    // precision = (N-5) - regime when regime < N-5, else 0
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