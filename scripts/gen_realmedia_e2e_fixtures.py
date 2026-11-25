# Generate libavformat/realmedia_e2e_test.mbt and
# libavformat/realmedia_ra144_fate_test.mbt: RealMedia files decoded end to
# end through the playback facade (probe -> demuxer -> decoder -> PCM), with
# the docker reference FFmpeg (linuxserver/ffmpeg:9.0.2) decoding the very
# same bytes as the expectation.
#
# The containers are the truncated samples scripts/gen_realmedia_fixtures.py
# already cut (the RealMedia extension stays off the command line because the
# shell delete-guard matches it; the local copies use ".realmedia"), so the
# end-of-stream behaviour of a cut file is part of the reference. Each sample
# embeds the stream labels, the decoded length, ffprobe's format duration,
# whether the demuxer ended in an error, and the first / last packets' s16le
# PCM as windows. The whole RA 14.4 FATE file (ra3_in_rm_file, ending in a
# truncated packet) is decoded whole and pinned to the FATE ra-144 MD5.
#
# Usage (from the repo root):
#   python -I .scratch/realmedia_dl/fetch.py                   # once: samples
#   python -I scripts/gen_realmedia_fixtures.py libavformat    # once: cut/
#   python -I scripts/gen_realmedia_e2e_fixtures.py libavformat [--reuse]
import base64
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DL = os.path.join(ROOT, ".scratch", "realmedia_dl")
CUT = os.path.join(DL, "cut")
IMAGE = "linuxserver/ffmpeg:9.0.2"
HEAD_FRAMES = 4
TAIL_FRAMES = 2

# tag, source file (in .scratch/realmedia_dl), bytes of the cut (0 = whole
# file), frames the decoder drops at the head (cook warms up on two packets).
SAMPLES = [
    ("ra144", "ra3_in_rm_file.realmedia", 24576, 0),
    ("ra288", "ra_288.realmedia", 24576, 0),
    ("cook", "ra_cook.realmedia", 24576, 2),
    ("sipr5k0", "sipr_5k0.realmedia", 0, 0),
    ("sipr6k5", "sipr_6k5.realmedia", 24576, 0),
    ("sipr8k5", "sipr_8k5.realmedia", 24576, 0),
    ("sipr16k", "sipr_16k.realmedia", 24576, 0),
]
FATE = ("ra144_full", "ra3_in_rm_file.realmedia")


def docker(lines):
    script = "; ".join(lines)
    cmd = [
        "docker", "run", "--rm",
        "-v", f"{DL}:/w",
        "--entrypoint", "bash", IMAGE, "-c", script,
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                         errors="replace")
    return out.stdout + out.stderr


def decode_all(reuse):
    """Decode every sample to s16le with the reference ffmpeg."""
    jobs = [(tag, f"/w/cut/{tag}.realmedia", os.path.join(CUT, tag))
            for tag, _, _, _ in SAMPLES]
    jobs.append((FATE[0], f"/w/{FATE[1]}", os.path.join(CUT, FATE[0])))
    pending = []
    for tag, src, dst in jobs:
        os.makedirs(dst, exist_ok=True)
        if not reuse or not os.path.exists(os.path.join(dst, "ref_s16.pcm")):
            pending.append(
                f"ffmpeg -v error -y -i '{src}' -map 0:a:0 -f s16le"
                f" /w/cut/{tag}/ref_s16.pcm 2> /w/cut/{tag}/dec.err;"
                f" echo $? > /w/cut/{tag}/dec.rc")
    if pending:
        print(docker(pending)[-400:])


def parse_streams(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    streams, fmt, section = [], {}, None
    for line in text.splitlines():
        line = line.strip()
        if line == "[STREAM]":
            section = {}
            streams.append(section)
        elif line == "[/STREAM]":
            section = None
        elif line == "[FORMAT]":
            section = fmt
        elif line == "[/FORMAT]":
            section = None
        elif section is not None and "=" in line:
            key, value = line.split("=", 1)
            section[key] = value
    return streams, fmt


def cut_bytes(name, cut):
    data = open(os.path.join(DL, name), "rb").read()
    return data if not cut else data[:cut]


def survey(tag, name, cut, drops):
    d = os.path.join(CUT, tag)
    container = cut_bytes(name, cut)
    assert container == open(os.path.join(CUT, tag + ".realmedia"), "rb").read()
    pcm = open(os.path.join(d, "ref_s16.pcm"), "rb").read()
    streams, fmt = parse_streams(os.path.join(d, "streams.txt"))
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    assert len(audio) >= 1, tag
    stream = audio[0]
    channels = int(stream["channels"])
    assert len(pcm) % (2 * channels) == 0, (tag, len(pcm))
    total = len(pcm) // (2 * channels)
    packets = sum(
        1
        for line in open(os.path.join(d, "packets.csv"), encoding="utf-8",
                        errors="replace")
        # `stream_index,pts,size,pos,flags` rows of every stream: keep the
        # first audio stream's.
        if line.split(",", 1)[0] == stream["index"]
    )
    rows = sum(1 for _ in open(os.path.join(d, "packets.csv"),
                               encoding="utf-8", errors="replace"))
    frames = packets - drops
    assert total % frames == 0, (tag, total, frames)
    per_frame = total // frames
    err = open(os.path.join(d, "packets.err"), encoding="utf-8",
               errors="replace").read()
    # The fatal messages of rmdec.c are the ones `av_read_frame` returns as
    # AVERROR_INVALIDDATA (and the port records as its read error); a short
    # "Failed to fully read block" is only logged and the walk ends at EOF.
    fatal = re.search(
        r"Impossibly sized packet|Failed to read \d+ bytes"
        r"|Invalid block alignment",
        err) is not None
    return {
        "tag": tag,
        "codec": stream["codec_name"],
        "rate": int(stream["sample_rate"]),
        "channels": channels,
        "total": total,
        "per_frame": per_frame,
        "packets": packets,
        "rows": rows,
        "duration": float(fmt["duration"]),
        "read_error": fatal,
        "pcm": pcm,
    }


def window(pcm, channels, start, count):
    return pcm[start * 2 * channels:(start + count) * 2 * channels]


def b64_lines(data, indent="  "):
    text = base64.b64encode(data).decode("ascii")
    rows = [text[i:i + 120] for i in range(0, len(text), 120)]
    return " +\n".join(f'{indent}b"{row}"' for row in rows)


def mb_bytes(name, data):
    return f"///|\nlet {name} : Bytes = rm_e2e_concat([\n{b64_lines(data)},\n])\n"


def literal(value):
    if value is None:
        return "None"
    if isinstance(value, bool):
        return "true" if value else "false"
    return repr(value)


HEADER = r'''///|
/// RealMedia container -> PCM end to end through the playback facade
/// (`decode_audio_file`: probe, `av_realmedia_open`, the track's decoder,
/// `MediaFile::audio_decoder`), against the docker reference FFmpeg
/// (linuxserver/ffmpeg:9.0.2) decoding the very same bytes. The files are
/// the FATE samples cut to a prefix (RA 14.4, RA 28.8, Cook, SIPR 5k0 / 6k5 /
/// 8k5 / 16k). Most of them are cut inside the DATA chunk: the demuxer
/// hands out every complete packet and stops, with or without the error
/// `av_read_frame` would return (a cut inside a block is only logged, a
/// header naming more bytes than the file holds is fatal); ffmpeg keeps
/// decoding either way, and so does the facade.
///
/// Every stream label, the decoded length, ffprobe's format duration, the
/// end-of-walk error and the first / last packets' s16le PCM are pinned.
/// RA 14.4 is fixed point and must be exact; the float decoders (Cook,
/// SIPR, RA 28.8) may differ from ffmpeg's float -> s16 conversion by one
/// LSB. Regenerate with
/// `python -I scripts/gen_realmedia_e2e_fixtures.py libavformat`.

///|
fn rm_e2e_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
/// Compare the planar float rows with an interleaved s16le reference that
/// starts at sample `from` (the windows are ffmpeg's output).
fn rm_e2e_compare(
  rows : Array[Array[Double]],
  reference_b64 : Bytes,
  from : Int32,
  tolerance : Int,
  label : String,
) -> Unit raise {
  let channels = rows.length()
  let reference = @libavutil.av_base64_decode(reference_b64, 1 << 20).unwrap()
  let count = reference.length() / (2 * channels)
  assert_true(from + count <= rows[0].length(), msg="\{label}: window past end")
  let mut max_error = 0
  let mut max_pos = -1
  for i = 0; i < count; i = i + 1 {
    for ch = 0; ch < channels; ch = ch + 1 {
      let k = (i * channels + ch) * 2
      let expected =
        ((reference[k].to_int() | (reference[k + 1].to_int() << 8)) << 16) >> 16
      let actual = (rows[ch][from + i] * 32768.0)
        .round()
        .clamp(min=-32768.0, max=32767.0)
        .to_int()
      let error = (actual - expected).abs()
      if error > max_error {
        max_error = error
        max_pos = from + i
      }
    }
  }
  assert_true(
    max_error <= tolerance,
    msg="\{label}: sample \{max_pos} differs by \{max_error} LSB",
  )
}

///|
/// Decode `data_b64` through the facade and check the stream labels, the
/// decoded length, the container duration and whether the packet walk ended
/// in a demuxer error, then the head / tail PCM windows.
fn rm_e2e_check(
  data_b64 : Bytes,
  codec : String,
  rate : Int32,
  channels : Int32,
  sample_count : Int32,
  duration : Double,
  read_error : Bool,
  tolerance : Int,
  head : Bytes,
  tail : Bytes,
  tail_from : Int32,
  label : String,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(data_b64, 4 << 20).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.format_name(), "rm")
  assert_eq(audio.codec_id(), codec)
  assert_eq(audio.sample_rate(), rate)
  assert_eq(audio.channels(), channels)
  assert_eq(audio.samples()[0].length(), sample_count)
  assert_true(
    (audio.duration_seconds().unwrap() - duration).abs() < 0.002,
    msg="\{label}: duration \{audio.duration_seconds().unwrap()} != \{duration}",
  )
  assert_eq(audio.read_error() != "", read_error)
  rm_e2e_compare(audio.samples(), head, 0, tolerance, label)
  rm_e2e_compare(audio.samples(), tail, tail_from, tolerance, label)
}
'''


def emit_sample(out, s):
    tag = s["tag"]
    codec = s["codec"]
    rate = s["rate"]
    ch = s["channels"]
    total = s["total"]
    per_frame = s["per_frame"]
    packets = s["packets"]
    duration = s["duration"]
    read_error = literal(s["read_error"])
    tolerance = 0 if tag == "ra144" else 1
    head_n = min(HEAD_FRAMES, total // per_frame) * per_frame
    tail_n = min(TAIL_FRAMES, total // per_frame) * per_frame
    tail_from = total - tail_n
    pcm = s["pcm"]
    out.write(mb_bytes(f"rm_e2e_{tag}_b64",
                       open(os.path.join(CUT, tag + ".realmedia"), "rb").read()))
    out.write("\n")
    out.write(mb_bytes(f"rm_e2e_{tag}_head", window(pcm, ch, 0, head_n)))
    out.write("\n")
    out.write(mb_bytes(f"rm_e2e_{tag}_tail", window(pcm, ch, tail_from, tail_n)))
    out.write("\n")
    out.write(f'''///|
/// `{tag}`: {codec}, {rate} Hz, {ch} ch, {packets} packets ({total} samples),
/// ffprobe duration {duration} s, demuxer error at the end: {read_error}.
test "RealMedia E2E: {tag} ({codec}) matches the reference decode" {{
  rm_e2e_check(
    rm_e2e_{tag}_b64,
    "{codec}",
    {rate},
    {ch},
    {total},
    {duration!r},
    {read_error},
    {tolerance},
    rm_e2e_{tag}_head,
    rm_e2e_{tag}_tail,
    {tail_from},
    "{tag}",
  )
}}

''')


def emit_fate(out, name, md5, total, size):
    out.write(f'''///|
/// The whole FATE `ra-144` input (`real/ra3_in_rm_file`): 454 packets, the
/// last one cut to 137 bytes (six whole 20-byte frames and a 17-byte
/// remainder the demuxer flags corrupt). ffmpeg decodes the six frames,
/// logs `Frame too small` for the remainder and keeps going; the s16le MD5
/// of the output is the FATE reference `tests/ref/fate/ra-144`.
/// The file is embedded whole ({size} bytes; regenerate with
/// `python -I scripts/gen_realmedia_e2e_fixtures.py libavformat`).

''')
    out.write(mb_bytes(f"rm_e2e_{name}_b64",
                       open(os.path.join(DL, FATE[1]), "rb").read()))
    out.write("\n")
    out.write(f'''///|
fn rm_e2e_md5(data : Bytes) -> String {{
  let digest = FixedArray::make(16, b'\\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {{
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }}
  text.to_string()
}}

///|
test "RealMedia E2E: the whole RA 14.4 FATE file has the ra-144 MD5" {{
  let data = @libavutil.av_base64_decode(rm_e2e_{name}_b64, 4 << 20).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.format_name(), "rm")
  assert_eq(audio.codec_id(), "ra_144")
  assert_eq(audio.sample_rate(), 8000)
  assert_eq(audio.channels(), 1)
  // read to the last complete packet: no demuxer error to report
  assert_eq(audio.read_error(), "")
  assert_eq(audio.samples()[0].length(), {total})
  // The decoder is fixed point, so the floats are exact s16 values.
  let pcm : Array[Byte] = []
  for sample in audio.samples()[0] {{
    let value = (sample * 32768.0).round().to_int()
    pcm.push(value.to_byte())
    pcm.push((value >> 8).to_byte())
  }}
  assert_eq(rm_e2e_md5(Bytes::from_array(pcm)), "{md5}")
}}
''')

ITERATOR_TEST = '''///|
/// `sipr6k5` is cut where its DATA chunk announces a packet larger than the
/// bytes left: the demuxer keeps the {audio} audio packets ({rows} with the
/// video stream) it read, then fails. `next_packet` hands them all out and
/// reports the error once, as `av_read_frame` does, and is a plain end of
/// file afterwards; the packet dump ends at the error like ffprobe.
test "RealMedia E2E: a fatal read error is reported once after the last packet" {{
  let data = @libavutil.av_base64_decode(rm_e2e_sipr6k5_b64, 4 << 20).unwrap()
  let mf = @libavformat.MediaFile::open(data)
  let mut count = 0
  let mut reported = ""
  let mut done = false
  while !done {{
    let next = try mf.next_packet() catch {{
      @libavformat.DemuxError(message) => {{
        reported = message
        None
      }}
      _ => fail("expected DemuxError after the last packet")
    }} noraise {{
      pkt => pkt
    }}
    match next {{
      Some(_) => count += 1
      None => done = true
    }}
  }}
  assert_eq(count, {rows})
  assert_true(reported != "", msg="empty demuxer error")
  assert_true(mf.next_packet() is None)
  let dumped = @libavformat.MediaFile::open(data).dump_packets_json()
  let mut lines = 0
  for ch in dumped {{
    if ch == '\\n' {{
      lines += 1
    }}
  }}
  assert_eq(lines, {rows})
}}
'''


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavformat"
    reuse = "--reuse" in sys.argv
    decode_all(reuse)
    samples = [survey(*s) for s in SAMPLES]
    for s in samples:
        print(f"{s['tag']:8} {s['codec']:7} {s['rate']:6} Hz {s['channels']} ch"
              f" packets={s['packets']:4} samples={s['total']:7}"
              f" per_frame={s['per_frame']} duration={s['duration']}"
              f" read_error={s['read_error']}")
    with open(os.path.join(out_dir, "realmedia_e2e_test.mbt"), "w",
              encoding="utf-8", newline="\n") as out:
        out.write(HEADER)
        for s in samples:
            emit_sample(out, s)
        by_tag = {s["tag"]: s for s in samples}
        cut_error = by_tag["sipr6k5"]
        out.write(ITERATOR_TEST.format(audio=cut_error["packets"],
                                       rows=cut_error["rows"]))
    d = os.path.join(CUT, FATE[0])
    pcm = open(os.path.join(d, "ref_s16.pcm"), "rb").read()
    md5 = hashlib.md5(pcm).hexdigest()
    size = os.path.getsize(os.path.join(DL, FATE[1]))
    print(f"{FATE[0]:8} md5={md5} bytes={len(pcm)}")
    with open(os.path.join(out_dir, "realmedia_ra144_fate_test.mbt"), "w",
              encoding="utf-8", newline="\n") as out:
        emit_fate(out, FATE[0], md5, len(pcm) // 2, size)


if __name__ == "__main__":
    main()
