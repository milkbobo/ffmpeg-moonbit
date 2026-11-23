# Generate libavcodec/cook_realdata_test.mbt from RealMedia Cook streams
# decoded by the docker reference FFmpeg.
#
# Inputs per sample live in .scratch/cook_dl/<tag>/ (see the regeneration
# commands in the emitted file header): extradata.bin (the RM MDPR codec
# private data), packets.raw (the `-c copy -f data` packet dump, every
# packet exactly `block_align` bytes) and ref_s16.pcm (the s16le decode; the
# decoder drops the first two packets, so it holds packets - 2 frames).
#
# Usage: python -I scripts/gen_cook_fixtures.py libavcodec [--stats] [--trace]
#   --stats  also print the per-fixture diff statistics from the test
#   --trace  add a test that prints the symbol-level trace of the first
#            packets (compared against the instrumented C decoder)
import base64
import os
import sys

# tag, source, description, block_align, channels, rate,
# samples_per_channel, packets embedded, first frame checked, frames checked.
# The decoder is stateful, so the packets always start at the beginning of
# the stream; the checked window skips the (near-)silent lead-in of two of
# the samples so that the comparison covers real audio.
SAMPLES = [
    (
        "joint", "ra_cook.rm",
        "joint stereo, 64 kb/s, 37 subbands, coupling from subband 6",
        186, 2, 44100, 1024, 18, 0, 16,
    ),
    (
        "spy", "spygames-2MB.rmvb",
        "joint stereo, 96 kb/s, 34 subbands, coupling from subband 19",
        280, 2, 44100, 1024, 118, 98, 18,
    ),
    (
        "mono", "rv30.rm",
        "single channel, cook version STEREO with one container channel",
        186, 1, 44100, 1024, 62, 36, 24,
    ),
]


def b64_lines(blob, per_line=100):
    text = base64.b64encode(blob).decode("ascii")
    lines = []
    for i in range(0, len(text), per_line):
        lines.append('  b"' + text[i : i + per_line] + '"')
    return " +\n".join(lines)


def bytes_literal(blob):
    return 'b"' + "".join("\\x%02x" % b for b in blob) + '"'


def emit(sample):
    (tag, source, description, block_align, channels, rate, spc, count,
     check_from, check_frames) = sample
    d = os.path.join(".scratch", "cook_dl", tag)
    extradata = open(os.path.join(d, "extradata.bin"), "rb").read()
    packets = open(os.path.join(d, "packets.raw"), "rb").read()
    ref = open(os.path.join(d, "ref_s16.pcm"), "rb").read()
    assert len(packets) % block_align == 0, (tag, len(packets), block_align)
    frames = len(packets) // block_align - 2
    frame_bytes = spc * channels * 2
    assert len(ref) == frames * frame_bytes, (tag, len(ref), frames)
    assert count - 2 >= check_from + check_frames, tag
    checked = ref[check_from * frame_bytes : (check_from + check_frames) * frame_bytes]
    fixture = f'''///|
/// `{source}` ({description}): {count} packets of {block_align} bytes,
/// {channels} channel(s) at {rate} Hz, {spc} samples per channel per frame,
/// followed by the s16le reference for frames {check_from} to
/// {check_from + check_frames - 1} of the {count - 2} frames they produce.

///|
let cook_{tag}_extradata : Bytes = {bytes_literal(extradata)}

///|
let cook_{tag}_packets_b64 : Bytes = cook_concat([
{b64_lines(packets[: count * block_align])}
])

///|
let cook_{tag}_ref_b64 : Bytes = cook_concat([
{b64_lines(checked)}
])

'''
    test = f'''///|
test "Cook: {tag} stream ({source}) matches FFmpeg PCM within one s16 LSB" {{
  cook_check_fixture(
    "{tag}", cook_{tag}_extradata, {block_align}, {channels}, {rate}, {spc},
    cook_{tag}_packets_b64, cook_{tag}_ref_b64, {check_from}, {check_frames},
  )
}}

'''
    return fixture, test


TEMPLATE = '''///|
/// Real-data Cook decoder tests. The fixtures are RealMedia streams from the
/// FFmpeg FATE suite, decoded by the docker reference FFmpeg 9.0.2
/// (linuxserver/ffmpeg:9.0.2). The C decoder runs a float pipeline while the
/// port evaluates the same algorithm in doubles, so the tests bound the
/// output by one s16 LSB instead of comparing an MD5.
///
/// Regeneration (docker image as above, the downloaded samples and this
/// script's companions in `.scratch/cook_dl`, mounted at /w):
///   python -I .scratch/cook_dl/extract.py \\
///     joint=ra_cook.rm spy=spygames-2MB.rmvb mono=rv30.rm
///   python -I scripts/gen_cook_fixtures.py libavcodec
/// `extract.py` dumps `extradata` (ffprobe), the packet sizes and the
/// `-c copy -f data` packet stream, and decodes the s16le reference.
/// Cook discards the first two packets, so a stream of N packets yields
/// N - 2 frames of `samples_per_channel` samples per channel.

///|
fn cook_concat(parts : Array[Bytes]) -> Bytes {{
  let out : Array[Byte] = []
  for part in parts {{
    for b in part {{
      out.push(b)
    }}
  }}
  Bytes::from_array(out)
}}

{fixtures}///|
fn cook_to_s16(v : Double) -> Int32 {{
  if v >= 1.0 {{
    32767
  }} else if v <= -1.0 {{
    -32768
  }} else {{
    (v * 32768.0).round().to_int()
  }}
}}

///|
/// Decode `cook_<tag>_packets_b64` and bound the samples of frames
/// `check_from ..< check_from + check_frames` by one s16 LSB against
/// `cook_<tag>_ref_b64` (planar float -> s16, as FFmpeg does for its FLTP
/// output).
fn cook_check_fixture(
  tag : String,
  extradata : Bytes,
  block_align : Int32,
  channels : Int32,
  rate : Int32,
  samples_per_channel : Int32,
  packets_b64 : Bytes,
  ref_b64 : Bytes,
  check_from : Int32,
  check_frames : Int32,
) -> Unit raise {{
  let data = @libavutil.av_base64_decode(packets_b64, 4000000).unwrap()
  let reference = @libavutil.av_base64_decode(ref_b64, 4000000).unwrap()
  let dec = match
    @libavcodec.CookDecoder::new(
      extradata, channels, block_align, sample_rate=rate,
    ) {{
    Ok(d) => d
    Err(e) => fail("\\{{tag}}: init failed: \\{{e}}")
  }}
  let pcm : Array[Array[Int32]] = Array::makei(channels, _ => [])
  let mut pos = 0
  let mut index = 0
  while pos + block_align <= data.length() {{
    let result = dec.decode_packet(data[pos:pos + block_align].to_owned())
    match result {{
      Ok(Some(frame)) => {{
        // The first two packets prime the overlap and produce no output.
        guard index >= 2 else {{
          fail("\\{{tag}}: packet \\{{index}} produced output early")
        }}
        assert_eq(frame.channels, channels, msg=tag)
        assert_eq(frame.sample_rate, rate, msg=tag)
        for c = 0; c < channels; c = c + 1 {{
          assert_eq(
            frame.samples[c].length(),
            samples_per_channel,
            msg="\\{{tag}}: packet \\{{index}} channel \\{{c}}",
          )
          for v in frame.samples[c] {{
            pcm[c].push(cook_to_s16(v))
          }}
        }}
      }}
      Ok(None) =>
        if index >= 2 {{
          fail("\\{{tag}}: packet \\{{index}} produced no output")
        }}
      Err(e) => fail("\\{{tag}}: packet \\{{index}}: \\{{e}}")
    }}
    pos = pos + block_align
    index = index + 1
  }}
  assert_eq(index, data.length() / block_align, msg=tag)
  let frames = index - 2
  assert_eq(frames, pcm[0].length() / samples_per_channel, msg=tag)
  assert_true(
    frames >= check_from + check_frames,
    msg="\\{{tag}}: only \\{{frames}} frames for the checked window",
  )
  assert_eq(
    reference.length(),
    check_frames * samples_per_channel * channels * 2,
    msg=tag,
  )
  let first = check_from * samples_per_channel
  let count = check_frames * samples_per_channel
  let mut max_diff = 0
  let mut differing = 0
  for i = first; i < first + count; i = i + 1 {{
    for c = 0; c < channels; c = c + 1 {{
      let idx = ((i - first) * channels + c) * 2
      let raw = reference[idx].to_int() | (reference[idx + 1].to_int() << 8)
      let want = if raw >= 32768 {{ raw - 65536 }} else {{ raw }}
      let got = pcm[c][i]
      let d = if got > want {{ got - want }} else {{ want - got }}
      if d > max_diff {{
        max_diff = d
      }}
      if d > 0 {{
        differing = differing + 1
      }}
    }}
  }}
{stats}  assert_true(
    max_diff <= 1,
    msg="\\{{tag}}: max diff \\{{max_diff}}, \\{{differing}} of \\{{count * channels}} samples differ",
  )
}}

{tests}{trace_test}///|
/// `Result::is_err` for the decoder constructor.
fn cook_rejected(r : Result[@libavcodec.CookDecoder, String]) -> Bool {{
  r is Err(_)
}}

///|
test "Cook: rejects unusable stream setups" {{
  let joint = cook_joint_extradata
  // extradata shorter than the 8-byte minimum
  assert_true(
    cook_rejected(@libavcodec.CookDecoder::new(b"\\x01\\x00", 1, 186)),
  )
  // joint stereo is declared for exactly two container channels
  assert_true(cook_rejected(@libavcodec.CookDecoder::new(joint, 3, 186)))
  assert_true(cook_rejected(@libavcodec.CookDecoder::new(joint, 1, 186)))
  // an unknown cook version
  assert_true(
    cook_rejected(
      @libavcodec.CookDecoder::new(
        b"\\x01\\x00\\x00\\x09\\x08\\x00\\x00\\x25\\x00\\x00\\x00\\x00\\x00\\x06\\x00\\x05",
        2,
        186,
      ),
    ),
  )
  // js_vlc_bits below the joint-stereo minimum of 2
  assert_true(
    cook_rejected(
      @libavcodec.CookDecoder::new(
        b"\\x01\\x00\\x00\\x03\\x08\\x00\\x00\\x25\\x00\\x00\\x00\\x00\\x00\\x06\\x00\\x01",
        2,
        186,
      ),
    ),
  )
  // samples per channel must be 256, 512 or 1024
  assert_true(
    cook_rejected(
      @libavcodec.CookDecoder::new(
        b"\\x01\\x00\\x00\\x02\\x07\\x00\\x00\\x25", 1, 186,
      ),
    ),
  )
  // a packet below block_align is not decoded at all
  let short = @libavcodec.CookDecoder::new(joint, 2, 186).unwrap()
  assert_true(short.decode_packet(b"\\x00\\x00\\x00\\x00").unwrap() is None)
}}

///|
test "Cook: only two packets prime before the first output" {{
  let dec = @libavcodec.CookDecoder::new(
    cook_mono_extradata, 1, 186, sample_rate=44100,
  ).unwrap()
  let data = @libavutil.av_base64_decode(
    cook_mono_packets_b64, 4000000,
  ).unwrap()
  assert_true(dec.decode_packet(data[:186].to_owned()).unwrap() is None)
  assert_true(dec.decode_packet(data[186:372].to_owned()).unwrap() is None)
  let third = match dec.decode_packet(data[372:558].to_owned()) {{
    Ok(Some(frame)) => frame
    _ => fail("expected a decoded frame")
  }}
  assert_eq(third.channels, 1)
  assert_eq(third.samples.length(), 1)
  assert_eq(third.samples[0].length(), 1024)
  assert_eq(third.sample_rate, 44100)
}}
'''

TRACE_TEST = '''///|
fn cook_trace_fixture(
  tag : String,
  extradata : Bytes,
  block_align : Int32,
  channels : Int32,
  rate : Int32,
  packets_b64 : Bytes,
) -> Unit raise {
  // re-arms the per-fixture packet counter
  @libavcodec.cook_enable_trace(6)
  let data = @libavutil.av_base64_decode(packets_b64, 4000000).unwrap()
  let dec = @libavcodec.CookDecoder::new(
    extradata, channels, block_align, sample_rate=rate,
  ).unwrap()
  let mut pos = 0
  while pos + block_align <= data.length() {
    ignore(dec.decode_packet(data[pos:pos + block_align].to_owned()))
    pos = pos + block_align
  }
  println("TRACE-END \\{tag}")
}

///|
test "Cook: trace" {
  cook_trace_fixture("joint", cook_joint_extradata, 186, 2, 44100, cook_joint_packets_b64)
  cook_trace_fixture("spy", cook_spy_extradata, 280, 2, 44100, cook_spy_packets_b64)
  cook_trace_fixture("mono", cook_mono_extradata, 186, 1, 44100, cook_mono_packets_b64)
}

'''


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "libavcodec"
    stats = ""
    if "--stats" in sys.argv[2:]:
        stats = (
            '  println("\\{tag}: max diff \\{max_diff}, \\{differing} of '
            '\\{count * channels} samples differ")\n'
        )
    trace_test = TRACE_TEST if "--trace" in sys.argv[2:] else ""
    blocks = [emit(sample) for sample in SAMPLES]
    body = TEMPLATE.format(
        fixtures="".join(f for f, _ in blocks),
        tests="".join(t for _, t in blocks),
        stats=stats,
        trace_test=trace_test,
    )
    path = os.path.join(out_dir, "cook_realdata_test.mbt")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(path, len(body), "bytes")


main()
