# Generate libavcodec/realaudio_tables.mbt: the tables of the RealAudio
# decoders (SIPR, RA 14.4, RA 28.8), extracted from the FFmpeg 9.0.2 C
# sources. Nothing is transcribed by hand; every value is parsed from the
# C initializer it came from and the count is checked against the declared
# dimensions.
#
# Large tables travel as base64 (little-endian binary32 values widened
# exactly to doubles, or the integer type of the C array) and are decoded
# once at startup, so they do not use init locals in the whitebox wasm.
#
# Usage (from the repo root; FFmpeg sources one directory up):
#   python -I scripts/gen_realaudio_tables.py libavcodec [ffmpeg_root]
import base64
import re
import struct
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# (C file, C name, MoonBit name, declared dims or None to read from the
# declaration, pad_to or None)
TABLES = [
    # SIPR below 16 kHz: siprdata.h
    ("siprdata.h", "mean_lsf", "sipr_mean_lsf", None, None),
    ("siprdata.h", "lsf_cb1", "sipr_lsf_cb1", None, None),
    ("siprdata.h", "lsf_cb2", "sipr_lsf_cb2", None, None),
    ("siprdata.h", "lsf_cb3", "sipr_lsf_cb3", None, None),
    ("siprdata.h", "lsf_cb4", "sipr_lsf_cb4", None, None),
    ("siprdata.h", "lsf_cb5", "sipr_lsf_cb5", None, None),
    ("siprdata.h", "gain_cb", "sipr_gain_cb", None, None),
    ("siprdata.h", "pred", "sipr_pred", None, None),
    # SIPR 16 kHz: sipr16kdata.h (`sinc_win` has 30 initializers for 40
    # slots; the rest are zero)
    ("sipr16kdata.h", "pred_16k", "sipr_pred_16k", None, None),
    ("sipr16kdata.h", "qu", "sipr_qu", None, None),
    ("sipr16kdata.h", "gain_cb_16k", "sipr_gain_cb_16k", None, None),
    ("sipr16kdata.h", "gain_pitch_cb_16k", "sipr_gain_pitch_cb_16k", None, None),
    ("sipr16kdata.h", "mean_lsf_16k", "sipr_mean_lsf_16k", None, None),
    ("sipr16kdata.h", "sinc_win", "sipr_sinc_win", None, None),
    ("sipr16kdata.h", "lsf_cb1_16k", "sipr_lsf_cb1_16k", None, None),
    ("sipr16kdata.h", "lsf_cb2_16k", "sipr_lsf_cb2_16k", None, None),
    ("sipr16kdata.h", "lsf_cb3_16k", "sipr_lsf_cb3_16k", None, None),
    ("sipr16kdata.h", "lsf_cb4_16k", "sipr_lsf_cb4_16k", None, None),
    ("sipr16kdata.h", "lsf_cb5_16k", "sipr_lsf_cb5_16k", None, None),
    # shared ACELP tables of sipr.c / sipr16k.c
    ("acelp_vectors.c", "ff_pow_0_7", "sipr_pow_0_7", None, None),
    ("acelp_vectors.c", "ff_pow_0_75", "sipr_pow_0_75", None, None),
    ("acelp_vectors.c", "ff_pow_0_55", "sipr_pow_0_55", None, None),
    ("acelp_vectors.c", "ff_fc_4pulses_8bits_tracks_13",
     "sipr_fc_4pulses_8bits_tracks_13", None, None),
    ("sipr.c", "ff_pow_0_5", "sipr_pow_0_5", None, None),
    # RA 14.4: ra144.c
    ("ra144.c", "ff_gain_val_tab", "ra144_gain_val_tab", None, None),
    ("ra144.c", "ff_gain_exp_tab", "ra144_gain_exp_tab", None, None),
    ("ra144.c", "ff_cb1_vects", "ra144_cb1_vects", None, None),
    ("ra144.c", "ff_cb2_vects", "ra144_cb2_vects", None, None),
    ("ra144.c", "ff_cb1_base", "ra144_cb1_base", None, None),
    ("ra144.c", "ff_cb2_base", "ra144_cb2_base", None, None),
    ("ra144.c", "ff_energy_tab", "ra144_energy_tab", None, None),
    ("ra144.c", "lpc_refl_cb1", "ra144_lpc_refl_cb1", None, None),
    ("ra144.c", "lpc_refl_cb2", "ra144_lpc_refl_cb2", None, None),
    ("ra144.c", "lpc_refl_cb3", "ra144_lpc_refl_cb3", None, None),
    ("ra144.c", "lpc_refl_cb4", "ra144_lpc_refl_cb4", None, None),
    ("ra144.c", "lpc_refl_cb5", "ra144_lpc_refl_cb5", None, None),
    ("ra144.c", "lpc_refl_cb6", "ra144_lpc_refl_cb6", None, None),
    ("ra144.c", "lpc_refl_cb7", "ra144_lpc_refl_cb7", None, None),
    ("ra144.c", "lpc_refl_cb8", "ra144_lpc_refl_cb8", None, None),
    ("ra144.c", "lpc_refl_cb9", "ra144_lpc_refl_cb9", None, None),
    ("ra144.c", "lpc_refl_cb10", "ra144_lpc_refl_cb10", None, None),
    # RA 28.8: ra288.h (the windows and bandwidth tables are declared with
    # DECLARE_ALIGNED(..)[FFALIGN(n, 16)], the unused slots being zero)
    ("ra288.h", "amptable", "ra288_amptable", None, None),
    ("ra288.h", "codetable", "ra288_codetable", None, None),
    ("ra288.h", "syn_window", "ra288_syn_window", None, 112),
    ("ra288.h", "gain_window", "ra288_gain_window", None, 48),
    ("ra288.h", "syn_bw_tab", "ra288_syn_bw_tab", None, 48),
    ("ra288.h", "gain_bw_tab", "ra288_gain_bw_tab", None, 16),
]

NUMBER = re.compile(r"-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][-+]?\d+)?"
                    r"(?:\s*/\s*\d+(?:\.\d*)?)?")
FLOAT_TYPES = {"float", "double"}
INT_TYPES = {"int8_t": "b", "uint8_t": "B", "int16_t": "h", "uint16_t": "H",
             "int32_t": "i", "uint32_t": "I", "int": "i", "unsigned": "I"}
SMALL = 16  # tables up to this many values are emitted as literals


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", " ", text)


def find_array(text, name):
    """(C type, dims, initializer text) of one array. The initializer is
    taken up to the brace matching the opening one, so two-dimensional
    tables keep all their rows."""
    text = strip_comments(text)
    # `1.0/(1 << n)` powers of two (ff_pow_0_5)
    text = re.sub(r"\(1\s*<<\s*(\d+)\)", lambda m: str(1 << int(m.group(1))), text)
    plain = re.compile(
        r"(?:static\s+)?const\s+(\w+)\s+" + re.escape(name) +
        r"\s*((?:\[[^\]]*\]\s*)+)=\s*\{")
    m = plain.search(text)
    dims, aligned_len = None, None
    if m:
        ctype, dims = m.group(1), m.group(2)
    else:
        special = re.compile(
            r"DECLARE_ALIGNED\(\s*\d+\s*,\s*static\s+const\s+(\w+)\s*,\s*" +
            re.escape(name) +
            r"\s*\)\s*\[\s*FFALIGN\(\s*(\d+)\s*,\s*16\s*\)\s*\]\s*=\s*\{")
        m = special.search(text)
        if not m:
            return None
        ctype = m.group(1)
        aligned_len = (int(m.group(2)) + 15) // 16 * 16
    i, depth = m.end(), 1
    while depth > 0:
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    body = text[m.end():i - 1]
    if dims:
        sizes = [int(s) for s in re.findall(r"\[\s*(\d+)\s*\]", dims)]
    else:
        sizes = [aligned_len]
    return ctype, sizes, body


def parse_values(body):
    values = []
    for tok in NUMBER.findall(strip_comments(body)):
        # "a / b" rationals (M_PI multiples are not expected here)
        if "/" in tok:
            num, den = tok.split("/")
            values.append(eval(num.strip()) / eval(den.strip()))
        else:
            values.append(eval(tok.strip()))
    return values


def dims_of(sizes):
    n = 1
    for s in sizes:
        n *= s
    return n


def f64_blob(values):
    return base64.b64encode(
        b"".join(struct.pack("<d", struct.unpack("<f", struct.pack("<f", v))[0])
                 for v in values)).decode("ascii")


def int_blob(values, code):
    return base64.b64encode(
        b"".join(struct.pack("<" + code, int(v)) for v in values)).decode("ascii")


def fmt(v):
    text = repr(float(v))
    return text if "." in text or "e" in text else text + ".0"


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavcodec"
    ffroot = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(ROOT))
    sources = {}
    blocks = []
    for cfile, cname, mname, _, pad_to in TABLES:
        if cfile not in sources:
            path = os.path.join(ffroot, "libavcodec", cfile)
            sources[cfile] = open(path, encoding="utf-8", errors="replace").read()
        found = find_array(sources[cfile], cname)
        if not found:
            raise SystemExit(f"{cfile}: array {cname} not found")
        ctype, sizes, body = found
        values = parse_values(body)
        if not sizes:  # `[]`: the initializer sets the length
            sizes = [len(values)]
        if pad_to is not None:
            if len(values) > pad_to:
                raise SystemExit(f"{cname}: {len(values)} values > {pad_to}")
            values += [0] * (pad_to - len(values))
        expected = dims_of(sizes)
        if len(values) > expected:
            raise SystemExit(f"{cname}: {len(values)} values for {sizes}")
        if len(values) < expected:
            print(f"  note: {cname} has {len(values)} initializers for "
                  f"{expected} slots; the rest are zero")
            values += [0] * (expected - len(values))
        shape = "".join(f"[{s}]" for s in sizes)
        if ctype in FLOAT_TYPES:
            if len(values) <= SMALL:
                init = "[" + ", ".join(fmt(v) for v in values) + "]"
                kind = "FixedArray[Double]"
            else:
                init = f'realaudio_unpack_f64(b"{f64_blob(values)}")'
                kind = "FixedArray[Double]"
        else:
            code = INT_TYPES[ctype]
            wrap = {"b": "realaudio_unpack_i8", "B": "realaudio_unpack_u8",
                    "h": "realaudio_unpack_i16", "H": "realaudio_unpack_u16"}[code]
            if len(values) <= SMALL:
                init = "[" + ", ".join(str(int(v)) for v in values) + "]"
            else:
                init = f'{wrap}(b"{int_blob(values, code)}")'
            kind = "FixedArray[Int32]"
        dims_text = "".join(f"[{s}]" for s in sizes)
        blocks.append(f'''///|
/// `{cname}{dims_text}` (`libavcodec/{cfile}`), in file order.

///|
let {mname} : {kind} = {init}
''')
        print(f"{mname:34s} {ctype:9s} {shape:16s} {len(values)} values")

    body = PROLOGUE + "\n" + "".join(blocks)
    path = os.path.join(out_dir, "realaudio_tables.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(path, len(body), "bytes")


PROLOGUE = '''///|
/// Tables of the RealAudio decoders - SIPR / ACELP.NET (`siprdata.h`,
/// `sipr16kdata.h`, the shared ACELP tables `sipr.c` and `sipr16k.c` use),
/// RealAudio 14.4 (`ra144.c`) and RealAudio 28.8 (`ra288.h`) - extracted
/// from FFmpeg 9.0.2 by `scripts/gen_realaudio_tables.py`, which parses the
/// C initializers and checks every count against the declared dimensions.
/// Original FFmpeg code is LGPL-2.1-or-later; this transcription keeps the
/// same license.
///
/// The C tables are `float`. Large ones travel as base64 of the binary32
/// values widened exactly to doubles and are decoded once at startup (the
/// decoders evaluate the C float pipeline in doubles); integer tables are
/// base64 of the C integer type. Two-dimensional tables are flattened in
/// file order, so `cb[index * stride + k]` is the C `cb[index][k]`.

///|
/// Decode one base64'd little-endian f64 blob into doubles.
fn realaudio_unpack_f64(b64 : Bytes) -> FixedArray[Double] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("realaudio f64 table: invalid base64")
  }
  let n = raw.length() / 8
  let out = FixedArray::make(n, 0.0)
  for i in 0..<n {
    let mut v : UInt64 = 0
    for k in 0..<8 {
      v = v | (raw[i * 8 + k].to_int().reinterpret_as_uint().to_uint64() << (k * 8))
    }
    out[i] = v.reinterpret_as_double()
  }
  out
}

///|
/// Decode one base64'd byte blob into sign-extended int8 values.
fn realaudio_unpack_i8(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("realaudio i8 table: invalid base64")
  }
  let out = FixedArray::make(raw.length(), 0)
  for i in 0..<raw.length() {
    let v = raw[i].to_int()
    out[i] = if v >= 128 { v - 256 } else { v }
  }
  out
}

///|
/// Decode one base64'd byte blob into unsigned 8-bit values.
fn realaudio_unpack_u8(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("realaudio u8 table: invalid base64")
  }
  let out = FixedArray::make(raw.length(), 0)
  for i in 0..<raw.length() {
    out[i] = raw[i].to_int()
  }
  out
}

///|
/// Decode one base64'd little-endian int16 blob into sign-extended values.
fn realaudio_unpack_i16(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("realaudio i16 table: invalid base64")
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
fn realaudio_unpack_u16(b64 : Bytes) -> FixedArray[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 22) {
    Ok(v) => v
    Err(_) => abort("realaudio u16 table: invalid base64")
  }
  let n = raw.length() / 2
  let out = FixedArray::make(n, 0)
  for i in 0..<n {
    out[i] = raw[i * 2].to_int() | (raw[i * 2 + 1].to_int() << 8)
  }
  out
}
'''

main()
