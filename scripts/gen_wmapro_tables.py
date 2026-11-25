# Generate libavcodec/wmapro_tables.mbt: every table the WMA Pro decoder
# (wmaprodec.c) reads, extracted from FFmpeg 9.0.2 `libavcodec/wmaprodata.h`.
# Nothing is transcribed by hand; each value is parsed from its C
# initializer and the count is checked against the declared dimensions.
#
# Tables travel as base64 of the C integer type (or of the binary32 value
# widened exactly to a double) and are decoded once at startup, so they do
# not use init locals in the whitebox wasm.
#
# Every Huffman table comes out as a symbol table and a code length table
# (`*_syms` / `*_lens`). The C `[N][2]` tables hold `{ symbol, length }`
# rows; the decoder applies the symbol offsets of `decode_init_static`
# (-60 for the scale factor table, -1 for the vector tables) itself.
#
# Usage (from the repo root; FFmpeg sources one directory up):
#   python -I scripts/gen_wmapro_tables.py libavcodec [ffmpeg_root]
import base64
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# C array name -> MoonBit base name, declared-size macros, kind.
# kind: "u8" / "u16" as in C; "pair8" is a uint8_t[N][2] table split into
# `_syms` / `_lens`; "level" a float table that must hold whole numbers
# (stored as bytes); "f32" a float table widened to doubles.
TABLES = [
    ("critical_freq", "wmapro_critical_freq", [], "u16"),
    ("scale_table", "wmapro_scale", ["HUFF_SCALE_SIZE"], "pair8"),
    ("scale_rl_table", "wmapro_scale_rl", ["HUFF_SCALE_RL_SIZE"], "pair8"),
    ("scale_rl_run", "wmapro_scale_rl_run", ["HUFF_SCALE_RL_SIZE"], "u8"),
    ("scale_rl_level", "wmapro_scale_rl_level", ["HUFF_SCALE_RL_SIZE"], "u8"),
    ("coef0_lens", "wmapro_coef0_lens", ["HUFF_COEF0_SIZE"], "u8"),
    ("coef0_syms", "wmapro_coef0_syms", ["HUFF_COEF0_SIZE"], "u16"),
    ("coef1_table", "wmapro_coef1", ["HUFF_COEF1_SIZE"], "pair8"),
    ("coef0_run", "wmapro_coef0_run", ["HUFF_COEF0_SIZE"], "u16"),
    ("coef0_level", "wmapro_coef0_level", ["HUFF_COEF0_SIZE"], "level"),
    ("coef1_run", "wmapro_coef1_run", ["HUFF_COEF1_SIZE"], "u16"),
    ("coef1_level", "wmapro_coef1_level", ["HUFF_COEF1_SIZE"], "level"),
    ("vec4_lens", "wmapro_vec4_lens", ["HUFF_VEC4_SIZE"], "u8"),
    ("vec4_syms", "wmapro_vec4_syms", ["HUFF_VEC4_SIZE"], "u16"),
    ("vec2_table", "wmapro_vec2", ["HUFF_VEC2_SIZE"], "pair8"),
    ("vec1_table", "wmapro_vec1", ["HUFF_VEC1_SIZE"], "pair8"),
    (
        "default_decorrelation_matrices",
        "wmapro_default_decorrelation_matrices",
        [],
        "f32",
    ),
]

# Huffman tables: (symbol table, length table) for the Kraft sum check.
HUFFMAN = [
    ("wmapro_scale_syms", "wmapro_scale_lens"),
    ("wmapro_scale_rl_syms", "wmapro_scale_rl_lens"),
    ("wmapro_coef0_syms", "wmapro_coef0_lens"),
    ("wmapro_coef1_syms", "wmapro_coef1_lens"),
    ("wmapro_vec4_syms", "wmapro_vec4_lens"),
    ("wmapro_vec2_syms", "wmapro_vec2_lens"),
    ("wmapro_vec1_syms", "wmapro_vec1_lens"),
]

# Offsets of the default matrices, indexed by the group's channel count:
# 1 channel -> 0 (unused), 2 -> 1, 3 -> 5, 4 -> 14, 5 -> 30, 6 -> 55.
DECORRELATION_OFFSETS = {"default_decorrelation": [0, 1, 5, 14, 30, 55]}

NUMBER = re.compile(r"-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?")


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def read_macros(text):
    return {k: int(v) for k, v in re.findall(r"#define\s+(HUFF_\w+_SIZE)\s+(\d+)", text)}


def find_array(text, name, macros):
    """(dims, values) of one array."""
    text = strip_comments(text)
    for key, value in macros.items():
        text = re.sub(r"\b" + key + r"\b", str(value), text)
    m = re.search(
        r"(?:static\s+)?const\s+(?:\w+\s+)*\w+\s+"
        + re.escape(name)
        + r"\s*((?:\[[^\]]*\]\s*)+)=\s*\{",
        text,
    )
    if not m:
        raise SystemExit("array not found: " + name)
    i, depth = m.end(), 1
    while depth > 0:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    dims = [s.strip() for s in re.findall(r"\[([^\]]*)\]", m.group(1))]
    values = [float(tok) for tok in NUMBER.findall(text[m.end() : i - 1])]
    known = 1
    for d in dims:
        if d:
            known *= int(d)
    dims = [int(d) if d else len(values) // known for d in dims]
    return dims, values


def find_offsets(text, name):
    """The `&table[n]` offsets of a pointer table."""
    text = strip_comments(text)
    m = re.search(
        r"const\s+float\s*\*\s*const\s+" + re.escape(name) + r"\[\]\s*=\s*\{(.*?)\};",
        text,
        flags=re.S,
    )
    if not m:
        raise SystemExit("pointer table not found: " + name)
    offsets = []
    for tok in re.findall(r"&\w+\[(\d+)\]|NULL", m.group(1)):
        offsets.append(int(tok) if tok else None)
    return offsets


def pack(values, fmt):
    return b"".join(struct.pack("<" + fmt, v) for v in values)


def emit(out, name, comment, ty, unpack, data):
    out.append("///|")
    for line in comment.splitlines():
        out.append("/// " + line if line else "///")
    out.append("let " + name + " : " + ty + " = " + unpack + '(b"' + base64.b64encode(data).decode("ascii") + '")')
    out.append("")


def as_values(cname, kind, ctype, values):
    """Check the range and return (values, struct format)."""
    if kind == "f32":
        # The C `float` array holds the binary32-rounded literal.
        return [struct.unpack("<f", struct.pack("<f", v))[0] for v in values], "d"
    if kind == "level":
        for v in values:
            if v != int(v) or v < 0 or v > 255:
                raise SystemExit("%s: not a byte-sized whole number: %r" % (cname, v))
        return [int(v) for v in values], "B"
    limit = 255 if ctype == "u8" else 65535
    if any(v < 0 or v > limit for v in values):
        raise SystemExit("%s: out of %s range" % (cname, ctype))
    return [int(v) for v in values], ("B" if ctype == "u8" else "H")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavcodec"
    ffmpeg_root = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(ROOT), "")
    src = os.path.join(ffmpeg_root, "libavcodec", "wmaprodata.h")
    text = open(src, encoding="utf-8").read()
    macros = read_macros(text)
    expected = {
        "HUFF_SCALE_SIZE": 121,
        "HUFF_SCALE_RL_SIZE": 120,
        "HUFF_COEF0_SIZE": 272,
        "HUFF_COEF1_SIZE": 244,
        "HUFF_VEC4_SIZE": 127,
        "HUFF_VEC2_SIZE": 137,
        "HUFF_VEC1_SIZE": 101,
    }
    if macros != expected:
        raise SystemExit("unexpected size macros: " + repr(macros))
    decorrelation = find_offsets(text, "default_decorrelation")
    if decorrelation != [None] + DECORRELATION_OFFSETS["default_decorrelation"]:
        raise SystemExit("unexpected default_decorrelation offsets: " + repr(decorrelation))

    out = [
        "///|",
        "/// Tables of the WMA Pro decoder (`libavcodec/wmaprodata.h`), extracted",
        "/// from FFmpeg 9.0.2 by `scripts/gen_wmapro_tables.py`, which parses the C",
        "/// initializers and checks every count against the declared dimensions.",
        "/// Original FFmpeg code is LGPL-2.1-or-later; this transcription keeps the",
        "/// same license.",
        "///",
        "/// The tables are the C integer types as base64 bytes, decoded once at",
        "/// startup. Every Huffman table is a symbol table and a code length table",
        "/// (`*_syms` / `*_lens`) in C row order; the decoder adds the symbol",
        "/// offsets of `decode_init_static`. The run/level tables hold whole",
        "/// numbers, stored as bytes. The decorrelation matrices are the binary32",
        "/// values of the C `float` literals widened exactly to doubles.",
        "",
        "///|",
        "/// Decode one base64'd byte blob.",
        "fn wmapro_unpack_u8(b64 : Bytes) -> FixedArray[Int32] {",
        '  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {',
        "    Ok(v) => v",
        '    Err(_) => abort("wmapro u8 table: invalid base64")',
        "  }",
        "  let out = FixedArray::make(raw.length(), 0)",
        "  for i in 0..<raw.length() {",
        "    out[i] = raw[i].to_int()",
        "  }",
        "  out",
        "}",
        "",
        "///|",
        "/// Decode one base64'd little-endian uint16 blob.",
        "fn wmapro_unpack_u16(b64 : Bytes) -> FixedArray[Int32] {",
        '  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {',
        "    Ok(v) => v",
        '    Err(_) => abort("wmapro u16 table: invalid base64")',
        "  }",
        "  let n = raw.length() / 2",
        "  let out = FixedArray::make(n, 0)",
        "  for i in 0..<n {",
        "    out[i] = raw[i * 2].to_int() | (raw[i * 2 + 1].to_int() << 8)",
        "  }",
        "  out",
        "}",
        "",
        "///|",
        "/// Decode one base64'd little-endian f64 blob into doubles.",
        "fn wmapro_unpack_f64(b64 : Bytes) -> FixedArray[Double] {",
        '  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {',
        "    Ok(v) => v",
        '    Err(_) => abort("wmapro f64 table: invalid base64")',
        "  }",
        "  let n = raw.length() / 8",
        "  let out = FixedArray::make(n, 0.0)",
        "  for i in 0..<n {",
        "    let mut v : UInt64 = 0",
        "    for k in 0..<8 {",
        "      v = v |",
        "        (raw[i * 8 + k].to_int().reinterpret_as_uint().to_uint64() << (k * 8))",
        "    }",
        "    out[i] = v.reinterpret_as_double()",
        "  }",
        "  out",
        "}",
        "",
    ]
    check = {}
    for cname, mname, size_macros, kind in TABLES:
        dims, values = find_array(text, cname, macros)
        count = 1
        for d in dims:
            count *= d
        if len(values) != count:
            raise SystemExit("%s: %d values, declared %r" % (cname, len(values), dims))
        for key in size_macros:
            if dims[0] != macros[key]:
                raise SystemExit("%s: dimension %d != %s" % (cname, dims[0], key))
        dims_text = "".join("[%d]" % d for d in dims)
        if kind == "pair8":
            parts = [
                (mname + "_syms", values[0::2]),
                (mname + "_lens", values[1::2]),
            ]
            ctype = "u8"
        else:
            ctype = {"level": "u8"}.get(kind, kind)
            parts = [(mname, values)]
        for name, part in parts:
            column = ""
            if kind == "pair8":
                column = ", column " + ("0 (symbol)" if name.endswith("_syms") else "1 (code length)")
            checked, fmt = as_values(cname, kind, ctype, part)
            ty = "FixedArray[Double]" if ctype == "f32" else "FixedArray[Int32]"
            unpack = {"u8": "wmapro_unpack_u8", "u16": "wmapro_unpack_u16", "f32": "wmapro_unpack_f64"}[ctype]
            emit(
                out,
                name,
                "`%s%s`%s: %d values." % (cname, dims_text, column, len(checked)),
                ty,
                unpack,
                pack(checked, fmt),
            )
            check[name] = (checked, fmt)

    body = "\n".join(out) + "\n"
    dst = os.path.join(out_dir, "wmapro_tables.mbt")
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)

    # Read the written file back and decode every blob against the C values.
    written = open(dst, encoding="utf-8").read()
    decoded = {}
    for name, (values, fmt) in check.items():
        m = re.search(r"let " + name + r" : FixedArray\[\w+\] = \w+\(b\"([A-Za-z0-9+/=]+)\"\)", written)
        if not m:
            raise SystemExit("round trip: table not found: " + name)
        raw = base64.b64decode(m.group(1))
        back = list(struct.unpack("<" + str(len(values)) + fmt, raw))
        if back != values:
            raise SystemExit("round trip: mismatch in " + name)
        decoded[name] = back
    # Every Huffman table must be a complete prefix code (Kraft sum 1):
    # an incomplete one would give `get_vlc2` holes the port does not model.
    report = []
    for syms_name, lens_name in HUFFMAN:
        kraft = sum(2.0 ** (-length) for length in decoded[lens_name] if length > 0)
        if abs(kraft - 1.0) > 1e-9:
            raise SystemExit("Kraft sum %r for %s" % (kraft, syms_name))
        report.append("%s=%d" % (syms_name, len(decoded[syms_name])))
    print("wrote %s: %d tables, round trip ok; Huffman tables complete: %s" % (dst, len(check), ", ".join(report)))


if __name__ == "__main__":
    main()
