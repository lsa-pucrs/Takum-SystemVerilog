# Takum SystemVerilog RTL

SystemVerilog implementation of the [Takum](https://takum-arithmetic.org/) codec RTL, converted from the original VHDL at [takum-arithmetic/Takum-Codec-RTL](https://github.com/takum-arithmetic/Takum-Codec-RTL).

All modules are functionally equivalent to the original VHDL and have been validated with exhaustive simulation (65536 values for N=16).

## Modules

### Decoder (predecoder + output selection)

| Module | File | Description |
|--------|------|-------------|
| `predecoder` | `rtl/decoder/predecoder.sv` | Core decoder: takum → (sign, characteristic/exponent, mantissa, precision, is_zero, is_nar) |
| `decoder_linear` | `rtl/decoder/decoder_linear.sv` | Linear decoder wrapper (characteristic output) |
| `decoder_logarithmic` | `rtl/decoder/decoder_logarithmic.sv` | Logarithmic decoder wrapper (exponent output) |

### Encoder (input formatting + postencoder)

| Module | File | Description |
|--------|------|-------------|
| `postencoder` | `rtl/encoder/postencoder.sv` | Core encoder: (sign, characteristic, mantissa, is_zero, is_nar) → takum |
| `encoder_linear` | `rtl/encoder/encoder_linear.sv` | Linear encoder wrapper (characteristic input) |
| `encoder_logarithmic` | `rtl/encoder/encoder_logarithmic.sv` | Logarithmic encoder wrapper (exponent input) |

### Package

| Module | File | Description |
|--------|------|-------------|
| `takum_pkg` | `rtl/takum_pkg.sv` | Shared types and constants (note: iverilog does not support packages; modules define parameters inline) |

### Testbenches

| Module | File | Description |
|--------|------|-------------|
| `predecoder_tb` | `simulation/decoder/predecoder_tb.sv` | Exhaustive testbench for predecoder (all 2^N values) |
| `postencoder_tb` | `simulation/encoder/postencoder_tb.sv` | Roundtrip testbench: decode → encode → compare |

## Parameters

All modules use a parameter `N` (default 16) for the takum bit width. Valid range: 2 to 254.

The `predecoder` module has an additional parameter `OUTPUT_EXPONENT`:
- `0` (default): outputs **characteristic** (for linear format)
- `1`: outputs **exponent** (for logarithmic format, base-2)

## Simulation

### Icarus Verilog

```bash
# Compile and run predecoder testbench (exhaustive)
iverilog -g2012 -o predecoder_tb \
  rtl/decoder/predecoder.sv \
  simulation/decoder/predecoder_tb.sv
./predecoder_tb

# Compile and run postencoder roundtrip testbench
iverilog -g2012 -o postencoder_tb \
  rtl/decoder/predecoder.sv \
  rtl/encoder/postencoder.sv \
  simulation/encoder/postencoder_tb.sv
./postencoder_tb
```

### Verilator (lint only)

```bash
# Lint individual modules
verilator --lint-only rtl/decoder/predecoder.sv
verilator --lint-only rtl/encoder/postencoder.sv
# ... etc
```

## Conversion Notes

The SystemVerilog implementation is a direct structural translation of the VHDL original. Key conversion decisions:

1. **VHDL `signed` arithmetic**: `shift_right(signed(...))` (arithmetic right shift) → SystemVerilog `>>>` on `logic signed` types. The predecoder required explicit `logic signed` declarations to preserve arithmetic shift semantics.

2. **VHDL `(6 downto 0 => '0')`**: This idiom produces **7 bits** of zero (indices 6 down to 0). The initial conversion incorrectly used `6'b0` (6 bits); this was corrected to `7'b0`.

3. **VHDL block statements**: Converted to named `always_comb` blocks with equivalent signal declarations.

4. **VHDL localparam arrays**: Iverilog does not support `localparam` arrays. The postencoder's LOD LUT and overflow/underflow bounds are implemented as `function` lookups instead.

5. **VHDL `generate` for parameterized ranges**: Where VHDL uses `generate` statements for bit selection dependent on `N`, SystemVerilog uses `always_comb` with part-select operations (`+:` operator).

6. **VHDL `numeric_std`**: `to_signed`, `to_unsigned`, `unsigned`, `signed` → SystemVerilog type casts (`$signed()`, `$unsigned()`, bit slicing, and assignment).

7. **VHDL `std_logic_vector` vs `unsigned`/`signed`**: SystemVerilog uses `logic` packed arrays with explicit signed qualifiers where needed, plus `$signed()`/`$unsigned()` casts for arithmetic operations.

## Validated Results

| Testbench | Result |
|-----------|--------|
| `predecoder_tb` | **65536/65536 PASS** (N=16, exhaustive) |
| `postencoder_tb` | **Roundtrip PASS** (decode → encode → compare, all values) |
| Verilator lint | **All 6 RTL modules pass** |

## License

ISC — same as the original [Takum-Codec-RTL](https://github.com/takum-arithmetic/Takum-Codec-RTL).