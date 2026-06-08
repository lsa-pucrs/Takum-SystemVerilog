# Takum SystemVerilog RTL

SystemVerilog implementation of the [Takum](https://takum-arithmetic.org/) codec RTL, converted from the original VHDL at [takum-arithmetic/Takum-Codec-RTL](https://github.com/takum-arithmetic/Takum-Codec-RTL) (Laslo Hunhold, ISC).

The RTL is verified against an **independent golden reference** (`tools/takum_oracle.py`) derived directly from the takum algebraic specification — not ported from either RTL — by exhaustive simulation at widths **N ∈ {8, 12, 16}** for both the decoder and the encoder, including the encoder's range-saturation boundary.

## Modules

### Decoder (predecoder + output selection)

| Module | File | Description |
|--------|------|-------------|
| `predecoder` | `rtl/decoder/predecoder.sv` | Core decoder: takum → (sign, characteristic/exponent, mantissa, precision, is_zero, is_nar) |
| `decoder_linear` | `rtl/decoder/decoder_linear.sv` | Linear decoder wrapper (exponent output, `OUTPUT_EXPONENT=1`) |
| `decoder_logarithmic` | `rtl/decoder/decoder_logarithmic.sv` | Logarithmic decoder wrapper (characteristic output, `OUTPUT_EXPONENT=0`) |

### Encoder (input formatting + postencoder)

| Module | File | Description |
|--------|------|-------------|
| `postencoder` | `rtl/encoder/postencoder.sv` | Core encoder: (sign, characteristic, mantissa, is_zero, is_nar) → takum, round-to-nearest-even |
| `encoder_linear` | `rtl/encoder/encoder_linear.sv` | Linear encoder wrapper (exponent input) |
| `encoder_logarithmic` | `rtl/encoder/encoder_logarithmic.sv` | Logarithmic encoder wrapper (barred-logarithmic-value input) |

### Package & tooling

| File | Description |
|------|-------------|
| `rtl/takum_pkg.sv` | Shared constants. Modules also define their parameters inline so they compile standalone under iverilog. |
| `tools/takum_oracle.py` | Independent spec-derived decode/encode reference + vector generator + self-test. |

### Testbenches

| File | Description |
|------|-------------|
| `simulation/decoder/predecoder_tb.sv` | Reads oracle vectors, drives `predecoder`, asserts every output field matches. |
| `simulation/encoder/postencoder_tb.sv` | Reads oracle vectors (full roundtrip set **plus** explicit `characteristic = -255 / +254` saturation boundary cases), asserts the encoded takum matches. |
| `simulation/run_all.sh` | Generates vectors, compiles, and runs the full gate for `WIDTHS` (default `8 12 16`). |

## Parameters

All modules use parameter `N` (default 16) for the takum bit width, valid range 2 to 254.

The `predecoder` has an additional parameter `OUTPUT_EXPONENT`:
- `0` (default): outputs the **characteristic** (logarithmic format)
- `1`: outputs the base-2 **exponent** (linear format)

## Simulation

The whole verification gate (oracle self-test + exhaustive RTL check for N ∈ {8, 12, 16}):

```bash
bash simulation/run_all.sh
# override widths:
WIDTHS="8 12 16 24" bash simulation/run_all.sh
```

Running a single configuration by hand — note the testbench reads its golden
vectors from a `+VEC=` file and takes `N` via an iverilog parameter override:

```bash
# predecoder, N=8
python3 tools/takum_oracle.py gen decode 8 /tmp/d8.txt 0
iverilog -g2012 -P predecoder_tb.N=8 -o /tmp/pre8.vvp \
  rtl/takum_pkg.sv rtl/decoder/predecoder.sv simulation/decoder/predecoder_tb.sv
vvp /tmp/pre8.vvp +VEC=/tmp/d8.txt        # -> PASS: predecoder N=8, 256 vectors, 0 mismatches.

# postencoder, N=16 (roundtrip + saturation boundary)
python3 tools/takum_oracle.py gen encode 16 /tmp/e16.txt
iverilog -g2012 -P postencoder_tb.N=16 -o /tmp/post16.vvp \
  rtl/takum_pkg.sv rtl/decoder/predecoder.sv rtl/encoder/postencoder.sv \
  simulation/encoder/postencoder_tb.sv
vvp /tmp/post16.vvp +VEC=/tmp/e16.txt
```

iverilog prints `sorry: constant selects in always_* processes ...` notes for
some part-selects; these concern sensitivity-list optimisation only and do not
affect the (combinational) simulation results.

### Verilator (lint only)

```bash
verilator --lint-only rtl/decoder/predecoder.sv
verilator --lint-only rtl/encoder/postencoder.sv
# ... etc
```

## Conversion notes

The SystemVerilog is a structural translation of the VHDL original. Key decisions:

1. **Arithmetic shift**: VHDL `shift_right(signed(...))` → SystemVerilog `>>>` on `logic signed`. The predecoder uses explicit `logic signed` to preserve arithmetic-shift semantics.
2. **Block statements** → named `always_comb` blocks.
3. **`localparam` arrays** (unsupported by iverilog) → `function` lookups (postencoder LOD LUT and overflow/underflow bound tables).
4. **`generate` / parameterised bit ranges** → `always_comb` part-selects.
5. **`numeric_std`** (`to_signed`/`to_unsigned`/`signed`/`unsigned`) → `$signed()` / `$unsigned()` casts and slicing.

### Two conversion bugs found and fixed

An earlier conversion passed its N=16-only, roundtrip-only testbench while still
being wrong in two places the original VHDL is right. Both are fixed here and
each is now covered by a test that fails if the bug is reintroduced (verified by
negative control):

- **Predecoder, N < 12 — segment zero-padding side.** The VHDL MSB-aligns the
  takum bits in the regime+characteristic segment and pads zeros on the LSB
  side (`takum(n-3 downto 0) & (11-n downto 0 => '0')`). The earlier SV padded
  the MSB side instead, forcing `regime_bits = 0` and corrupting nearly every
  decode at N=8 (the default `takum8` width). Fixed:
  `regime_characteristic_segment = { takum[N-3:0], {(12-N){1'b0}} }`.
  *Invisible at N ≥ 12 — caught only because the gate runs N=8.*

- **Postencoder, N ≥ 12 — underflow boundary sign.** The VHDL forces a round-up
  when `characteristic = -255`. The earlier SV compared against `9'sd255`
  (= +255, unreachable, since the maximum characteristic is +254), so the
  underflow guard never fired and the smallest-magnitude inputs were corrupted
  (positive → `0x0000` zero; negative → `0x8000` NaR). Fixed:
  `characteristic == -9'sd255`.
  *Invisible to a decode→encode roundtrip — caught only because the encoder gate
  feeds the saturation boundary directly.*

## Verified results

| Check | Result |
|-------|--------|
| oracle self-test (anchors + roundtrip) | **PASS** |
| `predecoder` vs oracle, N = 8 / 12 / 16 | **256 / 4096 / 65536 vectors, 0 mismatches** |
| `postencoder` vs oracle, N = 8 / 12 / 16 | **264 / 4104 / 65544 vectors, 0 mismatches** (incl. saturation boundary) |
| negative control (reintroduce either bug) | **gate FAILS** as expected |

## License

ISC — same as the original [Takum-Codec-RTL](https://github.com/takum-arithmetic/Takum-Codec-RTL).
