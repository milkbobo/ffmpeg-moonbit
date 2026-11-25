# Generate libavcodec/amrwb_tables.mbt: every table the AMR-WB decoder
# (amrwbdec.c) reads, extracted from FFmpeg 9.0.2 `libavcodec/amrwbdata.h`.
# Nothing is transcribed by hand; each value is parsed from its C
# initializer and the count is checked against the declared dimensions.
#
# The nine `order_MODE_*` bit-reordering tables are expanded the way the C
# sees them: `AMR_BIT(field)` is `offsetof(AMRWBFrame, field)` and
# `AMR_OF(n, field)` is `offsetof(AMRWBFrame, subframe[n].field)`, with the
# uint16_t layout of amrwbdata.h (vad, isp_id[7], subframe[4] of 24 bytes).
#
# Tables travel as base64 (float literals widened exactly from binary32 to
# doubles, or the integer type of the C array) and are decoded once at
# startup, so they do not use init locals in the whitebox wasm.
#
# Usage (from the repo root; FFmpeg sources one directory up):
#   python -I scripts/gen_amrwb_tables.py libavcodec [ffmpeg_root]
import base64
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

MACROS = {"LP_ORDER": "16", "LP_ORDER_16k": "20", "HB_FIR_SIZE": "30",
          "UPS_FIR_SIZE": "12", "UPS_MEM_SIZE": "24"}

# (C name, MoonBit name)
INT16_TABLES = [
    ("dico1_isf", "amrwb_dico1_isf"),
    ("dico2_isf", "amrwb_dico2_isf"),
    ("dico21_isf", "amrwb_dico21_isf"),
    ("dico22_isf", "amrwb_dico22_isf"),
    ("dico23_isf", "amrwb_dico23_isf"),
    ("dico24_isf", "amrwb_dico24_isf"),
    ("dico25_isf", "amrwb_dico25_isf"),
    ("dico21_isf_36b", "amrwb_dico21_isf_36b"),
    ("dico22_isf_36b", "amrwb_dico22_isf_36b"),
    ("dico23_isf_36b", "amrwb_dico23_isf_36b"),
    ("isf_mean", "amrwb_isf_mean"),
    ("isf_init", "amrwb_isf_init"),
    ("qua_gain_6b", "amrwb_qua_gain_6b"),
    ("qua_gain_7b", "amrwb_qua_gain_7b"),
]
UINT16_TABLES = [
    ("qua_hb_gain", "amrwb_qua_hb_gain"),
    ("cf_sizes_wb", "amrwb_cf_sizes_wb"),
]
UINT8_TABLES = [
    ("pulses_nb_per_mode_tr", "amrwb_pulses_nb_per_mode_tr"),
]
FLOAT_TABLES = [
    ("isfp_inter", "amrwb_isfp_inter"),
    ("ac_inter", "amrwb_ac_inter"),
    ("energy_pred_fac", "amrwb_energy_pred_fac"),
    ("ir_filter_str", "amrwb_ir_filter_str"),
    ("ir_filter_mid", "amrwb_ir_filter_mid"),
    ("hpf_zeros", "amrwb_hpf_zeros"),
    ("hpf_31_poles", "amrwb_hpf_31_poles"),
    ("hpf_400_poles", "amrwb_hpf_400_poles"),
    ("upsample_fir", "amrwb_upsample_fir"),
    ("bpf_6_7_coef", "amrwb_bpf_6_7_coef"),
    ("lpf_7_coef", "amrwb_lpf_7_coef"),
]
ORDER_TABLES = [
    "6k60", "8k85", "12k65", "14k25", "15k85", "18k25", "19k85", "23k05",
    "23k85",
]
SCALARS = [  # (C name, MoonBit name)
    ("hpf_31_gain", "amrwb_hpf_31_gain"),
    ("hpf_400_gain", "amrwb_hpf_400_gain"),
]

NUMBER = re.compile(
    r"-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?"
    r"(?:\s*/\s*\d+(?:\.\d*)?)?"
)
# offsetof(AMRWBFrame, field)
FRAME_OFF = {"vad": 0, **{f"isp_id[{i}]": 2 + 2 * i for i in range(7)}}
# offsetof(AMRWBSubFrame, field); a subframe is 24 bytes, subframe[] at 16
SUB_OFF = {"adap": 0, "ltp": 2, "vq_gain": 4, "hb_gain": 6,
           **{f"pul_ih[{i}]": 8 + 2 * i for i in range(4)},
           **{f"pul_il[{i}]": 16 + 2 * i for i in range(4)}}


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def find_array(text, name):
    """(C type, dims, initializer text) of one array, up to the brace that
    closes the initializer."""
    text = strip_comments(text)
    for key, value in MACROS.items():
        text = re.sub(r"\b" + key + r"\b", value, text)
    m = re.search(
        r"(?:static\s+)?const\s+(\w+)\s+" + re.escape(name)
        + r"\s*((?:\[[^\]]*\]\s*)+)=\s*\{", text)
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
    sizes = [int(s) if s.strip() else 0 for s in re.findall(r"\[([^\]]*)\]", m.group(2))]
    return m.group(1), sizes, text[m.end():i - 1]


def find_scalar(text, name):
    text = strip_comments(text)
    m = re.search(r"const\s+float\s+" + re.escape(name) + r"\s*=\s*([^;]+);", text)
    if not m:
        raise SystemExit("scalar not found: " + name)
    return float(m.group(1))


def values_of(body):
    values = []
    for tok in NUMBER.findall(strip_comments(body)):
        if "/" in tok:
            num, den = tok.split("/")
            values.append(eval(num.strip()) / eval(den.strip()))  # noqa: S307
        else:
            values.append(eval(tok.strip()))  # noqa: S307
    return values


def sized(name, sizes, values):
    if 0 in sizes:
        known = 1
        for s in sizes:
            if s:
                known *= s
        sizes = [len(values) // known if s == 0 else s for s in sizes]
    n = 1
    for s in sizes:
        n *= s
    if len(values) != n:
        raise SystemExit(f"{name}: {len(values)} values for {sizes}")
    return sizes


def f32(v):
    return struct.unpack("<f", struct.pack("<f", v))[0]


def b64(raw):
    return base64.b64encode(raw).decode("ascii")


def f64_blob(values):
    return b64(b"".join(struct.pack("<d", f32(v)) for v in values))


def int_blob(values, code):
    return b64(b"".join(struct.pack("<" + code, int(v)) for v in values))


def order_table(text, mode):
    """The expanded `order_MODE_<mode>`: (size, offset, bits...) words."""
    body = find_array(text, "order_MODE_" + mode)[2]
    body = re.sub(r"AMR_OF\(\s*(\d+)\s*,\s*([\w\[\]]+)\s*\)",
                  lambda m: str(16 + 24 * int(m.group(1)) + SUB_OFF[m.group(2)]), body)
    body = re.sub(r"AMR_BIT\(\s*([\w\[\]]+)\s*\)",
                  lambda m: str(FRAME_OFF[m.group(1)]), body)
    values = [int(x, 0) for x in re.findall(r"0x[0-9a-fA-F]+|-?\d+", strip_comments(body))]
    if values[-1] != 0:
        raise SystemExit("order_MODE_" + mode + " is not 0-terminated")
    return values


PROLOGUE = r'''///|
/// Tables of the AMR-WB decoder (`libavcodec/amrwbdata.h`), extracted from
/// FFmpeg 9.0.2 by `scripts/gen_amrwb_tables.py`, which parses the C
/// initializers and checks every count against the declared dimensions.
/// Original FFmpeg code is LGPL-2.1-or-later; this transcription keeps the
/// same license.
///
/// The C tables are `float`. They travel as base64 of the binary32 values
/// widened exactly to doubles and are decoded once at startup (the decoder
/// evaluates the C float pipeline in doubles); integer tables are base64 of
/// the C integer type. Two-dimensional tables are flattened in file order,
/// so `cb[index * stride + k]` is the C `cb[index][k]`.

///|
/// Decode one base64'd little-endian f64 blob into doubles.
fn amrwb_unpack_f64(b64 : Bytes) -> FixedArray[Double] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("amrwb f64 table: invalid base64")
  }
  let n = raw.length() / 8
  let out = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let mut v : UInt64 = 0
    for k in 0..<8 {
      v = v |
        (raw[i * 8 + k].to_int().reinterpret_as_uint().to_uint64() << (k * 8))
    }
    out[i] = v.reinterpret_as_double()
  }
  out
}

///|
/// Decode one base64'd little-endian int32 blob.
fn amrwb_unpack_i32(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("amrwb i32 table: invalid base64")
  }
  let n = raw.length() / 4
  let out = FixedArray::make(n, 0)
  for i in 0..<n {
    out[i] = raw[i * 4].to_int() |
      (raw[i * 4 + 1].to_int() << 8) |
      (raw[i * 4 + 2].to_int() << 16) |
      (raw[i * 4 + 3].to_int() << 24)
  }
  out
}

///|
/// Decode one base64'd little-endian int16 blob into sign-extended values.
fn amrwb_unpack_i16(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("amrwb i16 table: invalid base64")
  }
  let n = raw.length() / 2
  let out = FixedArray::make(n, 0)
  for i in 0..<n {
    let v = raw[i * 2].to_int() | (raw[i * 2 + 1].to_int() << 8)
    out[i] = if v >= 32768 { v - 65536 } else { v }
  }
  out
}

///|
/// Decode one base64'd little-endian uint16 blob.
fn amrwb_unpack_u16(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("amrwb u16 table: invalid base64")
  }
  let n = raw.length() / 2
  let out = FixedArray::make(n, 0)
  for i in 0..<n {
    out[i] = raw[i * 2].to_int() | (raw[i * 2 + 1].to_int() << 8)
  }
  out
}

///|
/// Decode one base64'd byte blob into unsigned 8-bit values.
fn amrwb_unpack_u8(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("amrwb u8 table: invalid base64")
  }
  let out = FixedArray::make(raw.length(), 0)
  for i in 0..<raw.length() {
    out[i] = raw[i].to_int()
  }
  out
}

'''


def wrap_b64(text, width=120):
    rows = [text[i:i + width] for i in range(0, len(text), width)]
    return " +\n".join(f'  b"{row}"' for row in rows)


def emit(name, kind, init):
    return f"///|\nlet {name} : {kind} = {init}\n\n"


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavcodec"
    ffroot = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(ROOT)
    path = os.path.join(ffroot, "libavcodec", "amrwbdata.h")
    text = open(path, encoding="utf-8", errors="replace").read()
    blocks = [PROLOGUE]
    for mode in ORDER_TABLES:
        values = order_table(text, mode)
        name = "amrwb_order_mode_" + mode
        blocks.append(emit(name, "FixedArray[Int32]",
                           f'amrwb_unpack_i32(b"{int_blob(values, "i")}")'))
        print(f"{name:28s} order   {len(values)} words")
    for cname, mname in INT16_TABLES:
        ctype, sizes, body = find_array(text, cname)
        values = values_of(body)
        sizes = sized(cname, sizes, values)
        blocks.append(emit(mname, "FixedArray[Int32]",
                           f'amrwb_unpack_i16(b"{int_blob(values, "h")}")'))
        print(f"{mname:28s} {ctype:8s} {sizes} {len(values)} values")
    for cname, mname in UINT16_TABLES:
        ctype, sizes, body = find_array(text, cname)
        values = values_of(body)
        sizes = sized(cname, sizes, values)
        blocks.append(emit(mname, "FixedArray[Int32]",
                           f'amrwb_unpack_u16(b"{int_blob(values, "H")}")'))
        print(f"{mname:28s} {ctype:8s} {sizes} {len(values)} values")
    for cname, mname in UINT8_TABLES:
        ctype, sizes, body = find_array(text, cname)
        values = values_of(body)
        sizes = sized(cname, sizes, values)
        blocks.append(emit(mname, "FixedArray[Int32]",
                           f'amrwb_unpack_u8(b"{int_blob(values, "B")}")'))
        print(f"{mname:28s} {ctype:8s} {sizes} {len(values)} values")
    for cname, mname in FLOAT_TABLES:
        ctype, sizes, body = find_array(text, cname)
        if ctype not in ("float", "double"):
            raise SystemExit(f"{cname}: unexpected type {ctype}")
        values = values_of(body)
        sizes = sized(cname, sizes, values)
        blocks.append(
            emit(mname, "FixedArray[Double]",
                 f"amrwb_unpack_f64(\n{wrap_b64(f64_blob(values))}\n)"))
        print(f"{mname:28s} {ctype:8s} {sizes} {len(values)} values")
    for cname, mname in SCALARS:
        v = f32(find_scalar(text, cname))
        text_v = repr(v)
        if "." not in text_v and "e" not in text_v:
            text_v += ".0"
        blocks.append(emit(mname, "Double", text_v))
        print(f"{mname:28s} float   {text_v}")
    out = os.path.join(out_dir, "amrwb_tables.mbt")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(blocks))
    print(out, os.path.getsize(out), "bytes")


main()
