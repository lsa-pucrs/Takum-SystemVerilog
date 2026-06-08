#!/usr/bin/env bash
# See LICENSE file for copyright and license details
#
# Full verification of the Takum SystemVerilog codec against the independent
# Python oracle (tools/takum_oracle.py).  Each gate compiles with Icarus
# Verilog and fails hard on any mismatch.  Coverage per width:
#
#   * predecoder, OUTPUT_EXPONENT=0 (characteristic)  -- exhaustive vs oracle
#   * predecoder, OUTPUT_EXPONENT=1 (exponent)        -- exhaustive vs oracle
#   * postencoder, roundtrip set + saturation boundary -- vs oracle
#   * postencoder, full (sign,characteristic,mantissa) sweep (N<=12) -- direct
#     rounding-path coverage over non-representable inputs vs the VHDL-faithful
#     reference; the oracle self-test separately cross-checks that reference
#     against an independent nearest-value encoder.
#   * codec end-to-end roundtrip (all four wrapper modules) -- identity
#
# The widths include N=8 (only place the predecoder padding bug is visible);
# the encoder coverage includes the characteristic = -255 / +254 saturation
# boundary (only place the underflow-sign bug is visible).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WIDTHS="${WIDTHS:-8 12 16}"
SWEEP_MAX="${SWEEP_MAX:-12}"   # full (s,c,m) encoder sweep only up to this width
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG="rtl/takum_pkg.sv"
DEC="rtl/decoder/predecoder.sv"
ENC="rtl/encoder/postencoder.sv"
WRAP="rtl/decoder/decoder_linear.sv rtl/decoder/decoder_logarithmic.sv \
      rtl/encoder/encoder_linear.sv rtl/encoder/encoder_logarithmic.sv"
fail=0

run_gate() { # <expected-prefix> <output>
    if echo "$2" | grep -q "^PASS: $1"; then
        echo "$2" | grep "^PASS:"
    else
        echo "$2"; echo "GATE FAIL: $1"; fail=1
    fi
}

echo "== oracle self-test (incl. independent value-encoder triangulation) =="
python3 tools/takum_oracle.py selftest

echo
echo "== verilator lint (all 6 RTL modules) =="
for m in $DEC $ENC $WRAP; do
    verilator --lint-only -Wno-fatal "$PKG" "$m" 2>/dev/null \
        && echo "  lint OK: $m" || { echo "  lint WARN: $m"; }
done

for N in $WIDTHS; do
    echo
    echo "=================== N=$N ==================="

    # ---- predecoder, characteristic (OE=0) ----
    dvec="$WORK/dec0_${N}.txt"
    python3 tools/takum_oracle.py gen decode "$N" "$dvec" 0 >/dev/null
    iverilog -g2012 -o "$WORK/pre0_${N}.vvp" -P predecoder_tb.N="$N" -P predecoder_tb.OE=0 \
        "$PKG" "$DEC" simulation/decoder/predecoder_tb.sv 2>/dev/null
    run_gate "predecoder" "$(vvp "$WORK/pre0_${N}.vvp" +VEC="$dvec" 2>/dev/null | grep -E 'PASS|FAIL')"

    # ---- predecoder, exponent (OE=1) ----
    dvec1="$WORK/dec1_${N}.txt"
    python3 tools/takum_oracle.py gen decode "$N" "$dvec1" 1 >/dev/null
    iverilog -g2012 -o "$WORK/pre1_${N}.vvp" -P predecoder_tb.N="$N" -P predecoder_tb.OE=1 \
        "$PKG" "$DEC" simulation/decoder/predecoder_tb.sv 2>/dev/null
    run_gate "predecoder" "$(vvp "$WORK/pre1_${N}.vvp" +VEC="$dvec1" 2>/dev/null | grep -E 'PASS|FAIL')"

    # ---- postencoder, roundtrip + boundary ----
    evec="$WORK/enc_${N}.txt"
    python3 tools/takum_oracle.py gen encode "$N" "$evec" >/dev/null
    iverilog -g2012 -o "$WORK/post_${N}.vvp" -P postencoder_tb.N="$N" \
        "$PKG" "$DEC" "$ENC" simulation/encoder/postencoder_tb.sv 2>/dev/null
    run_gate "postencoder" "$(vvp "$WORK/post_${N}.vvp" +VEC="$evec" 2>/dev/null | grep -E 'PASS|FAIL')"

    # ---- postencoder, full input sweep (small N only) ----
    if [ "$N" -le "$SWEEP_MAX" ]; then
        svec="$WORK/encsweep_${N}.txt"
        python3 tools/takum_oracle.py gen encsweep "$N" "$svec" >/dev/null
        run_gate "postencoder" "$(vvp "$WORK/post_${N}.vvp" +VEC="$svec" 2>/dev/null | grep -E 'PASS|FAIL')"
    fi

    # ---- codec wrappers: log identity + linear faithful (all wrappers) ----
    cvec="$WORK/codec_${N}.txt"
    python3 tools/takum_oracle.py gen codec "$N" "$cvec" >/dev/null
    iverilog -g2012 -o "$WORK/codec_${N}.vvp" -P codec_roundtrip_tb.N="$N" \
        "$PKG" "$DEC" "$ENC" $WRAP simulation/codec_roundtrip_tb.sv 2>/dev/null
    run_gate "codec wrappers" "$(vvp "$WORK/codec_${N}.vvp" +VEC="$cvec" 2>/dev/null | grep -E 'PASS|FAIL')"
done

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL GATES PASSED (widths: $WIDTHS)"
else
    echo "ONE OR MORE GATES FAILED"
fi
exit "$fail"
