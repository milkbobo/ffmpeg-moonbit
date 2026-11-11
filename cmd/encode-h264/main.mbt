///|
fn main raise {
  let args = @env.args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(
      "usage: encode-h264 input.yuv --width W --height H --output out.264",
    )
    println("  8-bit planar YUV420P")
    println(
      "  [--qp 0..51] [--cabac] [--aq] [--aq-strength 0..6] [--aud] [--target-bytes N]",
    )
    println("  [--vbv-maxrate bits/s --vbv-bufsize bits --fps N]")
    println(
      "  [--stream] feed frames to the streaming encoder (constant memory)",
    )
    println(
      "  [--b-slices] code odd display positions as B pictures (POC reorder)",
    )
    return
  }
  let opts = parse_options(args[1:].to_owned())
  let raw = @fs.read_file_to_bytes(opts.input)
  let (stream, count) = if opts.stream {
    encode_raw_stream(raw, opts)
  } else {
    encode_raw(raw, opts)
  }
  @fs.write_bytes_to_file(opts.output, stream)
  let summary : Json = {
    "codec": "h264",
    "format": "annexb",
    "pixel_format": "yuv420p",
    "width": opts.width,
    "height": opts.height,
    "frames": count,
    "bytes": stream.length(),
    "cabac": opts.cabac,
    "qp": opts.qp,
    "aq": opts.aq,
    "aq_strength": opts.aq_strength,
    "aud": opts.aud,
    "output": opts.output,
  }
  println(summary.stringify())
}
