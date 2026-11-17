///|
fn main raise {
  let args = @env.args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(
      "usage: encode-h264 input.yuv --width W --height H --output out.264",
    )
    println(
      "  planar YUV: --chroma 420|422|444 (default 420); samples above 8 bits are 16-bit little-endian",
    )
    println(
      "  [--qp 0..51] [--bit-depth 8|9|10|12|14] [--cabac] [--aq] [--aq-strength 0..6] [--aud] [--target-bytes N]",
    )
    println("  [--vbv-maxrate bits/s --vbv-bufsize bits --fps N]")
    println(
      "  [--crf 0..51] constant rate factor (decimals; replaces --target-bytes as the quality selector)",
    )
    println(
      "  streaming VBV supports P/B pictures; streaming ABR is unsupported",
    )
    println(
      "  [--stream] chunked host I/O (native); [--cabac-rd] requires --cabac",
    )
    println(
      "  [--dct8x8]  High profile 8x8 transform (I8x8, inter 8x8, I8x8-in-B)",
    )
    println(
      "  [--b-slices] code odd display positions as B pictures (POC reorder)",
    )
    println(
      "  [--b-parts]  sub-partitioned B kinds (16x8/8x16, B_8x8); requires --b-slices",
    )
    println(
      "  [--intra-in-b] Intra16x16 macroblocks inside B slices (scene cuts); requires --b-slices",
    )
    println(
      "  [--intra4x4-in-b] Intra4x4 macroblocks inside B slices; requires --b-slices",
    )
    println(
      "  [--no-weightp] disable explicit weighted P prediction (default on)",
    )
    println(
      "  [--weightp-b] [--no-weightp-b] explicit weighted B prediction (default off)",
    )
    println("  [--codec h264] codec selector (§414 facade; h264 only today)")
    println("  [--multi-ref N] reference history 1..16 (P and B schedules)")
    println("  [--keyint N] periodic IDR in display frames, 0 disables")
    println("  [--chroma-qp-offset N] Cb/Cr QP offset -12..12 (default 0)")
    println(
      "  [--deblock-alpha N] [--deblock-beta N] slice deblocking offsets -6..6 (div2, default 0)",
    )
    return
  }
  let opts = parse_options(args[1:].to_owned())
  let (count, bytes) = if opts.stream {
    encode_stream_file(opts)
  } else {
    let raw = @fs.read_file_to_bytes(opts.input)
    let (stream, count) = encode_raw(raw, opts)
    @fs.write_bytes_to_file(opts.output, stream)
    (count, stream.length())
  }
  let summary : Json = {
    "codec": opts.codec.name(),
    "format": "annexb",
    "pixel_format": @codec.video_pixel_format(
      opts.bit_depth,
      chroma_format=opts.chroma_format,
    ),
    "bit_depth": opts.bit_depth,
    "width": opts.width,
    "height": opts.height,
    "frames": count,
    "bytes": bytes,
    "cabac": opts.cabac,
    "qp": opts.qp,
    "aq": opts.aq,
    "aq_strength": opts.aq_strength,
    "aud": opts.aud,
    "keyint": opts.keyint,
    "output": opts.output,
  }
  println(summary.stringify())
}
