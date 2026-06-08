#!/usr/bin/env python3
# See LICENSE file for copyright and license details
#
# Independent golden reference for the Takum codec, derived directly from the
# algebraic specification (arXiv:2408.10594) -- NOT ported from the VHDL/SV
# RTL.  Its only purpose is to act as an oracle the SystemVerilog DUT is
# checked against, so it must not share an implementation lineage with either
# RTL.  Decode is built from the closed-form characteristic formula; encode is
# the deterministic field assembly + round-to-nearest-even with saturation.
#
# Self-validation (run `python3 takum_oracle.py selftest`) pins the oracle to
# externally-known-correct values before it is trusted:
#   * N=8  takum 0x01  -> characteristic -239  (logarithmic, output_exponent=0)
#   * N=16 (s=0,c=-255,m=0) -> 0x0001 ; (s=1,c=-255,m=0) -> 0x8001
# plus exhaustive decode<->encode roundtrip on every representable point.

import sys


def decode(takum, n, output_exponent):
    """N-bit takum -> (sign, characteristic_or_exponent, mantissa_bits,
    precision, is_zero, is_nar).  mantissa_bits is the (N-5)-bit left-aligned
    field, matching the RTL port.  output_exponent selects characteristic (0)
    or base-2 exponent (1)."""
    mask_n = (1 << n) - 1
    mask_m = (1 << (n - 5)) - 1
    takum &= mask_n

    sign = (takum >> (n - 1)) & 1
    is_zero = 1 if takum == 0 else 0
    is_nar = 1 if takum == (1 << (n - 1)) else 0

    direction = (takum >> (n - 2)) & 1

    # 3 regime bits sit immediately below the direction bit: takum[N-3:N-5].
    regime_bits = (takum >> (n - 5)) & 0b111
    regime = regime_bits if direction == 1 else 7 - regime_bits

    # The explicit characteristic field is the 7 bits below the regime field,
    # i.e. takum[N-6:N-12], MSB-first and top-aligned.  For N<12 the low bits of
    # this field fall off the bottom of the word and read as ghost zeros.
    char7 = 0
    for i in range(7):
        bitpos = (n - 6) - i
        bit = ((takum >> bitpos) & 1) if bitpos >= 0 else 0
        char7 = (char7 << 1) | bit

    # Only the top `regime` bits of the field carry the explicit characteristic.
    c_explicit = 0 if regime == 0 else (char7 >> (7 - regime))

    if direction == output_exponent:
        coe = -(2 ** (regime + 1)) + 1 + c_explicit
    else:
        coe = (2 ** regime) - 1 + c_explicit

    precision = 0 if regime >= (n - 5) else (n - regime - 5)

    # Mantissa occupies the lowest `precision` bits of the word; left-align it
    # inside the (N-5)-bit field by shifting up by `regime` (regime zeros fill
    # in at the bottom).
    mant_low = takum & mask_m
    mantissa = (mant_low << regime) & mask_m

    return sign, coe, mantissa, precision, is_zero, is_nar


def _saturation(c, mant, n):
    """Return (round_up_overflows, round_down_underflows) per the takum
    encoding rule.  These guard the extremes of the representable range."""
    # N<=11: characteristic that consumes the whole word has fixed bounds.
    bounds = {
        2:  (0,    -1),
        3:  (15,   -16),
        4:  (63,   -64),
        5:  (127,  -128),
        6:  (191,  -192),
        7:  (223,  -224),
        8:  (239,  -240),
        9:  (247,  -248),
        10: (251,  -252),
        11: (253,  -254),
    }
    if n <= 11:
        over_bound, under_bound = bounds[n]
        return (1 if c >= over_bound else 0,
                1 if c <= under_bound else 0)

    # N>=12: the bottom 6 mantissa bits are rounding room; the remaining
    # (N-11) top "crop" bits decide saturation together with the characteristic
    # extremes (c=-255 minimum, c=+254 maximum).
    crop_w = n - 11
    crop = (mant >> 6) & ((1 << crop_w) - 1)
    under = 1 if (crop == 0 and c == -255) else 0
    over = 1 if (crop == ((1 << crop_w) - 1) and c == 254) else 0
    return over, under


def encode(sign, c, mant, is_zero, is_nar, n):
    """(sign, characteristic, mantissa_bits, is_zero, is_nar) -> N-bit takum,
    with round-to-nearest-even and range saturation."""
    if is_nar:
        return 1 << (n - 1)
    if is_zero:
        return 0

    mask_n = (1 << n) - 1
    mant &= (1 << (n - 5)) - 1

    direction = 1 if c >= 0 else 0
    # precursor in 1..255; leading-one position is the regime.
    precursor = (c + 1) if c >= 0 else (-c)
    regime = precursor.bit_length() - 1

    cbits = precursor & 0x7F
    if direction == 0:
        cbits = (~cbits) & 0x7F
    regime_bits = regime if direction == 1 else (~regime) & 0b111

    # Assemble char(7) ++ mantissa(N-5) ++ 7 rounding zeros, then right-shift by
    # the regime to slide the fields into place.
    concat = (cbits << ((n - 5) + 7)) | (mant << 7)
    shifted = concat >> regime
    low = shifted & ((1 << (n + 2)) - 1)
    extended = (sign << (n + 6)) | (direction << (n + 5)) \
        | (regime_bits << (n + 2)) | low

    trunc = (extended >> 7) & mask_n
    guard = (extended >> 6) & 1
    lsb = (extended >> 7) & 1
    rest_zero = 1 if (extended & 0x3F) == 0 else 0

    over, under = _saturation(c, mant, n)
    round_up = under or (not over and guard and (not rest_zero or lsb))

    val = (trunc + 1) if round_up else trunc
    return val & mask_n


# --------------------------------------------------------------------------
# vector generation + self-test
# --------------------------------------------------------------------------

def gen_decode_vectors(n, output_exponent, out):
    """Emit one line per takum: takum sign coe mant prec is_zero is_nar
    (coe printed as a signed decimal, mant as N-5-bit binary)."""
    mw = n - 5
    with open(out, "w") as f:
        for t in range(1 << n):
            s, coe, mant, prec, iz, inar = decode(t, n, output_exponent)
            f.write(f"{t:0{n}b} {s} {coe} {mant:0{mw}b} {prec} {iz} {inar}\n")


def gen_encode_vectors(n, out, extra=None):
    """Roundtrip-style vectors: every takum decoded (logarithmic) to a tuple
    that the encoder must map back to the same takum.  `extra` appends explicit
    (sign,c,mant) boundary cases that exercise saturation directly."""
    mw = n - 5
    with open(out, "w") as f:
        for t in range(1 << n):
            s, c, mant, prec, iz, inar = decode(t, n, 0)
            exp = encode(s, c, mant, iz, inar, n)
            f.write(f"{s} {c} {mant:0{mw}b} {iz} {inar} {exp:0{n}b}\n")
        if extra:
            for (s, c, mant) in extra:
                exp = encode(s, c, mant, 0, 0, n)
                f.write(f"{s} {c} {mant & ((1<<mw)-1):0{mw}b} 0 0 {exp:0{n}b}\n")


def selftest():
    ok = True

    def check(label, got, want):
        nonlocal ok
        status = "PASS" if got == want else "FAIL"
        if got != want:
            ok = False
        print(f"  [{status}] {label}: got={got} want={want}")

    print("anchor: decode characteristic")
    # N=8 takum 0x01 -> -239 (report value)
    _, coe, _, _, _, _ = decode(0x01, 8, 0)
    check("N=8 0x01 characteristic", coe, -239)

    print("anchor: encode saturation (underflow path)")
    check("N=16 s=0,c=-255,m=0 -> 0x0001", encode(0, -255, 0, 0, 0, 16), 0x0001)
    check("N=16 s=1,c=-255,m=0 -> 0x8001", encode(1, -255, 0, 0, 0, 16), 0x8001)

    print("roundtrip: decode then encode == identity (all takum, non-special)")
    for n in (8, 12, 16):
        bad = 0
        for t in range(1 << n):
            s, c, mant, prec, iz, inar = decode(t, n, 0)
            if encode(s, c, mant, iz, inar, n) != t:
                bad += 1
                if bad <= 3:
                    print(f"    N={n} roundtrip miss takum={t:0{n}b}")
        check(f"N={n} roundtrip ({1<<n} vals)", bad, 0)

    print("RESULT:", "ALL PASS" if ok else "FAILURES PRESENT")
    return 0 if ok else 1


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "selftest":
        sys.exit(selftest())
    if len(sys.argv) >= 2 and sys.argv[1] == "gen":
        # gen <decode|encode> <N> <outfile> [output_exponent]
        kind, n, out = sys.argv[2], int(sys.argv[3]), sys.argv[4]
        if kind == "decode":
            oe = int(sys.argv[5]) if len(sys.argv) > 5 else 0
            gen_decode_vectors(n, oe, out)
        else:
            mw = n - 5
            extra = [
                (0, -255, 0), (1, -255, 0),
                (0, -255, (1 << mw) - 1), (1, -255, (1 << mw) - 1),
                (0, 254, (1 << mw) - 1), (1, 254, (1 << mw) - 1),
                (0, 254, 0), (1, 254, 0),
            ]
            gen_encode_vectors(n, out, extra)
        print(f"wrote {out}")
        sys.exit(0)
    print("usage: takum_oracle.py selftest | gen <decode|encode> <N> <out> [oe]")
    sys.exit(2)
