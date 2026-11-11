///|
fn main raise {
  let args = @env.args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(
      "usage: encode-h264 input.yuv --width W --height H --output out.264",
    )
    println("  8-bit planar YUV420P; all frames loaded into memory")
    println(
      "  [--qp 0..51] [--cabac] [--aq] [--aq-strength 0..6] [--aud] [--target-bytes N]",
    )
    println("  [--vbv-maxrate bits/s --vbv-bufsize bits --fps N]")
    return
  }
  let opts = parse_options(args[1:].to_owned())
  let (stream, count) = encode_raw(@fs.read_file_to_bytes(opts.input), opts)
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
