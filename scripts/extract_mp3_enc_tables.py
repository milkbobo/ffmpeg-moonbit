#!/usr/bin/env python3
"""Extract the shine MP3 (Layer III) encoder tables from a C dump.

Reads the output of `_ref/shine/dumper.exe` (built from shine 3.1.1 sources
together with the shine library) and writes `libavcodec/mp3_enc_tables.mbt`.

Zero-transcription policy: every integer table is copied verbatim from the
compiled C reference, so no value passes through a human or the script's
understanding of the algorithm. The only computed values are the f64 bit
patterns of `steptab`, which are re-materialised with Python's
shortest-roundtrip `repr` (any correctly-rounded parser recovers the bits).

Usage: python scripts/extract_mp3_enc_tables.py <tables_dump.txt> <out.mbt>
"""
import struct
import sys


def parse_dump(path):
    """Parse `name = [v,v,...]` lines (the dumper emits each array on one line
    preceded by an optional `name len=N` hint). `steptab` keeps raw tokens
    (`0x...ULL` f64 bit patterns)."""
    tables = {}
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if " = [" not in line:
                continue
            name, rest = line.split(" = [", 1)
            assert rest.endswith("]"), line
            if name == "steptab":
                tables[name] = [x.strip() for x in rest[:-1].split(",") if x.strip()]
            else:
                tables[name] = [int(x.strip()) for x in rest[:-1].split(",") if x.strip()]
    return tables


CODE_ARRAYS = [
    ("t1HB", 4), ("t2HB", 9), ("t3HB", 9), ("t5HB", 16), ("t6HB", 16),
    ("t7HB", 36), ("t8HB", 36), ("t9HB", 36), ("t10HB", 64), ("t11HB", 64),
    ("t12HB", 64), ("t13HB", 256), ("t15HB", 256), ("t16HB", 256),
    ("t24HB", 256), ("t32HB", 16), ("t33HB", 16),
]
LEN_ARRAYS = [
    ("t1l", 4), ("t2l", 9), ("t3l", 9), ("t5l", 16), ("t6l", 16),
    ("t7l", 36), ("t8l", 36), ("t9l", 36), ("t10l", 64), ("t11l", 64),
    ("t12l", 64), ("t13l", 256), ("t15l", 256), ("t16l", 256), ("t24l", 256),
    ("t32l", 16), ("t33l", 16),
]
# which code/len pair each of the 34 huffman table entries points at
TABLE_ENTRY = [
    None, ("t1HB", "t1l"), ("t2HB", "t2l"), ("t3HB", "t3l"), None,
    ("t5HB", "t5l"), ("t6HB", "t6l"), ("t7HB", "t7l"), ("t8HB", "t8l"),
    ("t9HB", "t9l"), ("t10HB", "t10l"), ("t11HB", "t11l"), ("t12HB", "t12l"),
    ("t13HB", "t13l"), None, ("t15HB", "t15l"), ("t16HB", "t16l"),
    ("t16HB", "t16l"), ("t16HB", "t16l"), ("t16HB", "t16l"), ("t16HB", "t16l"),
    ("t16HB", "t16l"), ("t16HB", "t16l"), ("t16HB", "t16l"), ("t24HB", "t24l"),
    ("t24HB", "t24l"), ("t24HB", "t24l"), ("t24HB", "t24l"), ("t24HB", "t24l"),
    ("t24HB", "t24l"), ("t24HB", "t24l"), ("t24HB", "t24l"), ("t32HB", "t32l"),
    ("t33HB", "t33l"),
]


def fmt_i32(name, values):
    body = ",".join(str(v) for v in values)
    return f"///|\n/// Extracted from the compiled shine 3.1.1 reference (zero transcription).\nlet {name} : Array[Int32] = [{body}]\n"


def main():
    dump_path, out_path = sys.argv[1], sys.argv[2]
    t = parse_dump(dump_path)

    # sanity-check the metadata against the statically known table shape
    meta = t["huff_meta"]
    assert len(meta) == 136
    code_off = {}
    hlen_off = {}
    code_flat = []
    len_flat = []
    for name, n in CODE_ARRAYS:
        vals = t[name]
        assert len(vals) == n, (name, len(vals), n)
        code_off[name] = len(code_flat)
        code_flat.extend(vals)
    for name, n in LEN_ARRAYS:
        vals = t[name]
        assert len(vals) == n, (name, len(vals), n)
        hlen_off[name] = len(len_flat)
        len_flat.extend(vals)

    desc = []
    for i in range(34):
        xlen, ylen, linbits, linmax = meta[i * 4:i * 4 + 4]
        pair = TABLE_ENTRY[i]
        if pair is None:
            assert xlen == 0 and ylen == 0, (i, xlen, ylen)
            desc.extend([xlen, ylen, linbits, linmax, -1, -1])
        else:
            assert xlen * ylen == len(t[pair[0]]), (i, xlen, ylen)
            desc.extend([xlen, ylen, linbits, linmax, code_off[pair[0]],
                         hlen_off[pair[1]]])

    lines = [
        "/// MoonBit tables for the shine 3.1.1 Layer III (MP3) encoder port.",
        "///",
        "/// GENERATED FILE - do not edit. Regenerate with:",
        "///   scripts/gen_mp3_enc_tables.sh",
        "/// from the compiled shine reference dumper (zero-transcription:",
        "/// values are copied verbatim from the C binary, see the script).",
        "",
    ]
    for name in ["samplerates", "bitrates", "slen1_tab", "slen2_tab",
                 "scale_fact_band_index", "enwindow"]:
        lines.append(fmt_i32("mp3enc_" + name, t[name]))
    lines.append(fmt_i32("mp3enc_huff_desc", desc))
    lines.append(fmt_i32("mp3enc_huff_code_flat", code_flat))
    lines.append(fmt_i32("mp3enc_huff_len_flat", len_flat))
    lines.append(fmt_i32("mp3enc_subband_fl", t["subband_fl"]))
    lines.append(fmt_i32("mp3enc_mdct_cos_l", t["mdct_cos_l"]))
    lines.append(fmt_i32("mp3enc_steptabi", t["steptabi"]))
    lines.append(fmt_i32("mp3enc_int2idx", t["int2idx"]))

    steptab_bits = t["steptab"]
    assert len(steptab_bits) == 128
    vals = []
    for tok in steptab_bits:
        bits = int(tok.replace("ULL", ""), 16)
        (d,) = struct.unpack("<d", struct.pack("<Q", bits))
        vals.append(repr(d))
    lines.append("///|\n/// `l3loop.steptab[i] = pow(2.0, (127-i)/4)`, copied as exact IEEE-754\n/// bit patterns from the C reference (libm pow is not bit-portable).\nlet mp3enc_steptab : Array[Double] = [" + ",".join(vals) + "]\n")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print(f"wrote {out_path}: {len(code_flat)} huff codes, {len(t['enwindow'])} enwindow, {len(t['int2idx'])} int2idx")


if __name__ == "__main__":
    main()
