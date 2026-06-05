// See LICENSE file for copyright and license details
// SystemVerilog conversion of simulation/decoder/predecoder_tb.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Exhaustive testbench for predecoder: instantiates the RTL predecoder
// and checks all 2^N takum values against a behavioral reference model.

`timescale 1ns / 1ps

// ── Behavioral reference model (matches VHDL 'behave' architecture) ──
module predecoder_behave #(
    parameter int N               = 16,
    parameter bit OUTPUT_EXPONENT = 1'b0
) (
    input  logic [N-1:0]  takum,
    output logic            sign_bit,
    output logic signed [8:0] characteristic_or_exponent,
    output logic [N-6:0]   mantissa_bits,
    output logic [$clog2(N-4)-1:0] precision,
    output logic            is_zero,
    output logic            is_nar
);

    // 11-bit prefix consisting of direction bit, 3 regime bits,
    // and 7 subsequent bits for all possible characteristic lengths 0-7
    logic [10:0] prefix;
    logic        direction_bit;
    logic [2:0]  regime_bits;
    logic [2:0]  regime;
    logic [6:0]  characteristic_explicit;
    logic [$clog2(N-4)-1:0] precision_internal;
    logic [N-6:0] zeros;

    assign zeros     = '0;
    assign sign_bit  = takum[N-1];

    // Build 11-bit prefix: direction_bit + regime_bits + 7 characteristic bits
    // VHDL: prefix <= takum(n-2 downto n-12) [for n >= 12]
    always_comb begin
        prefix = '0;
        if (N >= 12) begin
            prefix = takum[N-2 -: 11];  // bits [N-2 : N-12]
        end else begin
            prefix[N-2:0] = takum[N-2:0];
            // Upper bits remain zero (ghost bits)
        end
    end

    assign direction_bit = prefix[10];
    assign regime_bits   = prefix[9:7];

    // Determine regime: if D=0, regime = 7 - unsigned(R); if D=1, regime = unsigned(R)
    always_comb begin
        if (direction_bit == 1'b0)
            regime = 7 - unsigned'(regime_bits);
        else
            regime = unsigned'(regime_bits);
    end

    // Extract characteristic explicit bits: prefix[6 -: regime]
    // Width = regime bits (0..7)
    always_comb begin
        characteristic_explicit = '0;
        case (regime)
            3'd0: characteristic_explicit = 7'd0;
            3'd1: characteristic_explicit = {6'b0, prefix[6]};
            3'd2: characteristic_explicit = {5'b0, prefix[6:5]};
            3'd3: characteristic_explicit = {4'b0, prefix[6:4]};
            3'd4: characteristic_explicit = {3'b0, prefix[6:3]};
            3'd5: characteristic_explicit = {2'b0, prefix[6:2]};
            3'd6: characteristic_explicit = {1'b0, prefix[6:1]};
            3'd7: characteristic_explicit = prefix[6:0];
            default: characteristic_explicit = 7'd0;
        endcase
    end

    // Determine characteristic or exponent
    always_comb begin
        if (direction_bit == OUTPUT_EXPONENT) begin
            // -2^(regime+1) + 1 + characteristic_explicit
            characteristic_or_exponent = -(2 ** (unsigned'(regime) + 1)) + 1 + $signed({2'b0, characteristic_explicit});
        end else begin
            // 2^regime - 1 + characteristic_explicit
            characteristic_or_exponent = (2 ** unsigned'(regime)) - 1 + $signed({2'b0, characteristic_explicit});
        end
    end

    // Determine precision
    always_comb begin
        if (unsigned'(regime) >= N - 5)
            precision_internal = '0;
        else
            precision_internal = N - 5 - unsigned'(regime);
    end
    assign precision = precision_internal;

    // Determine mantissa bits
    always_comb begin
        if (precision_internal == '0) begin
            mantissa_bits = '0;
        end else begin
            mantissa_bits = unsigned'(takum[N-6:0]) << unsigned'(regime);
        end
    end

    // Special cases
    always_comb begin
        is_zero = 1'b0;
        is_nar  = 1'b0;
        if (takum == '0) begin
            is_zero = 1'b1;
        end else if (takum[N-1] == 1'b1 && takum[N-2:0] == '0) begin
            is_nar = 1'b1;
        end
    end

endmodule


// ── Testbench ────────────────────────────────────────────────────────
module predecoder_tb;

    parameter int N = 16;

    logic            clock;
    logic [N-1:0]    takum;
    logic            sign_bit;
    logic signed [8:0] characteristic_or_exponent;
    logic [N-6:0]    mantissa_bits;
    logic [$clog2(N-4)-1:0] precision;
    logic            is_zero;
    logic            is_nar;

    logic            sign_bit_ref;
    logic signed [8:0] characteristic_or_exponent_ref;
    logic [N-6:0]    mantissa_bits_ref;
    logic [$clog2(N-4)-1:0] precision_ref;
    logic            is_zero_ref;
    logic            is_nar_ref;

    // ── UUT: RTL implementation ───────────────────────────────────────
    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b0)
    ) uut_rtl (
        .takum                    (takum),
        .sign_bit                 (sign_bit),
        .characteristic_or_exponent(characteristic_or_exponent),
        .mantissa_bits            (mantissa_bits),
        .precision                (precision),
        .is_zero                  (is_zero),
        .is_nar                   (is_nar)
    );

    // ── Reference: behavioral model ────────────────────────────────────
    predecoder_behave #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b0)
    ) uut_ref (
        .takum                    (takum),
        .sign_bit                 (sign_bit_ref),
        .characteristic_or_exponent(characteristic_or_exponent_ref),
        .mantissa_bits            (mantissa_bits_ref),
        .precision                (precision_ref),
        .is_zero                  (is_zero_ref),
        .is_nar                   (is_nar_ref)
    );

    // ── Clock + stimulus ──────────────────────────────────────────────
    logic [N-1:0] takum_end;
    assign takum_end = {N{1'b1}};

    initial begin
        takum = '0;
        clock = 1'b0;
    end

    always begin
        #10 clock = ~clock;
    end

    integer error_count;
    initial error_count = 0;

    always @(posedge clock) begin
        if (sign_bit !== sign_bit_ref) begin
            $display("ERROR [%0d]: sign_bit mismatch (rtl=%b, behave=%b)",
                     takum, sign_bit, sign_bit_ref);
            error_count = error_count + 1;
        end
        if (characteristic_or_exponent !== characteristic_or_exponent_ref) begin
            $display("ERROR [%0d]: char/exp mismatch (rtl=%0d, behave=%0d)",
                     takum, characteristic_or_exponent, characteristic_or_exponent_ref);
            error_count = error_count + 1;
        end
        if (mantissa_bits !== mantissa_bits_ref) begin
            $display("ERROR [%0d]: mantissa mismatch (rtl=%b, behave=%b)",
                     takum, mantissa_bits, mantissa_bits_ref);
            error_count = error_count + 1;
        end
        if (is_zero !== is_zero_ref) begin
            $display("ERROR [%0d]: is_zero mismatch (rtl=%b, behave=%b)",
                     takum, is_zero, is_zero_ref);
            error_count = error_count + 1;
        end
        if (is_nar !== is_nar_ref) begin
            $display("ERROR [%0d]: is_nar mismatch (rtl=%b, behave=%b)",
                     takum, is_nar, is_nar_ref);
            error_count = error_count + 1;
        end
        if (precision !== precision_ref) begin
            $display("ERROR [%0d]: precision mismatch (rtl=%0d, behave=%0d)",
                     takum, precision, precision_ref);
            error_count = error_count + 1;
        end

        if (takum == takum_end) begin
            if (error_count == 0)
                $display("PASS: All %0d values tested successfully.", 2**N);
            else
                $display("FAIL: %0d errors found.", error_count);
            $finish;
        end

        takum = takum + 1'b1;
    end

endmodule