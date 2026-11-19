///|
/// `encode-hevc`: planar YUV in, HEVC Annex B out — through the §459
/// streaming encoder, one frame pushed at a time. The output is byte-equal
/// to `hevc_encode_sequence`'s batch entry for the same settings.

///|
/// Unpack one plane of `len` samples at `offset` into Int32 samples (u8 at
/// 8 bits, little-endian u16 above).
fn unpack_plane(
  data : Bytes,
  offset : Int32,
  len : Int32,
  bpp : Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(len, 0)
  for i in 0..<len {
    out[i] = if bpp == 1 {
      data[offset + i].to_int()
    } else {
      data[offset + i * 2].to_int() | (data[offset + i * 2 + 1].to_int() << 8)
    }
  }
  out
}

///|
/// Split one packed frame into its three Int32 planes (geometry from the
/// options; the chroma plane sizes follow the sub-sampling factors).
fn frame_planes(
  data : Bytes,
  offset : Int32,
  opts : Options,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
  let bpp = sample_bytes(opts.bit_depth)
  let luma = opts.width * opts.height
  let cw = opts.width / (if opts.chroma_format == 1 { 2 } else { 1 })
  let ch = opts.height / (if opts.chroma_format == 3 { 1 } else { 2 })
  let chroma = cw * ch
  (
    unpack_plane(data, offset, luma, bpp),
    unpack_plane(data, offset + luma * bpp, chroma, bpp),
    unpack_plane(data, offset + (luma + chroma) * bpp, chroma, bpp),
  )
}

///|
fn pixel_format_name(opts : Options) -> String {
  let base = match (opts.bit_depth, opts.chroma_format) {
    (8, 1) => "yuv420p"
    (8, 2) => "yuv422p"
    (8, 3) => "yuv444p"
    (10, 1) => "yuv420p10le"
    (10, 2) => "yuv422p10le"
    (10, 3) => "yuv444p10le"
    (12, 1) => "yuv420p12le"
    (12, 2) => "yuv422p12le"
    _ => "yuv444p12le"
  }
  base
}

///|
fn main raise {
  let args = @env.args()
  if args.length() == 1 || (args.length() == 2 && args[1] == "--help") {
    println(
      "usage: encode-hevc input.yuv --width W --height H --output out.265",
    )
    println(
      "  planar YUV: --chroma 420|422|444 (default 420); samples above 8 bits are 16-bit little-endian",
    )
    println("  [--qp 0..51] [--crf 0..51] constant rate factor (replaces --qp)")
    println("  [--bit-depth 8|10|12] [--b-slices] [--all-intra]")
    return
  }
  let opts = parse_options(args[1:].to_owned())
  let raw = @fs.read_file_to_bytes(opts.input)
  let frame_size = raw_frame_size(opts)
  if raw.length() == 0 || raw.length() % frame_size != 0 {
    fail(
      "encode-hevc: input must contain complete \{pixel_format_name(opts)} frames (\{frame_size} bytes each)",
    )
  }
  let enc = match
    @libavcodec.HevcStreamEncoder::open(
      width=opts.width,
      height=opts.height,
      qp=opts.qp,
      crf=opts.crf,
      inter=!opts.all_intra,
      b_slices=opts.b_slices,
      bit_depth=opts.bit_depth,
      chroma_format_idc=opts.chroma_format,
    ) {
    Ok(e) => e
    Err(e) => fail("encode-hevc: \{e}")
  }
  let out : Array[Byte] = []
  let mut count = 0
  for offset = 0; offset < raw.length(); offset = offset + frame_size {
    let (y, u, v) = frame_planes(raw, offset, opts)
    match enc.push_frame(y, u, v) {
      Ok(_) =>
        for au in enc.drain() {
          for b in au {
            out.push(b)
          }
        }
      Err(e) => fail("encode-hevc: \{e}")
    }
    count = count + 1
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        for b in au {
          out.push(b)
        }
      }
    Err(e) => fail("encode-hevc: \{e}")
  }
  let stream = Bytes::from_array(out)
  @fs.write_bytes_to_file(opts.output, stream)
  let summary : Json = {
    "codec": "hevc",
    "format": "annexb",
    "pixel_format": pixel_format_name(opts),
    "bit_depth": opts.bit_depth,
    "width": opts.width,
    "height": opts.height,
    "frames": count,
    "bytes": stream.length(),
    "qp": opts.qp,
    "crf": opts.crf,
    "b_slices": opts.b_slices,
    "all_intra": opts.all_intra,
    "output": opts.output,
  }
  println(summary.stringify())
}
