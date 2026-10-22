#!/usr/bin/env python3
"""Extract the VP9 decoder tables from FFmpeg 9.0.2 libavcodec/vp9data.c
into libavcodec/vp9_tables.mbt (flat Array[Int32] literals).

Rules follow agent.md §9: no manual transcription, every table is parsed
straight out of the C initialiser, and `--check` re-parses and diffs the
generated file value by value.

Usage:
  python scripts/extract_vp9_tables.py            # (re)generate vp9_tables.mbt
  python scripts/extract_vp9_tables.py --check    # verify without writing
"""

import difflib
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
C_SRC = os.path.join(HERE, "..", "..", "libavcodec", "vp9data.c")
OUT = os.path.join(HERE, "..", "libavcodec", "vp9_tables.mbt")

# enum values used by designated initialisers in vp9data.c
ENUMS = {
    # enum TxfmType
    "DCT_DCT": 0, "DCT_ADST": 1, "ADST_DCT": 2, "ADST_ADST": 3,
    # enum IntraPredMode
    "VERT_PRED": 0, "HOR_PRED": 1, "DC_PRED": 2, "DIAG_DOWN_LEFT_PRED": 3,
    "DIAG_DOWN_RIGHT_PRED": 4, "VERT_RIGHT_PRED": 5, "HOR_DOWN_PRED": 6,
    "VERT_LEFT_PRED": 7, "HOR_UP_PRED": 8, "TM_VP8_PRED": 9,
    "LEFT_DC_PRED": 10, "TOP_DC_PRED": 11, "DC_128_PRED": 12,
    "DC_127_PRED": 13, "DC_129_PRED": 14,
    # enum InterPredMode
    "NEARESTMV": 10, "NEARMV": 11, "ZEROMV": 12, "NEWMV": 13,
    # enum FilterMode
    "FILTER_8TAP_SMOOTH": 0, "FILTER_8TAP_REGULAR": 1, "FILTER_8TAP_SHARP": 2,
    "FILTER_BILINEAR": 3,
    # enum BlockSize (N_BS_SIZES = 13)
    "BS_64x64": 0, "BS_64x32": 1, "BS_32x64": 2, "BS_32x32": 3,
    "BS_32x16": 4, "BS_16x32": 5, "BS_16x16": 6, "BS_16x8": 7,
    "BS_8x16": 8, "BS_8x8": 9, "BS_8x4": 10, "BS_4x8": 11, "BS_4x4": 12,
    "N_BS_SIZES": 13,
    "PARTITION_NONE": 0, "PARTITION_H": 1, "PARTITION_V": 2, "PARTITION_SPLIT": 3,
}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def extract_block(src, name):
    """Return the raw text between `= {` and the matching closing brace."""
    m = re.search(r"\b%s\s*(?:\[[^=]*)?=\s*\{" % re.escape(name), src)
    if not m:
        raise SystemExit("table %r not found" % name)
    i = m.end() - 1
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i + 1:j]
    raise SystemExit("unbalanced braces in %r" % name)


def numbers(body):
    """All numeric tokens (enum identifiers resolved)."""
    out = []
    for tok in re.findall(r"(-?)\s*(0x[0-9A-Fa-f]+|\d+|[A-Z_][A-Z0-9_]*)", body):
        neg, core = tok
        if core in ENUMS:
            v = ENUMS[core]
        elif re.match(r"^(0x[0-9A-Fa-f]+|\d+)$", core):
            v = int(core, 0)
        else:
            raise SystemExit("unknown token %r" % core)
        out.append(-v if neg else v)
    return out


def parse_table(src, name, expect_len):
    vals = numbers(strip_comments(extract_block(src, name)))
    if len(vals) != expect_len:
        raise SystemExit("%s: got %d values, expected %d" % (name, len(vals), expect_len))
    return vals


def parse_designated(src, name, size):
    """Resolve a flat designated array ([IDX] = value) into a dense list."""
    body = strip_comments(extract_block(src, name))
    vals = [0] * size
    pos = 0
    depth = 0
    item_start = 0
    items = []
    for j, ch in enumerate(body):
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        elif ch == "," and depth == 0:
            items.append(body[item_start:j])
            item_start = j + 1
    items.append(body[item_start:])
    for item in items:
        item = item.strip()
        if not item:
            continue
        dm = re.match(r"^\[\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*\]\s*=\s*(.*)$", item, re.S)
        if dm:
            idx = dm.group(1)
            idx = ENUMS[idx] if idx in ENUMS else int(idx, 0)
            pos = idx
            vals[pos] = numbers(dm.group(2))[0]
        else:
            vals[pos] = numbers(item)[0]
        pos += 1
    return vals


def parse_prob_context(src):
    """Flatten `ff_vp9_default_probs` (ProbContext) in C struct order.

    Layout (311 bytes):
      y_mode[4][9], uv_mode[10][9], filter[4][2], mv_mode[7][3], intra[4],
      comp[5], single_ref[5][2], comp_ref[5], tx32p[2][3], tx16p[2][2],
      tx8p[2], skip[3], mv_joint[3],
      mv_comp[2]{33: sign, classes[10], class0, bits[10], class0_fp[2][3],
                 fp[3], class0_hp, hp},
      partition[4][4][3]
    """
    raw = extract_block(src, "ff_vp9_default_probs")
    # find the mv_comp block: it is the brace group whose first comment
    # mentions "mv vertical component"
    mv_m = re.search(r"\{\s*/\*\s*mv vertical component\s*\*/", raw)
    part_m = re.search(r"\{\s*/\*\s*partition\s*\*/", raw)
    if not mv_m or not part_m:
        raise SystemExit("prob context member markers not found")
    lead = raw[:mv_m.start()]
    mv = raw[mv_m.start():part_m.start()]
    part = raw[part_m.start():]

    names = ["y_mode", "uv_mode", "filter", "mv_mode", "intra", "comp",
             "single_ref", "comp_ref", "tx32p", "tx16p", "tx8p", "skip",
             "mv_joint"]
    sizes = [4 * 9, 10 * 9, 4 * 2, 7 * 3, 4, 5, 5 * 2, 5, 2 * 3, 2 * 2, 2, 3, 3]
    marks = []
    for nm in names:
        m = re.search(r"/\*\s*%s\s*\*/" % re.escape(nm), lead)
        if not m:
            raise SystemExit("member comment %r not found" % nm)
        marks.append((nm, m.end()))
    marks.append(("#end", len(lead)))

    out = []
    for i, (nm, start) in enumerate(marks[:-1]):
        end = marks[i + 1][1]
        vals = numbers(strip_comments(lead[start:end]))
        if len(vals) != sizes[i]:
            raise SystemExit("%s: got %d values, expected %d" % (nm, len(vals), sizes[i]))
        out.extend(vals)

    mv_vals = numbers(strip_comments(mv))
    if len(mv_vals) != 2 * 33:
        raise SystemExit("mv_comp: got %d values, expected 66" % len(mv_vals))
    out.extend(mv_vals)

    part_vals = numbers(strip_comments(part))
    if len(part_vals) != 48:
        raise SystemExit("partition: got %d values, expected 48" % len(part_vals))
    out.extend(part_vals)
    return out


def fmt(name, comment, vals, per_line=24):
    lines = []
    lines.append("///|")
    lines.append("/// `%s`%s" % (name, (" — " + comment) if comment else ""))
    lines.append("let %s : Array[Int32] = [" % name)
    for i in range(0, len(vals), per_line):
        lines.append("  " + ", ".join(str(v) for v in vals[i:i + per_line]) + ",")
    lines.append("]")
    return "\n".join(lines)


def build_content():
    with open(C_SRC, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()

    tables = []
    tables.append(fmt("vp9_bwh_tab",
        "`ff_vp9_bwh_tab[2][13][2]`: [0] in 4-px units, [1] in 8-px units",
        parse_table(src, "ff_vp9_bwh_tab", 52)))
    tables.append(fmt("vp9_partition_tree", "`ff_vp9_partition_tree[3][2]`",
        parse_table(src, "ff_vp9_partition_tree", 6)))
    tables.append(fmt("vp9_kf_partition_probs", "`ff_vp9_default_kf_partition_probs[4][4][3]`",
        parse_table(src, "ff_vp9_default_kf_partition_probs", 48)))
    tables.append(fmt("vp9_segmentation_tree", "`ff_vp9_segmentation_tree[7][2]`",
        parse_table(src, "ff_vp9_segmentation_tree", 14)))
    tables.append(fmt("vp9_intramode_tree", "`ff_vp9_intramode_tree[9][2]`",
        parse_table(src, "ff_vp9_intramode_tree", 18)))
    tables.append(fmt("vp9_kf_ymode_probs", "`ff_vp9_default_kf_ymode_probs[10][10][9]`",
        parse_table(src, "ff_vp9_default_kf_ymode_probs", 900)))
    tables.append(fmt("vp9_kf_uvmode_probs", "`ff_vp9_default_kf_uvmode_probs[10][9]`",
        parse_table(src, "ff_vp9_default_kf_uvmode_probs", 90)))
    tables.append(fmt("vp9_dc_qlookup", "`ff_vp9_dc_qlookup[3][256]` (bpp index major)",
        parse_table(src, "ff_vp9_dc_qlookup", 768)))
    tables.append(fmt("vp9_ac_qlookup", "`ff_vp9_ac_qlookup[3][256]`",
        parse_table(src, "ff_vp9_ac_qlookup", 768)))
    tables.append(fmt("vp9_intra_txfm_type", "`ff_vp9_intra_txfm_type[14]` (designated)",
        parse_designated(src, "ff_vp9_intra_txfm_type", 14)))

    for size_name, n in [("4x4", 16), ("8x8", 64), ("16x16", 256)]:
        for kind in ["default", "col", "row"]:
            cname = "ff_vp9_%s_scan_%s" % (kind, size_name)
            tables.append(fmt("vp9_%s_scan_%s" % (kind, size_name),
                "`%s[%d]`" % (cname, n),
                parse_table(src, cname, n)))
    tables.append(fmt("vp9_default_scan_32x32", "`ff_vp9_default_scan_32x32[1024]`",
        parse_table(src, "ff_vp9_default_scan_32x32", 1024)))

    for size_name, n in [("4x4", 16), ("8x8", 64), ("16x16", 256)]:
        for kind in ["default", "col", "row"]:
            cname = "ff_vp9_%s_scan_%s_nb" % (kind, size_name)
            tables.append(fmt("vp9_%s_scan_%s_nb" % (kind, size_name),
                "`%s[%d][2]` neighbour LUT" % (cname, n),
                parse_table(src, cname, 2 * n)))
    tables.append(fmt("vp9_default_scan_32x32_nb", "`ff_vp9_default_scan_32x32_nb[1024][2]`",
        parse_table(src, "ff_vp9_default_scan_32x32_nb", 2048)))

    tables.append(fmt("vp9_model_pareto8", "`ff_vp9_model_pareto8[256][8]`",
        parse_table(src, "ff_vp9_model_pareto8", 2048)))
    tables.append(fmt("vp9_default_probs",
        "`ff_vp9_default_probs` flattened (ProbContext layout, 311 entries)",
        parse_prob_context(src)))
    # The C initialiser omits band-0 rows 3..5 ([l=0][m>=3], the "dc only has
    # 3 pt" rows) — they are zero in the C static layout.  The C writes
    # 99 values per [tx][pl][ty] block (3 band-0 rows + 5 full bands of
    # 6x3); we re-insert 9 zeros per 99-value block to restore the dense
    # [6][6][3] = 108-value stride so index arithmetic stays uniform.
    coef_raw = parse_table(src, "ff_vp9_default_coef_probs",
                           4 * 2 * 2 * (9 + 5 * 18))
    coef = []
    for i in range(0, len(coef_raw), 99):
        coef.extend(coef_raw[i:i + 9])
        coef.extend([0] * 9)
        coef.extend(coef_raw[i + 9:i + 99])
    tables.append(fmt("vp9_default_coef_probs",
        "`ff_vp9_default_coef_probs[4][2][2][6][6][3]` (band-0 rows 3..5 zero-filled)",
        coef))

    header = """///|
/// VP9 decoder tables, batch-extracted from FFmpeg 9.0.2
/// `libavcodec/vp9data.c` by `scripts/extract_vp9_tables.py`
/// (no manual transcription; `--check` re-parses and diffs value by value).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (C) 2013
/// Ronald S. Bultje <rsbultje gmail com> and Clément Bœsch <u pkh me>.
/// This port keeps the same license.
///
/// Multi-dimensional C tables are flattened row-major in C order; the
/// accessor helpers in `vp9_block.mbt`/`vp9_decode.mbt` document the strides.
///
/// The inter-frame slice re-adds `ff_vp9_inter_mode_tree`,
/// `ff_vp9_filter_tree` and `ff_vp9_filter_lut` (consumed only by inter
/// block syntax, so they are not emitted for the keyframe slice).
"""

    return header + "\n\n" + "\n\n".join(tables) + "\n"


def main():
    check_only = "--check" in sys.argv
    content = build_content()
    if check_only:
        with open(OUT, "r", encoding="utf-8") as f:
            old = f.read()
        if old == content:
            print("check: vp9_tables.mbt matches the C source")
            return 0
        diff = list(difflib.unified_diff(old.splitlines(), content.splitlines(),
                                         "generated.mbt", "c-source", lineterm=""))
        print("check: MISMATCH (%d diff lines)" % len(diff))
        for line in diff[:40]:
            print(line)
        return 1
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    print("wrote %s (%d bytes)" % (os.path.normpath(OUT), len(content)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
