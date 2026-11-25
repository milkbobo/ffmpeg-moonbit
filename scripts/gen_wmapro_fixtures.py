# Generate libavformat/wmapro_realdata_test.mbt: WMA Pro through the
# unified playback API, against FATE's own reference PCM.
#
# Samples (downloaded from fate-suite.ffmpeg.org when missing):
#   wmapro/Beethovens_9th-1_small.wma      48 kHz stereo, 24 valid bits
#                                          (fate-wmapro-2ch)
#   wmapro/latin_192_mulitchannel_cut.wma  48 kHz 5.1 with an LFE channel
#                                          (fate-wmapro-5.1)
# The reference is FATE's s16le PCM next to each sample. A float decoder
# cannot be compared by MD5: the C's float FFT and this port's double
# evaluation differ by up to 1 LSB after the s16 conversion (16 and 35 of
# 1.25 million / 180 thousand values on these two files), so the test checks
# every `stride`-th s16 value within 1 LSB, and the per frame, per channel
# sum of |x| within 2048 (1 LSB per sample of a frame).
#
# FATE's references are the whole output: the decoded length equals them
# exactly. The decoder can still emit an end-of-stream frame (the second
# half of the last overlap-add), but `ff_wmapro_decoder` has no
# AV_CODEC_CAP_DELAY, so fftools never asks for it and the facade does not
# drain it either; a packet level test covers `WmaProDecoder::flush`.
#
# The WAV case wraps the complete latin packets behind a WAVEFORMATEX header
# (tag 0x0162, cbSize 18, the 18 codec private bytes of the ASF stream
# properties). ffmpeg's own WAV muxer cannot write that (it emits
# WAVE_FORMAT_EXTENSIBLE and drops the private bytes), so the packets are
# extracted with `-f data` and the header is assembled here; the reference
# build must then decode the result to FATE's PCM, which this script checks.
#
# Usage (from the repo root; needs the local FFmpeg 9.0.2 reference build):
#   python -I scripts/gen_wmapro_fixtures.py libavformat [ffmpeg.exe]
import base64
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DL = os.path.join(ROOT, ".scratch", "wmapro_dl")
BASE = "https://fate-suite.ffmpeg.org"
FRAME = 2048

SAMPLES = [
    # (file name, url path, channels, stride, MoonBit prefix)
    ("Beethovens_9th-1_small", "wmapro", 2, 97, "beet"),
    ("latin_192_mulitchannel_cut", "wmapro", 6, 251, "latin"),
]


def ensure(name, ext, url_path):
    path = os.path.join(DL, name + "." + ext)
    if not os.path.exists(path):
        import urllib.request

        os.makedirs(DL, exist_ok=True)
        urllib.request.urlretrieve("%s/%s/%s.%s" % (BASE, url_path, name, ext), path)
    return path


def b64_lines(data, indent="  "):
    text = base64.b64encode(data).decode("ascii")
    return [indent + 'b"' + text[i : i + 120] + '"' for i in range(0, len(text), 120)]


def emit_bytes(out, name, data, comment):
    out.append("///|")
    for line in (comment if isinstance(comment, list) else comment.splitlines()):
        out.append("/// " + line if line else "///")
    out.append("let %s : Bytes = wmapro_cat([" % name)
    lines = b64_lines(data)
    for i, line in enumerate(lines):
        out.append(line + (" +" if i < len(lines) - 1 else ""))
    out.append("])")
    out.append("")


def emit_s16(out, name, values, comment):
    emit_bytes(out, name, struct.pack("<%dh" % len(values), *values), comment)


def emit_i64(out, name, values, comment):
    emit_bytes(out, name, b"".join(struct.pack("<q", v) for v in values), comment)


def s16_ref(name, channels):
    raw = open(ensure(name, "pcm", "wmapro"), "rb").read()
    vals = list(struct.unpack("<%dh" % (len(raw) // 2), raw))
    frames = len(vals) // (FRAME * channels)
    assert len(vals) == frames * FRAME * channels, "FATE reference is not whole frames"
    return vals, frames


def asf_stream_properties(data):
    """The WAVEFORMATEX bytes of the first audio stream property object."""
    def u16(off):
        return struct.unpack_from("<H", data, off)[0]

    def u32(off):
        return struct.unpack_from("<I", data, off)[0]

    def u64(off):
        return struct.unpack_from("<Q", data, off)[0]

    header_size = u64(16)
    count = u32(24)
    pos = 30
    stream_guid = bytes([0x91, 0x07, 0xDC, 0xB7, 0xB7, 0xA9, 0xCF, 0x11, 0x8E, 0xE6, 0x00, 0xC0, 0x0C, 0x20, 0x53, 0x65])
    audio_guid = bytes([0x40, 0x9E, 0x69, 0xF8, 0x4D, 0x5B, 0xCF, 0x11, 0xA8, 0xFD, 0x00, 0x80, 0x5F, 0x5C, 0x44, 0x2B])
    for _ in range(count):
        if pos + 24 > header_size:
            break
        size = u64(pos + 16)
        if data[pos : pos + 16] == stream_guid:
            body = pos + 24
            assert data[body : body + 16] == audio_guid
            tss = u32(body + 40)
            wav = body + 54
            return data[wav : wav + tss]
        pos += size
    raise SystemExit("audio stream properties not found")


def make_wav(wma, payloads, out_path):
    fmt = asf_stream_properties(wma)
    tag, ch, rate, avg, ba, bits, cb = struct.unpack_from("<HHIIHHH", fmt, 0)
    assert cb + 18 == len(fmt) and tag == 0x0162
    body = b"".join(payloads)
    head = b"RIFF" + struct.pack("<I", 4 + (8 + 18 + cb) + 8 + len(body)) + b"WAVE"
    head += b"fmt " + struct.pack("<I", 18 + cb) + fmt
    head += b"data" + struct.pack("<I", len(body))
    open(out_path, "wb").write(head + body)
    return struct.unpack_from("<H", fmt, 2)[0]


def ffmpeg(args):
    return subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace")


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavformat"
    ffmpeg_exe = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, ".scratch", "wmapro_ff", "src", "ffmpeg.exe")
    if not os.path.exists(ffmpeg_exe):
        raise SystemExit("reference ffmpeg not found: " + ffmpeg_exe)
    out = [
        "///|",
        "/// WMA Pro through the unified playback API, against FATE.",
        "/// Every file is decoded by `decode_audio_file` (ASF or WAV demuxer,",
        "/// `wmaprodec.c` port) and its interleaved s16 output is checked against",
        "/// the s16le reference PCM that FATE keeps next to the sample",
        "/// (`fate-wmapro-2ch`, `fate-wmapro-5.1`): every N-th value within 1 LSB",
        "/// and the per frame, per channel sum of |x| within 2048, the float32",
        "/// noise the C's FFT leaves after the s16 conversion being at most 1 LSB",
        "/// per sample. The decoded length is FATE's as well: fftools never",
        "/// drains the decoder's end-of-stream frame.",
        "/// Generated by `scripts/gen_wmapro_fixtures.py`.",
        "///",
        "/// Regenerate with",
        "/// `python -I scripts/gen_wmapro_fixtures.py libavformat [ffmpeg.exe]`.",
        "",
        "///|",
        "fn wmapro_cat(parts : Array[Bytes]) -> Bytes {",
        "  let out : Array[Byte] = []",
        "  for part in parts {",
        "    for b in part {",
        "      out.push(b)",
        "    }",
        "  }",
        "  Bytes::from_array(out)",
        "}",
        "",
        "///|",
        "fn wmapro_load(b64 : Bytes) -> Bytes {",
        "  @libavutil.av_base64_decode(b64, 16 << 20).unwrap()",
        "}",
        "",
        "///|",
        "/// Little-endian int16 values of a base64 blob.",
        "fn wmapro_s16_values(b64 : Bytes) -> FixedArray[Int32] {",
        "  let raw = wmapro_load(b64)",
        "  FixedArray::makei(raw.length() / 2, i => {",
        "    let v = raw[i * 2].to_int() | (raw[i * 2 + 1].to_int() << 8)",
        "    if v >= 32768 {",
        "      v - 65536",
        "    } else {",
        "      v",
        "    }",
        "  })",
        "}",
        "",
        "///|",
        "/// Little-endian int64 values of a base64 blob.",
        "fn wmapro_i64_values(b64 : Bytes) -> FixedArray[Int64] {",
        "  let raw = wmapro_load(b64)",
        "  FixedArray::makei(raw.length() / 8, i => {",
        "    let mut v = 0L",
        "    for k in 0..<8 {",
        "      v = v | (raw[i * 8 + k].to_int().reinterpret_as_uint().to_int64() << (k * 8))",
        "    }",
        "    v",
        "  })",
        "}",
        "",
        "///|",
        "/// The facade's decode as interleaved s16 (x * 32768, half away from",
        "/// zero, clipped): the float decoder's output on the s16 grid.",
        "fn wmapro_s16(audio : @libavformat.DecodedAudio) -> Array[Int32] {",
        "  let rows = audio.samples()",
        "  let n = if rows.length() > 0 { rows[0].length() } else { 0 }",
        "  let out = Array::make(n * rows.length(), 0)",
        "  for i = 0; i < n; i = i + 1 {",
        "    for ch, row in rows {",
        "      let q = (row[i] * 32768.0).round().to_int()",
        "      out[i * rows.length() + ch] = if q > 32767 {",
        "        32767",
        "      } else if q < -32768 {",
        "        -32768",
        "      } else {",
        "        q",
        "      }",
        "    }",
        "  }",
        "  out",
        "}",
        "",
        "///|",
        "/// `extradata` with the decode flags (offset 14) replaced; the rest is",
        "/// the latin stream's: 24 valid bits, 5.1 channel mask.",
        "fn wmapro_with_flags(good : Bytes, flags : Int32) -> Bytes {",
        "  let e = FixedArray::makei(18, _ => b'\\x00')",
        "  for i in 0..<18 {",
        "    e[i] = good[i]",
        "  }",
        "  e[14] = (flags & 0xFF).to_byte()",
        "  e[15] = ((flags >> 8) & 0xFF).to_byte()",
        "  Bytes::from_array(e[:])",
        "}",
        "",
        "///|",
        "let wmapro_frame : Int32 = 2048",
        "",
        "///|",
        "/// Decode `data` and compare with the FATE reference of its stream:",
        "/// the stream labels, the decoded length, the sampled s16 values",
        "/// (<= 1 LSB), the per frame / channel sums of |x| (<= 2048).",
        "fn wmapro_check(",
        "  data : Bytes,",
        "  format : String,",
        "  channels : Int32,",
        "  ref_frames : Int32,",
        "  stride : Int32,",
        "  samples : FixedArray[Int32],",
        "  sums : FixedArray[Int64],",
        "  label : String,",
        ") -> Unit raise {",
        "  let audio = @libavformat.decode_audio_file(data)",
        "  assert_eq(audio.format_name(), format, msg=\"\\{label}: format\")",
        "  assert_eq(audio.codec_id(), \"wmapro\", msg=\"\\{label}: codec\")",
        "  assert_eq(audio.sample_rate(), 48000, msg=\"\\{label}: rate\")",
        "  assert_eq(audio.channels(), channels, msg=\"\\{label}: channels\")",
        "  assert_eq(audio.read_error(), \"\", msg=\"\\{label}: read error\")",
        "  let rows = audio.samples()",
        "  let n = rows[0].length()",
        "  assert_eq(n, ref_frames * wmapro_frame, msg=\"\\{label}: decoded length\")",
        "  let pcm = wmapro_s16(audio)",
        "  let total = ref_frames * wmapro_frame * channels",
        "  let mut k = 0",
        "  let mut idx = 0",
        "  while idx < total {",
        "    let d = pcm[idx] - samples[k]",
        "    assert_true(d <= 1 && d >= -1, msg=\"\\{label}: s16 value \\{idx}\")",
        "    k += 1",
        "    idx += stride",
        "  }",
        "  assert_eq(k, samples.length(), msg=\"\\{label}: sample count\")",
        "  assert_eq(sums.length(), ref_frames * channels, msg=\"\\{label}: sum count\")",
        "  for f in 0..<ref_frames {",
        "    for ch in 0..<channels {",
        "      let mut sum = 0L",
        "      for i in (f * wmapro_frame)..<((f + 1) * wmapro_frame) {",
        "        sum += pcm[i * channels + ch].to_int64().abs()",
        "      }",
        "      let d = sum - sums[f * channels + ch]",
        "      assert_true(d <= 2048 && d >= -2048, msg=\"\\{label}: frame \\{f} ch \\{ch} sum\")",
        "    }",
        "  }",
        "}",
        "",
    ]
    arrays = {}
    for name, url_path, channels, stride, prefix in SAMPLES:
        wma = ensure(name, "wma", url_path)
        data = open(wma, "rb").read()
        vals, frames = s16_ref(name, channels)
        sampled = vals[::stride]
        sums = []
        for f in range(frames):
            for ch in range(channels):
                sums.append(sum(abs(v) for v in vals[f * FRAME * channels + ch : (f + 1) * FRAME * channels : channels]))
        emit_bytes(out, "wmapro_%s_wma" % prefix, data, [
            "FATE `%s.wma` (%d bytes): 48 kHz, %d channels, 24 valid bits." % (name, len(data), channels),
        ])
        emit_s16(out, "wmapro_%s_samples" % prefix, sampled, [
            "Every %dth interleaved s16 value of FATE's `%s.pcm` (%d of %d)." % (stride, name, len(sampled), len(vals)),
        ])
        emit_i64(out, "wmapro_%s_sums" % prefix, sums, [
            "Per frame, per channel sum of |x| over FATE's `%s.pcm` (%d frames)." % (name, frames),
        ])
        arrays[prefix] = (channels, frames, stride)

    # The WAV case: the complete latin packets behind a WAVEFORMATEX header.
    name = SAMPLES[1][0]
    wma = open(ensure(name, "wma", SAMPLES[1][1]), "rb").read()
    raw_path = os.path.join(DL, "latin_payloads.bin")
    r = ffmpeg([ffmpeg_exe, "-hide_banner", "-v", "error", "-y", "-i", os.path.join(DL, name + ".wma"), "-map", "0:a:0", "-c:a", "copy", "-f", "data", raw_path])
    if r.returncode != 0:
        raise SystemExit("ffmpeg -f data failed: " + r.stderr)
    payloads = open(raw_path, "rb").read()
    block_align = struct.unpack_from("<H", asf_stream_properties(wma), 12)[0]
    complete = len(payloads) // block_align
    body = payloads[: complete * block_align]
    wav_path = os.path.join(DL, "latin_wmapro.wav")
    channels = make_wav(wma, [body[i * block_align : (i + 1) * block_align] for i in range(complete)], wav_path)
    # The reference build must decode the WAV to FATE's PCM (it has no raw
    # PCM muxers: write a WAV and take its data chunk).
    ref_wav = os.path.join(DL, "latin_wmapro.ref.wav")
    r = ffmpeg([ffmpeg_exe, "-hide_banner", "-v", "error", "-y", "-i", wav_path, "-c:a", "pcm_s16le", "-f", "wav", ref_wav])
    if r.returncode != 0:
        raise SystemExit("reference decode of the WAV failed: " + r.stderr)
    riff = open(ref_wav, "rb").read()
    pos = 12
    got = b""
    while pos + 8 <= len(riff):
        size = struct.unpack_from("<I", riff, pos + 4)[0]
        if riff[pos : pos + 4] == b"data":
            got = riff[pos + 8 : pos + 8 + size]
            break
        pos += 8 + size + (size & 1)
    want = open(ensure(name, "pcm", SAMPLES[1][1]), "rb").read()
    g = struct.unpack("<%dh" % (len(got) // 2), got)
    w = struct.unpack("<%dh" % (len(want) // 2), want)
    n = min(len(g), len(w))
    diff = [abs(g[i] - w[i]) for i in range(n)]
    print("WAV decode by the reference: %d values, max |diff| %d vs FATE, extra values %d" % (n, max(diff), len(g) - len(w)))
    assert max(diff) <= 1
    emit_bytes(out, "wmapro_latin_wav", open(wav_path, "rb").read(), [
        "The complete packets of `latin_192_mulitchannel_cut.wma` behind a",
        "WAVEFORMATEX header (tag 0x0162, cbSize 18, the ASF stream",
        "properties' 18 codec private bytes); %d packets of %d bytes." % (complete, block_align),
    ])
    out.append("///|")
    out.append("/// Offset of the WAV's `data` payload.")
    out.append("let wmapro_latin_wav_data : Int32 = %d" % (open(wav_path, "rb").read().index(b"data") + 8))
    out.append("")

    # A corrupt frame in the second packet: a length prefix of 100 bits over
    # all zero bits, i.e. a tile without subframes. The C decodes it with
    # the previous frame's stale layout, fails the length check and drops
    # the packet; the reference shows what survives.
    wav = bytearray(open(wav_path, "rb").read())
    data_offset = wav.index(b"data") + 8
    second = data_offset + block_align
    bad = bytearray(block_align)
    bad[0] = 0x10  # sequence number 1, two zero bits, no previous frame bits
    bad[4] = 100  # frame length 100 bits
    wav[second : second + block_align] = bad
    corrupt_path = os.path.join(DL, "latin_wmapro_corrupt.wav")
    open(corrupt_path, "wb").write(wav)
    ref_corrupt = os.path.join(DL, "latin_wmapro_corrupt.ref.wav")
    r = ffmpeg([ffmpeg_exe, "-hide_banner", "-v", "error", "-y", "-i", corrupt_path, "-c:a", "pcm_s16le", "-f", "wav", ref_corrupt])
    if r.returncode != 0:
        raise SystemExit("reference decode of the corrupt WAV failed: " + r.stderr)
    riff = open(ref_corrupt, "rb").read()
    pos = 12
    got = b""
    while pos + 8 <= len(riff):
        size = struct.unpack_from("<I", riff, pos + 4)[0]
        if riff[pos : pos + 4] == b"data":
            got = riff[pos + 8 : pos + 8 + size]
            break
        pos += 8 + size + (size & 1)
    cvals = list(struct.unpack("<%dh" % (len(got) // 2), got))
    cframes = len(cvals) // (FRAME * channels)
    assert cframes * FRAME * channels == len(cvals)
    assert cframes < frames, "the corrupt frame was not dropped"
    print("corrupt stream: the reference keeps %d of %d frames" % (cframes, frames))
    stride = SAMPLES[1][3]
    emit_s16(out, "wmapro_corrupt_samples", cvals[::stride], [
        "Every %dth s16 value of the reference decode of the corrupt WAV (%d frames)." % (stride, cframes),
    ])
    emit_i64(
        out,
        "wmapro_corrupt_sums",
        [
            sum(abs(v) for v in cvals[f * FRAME * channels + ch : (f + 1) * FRAME * channels : channels])
            for f in range(cframes)
            for ch in range(channels)
        ],
        ["Per frame, per channel sums of |x| of the corrupt WAV's reference decode."],
    )
    out.extend(
        [
            "///|",
            "test \"wmapro: a corrupt frame is dropped and the stream goes on\" {",
            "  // The second packet opens with a frame length of 100 bits over all",
            "  // zero bits: a tile without subframes. The C answers with an",
            "  // error for that packet, fftools logs it and continues; the port",
            "  // drops the same frames (checked against the reference decode).",
            "  let wav = wmapro_load(wmapro_latin_wav)",
            "  let off = wmapro_latin_wav_data + 8192",
            "  let bad = Bytes::from_array(Array::makei(8192, i => if i == 0 {",
            "    0x10",
            "  } else if i == 4 {",
            "    0x64",
            "  } else {",
            "    0x00",
            "  }))",
            "  let data = wmapro_cat([",
            "    wav[:off].to_owned(),",
            "    bad,",
            "    wav[off + 8192:].to_owned(),",
            "  ])",
            "  wmapro_check(",
            "    data,",
            "    \"wav\",",
            "    6,",
            "    %d," % cframes,
            "    %d," % stride,
            "    wmapro_s16_values(wmapro_corrupt_samples),",
            "    wmapro_i64_values(wmapro_corrupt_sums),",
            "    \"corrupt\",",
            "  )",
            "}",
            "",
        ]
    )

    out.append("///|")
    out.append("test \"wmapro: FATE Beethovens, 48 kHz stereo, 24 valid bits (ASF)\" {")
    out.append("  wmapro_check(")
    out.append("    wmapro_load(wmapro_beet_wma),")
    out.append("    \"asf\",")
    out.append("    2,")
    out.append("    %d," % arrays["beet"][1])
    out.append("    %d," % arrays["beet"][2])
    out.append("    wmapro_s16_values(wmapro_beet_samples),")
    out.append("    wmapro_i64_values(wmapro_beet_sums),")
    out.append("    \"beet\",")
    out.append("  )")
    out.append("}")
    out.append("")
    out.append("///|")
    out.append("test \"wmapro: FATE latin, 48 kHz 5.1 with LFE (ASF)\" {")
    out.append("  wmapro_check(")
    out.append("    wmapro_load(wmapro_latin_wma),")
    out.append("    \"asf\",")
    out.append("    6,")
    out.append("    %d," % arrays["latin"][1])
    out.append("    %d," % arrays["latin"][2])
    out.append("    wmapro_s16_values(wmapro_latin_samples),")
    out.append("    wmapro_i64_values(wmapro_latin_sums),")
    out.append("    \"latin\",")
    out.append("  )")
    out.append("}")
    out.append("")
    out.append("///|")
    out.append("test \"wmapro: the latin stream in a WAV (format tag 0x0162)\" {")
    out.append("  wmapro_check(")
    out.append("    wmapro_load(wmapro_latin_wav),")
    out.append("    \"wav\",")
    out.append("    6,")
    out.append("    %d," % arrays["latin"][1])
    out.append("    %d," % arrays["latin"][2])
    out.append("    wmapro_s16_values(wmapro_latin_samples),")
    out.append("    wmapro_i64_values(wmapro_latin_sums),")
    out.append("    \"latin wav\",")
    out.append("  )")
    out.append("}")
    out.append("")
    out.extend(
        [
            "///|",
            "/// The demuxed packets and the decoder's extradata of the latin",
            "/// file, for the packet level tests.",
            "fn wmapro_latin_packets()",
            "  -> (@libavcodec.WmaProDecoder, Array[Bytes]) raise {",
            "  let mf = @libavformat.MediaFile::open(wmapro_load(wmapro_latin_wma))",
            "  let extradata = match mf.streams()[0].extradata {",
            "    Some(v) => v",
            "    None => fail(\"latin: no extradata\")",
            "  }",
            "  let dec = match",
            "    @libavcodec.wmapro_decoder_new(extradata, 48000, 6, 8192) {",
            "    Ok(dec) => dec",
            "    Err(e) => fail(\"latin: open: \\{e}\")",
            "  }",
            "  let packets = []",
            "  while true {",
            "    match mf.next_packet() {",
            "      Some(p) => packets.push(p.data)",
            "      None => break",
            "    }",
            "  }",
            "  (dec, packets)",
            "}",
            "",
            "///|",
            "test \"wmapro: decoder facts\" {",
            "  let (dec, packets) = wmapro_latin_packets()",
            "  assert_eq(dec.channels(), 6)",
            "  assert_eq(dec.samples_per_frame(), 2048)",
            "  assert_eq(dec.block_align(), 8192)",
            "  assert_eq(packets.length(), 3)",
            "  assert_eq(packets[0].length(), 8192)",
            "}",
            "",
            "///|",
            "test \"wmapro: packets step the decoder until they are used up\" {",
            "  let (dec, packets) = wmapro_latin_packets()",
            "  // The first packet's first frame is skipped (its overlap-add has",
            "  // no predecessor) and the C reports it as consumed input.",
            "  let (used, frame) = dec.decode_packet(packets[0]).unwrap()",
            "  assert_true(used > 0 && used < 8192)",
            "  assert_true(frame is None)",
            "  assert_eq(dec.last_error(), \"\")",
            "  let mut pos = used",
            "  let mut frames = 0",
            "  while pos < 8192 {",
            "    let (u, f) = dec.decode_packet(packets[0][pos:].to_owned()).unwrap()",
            "    assert_true(u > 0)",
            "    if f is Some(_) {",
            "      frames += 1",
            "    }",
            "    pos += u",
            "  }",
            "  assert_eq(pos, 8192)",
            "  // Every packet but the last piece leaves a partial frame for the",
            "  // next one; the 5.1 stream packs about 25 frames per packet.",
            "  assert_true(frames > 20 && frames < 40)",
            "}",
            "",
            "///|",
            "test \"wmapro: a packet shorter than block_align is dropped and reported\" {",
            "  let (dec, packets) = wmapro_latin_packets()",
            "  let (used, frame) = dec.decode_packet(packets[0][:100].to_owned()).unwrap()",
            "  assert_eq(used, 100)",
            "  assert_true(frame is None)",
            "  assert_eq(dec.last_error(), \"wmapro: input packet too small (100 < 8192)\")",
            "}",
            "",
            "///|",
            "/// Every frame of the stream through the decoder API, then its",
            "/// end-of-stream frame: the last half frame, once.",
            "test \"wmapro: the decoder's end-of-stream frame\" {",
            "  let (dec, packets) = wmapro_latin_packets()",
            "  let mut frames = 0",
            "  for packet in packets {",
            "    let mut pos = 0",
            "    while pos < packet.length() {",
            "      let (used, frame) = dec.decode_packet(packet[pos:].to_owned()).unwrap()",
            "      assert_true(used > 0)",
            "      if frame is Some(_) {",
            "        frames += 1",
            "      }",
            "      pos += used",
            "    }",
            "  }",
            "  assert_eq(frames, 102)",
            "  assert_eq(dec.last_error(), \"\")",
            "  let last = dec.flush().unwrap()",
            "  assert_true(last is Some(_))",
            "  let rows = last.unwrap()",
            "  assert_eq(rows.length(), 6)",
            "  for ch, row in rows {",
            "    assert_eq(row.length(), 2048)",
            "    for i in 1024..<2048 {",
            "      assert_eq(row[i], 0.0, msg=\"end-of-stream frame ch \\{ch}\")",
            "    }",
            "    assert_true(row[0] != 0.0 || ch > 0)",
            "  }",
            "  assert_true(dec.flush().unwrap() is None)",
            "}",
            "",
            "///|",
            "test \"wmapro: invalid and unsupported stream headers\" {",
            "  let (_, packets) = wmapro_latin_packets()",
            "  let mf = @libavformat.MediaFile::open(wmapro_load(wmapro_latin_wma))",
            "  let good = match mf.streams()[0].extradata {",
            "    Some(v) => v",
            "    None => fail(\"latin: no extradata\")",
            "  }",
            "  assert_true(packets.length() > 0)",
            "  match @libavcodec.wmapro_decoder_new(b\"\\x12\\x34\", 48000, 6, 8192) {",
            "    Err(e) => assert_eq(e, \"wmapro: unknown extradata size (18 bytes needed)\")",
            "    Ok(_) => fail(\"short extradata accepted\")",
            "  }",
            "  match @libavcodec.wmapro_decoder_new(good, 48000, 6, 0) {",
            "    Err(e) => assert_eq(e, \"wmapro: block_align is not set\")",
            "    Ok(_) => fail(\"zero block_align accepted\")",
            "  }",
            "  // extradata: valid bits at 0, channel mask at 2, decode flags at 14.",
            "  // 14-bit blocks: frame_len_bits 13 + 1 (flags & 6 == 2).",
            "  match @libavcodec.wmapro_decoder_new(wmapro_with_flags(good, 0xE2), 100000, 6, 8192) {",
            "    Err(e) => assert_eq(e, \"wmapro: 14-bit block sizes are not supported\")",
            "    Ok(_) => fail(\"14-bit blocks accepted\")",
            "  }",
            "  // 128 subframes (flags & 0x38 == 0x38).",
            "  match @libavcodec.wmapro_decoder_new(wmapro_with_flags(good, 0xF8), 48000, 6, 8192) {",
            "    Err(e) => assert_eq(e, \"wmapro: invalid number of subframes 128\")",
            "    Ok(_) => fail(\"128 subframes accepted\")",
            "  }",
            "  // The 5.1 channel mask (0x3f) decides the decoder's channel count.",
            "  match @libavcodec.wmapro_decoder_new(wmapro_with_flags(good, 0xE0), 48000, 3, 8192) {",
            "    Err(e) => assert_eq(e, \"wmapro: more than 8 channels are not supported\")",
            "    Ok(_) => fail(\"9 channels accepted\")",
            "  }",
            "}",
            "",
        ]
    )
    dst = os.path.join(out_dir, "wmapro_realdata_test.mbt")
    with open(dst, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out) + "\n")
    print("wrote %s (%d bytes)" % (dst, os.path.getsize(dst)))


if __name__ == "__main__":
    main()
