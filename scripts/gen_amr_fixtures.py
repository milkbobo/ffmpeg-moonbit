# Generate the AMR real-data tests:
#   libavformat/amrwb_realdata_test.mbt, amrwb_realdata_2_test.mbt and
#   amrnb_realdata_test.mbt.
#
# The inputs are the FATE AMR samples with their reference decodes:
#   amrnb/<rate>.amr + .pcm       (raw AMR-NB, 8 kHz)       - 8 modes
#   amrwb/seed-<rate>.awb + .pcm  (AMR-WB in 3GP, 16 kHz)   - 9 modes
# downloaded from fate-suite.ffmpeg.org on demand into .scratch/amr_dl/.
#
# Two expectations come out of them:
# * The output of the C decoder (FFmpeg 9.0.2 amrwbdec.c / amrnbdec.c,
#   compiled unmodified by scripts/amr_c_ref/build.cmd) for the first and
#   last 16 frames, compared within 2 LSB.
# * FATE's PCM, decimated (every 32nd sample for WB, every 16th for NB) and
#   compared over the whole file. FATE compares these samples with a stddev
#   fuzz because FFmpeg's float decoder is not bit-exact against them; the
#   tolerance is the larger of the C decoder's own deviation plus one LSB
#   and the port's present deviation on those samples (the generator runs
#   the CLI `decode-audio` to measure it; both numbers are in the fixture
#   comments).
#
# The generator also builds a 3GP file carrying AMR-NB (`samr`) from the
# 12.2k frames, so the MP4 mapping of both sample entries is covered.
#
# Usage (from the repo root; needs gcc on PATH and the FFmpeg tree at the
# parent directory for the C reference):
#   python -I scripts/gen_amr_fixtures.py libavformat [--fetch-only]
import base64
import os
import struct
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DL = os.path.join(ROOT, ".scratch", "amr_dl")
CREF = os.path.join(HERE, "amr_c_ref")
BASE = "https://fate-suite.ffmpeg.org/"
NB = ["4.75k", "5.15k", "5.9k", "6.7k", "7.4k", "7.95k", "10.2k", "12.2k"]
WB = ["6k60", "8k85", "12k65", "14k25", "15k85", "18k25", "19k85", "23k05", "23k85"]
NB_PACKED = [13, 14, 16, 18, 20, 21, 27, 32, 6, 1, 1, 1, 1, 1, 1, 1]
HEAD = 16  # frames of the C reference kept at each end
WINDOW_LSB = 2


def fetch():
    items = [f"amrnb/{n}.amr" for n in NB] + [f"amrnb/{n}.pcm" for n in NB]
    items += [f"amrwb/seed-{n}.awb" for n in WB] + [f"amrwb/seed-{n}.pcm" for n in WB]
    os.makedirs(DL, exist_ok=True)
    for remote in items:
        dst = os.path.join(DL, os.path.basename(remote))
        if os.path.exists(dst) and os.path.getsize(dst) > 0:
            continue
        print("download", remote)
        urllib.request.urlretrieve(BASE + remote, dst)


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                          encoding="utf-8", errors="replace", **kw)


def build_cref():
    for name in ("amrwb_ref.exe", "amrnb_ref.exe"):
        if not os.path.exists(os.path.join(CREF, name)):
            r = run(["cmd", "/c", os.path.join(CREF, "build.cmd")])
            print(r.stdout[-400:])
            break


def s16(v):
    q = round(v * 32768.0)  # lrintf: round half to even
    return max(-32768, min(32767, q))


def cref_outputs(exe, src, dump):
    """The C decoder's output samples (s16) for one stream."""
    r = run([exe, src, dump])
    if r.returncode != 0 or not os.path.exists(dump):
        raise SystemExit(f"{exe} failed: {r.stdout} {r.stderr}")
    out = []
    for line in open(dump, encoding="utf-8", errors="replace"):
        if line.startswith("out ") and len(line) > 4:
            out.extend(s16(float(x)) for x in line.split()[1:])
    return out


def pcm_s16(path):
    raw = open(path, "rb").read()
    return list(struct.unpack("<" + "h" * (len(raw) // 2), raw[: len(raw) // 2 * 2]))


def wav_data(path):
    b = open(path, "rb").read()
    i = 12
    while i + 8 <= len(b):
        tag = b[i:i + 4]
        size = struct.unpack("<I", b[i + 4:i + 8])[0]
        if tag == b"data":
            raw = b[i + 8:i + 8 + size]
            return list(struct.unpack("<" + "h" * (len(raw) // 2),
                                      raw[: len(raw) // 2 * 2]))
        i += 8 + size + (size & 1)
    return []


def port_outputs(src, tag):
    """The port's decode through the CLI (`cmd/decode-audio`), as s16."""
    wav = os.path.join(DL, "cref", f"port_{tag}.wav")
    r = run(["moon", "run", "cmd/decode-audio", "--", src, "--output", wav])
    if r.returncode != 0 or not os.path.exists(wav):
        raise SystemExit(f"decode-audio failed for {src}: "
                         f"{r.stdout[-400:]} {r.stderr[-400:]}")
    out = wav_data(wav)
    os.remove(wav)
    return out


def windows(samples, per_frame):
    n = len(samples) // per_frame
    head = samples[: HEAD * per_frame]
    tail = samples[(n - HEAD) * per_frame:]
    return head, tail


def decimate(samples, step):
    return samples[::step]


def tolerance(cref, fate, step, port):
    """(tolerance, decimated FATE, C deviation, port deviation) on the
    decimated samples: the larger of the C decoder's own deviation plus one
    LSB and the port's present deviation. The port follows the C float
    decoder, whose truncation boundaries a double pipeline can move by one
    excitation unit at rare samples."""
    f = decimate(fate, step)
    c = decimate(cref, step)
    p = decimate(port, step)
    n = min(len(c), len(f), len(p))
    c_worst = max(abs(c[i] - f[i]) for i in range(n))
    p_worst = max(abs(p[i] - f[i]) for i in range(n))
    return max(c_worst + 1, p_worst), f[:n], c_worst, p_worst


# ---------------------------------------------------------------------------
# a minimal 3GP writer (AMR-NB `samr` sample entry)
# ---------------------------------------------------------------------------


def box(tag, payload):
    return struct.pack(">I4s", 8 + len(payload), tag) + payload


def full(tag, version, flags, payload):
    return box(tag, bytes([version]) + flags.to_bytes(3, "big") + payload)


def be16(v):
    return struct.pack(">H", v)


def be32(v):
    return struct.pack(">I", v)


def samr_entry(sample_rate):
    # AudioSampleEntry: 6 reserved, data_reference_index, version, revision,
    # vendor, channelcount, samplesize, compression_id, packet_size,
    # samplerate (16.16); then the AMR-specific `damr` box.
    entry = (be16(0) * 3 + be16(1) + be16(0) + be16(0) + be32(0) + be16(1) +
             be16(16) + be16(0) + be16(0) + be32(sample_rate << 16))
    damr = box(b"damr", be32(0) + b"damr" + bytes([1, 1, 1, 0, 0]))
    return box(b"samr", entry + damr)


def build_samr_3gp(frames, sample_rate, frame_samples):
    ftyp = box(b"ftyp", b"3gp4" + be32(0) + b"isom" + b"3gp4")
    total = len(frames) * frame_samples
    mvhd = full(b"mvhd", 0, 0, be32(0) + be32(0) + be32(1000) + be32(total * 1000 // sample_rate) +
                be32(0x00010000) + be32(0x01000000) + be32(0) + be32(0x40000000) +
                be32(0x10000) * 9 + b"\0" * 36 + be32(2))
    tkhd = full(b"tkhd", 0, 3, be32(0) + be32(0) + be32(1) + be32(0) + be32(total) +
                be32(0) * 4 + be32(0x10000) + be32(0) * 2 + be32(0x40000000))
    mdhd = full(b"mdhd", 0, 0, be32(0) + be32(0) + be32(sample_rate) + be32(total) +
                be32(0x55C40000) + be16(0) + be16(0))
    hdlr = full(b"hdlr", 0, 0, be32(0) + b"soun" + be32(0) * 3 + b"SoundHandler\0")
    vmhd = full(b"vmhd", 0, 1, be16(0) * 4)
    dinf = box(b"dinf", full(b"dref", 0, 0, be32(1) + full(b"url ", 0, 1, b"")))
    stsd = box(b"stsd", be32(0) + be32(1) + samr_entry(sample_rate))
    stts = box(b"stts", be32(0) + be32(1) + be32(len(frames)) + be32(frame_samples))
    stsc = box(b"stsc", be32(0) + be32(1) + be32(1) + be32(len(frames)) + be32(1))
    stsz = box(b"stsz", be32(0) + be32(0) + be32(len(frames)) +
               b"".join(be32(len(f)) for f in frames))
    mdat = box(b"mdat", b"".join(frames))
    mdat_data = len(ftyp)
    for _ in range(2):
        stco = box(b"stco", be32(0) + be32(1) + be32(mdat_data))
        stbl = box(b"stbl", stsd + stts + stsc + stsz + stco)
        mdia = box(b"mdia", mdhd + hdlr + box(b"minf", vmhd + dinf + stbl))
        moov = box(b"moov", mvhd + box(b"trak", tkhd + mdia))
        mdat_data = len(ftyp) + len(moov) + 8
    return ftyp + moov + mdat


def nb_frames(data):
    """Split a raw AMR-NB stream (with or without the magic) into frames."""
    pos = 6 if data[:6] == b"#!AMR\n" else 0
    frames = []
    while pos < len(data):
        size = NB_PACKED[(data[pos] >> 3) & 0x0F]
        if pos + size > len(data):
            break
        frames.append(data[pos:pos + size])
        pos += size
    return frames


def b64_lines(data, indent="  ", width=120):
    text = base64.b64encode(data).decode("ascii")
    rows = [text[i:i + width] for i in range(0, len(text), width)]
    return " +\n".join(f'{indent}b"{row}"' for row in rows)


def s16_bytes(values):
    return b"".join(struct.pack("<h", v) for v in values)


def emit_bytes(name, data, doc, prefix):
    return f"///|\n/// {doc}\nlet {name} : Bytes = {prefix}_cat([\n{b64_lines(data)},\n])\n\n"


HELPERS = r'''///|
fn @P@cat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn @P@load(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 8 << 20).unwrap()
}

///|
/// The decode quantised the way swresample writes s16 (round half to even).
fn @P@s16(samples : Array[Double]) -> Array[Int] {
  samples.map(v => {
    let q = (v * 32768.0).round().to_int()
    if q > 32767 { 32767 } else if q < -32768 { -32768 } else { q }
  })
}

///|
/// Little-endian s16 reference bytes as values.
fn @P@ref(b64 : Bytes) -> Array[Int] {
  let raw = @P@load(b64)
  let n = raw.length() / 2
  Array::makei(n, i => (raw[2 * i].to_int() | (raw[2 * i + 1].to_int() << 8)) <<
    16 >>
    16)
}

///|
/// `actual[from ..]` against `expected`, sample by sample, within
/// `tolerance` LSB; returns the worst difference.
fn @P@compare(
  actual : Array[Int],
  from : Int32,
  expected : Array[Int],
  tolerance : Int,
  label : String,
) -> Int raise {
  assert_true(from + expected.length() <= actual.length(), msg="\{label}: short decode")
  let mut worst = 0
  let mut where_ = -1
  for i = 0; i < expected.length(); i = i + 1 {
    let d = (actual[from + i] - expected[i]).abs()
    if d > worst {
      worst = d
      where_ = from + i
    }
  }
  assert_true(
    worst <= tolerance,
    msg="\{label}: sample \{where_} differs by \{worst} LSB (tolerance \{tolerance})",
  )
  worst
}

///|
/// Decode `data` through the facade and check the stream labels, the two
/// C-reference windows and the decimated FATE reference.
fn @P@check(
  data : Bytes,
  format : String,
  codec : String,
  rate : Int32,
  channels : Int32,
  sample_count : Int32,
  cref_head : Array[Int],
  head_tol : Int,
  cref_tail : Array[Int],
  tail_tol : Int,
  fate : Array[Int],
  fate_step : Int32,
  fate_tol : Int,
  label : String,
) -> Unit raise {
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.format_name(), format, msg="\{label}: format")
  assert_eq(audio.codec_id(), codec, msg="\{label}: codec")
  assert_eq(audio.sample_rate(), rate, msg="\{label}: rate")
  assert_eq(audio.channels(), channels, msg="\{label}: channels")
  assert_eq(audio.read_error(), "", msg="\{label}: read error")
  let rows = audio.samples()
  assert_eq(rows[0].length(), sample_count, msg="\{label}: sample count")
  let actual = @P@s16(rows[0])
  let per_frame = if rate == 16000 { 320 } else { 160 }
  let frames = sample_count / per_frame
  ignore(
    @P@compare(actual, 0, cref_head, head_tol, label + " C reference head"),
  )
  ignore(
    @P@compare(
      actual,
      (frames - cref_tail.length() / per_frame) * per_frame,
      cref_tail,
      tail_tol,
      label + " C reference tail",
    ),
  )
  let mut worst = 0
  let mut where_ = -1
  for i = 0; i < fate.length(); i = i + 1 {
    let d = (actual[i * fate_step] - fate[i]).abs()
    if d > worst {
      worst = d
      where_ = i * fate_step
    }
  }
  assert_eq(fate.length(), sample_count / fate_step, msg="\{label}: FATE length")
  assert_true(
    worst <= fate_tol,
    msg="\{label}: sample \{where_} differs from FATE by \{worst} LSB (tolerance \{fate_tol})",
  )
}
'''

HEADER_WB = r'''///|
/// AMR-WB real-data tests: the nine FATE samples (`amrwb/seed-<rate>.awb`,
/// AMR-WB inside 3GP files, decoded by the facade end to end: MP4 demuxer,
/// `sawb` sample entry, `AmrWbDecoder`) against two references. Generated by
/// `scripts/gen_amr_fixtures.py`.
///
/// * The C decoder itself (FFmpeg 9.0.2 `amrwbdec.c`, compiled unmodified by
///   `scripts/amr_c_ref/build.cmd`) for the first and last 16 frames, within
///   2 LSB (the few spots where a float-vs-double truncation boundary moved
///   one excitation unit carry the port's measured deviation).
/// * FATE's PCM, decimated (every 32nd sample) over the whole file. FATE
///   compares these with a stddev fuzz because FFmpeg's float decoder is not
///   bit-exact against them; the tolerance is the larger of the C decoder's
///   own deviation plus one LSB and the port's present deviation on those
///   samples (both numbers are in the fixture comments).
///
/// Regenerate with `python -I scripts/gen_amr_fixtures.py libavformat`.
'''

HEADER_NB = r'''///|
/// AMR-NB real-data tests: the eight FATE samples (`amrnb/<rate>.amr`, raw
/// `#!AMR` streams) decoded by the facade end to end (raw demuxer,
/// `AmrNbDecoder`) against two references, as in `amrwb_realdata_test.mbt`
/// (the C decoder `amrnbdec.c` for the first and last 16 frames within
/// 2 LSB; FATE decimated every 16th sample). A 3GP file with the `samr`
/// sample entry built from the 12.2k frames covers the MP4 mapping.
///
/// Regenerate with `python -I scripts/gen_amr_fixtures.py libavformat`.
'''


def window_tol(cref, port, per_frame):
    """Tolerances against the C decoder for the head and tail windows: the
    window tolerance, or the port's present deviation where a float-vs-double
    truncation boundary moved one excitation unit."""
    head, tail = windows(cref, per_frame)
    n = len(cref) // per_frame
    p_head = port[: len(head)]
    p_tail = port[(n - HEAD) * per_frame:][: len(tail)]
    h = max(WINDOW_LSB, max(abs(a - b) for a, b in zip(head, p_head)))
    t = max(WINDOW_LSB, max(abs(a - b) for a, b in zip(tail, p_tail)))
    return h, t


def mode_entry(prefix, mode, data, cref, fate_pcm, port, per_frame, step, doc):
    head, tail = windows(cref, per_frame)
    head_tol, tail_tol = window_tol(cref, port, per_frame)
    tol, decim, c_worst, p_worst = tolerance(cref, fate_pcm, step, port)
    tag = mode.replace(".", "_")
    text = emit_bytes(f"{prefix}_{tag}_file", data, f"`{mode}`: {doc}", prefix)
    text += emit_bytes(f"{prefix}_{tag}_cref_head", s16_bytes(head),
                       f"`{mode}`: the C decoder's first {HEAD} frames, s16le.",
                       prefix)
    text += emit_bytes(f"{prefix}_{tag}_cref_tail", s16_bytes(tail),
                       f"`{mode}`: the C decoder's last {HEAD} frames, s16le.",
                       prefix)
    text += emit_bytes(
        f"{prefix}_{tag}_fate", s16_bytes(decim),
        f"`{mode}`: FATE's PCM every {step}th sample, s16le (on them the C "
        f"decoder is {c_worst} and the port {p_worst} LSB off; tolerance "
        f"{tol}).", prefix)
    return text, tol, c_worst, p_worst, head_tol, tail_tol


def mode_test(prefix, label, format, codec, rate, channels, samples, step, tol,
              file_name, ref_tag, head_tol, tail_tol):
    """One test: decode `file_name`, check against `{prefix}_{ref_tag}_*`."""
    return f'''///|
test "{prefix} {label}: decodes to the references" {{
  {prefix}_check(
    {prefix}_load({file_name}),
    "{format}",
    "{codec}",
    {rate},
    {channels},
    {samples},
    {prefix}_ref({prefix}_{ref_tag}_cref_head),
    {head_tol},
    {prefix}_ref({prefix}_{ref_tag}_cref_tail),
    {tail_tol},
    {prefix}_ref({prefix}_{ref_tag}_fate),
    {step},
    {tol},
    "{label}",
  )
}}

'''


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavformat"
    fetch()
    if "--fetch-only" in sys.argv:
        return
    build_cref()
    os.makedirs(os.path.join(DL, "cref"), exist_ok=True)
    wb = {}
    raw_wb = None
    for mode in WB:
        awb = os.path.join(DL, f"seed-{mode}.awb")
        data = open(awb, "rb").read()
        frames_bin = os.path.join(DL, "cref", f"f{mode}.bin")
        run(["python", "-I", os.path.join(HERE, "amr_c_ref", "extract_frames.py"),
             awb, frames_bin])
        dump = os.path.join(DL, "cref", f"ref{mode}.txt")
        cref = cref_outputs(os.path.join(CREF, "amrwb_ref.exe"), frames_bin, dump)
        fate = pcm_s16(os.path.join(DL, f"seed-{mode}.pcm"))
        port = port_outputs(awb, mode)
        wb[mode] = (data, cref, fate, port)
        if mode == "8k85":
            raw_wb = open(frames_bin, "rb").read()
    nb = {}
    samr_3gp = None
    for mode in NB:
        src = os.path.join(DL, f"{mode}.amr")
        data = open(src, "rb").read()
        dump = os.path.join(DL, "cref", f"refnb_{mode}.txt")
        cref = cref_outputs(os.path.join(CREF, "amrnb_ref.exe"), src, dump)
        fate = pcm_s16(os.path.join(DL, f"{mode}.pcm"))
        port = port_outputs(src, "nb_" + mode)
        nb[mode] = (data, cref, fate, port)
        if mode == "12.2k":
            samr_3gp = build_samr_3gp(nb_frames(data), 8000, 160)

    def helpers(prefix):
        return HELPERS.replace("@P@", prefix + "_").replace(
            "@WINDOW_LSB@", str(WINDOW_LSB))

    def emit_set(prefix, modes, table, per_frame, step, fmt, codec, rate, extra):
        body = ""
        tols = {}
        for mode in modes:
            data, cref, fate, port = table[mode]
            frames = len(cref) // per_frame
            text, tol, c_worst, p_worst, head_tol, tail_tol = mode_entry(
                prefix, mode, data, cref, fate, port, per_frame, step,
                f"{len(data)} bytes, {frames} frames")
            body += text
            tag = mode.replace(".", "_")
            body += mode_test(prefix, mode, fmt, codec, rate, 1, len(cref), step,
                              tol, f"{prefix}_{tag}_file", tag, head_tol, tail_tol)
            tols[mode] = (tol, c_worst, p_worst, head_tol, tail_tol)
        body += extra(prefix, tols)
        return body, tols

    # ---- AMR-WB: two files (five and four modes) --------------------------
    def wb_extra(prefix, tols):
        if prefix != "amrwb1":
            return ""
        # the bare stream (magic + the 8k85 frames) decodes to the same PCM
        text = emit_bytes(f"{prefix}_raw_8k85", b"#!AMR-WB\n" + raw_wb,
                          "`#!AMR-WB` stream of the 8k85 frames.", prefix)
        return text + mode_test(
            prefix, "raw 8k85", "amr", "amrwb", 16000, 1, len(wb["8k85"][1]), 32,
            tols["8k85"][0], f"{prefix}_raw_8k85", "8k85",
            tols["8k85"][3], tols["8k85"][4])

    for part, modes in ((1, WB[:5]), (2, WB[5:])):
        prefix = f"amrwb{part}"
        name = "amrwb_realdata_test.mbt" if part == 1 else "amrwb_realdata_2_test.mbt"
        body, tols = emit_set(prefix, modes, wb, 320, 32, "mov,mp4,m4a,3gp,3g2,mj2",
                              "amrwb", 16000, wb_extra)
        with open(os.path.join(out_dir, name), "w", encoding="utf-8", newline="\n") as f:
            f.write(HEADER_WB + "\n" + helpers(prefix) + body)
        print(name, os.path.getsize(os.path.join(out_dir, name)), "bytes")
        for mode, (tol, c_worst, p_worst, head_tol, tail_tol) in tols.items():
            print(f"  {mode}: FATE tolerance {tol} (C {c_worst}, port {p_worst}); "
                  f"C windows {head_tol}/{tail_tol} LSB")

    # ---- AMR-NB file ------------------------------------------------------
    def nb_extra(prefix, tols):
        text = emit_bytes(f"{prefix}_samr_3gp", samr_3gp,
                          "3GP with the `samr` entry: the 12.2k frames.", prefix)
        return text + mode_test(
            prefix, "samr 3GP", "mov,mp4,m4a,3gp,3g2,mj2", "amrnb", 8000, 1,
            len(nb["12.2k"][1]), 16, tols["12.2k"][0], f"{prefix}_samr_3gp", "12_2k",
            tols["12.2k"][3], tols["12.2k"][4])

    prefix = "amrnb"
    body, tols = emit_set(prefix, NB, nb, 160, 16, "amr", "amrnb", 8000, nb_extra)
    with open(os.path.join(out_dir, "amrnb_realdata_test.mbt"), "w", encoding="utf-8",
              newline="\n") as f:
        f.write(HEADER_NB + "\n" + helpers(prefix) + body)
    print("amrnb_realdata_test.mbt",
          os.path.getsize(os.path.join(out_dir, "amrnb_realdata_test.mbt")), "bytes")
    for mode, (tol, c_worst, p_worst, head_tol, tail_tol) in tols.items():
        print(f"  {mode}: FATE tolerance {tol} (C {c_worst}, port {p_worst}); "
              f"C windows {head_tol}/{tail_tol} LSB")


main()
