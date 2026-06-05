// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/postencoder.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Postencoder: encodes (sign, characteristic, mantissa, is_zero, is_nar)
// into an n-bit takum word. Includes round-to-nearest-even with
// underflow/overflow prediction.

module postencoder #(
    parameter int N = 16
) (
    input  logic            sign_bit,
    input  logic signed [8:0] characteristic,   // -255..254
    input  logic [N-6:0]   mantissa_bits,
    input  logic            is_zero,
    input  logic            is_nar,
    output logic [N-1:0]   takum
);

    // ── Internal signals ─────────────────────────────────────────────
    logic       direction_bit;
    logic [7:0] characteristic_precursor;
    logic [2:0] regime;          // 0..7
    logic [N+6:0] extended_takum;
    logic [N-1:0] takum_rounded;
    logic       round_up_overflows;
    logic       round_down_underflows;

    // ── Direction bit: 1 when characteristic >= 0 ─────────────────────
    assign direction_bit = ~characteristic[8];

    // ── Predict underflow/overflow ────────────────────────────────────
    // Precomputed bounds for N in {2..11}, indexed by (N-2)
    // For N >= 12: check mantissa boundaries at characteristic extremes
    function automatic int get_underflow_bound(input int n);
        case (n)
            2:  get_underflow_bound = -1;
            3:  get_underflow_bound = -16;
            4:  get_underflow_bound = -64;
            5:  get_underflow_bound = -128;
            6:  get_underflow_bound = -192;
            7:  get_underflow_bound = -224;
            8:  get_underflow_bound = -240;
            9:  get_underflow_bound = -248;
            10: get_underflow_bound = -252;
            11: get_underflow_bound = -254;
            default: get_underflow_bound = 0;
        endcase
    endfunction

    function automatic int get_overflow_bound(input int n);
        case (n)
            2:  get_overflow_bound = 0;
            3:  get_overflow_bound = 15;
            4:  get_overflow_bound = 63;
            5:  get_overflow_bound = 127;
            6:  get_overflow_bound = 191;
            7:  get_overflow_bound = 223;
            8:  get_overflow_bound = 239;
            9:  get_overflow_bound = 247;
            10: get_overflow_bound = 251;
            11: get_overflow_bound = 253;
            default: get_overflow_bound = 0;
        endcase
    endfunction

    // Mantissa crop signals for N > 11
    logic [N-12:0] mantissa_bits_crop;
    logic [N-12:0] mantissa_bits_crop_zero;
    logic [N-12:0] mantissa_bits_crop_one;

    always_comb begin : check_characteristic
        if (N <= 11) begin
            if ($signed(characteristic) <= $signed(9'(get_underflow_bound(N))))
                round_down_underflows = 1'b1;
            else
                round_down_underflows = 1'b0;

            if ($signed(characteristic) >= $signed(9'(get_overflow_bound(N))))
                round_up_overflows = 1'b1;
            else
                round_up_overflows = 1'b0;
        end else begin
            // For N > 11: check mantissa boundary conditions
            // mantissa_bits_crop = mantissa_bits[N-6 : 6] (N-11 bits)
            mantissa_bits_crop      = mantissa_bits[N-6 -: (N-11)];
            mantissa_bits_crop_zero = '0;
            mantissa_bits_crop_one  = {(N-11){1'b1}};

            if (mantissa_bits_crop == mantissa_bits_crop_zero) begin
                if (characteristic == 9'sd255)
                    round_down_underflows = 1'b1;  // -255 with all-zero crop => underflow
                else
                    round_down_underflows = 1'b0;
            end else begin
                round_down_underflows = 1'b0;
            end

            if (mantissa_bits_crop == mantissa_bits_crop_one) begin
                if (characteristic == 9'sd254)
                    round_up_overflows = 1'b1;    // 254 with all-one crop => overflow
                else
                    round_up_overflows = 1'b0;
            end else begin
                round_up_overflows = 1'b0;
            end
        end
    end

    // ── Determine characteristic precursor ─────────────────────────────
    logic [8:0] characteristic_bits;
    logic [7:0] characteristic_normal_bits;

    // Reinterpret signed[8:0] as 9-bit vector
    assign characteristic_bits = characteristic;

    // Invert based on direction bit; +1 to get precursor
    always_comb begin
        if (direction_bit == 1'b1) begin
            characteristic_normal_bits = characteristic_bits[7:0];
        end else begin
            characteristic_normal_bits = ~characteristic_bits[7:0];
        end
        characteristic_precursor = characteristic_normal_bits + 8'd1;
    end

    // ── Detect leading one (LOD) ───────────────────────────────────────
    // 8-input leading one detector using 2-stage LUT approach
    logic [7:0] lod_input;
    logic [2:0] leading_one_offset;
    logic [1:0] lod4_low;
    logic [1:0] lod4_high;

    // LUT: 4-bit leading-one position
    function automatic logic [1:0] lod4(input logic [3:0] v);
        casez (v)
            4'b1???:  lod4 = 2'd3;
            4'b01??:  lod4 = 2'd2;
            4'b001?:  lod4 = 2'd1;
            4'b0001:  lod4 = 2'd0;
            default:  lod4 = 2'd0;
        endcase
    endfunction

    assign lod_input = characteristic_precursor;

    always_comb begin : detect_leading_one
        lod4_low  = lod4(lod_input[3:0]);
        lod4_high = lod4(lod_input[7:4]);

        if (lod_input[7:4] == 4'b0000)
            leading_one_offset = {1'b0, lod4_low};
        else
            leading_one_offset = {1'b1, lod4_high};
    end

    assign regime = leading_one_offset;

    // ── Generate extended takum ────────────────────────────────────────
    logic [2:0] regime_bits;
    logic [6:0] characteristic_bits_out;

    always_comb begin : set_regime_and_characteristic_raw_bits
        if (direction_bit == 1'b0) begin
            regime_bits             = ~regime;
            characteristic_bits_out = ~characteristic_precursor[6:0];
        end else begin
            regime_bits             = regime;
            characteristic_bits_out = characteristic_precursor[6:0];
        end
    end

    // Concatenate and shift right by regime
    // VHDL: shift_right(unsigned(characteristic_bits & mantissa_bits & (6 downto 0 => '0')), regime)
    // (6 downto 0 => '0') = 7 zeros, NOT 6
    // Total width: 7 (char_bits) + (N-5) (mantissa) + 7 (padding) = N+9 bits
    /* verilator lint_off WIDTHEXPAND */
    logic [N+8:0] concat_bits;
    logic [N+8:0] characteristic_mantissa_bits_shifted;

    always_comb begin
        concat_bits = {characteristic_bits_out, mantissa_bits, 7'b0};
        characteristic_mantissa_bits_shifted = concat_bits >> regime;
    end
    /* verilator lint_on WIDTHEXPAND */

    // Assemble extended takum: sign & direction & regime_bits & shifted result
    assign extended_takum = {sign_bit, direction_bit, regime_bits,
                              characteristic_mantissa_bits_shifted[N+1:0]};

    // ── Round to nearest even ──────────────────────────────────────────
    logic [N-1:0] takum_rounded_up;
    logic [N-1:0] takum_rounded_down;
    logic       is_rest_zero;

    // truncated value (bits [N+6:7] of extended_takum)
    assign takum_rounded_down = extended_takum[N+6:7];

    // rounded-up value
    assign takum_rounded_up = unsigned'(extended_takum[N+6:7]) + 1'b1;

    // check if rest bits are all zero
    assign is_rest_zero = (extended_takum[5:0] == 6'b000000);

    // Round-up condition (round-to-nearest-even)
    always_comb begin : round
        if (round_down_underflows ||
            (!round_up_overflows && extended_takum[6] && (!is_rest_zero || extended_takum[7]))) begin
            takum_rounded = takum_rounded_up;
        end else begin
            takum_rounded = takum_rounded_down;
        end
    end

    // ── Drive output ──────────────────────────────────────────────────
    always_comb begin : drive_output
        if (is_zero || is_nar) begin
            takum = '0;
            takum[N-1] = is_nar;  // NaR: MSB=1, rest=0; Zero: all zeros
        end else begin
            takum = takum_rounded;
        end
    end

endmodule