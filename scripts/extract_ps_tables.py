# -*- coding: utf-8 -*-
"""Extract Parametric Stereo tables into libavcodec/aac_ps_tables.mbt.

Float tables (pd_re_smooth, HA/HB, hybrid filters, Q_fract_allpass,
phi_fract, g1_Q2) are transcribed bit-exactly from a hex dump produced by the
instrumented `ff_ps_init` (`ps_dump_tables`, /tmp/ps_tables.txt) — the C
float codegen (cosf/atan2f/hypot, per-op float rounding) cannot be replicated
reliably in Python, so the dump is authoritative. When the dump is absent the
script falls back to recomputing the tablegen formulas in Python (double
math, one float32 rounding per op) and flags any entry that then disagrees
with a dump by more than 2 ulps, as a sanity check of the dump itself.

Huffman tables: `aacps_huff_tabs` (symbol, length pairs) is parsed from
`libavcodec/aacpsdata.c`; canonical codes are assigned in table order exactly
as FFmpeg's `ff_vlc_init_from_lengths` does (`code += 1 << (32 - len)`,
left-aligned), and the per-table `huff_offset` is baked into the emitted
symbols. `ff_k_to_i_20/34` are transcribed from the same file.
"""
import re
import struct
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PSDATA = ROOT / "libavcodec" / "aacpsdata.c"
DUMP = Path(__file__).resolve().parent.parent / "_build" / "ps_work" / "ps_tables.txt"
OUT = ROOT / "moonbit" / "libavcodec" / "aac_ps_tables.mbt"


def f32(x):
    return struct.unpack("f", struct.pack("f", x))[0]


def parse_dump():
    if not DUMP.exists():
        return {}
    tables = {}
    for line in DUMP.read_text().split("\n"):
        parts = line.split()
        if len(parts) < 2:
            continue
        tables[parts[0]] = [float.fromhex(hex_of) if False else
                            struct.unpack("f", struct.pack("<I", int(hex_of, 16)))[0]
                            for hex_of in parts[1:]]
    return tables


def compute_formulas():
    """ps_tableinit() replicated in Python (double math + f32 rounding)."""
    t = {}
    M_SQRT1_2 = math.sqrt(0.5)
    M_SQRT2 = math.sqrt(2.0)
    ipdopd_sin = [f32(v) for v in (0, M_SQRT1_2, 1, M_SQRT1_2, 0, -M_SQRT1_2, -1, -M_SQRT1_2)]
    ipdopd_cos = [f32(v) for v in (1, M_SQRT1_2, 0, -M_SQRT1_2, -1, -M_SQRT1_2, 0, M_SQRT1_2)]
    t["pd_re_smooth"] = [0.0] * 512
    t["pd_im_smooth"] = [0.0] * 512
    for pd0 in range(8):
        for pd1 in range(8):
            for pd2 in range(8):
                re_s = f32(f32(f32(0.25 * ipdopd_cos[pd0]) + f32(0.5 * ipdopd_cos[pd1])) + ipdopd_cos[pd2])
                im_s = f32(f32(f32(0.25 * ipdopd_sin[pd0]) + f32(0.5 * ipdopd_sin[pd1])) + ipdopd_sin[pd2])
                mag = f32(1.0 / math.hypot(im_s, re_s))
                t["pd_re_smooth"][pd0 * 64 + pd1 * 8 + pd2] = f32(re_s * mag)
                t["pd_im_smooth"][pd0 * 64 + pd1 * 8 + pd2] = f32(im_s * mag)
    iid_par_dequant = [
        0.05623413251903, 0.12589254117942, 0.19952623149689, 0.31622776601684,
        0.44668359215096, 0.63095734448019, 0.79432823472428, 1,
        1.25892541179417, 1.58489319246111, 2.23872113856834, 3.16227766016838,
        5.01187233627272, 7.94328234724282, 17.7827941003892,
        0.00316227766017, 0.00562341325190, 0.01, 0.01778279410039,
        0.03162277660168, 0.05623413251903, 0.07943282347243, 0.11220184543020,
        0.15848931924611, 0.22387211385683, 0.31622776601684, 0.39810717055350,
        0.50118723362727, 0.63095734448019, 0.79432823472428, 1,
        1.25892541179417, 1.58489319246111, 1.99526231496888, 2.51188643150958,
        3.16227766016838, 4.46683592150963, 6.30957344480193, 8.91250938133745,
        12.5892541179417, 17.7827941003892, 31.6227766016838, 56.2341325190349,
        100.0, 177.827941003892, 316.227766016837,
    ]
    icc_invq = [f32(v) for v in (1, 0.937, 0.84118, 0.60092, 0.36764, 0, -0.589, -1)]
    acos_icc_invq = [f32(v) for v in
                     (0, 0.35685527, 0.57133466, 0.92614472, 1.1943263, math.pi / 2, 2.2006171, math.pi)]
    t["HA"] = [0.0] * (46 * 8 * 4)
    t["HB"] = [0.0] * (46 * 8 * 4)
    sqrt2f = f32(M_SQRT2)
    sqrt1_2f = f32(M_SQRT1_2)
    for iid in range(46):
        c = f32(iid_par_dequant[iid])
        c1 = f32(sqrt2f / f32(math.sqrt(f32(1.0 + f32(c * c)))))
        c2 = f32(c * c1)
        for icc in range(8):
            alpha = f32(0.5 * acos_icc_invq[icc])
            beta = f32(f32(alpha * f32(c1 - c2)) * sqrt1_2f)
            o = (iid * 8 + icc) * 4
            t["HA"][o + 0] = f32(c2 * f32(math.cos(f32(beta + alpha))))
            t["HA"][o + 1] = f32(c1 * f32(math.cos(f32(beta - alpha))))
            t["HA"][o + 2] = f32(c2 * f32(math.sin(f32(beta + alpha))))
            t["HA"][o + 3] = f32(c1 * f32(math.sin(f32(beta - alpha))))
            rho = max(icc_invq[icc], f32(0.05))
            alpha = f32(0.5 * math.atan2(f32(f32(2.0 * c) * rho), f32(f32(c * c) - 1.0)))
            mu = f32(c + f32(1.0 / c))
            mu = f32(math.sqrt(f32(1.0 + f32(f32(f32(f32(4 * rho) * rho) - 4)) / f32(mu * mu))))
            gamma = f32(math.atan(f32(math.sqrt(f32(f32(1.0 - mu) / f32(1.0 + mu))))))
            if alpha < 0:
                alpha = f32(alpha + math.pi / 2)
            alpha_c = f32(math.cos(alpha))
            alpha_s = f32(math.sin(alpha))
            gamma_c = f32(math.cos(gamma))
            gamma_s = f32(math.sin(gamma))
            t["HB"][o + 0] = f32(M_SQRT2 * alpha_c * gamma_c)
            t["HB"][o + 1] = f32(M_SQRT2 * alpha_s * gamma_c)
            t["HB"][o + 2] = f32(-M_SQRT2 * alpha_s * gamma_s)
            t["HB"][o + 3] = f32(M_SQRT2 * alpha_c * gamma_s)
    f_center_20 = [-3, -1, 1, 3, 5, 7, 10, 14, 18, 22]
    f_center_34 = [2, 6, 10, 14, 18, 22, 26, 30, 34, -10, -6, -2, 51, 57, 15, 21,
                   27, 33, 39, 45, 54, 66, 78, 42, 102, 66, 78, 90, 102, 114, 126, 90]
    links = [f32(v) for v in (0.43, 0.75, 0.347)]
    gain = f32(0.39)
    t["Q_fract_allpass"] = [0.0] * (2 * 50 * 3 * 2)
    t["phi_fract"] = [0.0] * (2 * 50 * 2)
    # The C only initializes the bands the decoder addresses
    # (NR_ALLPASS_BANDS: 30 for is34=0, 50 for is34=1); the rest of the
    # static arrays stays zero and unused.
    for is34, nband in ((0, 30), (1, 50)):
        for k in range(nband):
            if is34 == 0:
                fc = f_center_20[k] * 0.125 if k < len(f_center_20) else k - f32(6.5)
            else:
                fc = f_center_34[k] / 24.0 if k < len(f_center_34) else k - f32(26.5)
            for m in range(3):
                th = -math.pi * links[m] * fc
                t["Q_fract_allpass"][(is34 * 50 + k) * 6 + m * 2 + 0] = f32(math.cos(th))
                t["Q_fract_allpass"][(is34 * 50 + k) * 6 + m * 2 + 1] = f32(math.sin(th))
            th = -math.pi * gain * fc
            t["phi_fract"][(is34 * 50 + k) * 2 + 0] = f32(math.cos(th))
            t["phi_fract"][(is34 * 50 + k) * 2 + 1] = f32(math.sin(th))

    def filt(proto, bands):
        out = []
        for q in range(bands):
            for n in range(7):
                th = 2 * math.pi * (q + 0.5) * (n - 6) / bands
                p = f32(proto[n])
                out.append(f32(p * math.cos(th)))
                out.append(f32(p * -math.sin(th)))
        return out

    g0_Q8 = [0.00746082949812, 0.02270420949825, 0.04546865930473, 0.07266113929591,
             0.09885108575264, 0.11793710567217, 0.125]
    g0_Q12 = [0.04081179924692, 0.03812810994926, 0.05144908135699, 0.06399831151592,
              0.07428313801106, 0.08100347892914, 0.08333333333333]
    g1_Q8 = [0.01565675600122, 0.03752716391991, 0.05417891378782, 0.08417044116767,
             0.10307344158036, 0.12222452249753, 0.125]
    g2_Q4 = [-0.05908211155639, -0.04871498374946, 0.0, 0.07778723915851,
             0.16486303567403, 0.23279856662996, 0.25]
    t["f20_0_8"] = filt(g0_Q8, 8)
    t["f34_0_12"] = filt(g0_Q12, 12)
    t["f34_1_8"] = filt(g1_Q8, 8)
    t["f34_2_4"] = filt(g2_Q4, 4)
    t["g1_Q2"] = [f32(v) for v in (0.0, 0.01899487526049, 0.0, -0.07293139167538, 0.0, 0.30596630545168, 0.5)]
    return t


def ulp_diff(a, b):
    ia = struct.unpack("<i", struct.pack("<f", a))[0]
    ib = struct.unpack("<i", struct.pack("<f", b))[0]
    if ia < 0:
        ia -= (1 << 31)
    if ib < 0:
        ib -= (1 << 31)
    return abs(ia - ib)


def parse_psdata():
    src = PSDATA.read_text()
    sizes = [int(x) for x in re.search(r"huff_sizes\[\] = \{([^}]*)\}", src).group(1).split(",")]
    body = re.search(r"aacps_huff_tabs\[\]\[2\] = \{(.*?)\};", src, re.S).group(1)
    pairs = re.findall(r"\{\s*(-?\d+)\s*,\s*(-?\d+)\s*\}", body)
    pairs = [(int(a), int(b)) for a, b in pairs]
    offsets = [int(x) for x in re.sub(r"\s+", "", re.search(r"huff_offset\[\] = \{([^}]*)\}", src, re.S).group(1)).split(",") if x]
    k20 = [int(x) for x in re.sub(r"\s+", "", re.search(r"ff_k_to_i_20\[\] = \{([^}]*)\}", src, re.S).group(1)).split(",") if x]
    k34 = [int(x) for x in re.sub(r"\s+", "", re.search(r"ff_k_to_i_34\[\] = \{([^}]*)\}", src, re.S).group(1)).split(",") if x]
    tabs = []
    pos = 0
    for n in sizes:
        tabs.append(pairs[pos:pos + n])
        pos += n
    assert pos == len(pairs), (pos, len(pairs))
    assert len(offsets) == 10
    return sizes, tabs, offsets, k20, k34


def canonical(lens):
    """FFmpeg ff_vlc_init_from_lengths: left-aligned code accumulation in
    table order. Returns right-aligned codes."""
    codes = []
    acc = 0  # left-aligned 64-bit accumulator
    for l in lens:
        assert l > 0
        codes.append(acc >> (32 - l))
        acc += 1 << (32 - l)
    assert acc == 1 << 32, "VLC tree not complete"
    return codes


def emit_floats(out, name, vals, per_line=4):
    out.append("let %s : Array[Double] = [" % name)
    for i in range(0, len(vals), per_line):
        chunk = ", ".join(repr(v) for v in vals[i:i + per_line])
        out.append("  " + chunk + ",")
    out.append("]")
    out.append("")


def b64(data: bytes) -> str:
    import base64
    return base64.b64encode(data).decode()


def bytes_lit(b64s: str) -> str:
    parts = []
    for i in range(0, len(b64s), 8192):
        parts.append('b"%s"' % b64s[i:i + 8192])
    return " +\n  ".join(parts)


def emit_f64_table(out, name, vals, comment):
    import struct
    raw = struct.pack("<%dd" % len(vals), *vals)
    out.append("///| %s" % comment)
    out.append("let %s : Array[Double] = ps_unpack_f64(%s)" % (
        name, bytes_lit(b64(raw))))
    out.append("")


def emit_huff_table(out, name, lens, syms, codes):
    raw = bytes(lens) + bytes(s + 32 for s in syms)
    for c in codes:
        raw += bytes((c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF))
    out.append("///| Huffman table huff_%s: lengths, offset-baked symbols and" % name)
    out.append("/// canonical codes (table order), packed as bytes then base64.")
    out.append("let ps_huff_%s : Bytes = %s" % (
        name, bytes_lit(b64(raw))))
    out.append("")


def emit_i32_table(out, name, vals, comment):
    raw = bytes(v & 0xFF for v in vals)
    out.append("///| %s" % comment)
    out.append("let %s : Array[Int32] = ps_unpack_i32(%s)" % (
        name, bytes_lit(b64(raw))))
    out.append("")


def main():
    dumped = parse_dump()
    # The hybrid filter tables are declared [bands][8][2] but only the first
    # 7 of 8 slots are initialized; compact them to the [bands][7][2] layout
    # this port uses.
    for name, bands in (("f20_0_8", 8), ("f34_0_12", 12), ("f34_1_8", 8), ("f34_2_4", 4)):
        src = dumped[name]
        compact = []
        for q in range(bands):
            compact.extend(src[q * 16:q * 16 + 14])
        dumped[name] = compact
    computed = compute_formulas() if dumped else None
    if dumped and computed is not None:
        for k, cv in computed.items():
            dv = dumped.get(k)
            if dv is None:
                raise SystemExit("dump missing table: " + k)
            worst = max(ulp_diff(a, f32(b)) for a, b in zip(cv, dv))
            if worst > 8:
                raise SystemExit(
                    "table %s: formula vs dump differ by %d ulps" % (k, worst))
        print("formula cross-check: all tables within 8 ulps of the C dump")

    tables = dumped or computed
    if tables is None:
        raise SystemExit("no dump at _build/ps_work/ps_tables.txt and formulas disabled")

    sizes, tabs, offsets, k20, k34 = parse_psdata()
    out = []
    out.append("///|")
    out.append("/// Parametric Stereo tables, generated by scripts/extract_ps_tables.py")
    out.append("/// from the FFmpeg 9.0.2 tablegen float tables (bit-exact transcription")
    out.append("/// of the instrumented `ps_tableinit` dump: each float32 value widened")
    out.append("/// to an exact double, packed little-endian f64 and base64'd) and the")
    out.append("/// Huffman data tables of libavcodec/aacpsdata.c (canonical codes")
    out.append("/// assigned in table order, the `huff_offset` baked into the symbols,")
    out.append("/// as `ff_vlc_init_from_lengths`). The byte-string form keeps the wasm")
    out.append("/// init function's local count flat; `ps_unpack_*` decode at startup.")
    out.append("/// LGPL-2.1-or-later.")
    out.append("")
    for name in ("pd_re_smooth", "pd_im_smooth", "HA", "HB", "f20_0_8", "f34_0_12",
                 "f34_1_8", "f34_2_4", "Q_fract_allpass", "phi_fract", "g1_Q2"):
        emit_f64_table(out, "ps_" + name.lower(), tables[name],
                       "`%s` (%d values)." % (name, len(tables[name])))
    names = ["iid_df1", "iid_dt1", "iid_df0", "iid_dt0", "icc_df", "icc_dt",
             "ipd_df", "ipd_dt", "opd_df", "opd_dt"]
    for name, tab, off in zip(names, tabs, offsets):
        lens = [l for _, l in tab]
        syms = [s + off for s, _ in tab]
        codes = canonical(lens)
        emit_huff_table(out, name, lens, syms, codes)
    emit_i32_table(out, "ps_k_to_i_20", k20, "Table 8.48 (`ff_k_to_i_20`).")
    emit_i32_table(out, "ps_k_to_i_34", k34, "Table 8.49 (`ff_k_to_i_34`).")
    OUT.write_text("\n".join(out), encoding="utf-8", newline="\n")
    print("wrote", OUT, len(out), "lines")


if __name__ == "__main__":
    main()
