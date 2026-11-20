///|
/// `encode-av1`: planar 8-bit YUV420P in, raw AV1 OBU stream out, via the
/// pure-MoonBit `Av1Encoder` (§451+). Frame geometry must be 64-multiples.
/// Quality selector: --qp (flat qindex) or --rd-lambda (§457 per-frame
/// qindex choice); --skip-pct enables the §458 per-SB skip decision.

///|
fn main raise {
  let args = @env.args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println("usage: encode-av1 input.yuv --width W --height H --output out.av1")
    println("  planar 8-bit yuv420p: Y (W*H) + U,V (W/2*H/2) per frame")
    println("  W/H must be positive 64-multiples")
    println(
      "  [--qp 1..=255] [--rd-lambda N] [--skip-pct 0..=100] [--me-range 0..=1024]",
    )
    println(
      "  [--skip-uniform]  allow non-zero-MV skip via NEWMV/NEARESTMV (§460)",
    )
    return
  }
  let opts = parse_options(args[1:].to_owned())
  let raw = @fs.read_file_to_bytes(opts.input)
  let frame_size = raw_frame_size(opts)
  if raw.length() == 0 || raw.length() % frame_size != 0 {
    fail(
      "encode-av1: input must contain complete yuv420p frames (\{frame_size} bytes each)",
    )
  }
  let enc = @libavcodec.Av1Encoder::new(
    @libavcodec.Av1SeqEncConfig::default(width=opts.width, height=opts.height),
  )
  let cw = opts.width >> 1
  let ch = opts.height >> 1
  let dec = @libavcodec.Av1Decoder::new()
  let out : Array[Byte] = []
  let mut count = 0
  for offset = 0; offset < raw.length(); offset = offset + frame_size {
    let y = plane(raw, offset, opts.width * opts.height)
    let u = plane(raw, offset + opts.width * opts.height, cw * ch)
    let v = plane(raw, offset + opts.width * opts.height + cw * ch, cw * ch)
    let src = @libavcodec.Av1EncPlanes::{
      y,
      y_stride: opts.width,
      u,
      uv_stride: cw,
      v,
    }
    let encoded = if opts.rd_lambda < 0 {
      enc.encode_frame(
        src,
        base_q_idx=opts.qp,
        range=opts.me_range,
        skip_sad_pct=opts.skip_pct,
        skip_uniform=opts.skip_uniform,
      )
    } else {
      enc.encode_frame(
        src,
        base_q_idx=opts.qp,
        range=opts.me_range,
        rd_lambda=opts.rd_lambda,
        skip_sad_pct=opts.skip_pct,
        skip_uniform=opts.skip_uniform,
      )
    }
    let (pkt, exp) = match encoded {
      Ok(v) => v
      Err(e) => fail("encode-av1: \{e}")
    }
    // Self-check: every emitted packet decodes to exactly the planes the
    // encoder predicted. This is the encoder's own contract (no external
    // ffmpeg oracle needed for wasm-only AV1).
    let f = match dec.decode_packet(pkt) {
      Ok(Some(f)) => f
      Ok(None) => fail("encode-av1: frame \{count} hidden")
      Err(e) => fail("encode-av1: decode frame \{count}: \{e}")
    }
    for yy in 0..<opts.height {
      for xx in 0..<opts.width {
        if f.y[yy * f.y_stride + xx] != exp.y[yy * opts.width + xx] {
          fail("encode-av1: frame \{count} Y(\{yy},\{xx}) diverged")
        }
      }
    }
    for b in pkt {
      out.push(b)
    }
    count = count + 1
  }
  let stream = Bytes::from_array(out)
  @fs.write_bytes_to_file(opts.output, stream)
  let summary : Json = {
    "codec": "av1",
    "format": "obu",
    "pixel_format": "yuv420p",
    "width": opts.width,
    "height": opts.height,
    "frames": count,
    "bytes": stream.length(),
    "qp": opts.qp,
    "rd_lambda": opts.rd_lambda,
    "skip_pct": opts.skip_pct,
    "skip_uniform": opts.skip_uniform,
    "output": opts.output,
  }
  println(summary.stringify())
}
