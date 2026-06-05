// See LICENSE file for copyright and license details
// Takum-Codec-RTL - Takum Codec SystemVerilog implementation
// Converted from VHDL by Laslo Hunhold's original design

package takum_pkg;

    // Range constants (matching VHDL: integer range -255 to 254)
    localparam int CHAR_EXP_WIDTH = 9;  // bits for characteristic/exponent signed
    localparam int CHAR_EXP_MIN   = -255;
    localparam int CHAR_EXP_MAX   = 254;

    // Regime range (3 bits -> 0..7)
    localparam int REGIME_MAX = 7;

endpackage: takum_pkg