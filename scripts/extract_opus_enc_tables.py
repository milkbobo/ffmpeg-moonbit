#!/usr/bin/env python3
"""Extract the FFmpeg native Opus encoder tables from a C dump.

Reads the output of `_ref/opus/dumper.exe` (built from the FFmpeg 9.0.2 tree,
see scripts/gen_opus_enc_tables.sh) and writes `libavcodec/opus_enc_tables.mbt`.

Zero-transcription policy: floats are copied verbatim as IEEE-754 bit patterns
and re-materialised with Python's shortest-roundtrip repr.

Usage: python scripts/extract_opus_enc_tables.py <dump.txt> <out.mbt>
"""
import struct
import sys


def parse_dump(path):
    tables = {}
    pending = None
    for line in open(path, "r", encoding="ascii"):
        line = line.strip()
        if " len=" in line and " = [" not in line:
            pending = line.split()[0]
            continue
        if " = [" in line:
            name, rest = line.split(" = [", 1)
            assert rest.endswith("]"), line
            vals = [x.strip() for x in rest[:-1].split(",") if x.strip()]
            if name in tables:
                tables[name].extend(vals)
            else:
                tables[name] = vals
            pending = None
    return tables


def f32_array(name, tokens):
    vals = []
    for tok in tokens:
        bits = int(tok.replace("u", ""), 16)
        (d,) = struct.unpack("<f", struct.pack("<I", bits))
        vals.append(repr(d))
    return "let %s : FixedArray[Float] = FixedArray::make(%d, 0.0) && {\n  let a = %s\n  for i in 0..<%d { a[i] = [%s][i] }\n  a\n}" % (
        name, len(vals), name, len(vals), ", ".join(vals))


def main():
    dump_path, out_path = sys.argv[1], sys.argv[2]
    t = parse_dump(dump_path)

    # merge the repeated psy_window / bessel dumps into flat arrays
    flat = {}
    order = []
    for k, v in t.items():
        if k not in flat:
            flat[k] = []
            order.append(k)
        flat[k].extend(v)

    lines = [
        "/// MoonBit tables for the FFmpeg 9.0.2 native Opus encoder port.",
        "///",
        "/// GENERATED FILE - do not edit. Regenerate with:",
        "///   scripts/gen_opus_enc_tables.sh",
        "/// Floats are IEEE-754 bit patterns from the compiled reference",
        "/// (zero transcription).",
        "",
    ]

    def emit(name, tokens, kind):
        if kind == "f32":
            vals = []
            for tok in tokens:
                bits = int(tok.replace("u", ""), 16)
                (d,) = struct.unpack("<f", struct.pack("<I", bits))
                vals.append(repr(d))
            lines.append("///|\nlet %s : FixedArray[Float] = [\n  %s,\n]" % (name, ",\n  ".join(vals)))
        else:
            lines.append("///|\nlet %s : FixedArray[Int] = [%s]" % (name, ", ".join(tokens)))


    emit("opus_enc_band_end", flat["band_end"], "i32")
    emit("opus_enc_mean_energy", flat["mean_energy"], "f32")
    emit("opus_enc_postfilter_taps", flat["postfilter_taps"], "f32")
    emit("opus_enc_deemph_weights", flat["deemph_weights"], "f32")
    emit("opus_enc_celt_window", flat["celt_window"], "f32")
    emit("opus_enc_celt_window_padded", flat["celt_window_padded"], "f32")

    # psy windows: emitted per size in dump order
    idx = 0
    for size in range(4):
        n = 2 * (2 * 15 * (1 << (size + 2)))
        toks = flat["psy_window"][idx:idx + n]
        idx += n
        assert len(toks) == n, (size, len(toks), n)
        emit("opus_enc_psy_window_%d" % size, toks, "f32")

    # bessel coefficients: 2 ch x 21 bands x (hi a3+b2, lo a3+b2)
    per = (3 + 2 + 3 + 2)
    total = 2 * 21 * per
    got = len(flat["bessel_hi"]) + len(flat["bessel_lo"])
    assert got == total, (got, total)
    hi = flat["bessel_hi"]
    lo = flat["bessel_lo"]
    # flat order: ch, band -> hi.a(3), hi.b(2), lo.a(3), lo.b(2)
    merged = []
    ptr_hi = 0
    ptr_lo = 0
    for ch in range(2):
        for band in range(21):
            merged.extend(hi[ptr_hi:ptr_hi + 3]); ptr_hi += 3
            merged.extend(hi[ptr_hi:ptr_hi + 2]); ptr_hi += 2
            merged.extend(lo[ptr_lo:ptr_lo + 3]); ptr_lo += 3
            merged.extend(lo[ptr_lo:ptr_lo + 2]); ptr_lo += 2
    emit("opus_enc_bessel_coeffs", merged, "f32")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s" % out_path)


if __name__ == "__main__":
    main()
