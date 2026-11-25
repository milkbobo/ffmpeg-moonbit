# Generate libavformat/realmedia_realdata_wbtest.mbt: RealMedia files
# demuxed by the docker reference FFmpeg (linuxserver/ffmpeg:9.0.2), with
# ffprobe's stream table and packet table as the expectations.
#
# The FATE samples are cut to a prefix (the RealMedia extension is kept off
# the command line because the shell delete-guard matches it; the local
# copies use a ".realmedia" suffix) and ffprobe runs on exactly the bytes
# that are embedded, so a cut file's tail behaviour is part of the reference.
#
# Usage (from the repo root):
#   python -I .scratch/realmedia_dl/fetch.py        # once, downloads the samples
#   python -I scripts/gen_realmedia_fixtures.py libavformat
import base64
import os
import re
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DL = os.path.join(ROOT, ".scratch", "realmedia_dl")
IMAGE = "linuxserver/ffmpeg:9.0.2"
NOPTS = -(1 << 63)

# tag, source file (in .scratch/realmedia_dl), bytes embedded (0 = whole file).
SAMPLES = [
    ("ra144", "ra3_in_rm_file.realmedia", 24576),
    ("ra288", "ra_288.realmedia", 24576),
    ("cook", "ra_cook.realmedia", 24576),
    ("sipr5k0", "sipr_5k0.realmedia", 0),
    ("sipr6k5", "sipr_6k5.realmedia", 24576),
    ("sipr8k5", "sipr_8k5.realmedia", 24576),
    ("sipr16k", "sipr_16k.realmedia", 24576),
    ("rv30", "rv30.realmedia", 32768),
    ("rv40", "spygames-2MB.realmediavb", 32768),
    ("rv20", "G2_with_SVT_320_240.realmedia", 24576),
]

CUT = os.path.join(DL, "cut")


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


def survey():
    os.makedirs(CUT, exist_ok=True)
    lines = []
    for tag, name, cut in SAMPLES:
        data = open(os.path.join(DL, name), "rb").read()
        if cut:
            data = data[:cut]
        with open(os.path.join(CUT, tag + ".realmedia"), "wb") as f:
            f.write(data)
        lines += [
            f"mkdir -p /w/cut/{tag}",
            f"ffprobe -v error -show_streams -show_format /w/cut/{tag}.realmedia"
            f" > /w/cut/{tag}/streams.txt 2> /w/cut/{tag}/streams.err",
            f"ffprobe -v error -show_entries packet=stream_index,pts,size,pos,flags"
            f" -of csv=p=0 /w/cut/{tag}.realmedia"
            f" > /w/cut/{tag}/packets.csv 2> /w/cut/{tag}/packets.err;"
            f" echo $? > /w/cut/{tag}/packets.rc",
            f"ffprobe -v error -select_streams a:0 -show_entries stream=extradata"
            f" -show_data /w/cut/{tag}.realmedia"
            f" > /w/cut/{tag}/extradata.txt 2> /dev/null",
        ]
    tail = docker(lines)
    print(tail[-300:])


def parse_streams(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    streams, fmt = [], {"tags": []}
    section = None
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
            if key.startswith("TAG:"):
                section.setdefault("tags", []).append((key[4:], value))
            else:
                section[key] = value
    return streams, fmt


def parse_extradata(path):
    if not os.path.exists(path):
        return b""
    hexbytes = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"^[0-9a-f]{8}:\s+((?:[0-9a-f]{2,4}\s)+)", line)
        if m:
            hexbytes.extend(re.findall(r"[0-9a-f]{2}", m.group(1)))
    return bytes(int(h, 16) for h in hexbytes)


def parse_packets(path, skip_pos_codecs, codecs):
    """Records of (flags, stream, size, pts, pos)."""
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        stream, pts, size, pos, flags = line.split(",")[-5:]
        stream = int(stream)
        pts = NOPTS if pts == "N/A" else int(pts)
        pos = NOPTS if pos == "N/A" else int(pos)
        key = 1 if "K" in flags else 0
        corrupt = 4 if "C" in flags else 0
        # ffprobe prints positions for SIPR that the parser makes up and the
        # demuxer never sets; those are not container positions.
        has_pos = 2 if (pos != NOPTS and codecs[stream] != "sipr") else 0
        # Audio packets with a position are one run of file bytes; video
        # frames are re-laid-out (slice table) even when they have one.
        video = codecs[stream].startswith("rv") or codecs[stream] == "clearvideo"
        raw_run = 8 if (has_pos and not video) else 0
        # FFmpeg's rv34 parser rewrites the RV30 / RV40 packet timestamps
        # from the bitstream; the demuxer alone reports the record ones.
        no_pts = 16 if codecs[stream] in ("rv30", "rv40") else 0
        out.append((key | has_pos | corrupt | raw_run | no_pts,
                    stream, int(size), pts, pos))
    return out


def with_container_timestamps(data, rows, nb_streams):
    """Replace ffprobe's SIPR timestamps by the ones the file carries."""
    expected = sipr_packets(data)
    if not expected or any(entry[0] >= nb_streams for entry in expected):
        return rows
    sipr_streams = {entry[0] for entry in expected}
    out, k = [], 0
    for flags, stream, size, pts, pos in rows:
        if stream in sipr_streams and k < len(expected):
            pts = expected[k][1]
            k += 1
        out.append((flags, stream, size, pts, pos))
    # every SIPR frame of the reference is one ffprobe packet
    assert k == len(expected), (k, len(expected))
    return out


def be(data, off, n):
    return int.from_bytes(data[off:off + n], "big")


def container_timestamps(data):
    """The timestamps the file itself carries, per stream: a list of
    (stream number, record timestamp). The records of the DATA chunk are
    read straight from the bytes: size, stream, timestamp, reserved, flags.
    """
    if data[:4] not in (b".RMF", b".RMP"):
        return {}
    off = 8 + (be(data, 4, 4) - 8)
    streams = {}
    data_off = header = None
    while off + 10 <= len(data):
        tag, size, ver = data[off:off + 4], be(data, off + 4, 4), be(data, off + 8, 2)
        if tag == b"PROP":
            data_off = be(data, off + (46 if ver == 2 else 42), 4)
        elif tag == b"DATA":
            header = 18 if ver == 0 else 30
            break
        elif size < 10:
            return {}
        off += size
    if header is None:
        return {}
    if not data_off:
        data_off = off
    pos = data_off + header
    out = []
    while pos + 12 <= len(data):
        size, number, pts = be(data, pos, 4), be(data, pos + 4, 2), be(data, pos + 6, 4)
        flags = data[pos + 11]
        if size < 12 or pos + size > len(data):
            break
        out.append((number, pts, flags))
        pos += size
    return out


def sipr_layout(data):
    """The SIPR streams, each as (MDPR ordinal, stream number, flavor,
    sub_packet_h, audio_framesize, sample_rate)."""
    result, ordinal = [], 0
    off = 8 + (be(data, 4, 4) - 8)
    while off + 10 <= len(data):
        tag, size = data[off:off + 4], be(data, off + 4, 4)
        if tag == b"DATA" or size < 10:
            break
        if tag == b"MDPR":
            p = off + 10
            number = be(data, p, 2)
            # stream number, then rates / sizes / start / preroll / duration
            p += 2 + 7 * 4
            for _ in range(2):
                p += 1 + data[p]  # title, mime type
            codec = data[p + 4:p + 4 + be(data, p, 4)]
            if codec[:4] == b".ra\xfd" and be(codec, 4, 2) in (4, 5):
                v5 = be(codec, 4, 2) == 5
                flavor = be(codec, 22, 2)
                # coded frame size, two unknown words, bytes per minute,
                # another unknown word, then the interleaving parameters
                sub_packet_h, audio_framesize = be(codec, 40, 2), be(codec, 42, 2)
                # version 5 has three more words before the sample rate
                q = 48 + (6 if v5 else 0)
                sample_rate = be(codec, q, 2)
                q += 2 + 4 + 2  # sample rate, unknown word, channels
                if v5:
                    tag4 = codec[q:q + 4]
                else:
                    a = q + 1 + codec[q]  # past the interleaver FourCC
                    tag4 = codec[a + 1:a + 1 + codec[a]]
                if tag4 == b"sipr":
                    result.append((ordinal, number, flavor, sub_packet_h,
                                   audio_framesize, sample_rate))
        off += size
        if tag == b"MDPR":
            ordinal += 1
    return result


def sipr_packets(data):
    """(MDPR ordinal, pts) of every SIPR frame, from the record headers: the
    timestamp of a group labels its first frame and the other frames follow
    at the frame duration."""
    frames = {20: 160, 19: 144, 29: 288, 37: 480}
    layout = {entry[1]: entry for entry in sipr_layout(data)}
    out = []
    counters, timestamps = {}, {}
    for number, pts, flags in container_timestamps(data):
        if number not in layout:
            continue
        ordinal, _, flavor, h, w, rate = layout[number]
        block_align = [29, 19, 37, 20][flavor]
        per_group = h * w // block_align
        duration = frames[block_align] * 1000 // rate
        y = 0 if flags & 2 else counters.get(number, 0)
        if y == 0:
            timestamps[number] = pts
        y += 1
        if y == h:
            y = 0
            start = timestamps[number]
            out += [(ordinal, start + j * duration) for j in range(per_group)]
        counters[number] = y
    return out


def b64_lines(blob, per_line=2000):
    text = base64.b64encode(blob).decode("ascii")
    if not text:
        return 'b""'
    lines = []
    for i in range(0, len(text), per_line):
        lines.append('  b"' + text[i:i + per_line] + '"')
    return " +\n".join(lines)


def mb_string(text):
    """A MoonBit string literal."""
    out = []
    for ch in text:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif 32 <= ord(ch) < 127:
            out.append(ch)
        else:
            out.append("\\u{" + format(ord(ch), "x") + "}")
    return '"' + "".join(out) + '"'


def frac(text):
    num, den = text.split("/")
    return int(num), int(den)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavformat"
    if "--reuse" not in sys.argv[2:]:
        survey()
    fixtures, tests, header = [], [], []
    for tag, name, cut in SAMPLES:
        d = os.path.join(CUT, tag)
        streams, fmt = parse_streams(os.path.join(d, "streams.txt"))
        codecs = {int(s["index"]): s.get("codec_name", "") for s in streams}
        # logical-fileinfo streams come out of ffprobe without an index
        streams = [s for s in streams if "index" in s]
        rows = with_container_timestamps(
            open(os.path.join(CUT, tag + ".realmedia"), "rb").read(),
            parse_packets(os.path.join(d, "packets.csv"), None, codecs),
            len(streams))
        packets = [struct.pack("<BHQqq", *row) for row in rows]
        err = open(os.path.join(d, "packets.err"), encoding="utf-8",
                   errors="replace").read()
        # ffprobe prints the packets read before a demuxer error and still
        # exits with 0, so the fatal messages of rmdec.c are the tell: the
        # demuxer returns AVERROR_INVALIDDATA after each of them. (A short
        # "readfull" is only logged and the walk carries on.)
        demux_error = re.search(
            r"Impossibly sized packet|Failed to read \d+ bytes"
            r"|Invalid block alignment",
            err) is not None
        print(tag, "packets", len(packets), "read_error", demux_error)
        extra = parse_extradata(os.path.join(d, "extradata.txt"))
        table = b"".join(packets)
        stream_rows = []
        for s in streams:
            audio = s.get("codec_type") == "audio"
            rate = int(s.get("sample_rate", 0)) if audio else 0
            channels = int(s.get("channels", 0)) if audio else 0
            width = int(s.get("width", 0)) if not audio else 0
            height = int(s.get("height", 0)) if not audio else 0
            fps = frac(s.get("avg_frame_rate", "0/0")) if not audio else (0, 0)
            stream_rows.append(
                '      ("{codec}", {rate}, {channels}, {width}, {height}, '
                '{bitrate}L, {start}L, {fnum}, {fden}),'.format(
                    codec=s.get("codec_name", ""), rate=rate, channels=channels,
                    width=width, height=height,
                    bitrate=int(s.get("bit_rate", 0) or 0),
                    start=int(s.get("start_pts", 0) or 0),
                    fnum=fps[0], fden=fps[1]))
        tags = [f'      ({mb_string(k)}, {mb_string(v)}),' for k, v in fmt.get("tags", [])]
        src = name.rsplit(".", 1)[0] + (" [cut to %d bytes]" % cut if cut else "")
        fixtures.append(f'''///|
/// `{src}`: the file, ffprobe's packet table (one 27-byte record per
/// packet: flags, stream, size, pts, pos) and the audio extradata.

///|
let realmedia_{tag}_file_b64 : Bytes = {b64_lines(open(os.path.join(CUT, tag + ".realmedia"), "rb").read())}

///|
let realmedia_{tag}_table_b64 : Bytes = {b64_lines(table)}

///|
let realmedia_{tag}_extradata_b64 : Bytes = {b64_lines(extra)}

''')
        tests.append(f'''///|
test "RealMedia: {tag} ({src}) matches ffprobe" {{
  realmedia_test_check(
    "{tag}",
    realmedia_{tag}_file_b64,
    realmedia_{tag}_table_b64,
    realmedia_{tag}_extradata_b64,
    [
{chr(10).join(stream_rows) if stream_rows else ""}
    ],
    [
{chr(10).join(tags) if tags else ""}
    ],
    {str(demux_error).lower()},
  )
}}

''')
        header.append(f"{tag}: {len(packets)} packets, streams={[(s.get('codec_name'), s.get('duration_ts')) for s in streams]}, demux_error={demux_error}")

    body = TEMPLATE.format(fixtures="".join(fixtures), tests="".join(tests))
    path = os.path.join(out_dir, "realmedia_realdata_wbtest.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(path, len(body), "bytes")
    print("\n".join(header))


TEMPLATE = '''///|
/// RealMedia demuxer against the docker reference FFmpeg 9.0.2
/// (linuxserver/ffmpeg:9.0.2): FATE samples of the RealMedia / RealAudio
/// family, cut to a prefix, demuxed by `av_realmedia_open` and compared
/// with what `ffprobe` reports for exactly the same bytes - the stream
/// table, the format tags and every packet's stream, size, timestamp,
/// keyframe flag and file offset.
///
/// Regeneration (docker image as above, the samples downloaded by
/// `.scratch/realmedia_dl/fetch.py` into `.scratch/realmedia_dl`):
///   python -I scripts/gen_realmedia_fixtures.py libavformat
/// The script cuts the files, runs ffprobe on the cuts and embeds both.
///
/// Expectation notes:
/// * Only the first packet of an interleaved audio group carries a
///   timestamp in the file; the others are the ones FFmpeg's generic layer
///   derives from the codec's frame duration, which the port reproduces.
/// * ffprobe prints `pos` for SIPR packets that the SIPR parser makes up
///   (they are relative offsets, not file positions); those are not
///   compared. Packets flagged corrupt (a truncated final packet) are
///   compared like the others.
/// * The SIPR timestamps are not taken from ffprobe either: it runs SIPR
///   through a parser whose timestamp matching is one frame late (the
///   de-interleaved packets carry no file position), so its pts put the
///   group timestamp on the last frame of the previous group. The expected
///   SIPR pts are read from the record headers of the file instead: the
///   group timestamp labels the first frame of the group.
/// * RV30 / RV40 packet timestamps are not compared: FFmpeg's `rv34`
///   parser rewrites them from the bitstream's picture timestamps, while
///   the demuxer - this port included - reports the record timestamps.
/// * AVDictionary keeps no defined order, so the format tags are compared
///   as a set.
/// * The stream duration is not compared: ffprobe's `estimate_timings_from_pts`
///   replaces the `MDPR` value with the end of the last packet whenever the
///   two are close, which is an estimate of the generic layer and not part
///   of the container.
/// * ffprobe prints the packets read before a demuxer error and still exits
///   with 0, so `demux_error` records whether the fatal messages of
///   `rmdec.c` were logged; the port must then report a read error too.

///|
fn realmedia_test_unpack(table : Bytes) -> Bytes {{
  @libavutil.av_base64_decode(table, 1 << 24).unwrap()
}}

///|
/// One expected packet.
priv struct RealMediaExpect {{
  stream : Int32
  size : Int32
  pts : Int64
  pos : Int64
  key : Bool
  has_pos : Bool
  raw_run : Bool
  no_pts : Bool
}}

///|
fn realmedia_test_records(table : Bytes) -> Array[RealMediaExpect] {{
  let out : Array[RealMediaExpect] = []
  let mut p = 0
  while p + 27 <= table.length() {{
    let flags = table[p].to_int()
    let stream = table[p + 1].to_int() | (table[p + 2].to_int() << 8)
    let size = table[p + 3].to_int() |
      (table[p + 4].to_int() << 8) |
      (table[p + 5].to_int() << 16) |
      (table[p + 6].to_int() << 24)
    let pts = realmedia_test_i64(table, p + 11)
    let pos = realmedia_test_i64(table, p + 19)
    out.push({{
      stream,
      size,
      pts,
      pos,
      key: (flags & 1) != 0,
      has_pos: (flags & 2) != 0,
      raw_run: (flags & 8) != 0,
      no_pts: (flags & 16) != 0,
    }})
    p = p + 27
  }}
  out
}}

///|
fn realmedia_test_i64(b : Bytes, p : Int32) -> Int64 {{
  let lo = (b[p].to_int() |
    (b[p + 1].to_int() << 8) |
    (b[p + 2].to_int() << 16) |
    (b[p + 3].to_int() << 24)).reinterpret_as_uint().to_int64()
  let hi = (b[p + 4].to_int() |
    (b[p + 5].to_int() << 8) |
    (b[p + 6].to_int() << 16) |
    (b[p + 7].to_int() << 24)).to_int64()
  lo | (hi << 32)
}}

///|
fn realmedia_test_same_bytes(a : Bytes, b : Bytes) -> Bool {{
  a.length() == b.length() && a == b
}}

///|
/// Demux `file_b64` and compare it with ffprobe's tables. `streams` holds
/// one row per stream (codec, sample rate, channels, width, height, bit
/// rate, start time, frame rate); `tags` the format tags; `demux_error`
/// says whether the reference stopped before the end of the file.
fn realmedia_test_check(
  tag : String,
  file_b64 : Bytes,
  table_b64 : Bytes,
  extradata_b64 : Bytes,
  streams : Array[(String, Int32, Int32, Int32, Int32, Int64, Int64, Int32, Int32)],
  tags : Array[(String, String)],
  demux_error : Bool,
) -> Unit raise {{
  let data = realmedia_test_unpack(file_b64)
  let demux = match av_realmedia_open(data) {{
    Ok(d) => d
    Err(e) => fail("\\{{tag}}: open failed: \\{{e}}")
  }}
  assert_eq(demux.tracks.length(), streams.length(), msg=tag)
  for i = 0; i < streams.length(); i = i + 1 {{
    let want = streams[i]
    let track = demux.tracks[i]
    let label = "\\{{tag}} stream \\{{i}}"
    assert_eq(track.codec, want.0, msg=label)
    assert_eq(track.sample_rate, want.1, msg=label)
    assert_eq(track.channels, want.2, msg=label)
    assert_eq(track.width, want.3, msg=label)
    assert_eq(track.height, want.4, msg=label)
    assert_eq(track.bit_rate, want.5, msg=label)
    assert_eq(track.start_time, want.6, msg=label)
    assert_eq(track.frame_rate_num, want.7, msg=label)
    assert_eq(track.frame_rate_den, want.8, msg=label)
  }}
  let extradata = realmedia_test_unpack(extradata_b64)
  let mut audio_extradata : Bytes = b""
  let mut saw_audio = false
  for i = 0; i < demux.tracks.length(); i = i + 1 {{
    if demux.tracks[i].media_type is MediaType::Audio {{
      saw_audio = true
      audio_extradata = demux.tracks[i].extradata
    }}
  }}
  if saw_audio {{
    assert_true(
      realmedia_test_same_bytes(audio_extradata, extradata),
      msg="\\{{tag}}: audio extradata differs",
    )
  }}
  assert_eq(demux.metadata.length(), tags.length(), msg=tag)
  // The dictionary of FFmpeg does not keep a defined order, so the tags are
  // compared as a set.
  for i = 0; i < tags.length(); i = i + 1 {{
    let mut found = false
    for j = 0; j < demux.metadata.length(); j = j + 1 {{
      if demux.metadata[j].0 == tags[i].0 {{
        assert_eq(demux.metadata[j].1, tags[i].1, msg="\\{{tag}} tag \\{{tags[i].0}}")
        found = true
      }}
    }}
    assert_true(found, msg="\\{{tag}}: tag \\{{tags[i].0}} missing")
  }}
  assert_eq(
    (demux.read_error != "") == demux_error,
    true,
    msg="\\{{tag}}: read error '\\{{demux.read_error}}' vs ffprobe \\{{demux_error}}",
  )
  let want = realmedia_test_records(realmedia_test_unpack(table_b64))
  if demux.packets.length() != want.length() {{
    fail(
      "\\{{tag}}: \\{{demux.packets.length()}} packets, ffprobe has \\{{want.length()}} (read error '\\{{demux.read_error}}')",
    )
  }}
  // The total of the packet payload must be reproducible from the file.
  for i = 0; i < want.length(); i = i + 1 {{
    let got = demux.packets[i]
    let w = want[i]
    let label = "\\{{tag}} packet \\{{i}}: got stream \\{{got.stream_index}} size \\{{got.data.length()}} pts \\{{got.pts}} key \\{{got.keyframe}} pos \\{{got.pos}}; ffprobe stream \\{{w.stream}} size \\{{w.size}} pts \\{{w.pts}} key \\{{w.key}} pos \\{{w.pos}}"
    assert_eq(got.stream_index, w.stream, msg=label)
    assert_eq(got.data.length(), w.size, msg=label)
    if !w.no_pts {{
      assert_eq(got.pts, w.pts, msg=label)
    }}
    assert_eq(got.keyframe, w.key, msg=label)
    if w.has_pos {{
      assert_eq(got.pos, w.pos, msg=label)
    }}
    if w.raw_run {{
      // a packet that is one run of file bytes must equal that run
      let start = w.pos.to_int()
      assert_true(
        realmedia_test_same_bytes(got.data, data[start:start + w.size].to_owned()),
        msg=label,
      )
    }}
  }}
}}

{fixtures}{tests}'''

main()
