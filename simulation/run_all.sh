#!/usr/bin/env bash
# See LICENSE file for copyright and license details
#
# Exhaustive verification of the Takum SystemVerilog codec against the
# independent Python oracle (tools/takum_oracle.py).  For every width in
# WIDTHS it generates golden vectors, compiles the DUT + oracle-vector
# testbench with Icarus Verilog, runs it, and fails hard on any mismatch.
#
# The widths deliberately include N=8 (the only place the historical
# predecoder padding bug is visible) and the encoder vector set deliberately
# includes the characteristic = -255 / +254 saturation boundary (the only
# place the historical underflow-sign bug is visible).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WIDTHS="${WIDTHS:-8 12 16}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PKG="rtl/takum_pkg.sv"
fail=0

echo "== oracle self-test =="
python3 tools/takum_oracle.py selftest

for N in $WIDTHS; do
    echo
    echo "=================== N=$N ==================="

    # ---- predecoder ----
    dvec="$WORK/decode_${N}.txt"
    python3 tools/takum_oracle.py gen decode "$N" "$dvec" 0 >/dev/null
    iverilog -g2012 -Wall -o "$WORK/pre_${N}.vvp" \
        -P predecoder_tb.N="$N" \
        "$PKG" rtl/decoder/predecoder.sv simulation/decoder/predecoder_tb.sv
    out="$(vvp "$WORK/pre_${N}.vvp" +VEC="$dvec")"
    echo "$out"
    echo "$out" | grep -q "^PASS: predecoder" || { echo "GATE FAIL: predecoder N=$N"; fail=1; }

    # ---- postencoder ----
    evec="$WORK/encode_${N}.txt"
    python3 tools/takum_oracle.py gen encode "$N" "$evec" >/dev/null
    iverilog -g2012 -Wall -o "$WORK/post_${N}.vvp" \
        -P postencoder_tb.N="$N" \
        "$PKG" rtl/decoder/predecoder.sv rtl/encoder/postencoder.sv \
        simulation/encoder/postencoder_tb.sv
    out="$(vvp "$WORK/post_${N}.vvp" +VEC="$evec")"
    echo "$out"
    echo "$out" | grep -q "^PASS: postencoder" || { echo "GATE FAIL: postencoder N=$N"; fail=1; }
done

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL GATES PASSED (widths: $WIDTHS)"
else
    echo "ONE OR MORE GATES FAILED"
fi
exit "$fail"
