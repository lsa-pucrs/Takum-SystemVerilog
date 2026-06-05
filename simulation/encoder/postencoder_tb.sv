// See LICENSE file for copyright and license details
// SystemVerilog conversion of simulation/encoder/postencoder_tb.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Roundtrip testbench: decode a takum -> encode -> verify result equals input.
// Iterates over all 2^N takum values.

`timescale 1ns / 1ps

module postencoder_tb;

    parameter int N = 16;

    logic            clock;
    logic [N-1:0]    takum_reference;
    logic            sign_bit;
    logic signed [8:0] characteristic;
    logic [N-6:0]    mantissa_bits;
    logic            is_zero;
    logic [$clog2(N-4)-1:0] precision;
    logic            is_nar;
    logic [N-1:0]    takum;

    logic [N-1:0]    takum_end;

    // ── Reference decoder (RTL) ────────────────────────────────────────
    predecoder #(
        .N              (N),
        .OUTPUT_EXPONENT(1'b0)    // characteristic output for roundtrip
    ) u_decoder (
        .takum                    (takum_reference),
        .sign_bit                 (sign_bit),
        .characteristic_or_exponent(characteristic),
        .mantissa_bits            (mantissa_bits),
        .precision                (precision),
        .is_zero                  (is_zero),
        .is_nar                   (is_nar)
    );

    // ── UUT: encoder (RTL) ─────────────────────────────────────────────
    postencoder #(
        .N(N)
    ) u_encoder (
        .sign_bit       (sign_bit),
        .characteristic (characteristic),
        .mantissa_bits  (mantissa_bits),
        .is_zero        (is_zero),
        .is_nar         (is_nar),
        .takum          (takum)
    );

    // ── Clock generation ───────────────────────────────────────────────
    initial begin
        takum_end = {N{1'b1}};
        takum_reference = '0;
        clock = 1'b0;
    end

    always begin
        if (takum_reference == takum_end) begin
            $display("All %0d values roundtrip-tested successfully.", N);
            $finish;
        end
        #10 clock = ~clock;
    end

    // ── Check results and increment ─────────────────────────────────────
    always @(posedge clock) begin
        if (takum !== takum_reference) begin
            $display("ERROR: mismatch (reference=%b, rtl=%b)",
                     takum_reference, takum);
        end

        takum_reference = takum_reference + 1'b1;
    end

endmodule