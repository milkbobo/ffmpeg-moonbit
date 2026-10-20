# -*- coding: utf-8 -*-
"""Batch-extract AAC decode tables from FFmpeg 9.0.2 sources into aac_tables.mbt.

Sources: libavcodec/aactab.c (scalefactor VLC, spectral codebooks 1..11,
codebook value/index tables) and the runtime-tablegen algorithms of
libavcodec/aactab.c (ff_aac_pow2sf_tab) and libavcodec/cbrt_tablegen*.c
(ff_cbrt_tab = float32(n^(4/3))), replicated here bit-exactly in Python
(float32 rounding after every C float multiply).
"""
import re
import struct
import math

ROOT = r"D:/project/FFmpeg-n9.0.2"
AACTAB = ROOT + "/libavcodec/aactab.c"

src = open(AACTAB, encoding="utf-8").read()


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def fmt_f(x):
    x = f32(x)
    s = repr(x)
    return s


def parse_array(name):
    m = re.search(r"\b" + name + r"\s*\[[^\]]*\]\s*=\s*\{", src)
    if not m:
        raise SystemExit("array not found: " + name)
    start = m.end()
    end = src.index("};", start)
    body = src[start:end]
    toks = [t.strip() for t in body.replace("\n", " ").split(",")]
    return [t for t in toks if t and not t.startswith("/*") and not t.startswith("//")]


def to_int(tok):
    return int(tok.rstrip("uUlL"), 0)


def emit_ints(out, name, vals, typ, per_line=10):
    out.append("let %s : Array[%s] = [" % (name, typ))
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(str(v) for v in vals[i : i + per_line])
        out.append("  " + chunk + ",")
    out.append("]")
    out.append("")


def emit_floats(out, name, vals, per_line=4):
    out.append("let %s : Array[Double] = [" % name)
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(fmt_f(v) for v in vals[i : i + per_line])
        out.append("  " + chunk + ",")
    out.append("]")
    out.append("")


lines = []
lines.append('///|')
lines.append('/// AAC decode tables, batch-extracted from FFmpeg 9.0.2')
lines.append('/// `libavcodec/aactab.c` by `scripts/extract_aac_tables.py`')
lines.append('/// (scalefactor VLC, spectral codebooks 1..11, codebook')
lines.append('/// value/index tables) plus faithful re-implementations of the')
lines.append('/// runtime table generators `ff_aac_pow2sf_tab` (aactab.c) and')
lines.append('/// `ff_cbrt_tab` (cbrt_tablegen.h, float32(n^(4/3))). Do not edit.')
lines.append('/// Original FFmpeg code is LGPL-2.1-or-later.')
lines.append('')

# --- scalefactor VLC (identity symbol = codeword) -------------------------
sf_code = [to_int(t) for t in parse_array("ff_aac_scalefactor_code")]
sf_bits = [to_int(t) for t in parse_array("ff_aac_scalefactor_bits")]
assert len(sf_code) == 121 and len(sf_bits) == 121
emit_ints(lines, "aac_scalefactor_code", sf_code, "UInt")
emit_ints(lines, "aac_scalefactor_bits", sf_bits, "Int")

# --- spectral codebooks 1..11 ----------------------------------------------
sizes = [to_int(t) for t in parse_array("ff_aac_spectral_sizes")]
assert len(sizes) == 11
emit_ints(lines, "aac_spectral_sizes", sizes, "Int")

for n in range(1, 12):
    codes = [to_int(t) for t in parse_array("codes%d" % n)]
    bits = [to_int(t) for t in parse_array("bits%d" % n)]
    assert len(codes) == sizes[n - 1] and len(bits) == sizes[n - 1], (n, len(codes), len(bits))
    emit_ints(lines, "aac_codes%d" % n, codes, "UInt")
    emit_ints(lines, "aac_bits%d" % n, bits, "Int")

# --- codebook vector index tables ------------------------------------------
idx_names = {
    "aac_idx_quads02": "codebook_vector02_idx",
    "aac_idx_quads4": "codebook_vector4_idx",
    "aac_idx_pairs6": "codebook_vector6_idx",
    "aac_idx_pairs8": "codebook_vector8_idx",
    "aac_idx_pairs10": "codebook_vector10_idx",
}
for moon, cname in idx_names.items():
    vals = [to_int(t) for t in parse_array(cname)]
    emit_ints(lines, moon, vals, "UInt")

# --- per-book value/index mapping (ff_aac_codebook_vector_{vals,idx}) ------
# vals: books 1..4 use codebook_vector0_vals, 5,6 use _4_vals, 7..11 _10_vals
# (mirroring the pointer tables in aactab.c).
# ff_aac_codebook_vector_vals[] = { 0_vals, 0_vals, 10_vals, 10_vals,
#                                   4_vals, 4_vals, 10_vals, 10_vals, 10_vals,
#                                   10_vals, 10_vals }
vals_ptr = [
    "codebook_vector0_vals", "codebook_vector0_vals",
    "codebook_vector10_vals", "codebook_vector10_vals",
    "codebook_vector4_vals", "codebook_vector4_vals",
    "codebook_vector10_vals", "codebook_vector10_vals",
    "codebook_vector10_vals", "codebook_vector10_vals",
    "codebook_vector10_vals",
]
idx_ptr = [
    "codebook_vector02_idx", "codebook_vector02_idx",
    "codebook_vector02_idx", "codebook_vector02_idx",
    "codebook_vector4_idx", "codebook_vector4_idx",
    "codebook_vector6_idx", "codebook_vector8_idx",
    "codebook_vector8_idx", "codebook_vector10_idx",
    "codebook_vector10_idx",
]

vals_tables = {}
for cname in ["codebook_vector0_vals", "codebook_vector4_vals", "codebook_vector10_vals"]:
    toks = parse_array(cname)
    vals_tables[cname] = [float(t) for t in toks]

emit_floats(lines, "aac_vals0", vals_tables["codebook_vector0_vals"])
emit_floats(lines, "aac_vals4", vals_tables["codebook_vector4_vals"])
emit_floats(lines, "aac_vals10", vals_tables["codebook_vector10_vals"])

moon_vals = {"codebook_vector0_vals": "aac_vals0", "codebook_vector4_vals": "aac_vals4", "codebook_vector10_vals": "aac_vals10"}
moon_idx = {
    "codebook_vector02_idx": "aac_idx_quads02",
    "codebook_vector4_idx": "aac_idx_quads4",
    "codebook_vector6_idx": "aac_idx_pairs6",
    "codebook_vector8_idx": "aac_idx_pairs8",
    "codebook_vector10_idx": "aac_idx_pairs10",
}
lines.append("let aac_book_vals : Array[Array[Double]] = [")
lines.append("  " + ", ".join(moon_vals[p] for p in vals_ptr) + ",")
lines.append("]")
lines.append("")
lines.append("let aac_book_idx : Array[Array[UInt]] = [")
lines.append("  " + ", ".join(moon_idx[p] for p in idx_ptr) + ",")
lines.append("]")
lines.append("")

# --- ff_aac_pow2sf_tab: 428 float32 values, iterative exp2_lut product -----
exp2_lut = [
    1.0, 1.04427378242741384032, 1.09050773266525765921, 1.1387886347566916537,
    1.18920711500272106672, 1.24185781207348404859, 1.29683955465100966593,
    1.3542555469368927283, 1.4142135623730950488, 1.47682614593949931139,
    1.54221082540794082361, 1.61049033194925430818, 1.68179283050742908606,
    1.75625216037329948311, 1.83400808640934246349, 1.91520656139714729387,
]
t1 = f32(8.8817841970012523233890533447265625e-16)
t2 = f32(3.63797880709171295166015625e-12)
t1_prev, t2_prev = 0, 8
pow2sf = []
for i in range(428):
    t1_cur = 4 * (i % 4)
    t2_cur = (8 + 3 * i) % 16
    if t1_cur < t1_prev:
        t1 = f32(t1 * 2)
    if t2_cur < t2_prev:
        t2 = f32(t2 * 2)
    pow2sf.append(f32(f32(t1) * f32(exp2_lut[t1_cur])))
    t1_prev, t2_prev = t1_cur, t2_cur
emit_floats(lines, "aac_pow2sf", pow2sf)

# --- ff_cbrt_tab: 8192 float32 n^(4/3) values ------------------------------
LUT = 1 << 13
TMP = LUT >> 1
tmp = [1.0] * TMP
for idx in range(1, 45):
    if tmp[idx] == 1.0:
        i = 2 * idx + 1
        cbrt_val = i * math.cbrt(i)
        k = i
        while k < LUT:
            idx2 = k >> 1
            while idx2 < TMP:
                tmp[idx2] *= cbrt_val
                idx2 += k
            k *= i
for idx in range(45, TMP):
    if tmp[idx] == 1.0:
        i = 2 * idx + 1
        cbrt_val = i * math.cbrt(i)
        for idx2 in range(idx, TMP, i):
            tmp[idx2] *= cbrt_val
cbrt = [0.0] * LUT
cbrt_2 = 2 * math.cbrt(2)
for idx in range(TMP - 1, -1, -1):
    v = tmp[idx]
    i = 2 * idx + 1
    while i < LUT:
        cbrt[i] = f32(v)
        v *= cbrt_2
        i *= 2
cbrt[0] = 0.0
emit_floats(lines, "aac_pow43", cbrt)

# --- scalefactor band (swb) offsets (LC: 1024/128 frame lengths) ----------
num_1024 = [to_int(t) for t in parse_array("ff_aac_num_swb_1024")]
num_128 = [to_int(t) for t in parse_array("ff_aac_num_swb_128")]
emit_ints(lines, "aac_num_swb_1024", num_1024, "Int")
emit_ints(lines, "aac_num_swb_128", num_128, "Int")

swb_tables = {}
for sub in [96, 64, 48, 32, 24, 16, 8]:
    swb_tables["1024_%d" % sub] = [to_int(t) for t in parse_array("swb_offset_1024_%d" % sub)]
for sub in [96, 48, 24, 16, 8]:
    swb_tables["128_%d" % sub] = [to_int(t) for t in parse_array("swb_offset_128_%d" % sub)]
for name, vals in swb_tables.items():
    emit_ints(lines, "aac_swb_" + name, vals, "UInt")

# ff_swb_offset_1024[] / ff_swb_offset_128[] pointer mappings (13 entries).
swb1024_ptr = [96, 96, 64, 48, 48, 32, 24, 24, 16, 16, 16, 8, 8]
swb128_ptr = [96, 96, 96, 48, 48, 48, 24, 24, 16, 16, 16, 8, 8]
lines.append("let aac_swb_offset_1024 : Array[Array[UInt]] = [")
lines.append("  " + ", ".join("aac_swb_1024_%d" % s for s in swb1024_ptr) + ",")
lines.append("]")
lines.append("")
tns_max_1024 = [to_int(t) for t in parse_array("ff_tns_max_bands_1024")]
tns_max_128 = [to_int(t) for t in parse_array("ff_tns_max_bands_128")]
emit_ints(lines, "aac_tns_max_bands_1024", tns_max_1024, "Int")
emit_ints(lines, "aac_tns_max_bands_128", tns_max_128, "Int")

lines.append("let aac_swb_offset_128 : Array[Array[UInt]] = [")
lines.append("  " + ", ".join("aac_swb_128_%d" % s for s in swb128_ptr) + ",")
lines.append("]")
lines.append("")

with open(ROOT + "/moonbit/libavcodec/aac_tables.mbt", "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines))
print("written:", len(lines), "lines")
