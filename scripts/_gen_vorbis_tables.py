"""Generate libavcodec/vorbis_tables.mbt from the FFmpeg 9.0.2 Vorbis sources.

Run from the moonbit/ directory:
    python scripts/_gen_vorbis_tables.py
The FFmpeg tree is expected at ../.scratch/FFmpeg-n9.0.2 (repository scratch).
"""

import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, ".scratch", "FFmpeg-n9.0.2", "libavcodec")
OUT = os.path.join(ROOT, "libavcodec", "vorbis_tables.mbt")


def read(name):
    with open(os.path.join(SRC, name), "r", encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def extract_block(text, name):
    m = re.search(r"\b" + re.escape(name) + r"\b[^=]*=\s*\{", text)
    if not m:
        raise SystemExit("array not found: " + name)
    i = m.end() - 1
    depth = 0
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[m.end():i]
        i += 1
    raise SystemExit("unterminated array: " + name)


def floats(block):
    vals = []
    for tok in block.split(","):
        tok = tok.strip().replace("F", "")
        if not tok:
            continue
        vals.append(float(tok))
    return vals


def fmt_float(v):
    # Keep enough digits for exact float32 round-trip.
    s = "%.9g" % v
    if "e" not in s and "." not in s:
        s += ".0"
    return s


def main():
    text = read("vorbis_data.c")
    wins = []
    for bl in range(6, 14):
        name = "vwin%d" % (1 << bl)
        vals = floats(extract_block(text, name))
        if len(vals) != (1 << bl) // 2:
            raise SystemExit("unexpected %s length %d" % (name, len(vals)))
        wins.append(vals)
    db = floats(extract_block(text, "ff_vorbis_floor1_inverse_db_table"))
    if len(db) != 256:
        raise SystemExit("unexpected db table length %d" % len(db))

    lines = []
    lines.append("///|")
    lines.append("/// Vorbis window slopes and floor1 curve table, extracted from")
    lines.append("/// FFmpeg 9.0.2 `libavcodec/vorbis_data.c` by `scripts/_gen_vorbis_tables.py`.")
    lines.append("///")
    lines.append("/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.")
    lines.append("")
    lines.append("///|")
    lines.append("/// `ff_vorbis_vwin[bl - 6]`: the rising half window of a `1 << bl` block")
    lines.append("/// (`blocksize/2` entries).")
    lines.append("let vorbis_vwin : Array[Array[Double]] = [")
    for vals in wins:
        lines.append("  [")
        for i in range(0, len(vals), 6):
            chunk = ", ".join(fmt_float(v) for v in vals[i:i + 6])
            lines.append("    " + chunk + ",")
        lines.append("  ],")
    lines.append("]")
    lines.append("")
    lines.append("///|")
    lines.append("/// `ff_vorbis_floor1_inverse_db_table`: `x` in 0..255 -> linear amplitude.")
    lines.append("let vorbis_floor1_inverse_db_table : Array[Double] = [")
    for i in range(0, len(db), 6):
        chunk = ", ".join(fmt_float(v) for v in db[i:i + 6])
        lines.append("  " + chunk + ",")
    lines.append("]")
    lines.append("")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
