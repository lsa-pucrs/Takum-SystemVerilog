// See LICENSE file for copyright and license details
// SystemVerilog conversion of rtl/encoder/encoder_linear.vhd
// Original VHDL by Laslo Hunhold, ISC license
//
// Linear Takum encoder: (sign, exponent, fraction, is_zero, is_nar) -> takum
// Negates the exponent depending on sign_bit to obtain the characteristic.

module encoder_linear #(
    parameter int N = 16
) (
    input  logic            sign_bit,
    input  logic signed [8:0] exponent,         // -255..254
    input  logic [N-6:0]   fraction_bits,
    input  logic            is_zero,
    input  logic            is_nar,
    output logic [N-1:0]   takum
);

    logic signed [8:0] characteristic;

    // Negate the exponent depending on sign_bit to obtain the characteristic
    // characteristic = exponent when sign_bit=0, ~(exponent) when sign_bit=1
    always_comb begin
        if (sign_bit == 1'b0) begin
            characteristic = exponent;
        end else begin
            characteristic = ~exponent;
        end
    end

    postencoder #(
        .N(N)
    ) u_postencoder (
        .sign_bit       (sign_bit),
        .characteristic (characteristic),
        .mantissa_bits  (fraction_bits),
        .is_zero        (is_zero),
        .is_nar         (is_nar),
        .takum          (takum)
    );

endmodule