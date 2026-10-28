"""Generate libavcodec/ac3_tables.mbt from the FFmpeg 9.0.2 AC-3 sources.

Run from the moonbit/ directory:
    python scripts/_gen_ac3_tables.py
The FFmpeg tree is expected at ../.scratch/FFmpeg-n9.0.2 (repository scratch).
"""

import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, ".scratch", "FFmpeg-n9.0.2", "libavcodec")
OUT = os.path.join(ROOT, "libavcodec", "ac3_tables.mbt")


def read(name):
    with open(os.path.join(SRC, name), "r", encoding="utf-8") as f:
        text = f.read()
    # Comments can contain look-alike array snippets; strip them first.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def extract_block(text, name):
    m = re.search(r"\b" + re.escape(name) + r"\s*\[[^=]*=\s*\{", text)
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


def numbers(block):
    return [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|\d+", block)]


def rows(block):
    """Split a 2-D initializer into rows of numbers."""
    out = []
    depth = 0
    start = None
    for i, c in enumerate(block):
        if c == "{":
            if depth == 0:
                start = i + 1
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                out.append(numbers(block[start:i]))
    return out


def one_d(block):
    return numbers(block)


def fmt(values, indent="  "):
    parts = []
    for v in values:
        parts.append(str(v))
    lines = []
    cur = indent
    for p in parts:
        add = p + ", "
        if len(cur) + len(add) > 92:
            lines.append(cur.rstrip())
            cur = indent + add
        else:
            cur += add
    if cur.strip():
        lines.append(cur.rstrip())
    return "\n".join(lines)


def emit_1d(name, values, comment):
    return "///|\n/// %s\nlet %s : FixedArray[Int32] = [\n%s\n]\n" % (
        comment, name, fmt(values))


def emit_2d(name, rws, comment):
    body = []
    for row in rws:
        body.append("  [" + ", ".join(str(v) for v in row) + "]")
    return "///|\n/// %s\nlet %s : Array[FixedArray[Int32]] = [\n%s\n]\n" % (
        comment, name, ",\n".join(body))


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


def symmetric_dequant(code, levels):
    return trunc_div((code - (levels >> 1)) * (1 << 24), levels)


ac3_c = read("ac3.c")
ac3tab_c = read("ac3tab.c")
ac3dec_data_c = read("ac3dec_data.c")

band_start = one_d(extract_block(ac3_c, "ff_ac3_band_start_tab"))
bin_to_band = one_d(extract_block(ac3_c, "ff_ac3_bin_to_band_tab"))
log_add = one_d(extract_block(ac3_c, "ac3_log_add_tab"))
hearing = rows(extract_block(ac3_c, "ac3_hearing_threshold_tab"))

frame_size = rows(extract_block(ac3tab_c, "ff_ac3_frame_size_tab"))
channels = one_d(extract_block(ac3tab_c, "ff_ac3_channels_tab"))
sample_rate = one_d(extract_block(ac3tab_c, "ff_ac3_sample_rate_tab"))
bitrate = one_d(extract_block(ac3tab_c, "ff_ac3_bitrate_tab"))
rematrix = one_d(extract_block(ac3tab_c, "ff_ac3_rematrix_band_tab"))
cpl_band_struct = one_d(extract_block(ac3tab_c, "ff_eac3_default_cpl_band_struct"))
bap = one_d(extract_block(ac3tab_c, "ff_ac3_bap_tab"))
slow_decay = one_d(extract_block(ac3tab_c, "ff_ac3_slow_decay_tab"))
fast_decay = one_d(extract_block(ac3tab_c, "ff_ac3_fast_decay_tab"))
slow_gain = one_d(extract_block(ac3tab_c, "ff_ac3_slow_gain_tab"))
db_per_bit = one_d(extract_block(ac3tab_c, "ff_ac3_db_per_bit_tab"))
# ff_ac3_floor_tab is int16_t; 0xf800 means -2048.
floor_tab = [v - 0x10000 if v >= 0x8000 else v
             for v in one_d(extract_block(ac3tab_c, "ff_ac3_floor_tab"))]
fast_gain = one_d(extract_block(ac3tab_c, "ff_ac3_fast_gain_tab"))

quantization = one_d(extract_block(ac3dec_data_c, "ff_ac3_quantization_tab"))
ungroup5 = rows(extract_block(ac3dec_data_c, "ff_ac3_ungroup_3_in_5_bits_tab"))

# COMMON_CHANNEL_MAP (ac3tab.h) expanded.
channel_map = [
    [[0, 1, 0, 0, 0, 0], [0, 1, 2, 0, 0, 0]],
    [[0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0]],
    [[0, 1, 0, 0, 0, 0], [0, 1, 2, 0, 0, 0]],
    [[0, 2, 1, 0, 0, 0], [0, 2, 1, 3, 0, 0]],
    [[0, 1, 2, 0, 0, 0], [0, 1, 3, 2, 0, 0]],
    [[0, 2, 1, 3, 0, 0], [0, 2, 1, 4, 3, 0]],
    [[0, 1, 2, 3, 0, 0], [0, 1, 4, 2, 3, 0]],
    [[0, 2, 1, 3, 4, 0], [0, 2, 1, 5, 3, 4]],
]

gain_levels = [
    "1.41421356237309504880",  # M_SQRT2 (+3 dB)
    "1.1892071150027209",      # +1.5 dB
    "1.0000000000000000",      # 0 dB
    "0.8408964152537145",      # -1.5 dB
    "0.70710678118654752440",  # M_SQRT1_2 (-3 dB)
    "0.5946035575013605",      # -4.5 dB
    "0.5000000000000000",      # -6 dB
    "0.0000000000000000",      # -inf
    "0.3535533905932738",      # -9 dB
]
gain_levels = [float(v) for v in gain_levels]

ungroup7 = [[i // 25, (i % 25) // 5, (i % 25) % 5] for i in range(128)]
bap1 = [[symmetric_dequant(u[0], 3), symmetric_dequant(u[1], 3),
         symmetric_dequant(u[2], 3)] for u in ungroup5]
bap2 = [[symmetric_dequant(u[0], 5), symmetric_dequant(u[1], 5),
         symmetric_dequant(u[2], 5)] for u in ungroup7]
bap4 = [[symmetric_dequant(i // 11, 11), symmetric_dequant(i % 11, 11)]
        for i in range(128)]
bap3 = [symmetric_dequant(i, 7) for i in range(8)]
bap5 = [symmetric_dequant(i, 15) for i in range(16)]


def emit_float_1d(name, values, comment, text):
    body = ",\n".join("  " + v for v in text)
    return "///|\n/// %s\nlet %s : FixedArray[Double] = [\n%s\n]\n" % (
        comment, name, body)


parts = []
parts.append("""///|
/// AC-3 tables extracted from FFmpeg 9.0.2 `libavcodec/ac3.c`, `ac3tab.c`
/// and `ac3dec_data.c`; generated by `scripts/_gen_ac3_tables.py`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
""")
parts.append(emit_2d("ac3_frame_size_tab", frame_size,
                     "`ff_ac3_frame_size_tab`: frame size code to 16-bit words."))
parts.append(emit_1d("ac3_channels_tab", channels,
                     "`ff_ac3_channels_tab`: acmod to full-bandwidth channels."))
parts.append(emit_1d("ac3_sample_rate_tab", sample_rate,
                     "`ff_ac3_sample_rate_tab`."))
parts.append(emit_1d("ac3_bitrate_tab", bitrate, "`ff_ac3_bitrate_tab` (kbit/s)."))
parts.append(emit_1d("ac3_rematrix_band_tab", rematrix,
                     "`ff_ac3_rematrix_band_tab`."))
parts.append(emit_1d("ac3_default_cpl_band_struct", cpl_band_struct,
                     "`ff_eac3_default_cpl_band_struct`."))
parts.append(emit_1d("ac3_bap_tab", bap, "`ff_ac3_bap_tab`."))
parts.append(emit_1d("ac3_slow_decay_tab", slow_decay,
                     "`ff_ac3_slow_decay_tab`."))
parts.append(emit_1d("ac3_fast_decay_tab", fast_decay,
                     "`ff_ac3_fast_decay_tab`."))
parts.append(emit_1d("ac3_slow_gain_tab", slow_gain,
                     "`ff_ac3_slow_gain_tab`."))
parts.append(emit_1d("ac3_db_per_bit_tab", db_per_bit,
                     "`ff_ac3_db_per_bit_tab`."))
parts.append(emit_1d("ac3_floor_tab", floor_tab, "`ff_ac3_floor_tab`."))
parts.append(emit_1d("ac3_fast_gain_tab", fast_gain,
                     "`ff_ac3_fast_gain_tab`."))
parts.append(emit_1d("ac3_band_start_tab", band_start,
                     "`ff_ac3_band_start_tab`."))
parts.append(emit_1d("ac3_bin_to_band_tab", bin_to_band,
                     "`ff_ac3_bin_to_band_tab`."))
parts.append(emit_1d("ac3_log_add_tab", log_add,
                     "`ac3_log_add_tab` (logadd table)."))
parts.append(emit_2d("ac3_hearing_threshold_tab", hearing,
                     "`ac3_hearing_threshold_tab`, [band][sr_code]."))
flat_channel_map = []
for acmod in channel_map:
    for lfe in acmod:
        flat_channel_map.extend(lfe)
parts.append(emit_1d("ac3_dec_channel_map", flat_channel_map,
                     "`ff_ac3_dec_channel_map` flattened: [acmod*2+lfe][decoded channel]."))
parts.append(emit_2d("ac3_bap1_mantissas", bap1,
                     "`ff_ac3_bap1_mantissas`: 3 grouped mantissas per 5-bit code."))
parts.append(emit_2d("ac3_bap2_mantissas", bap2,
                     "`ff_ac3_bap2_mantissas`: 3 grouped mantissas per 7-bit code."))
parts.append(emit_2d("ac3_bap4_mantissas", bap4,
                     "`ff_ac3_bap4_mantissas`: 2 grouped mantissas per 7-bit code."))
parts.append(emit_1d("ac3_bap3_mantissas", bap3, "`ff_ac3_bap3_mantissas`."))
parts.append(emit_1d("ac3_bap5_mantissas", bap5, "`ff_ac3_bap5_mantissas`."))
parts.append(emit_1d("ac3_quantization_tab", quantization,
                     "`ff_ac3_quantization_tab`."))
parts.append(emit_2d("ac3_ungroup_3_in_7_bits_tab", ungroup7,
                     "`ff_ac3_ungroup_3_in_7_bits_tab`."))

text = "\n".join(parts)
assert len(text) > 4000
with open(OUT + ".new", "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
os.replace(OUT + ".new", OUT)
print("wrote", OUT, len(text), "bytes")
print("band_start", len(band_start), "bin_to_band", len(bin_to_band),
      "log_add", len(log_add), "hearing", len(hearing),
      "frame_size", len(frame_size), "bap", len(bap))
