///|
priv struct Options {
  input : String
  output : String
  width : Int32
  height : Int32
  qp : Int32
  cabac : Bool
  aq : Bool
  aq_strength : Int32
  aud : Bool
  target_bytes : Int32
  maxrate : Int32
  bufsize : Int32
  fps : Int32
}

///|
/// args excludes the executable name. Reject unknown/repeated switches,
/// incomplete frames and invalid geometry before creating an output file.
fn parse_options(args : Array[String]) -> Options raise {
  let values : Map[String, String] = Map([])
  let mut input = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--cabac" | "--aq" | "--aud" => {
        if values.contains(arg) {
          fail("encode-h264: repeated option \{arg}")
        }
        values[arg] = "true"
        i += 1
      }
      "--output"
      | "--width"
      | "--height"
      | "--qp"
      | "--aq-strength"
      | "--target-bytes"
      | "--vbv-maxrate"
      | "--vbv-bufsize"
      | "--fps" => {
        if values.contains(arg) {
          fail("encode-h264: repeated option \{arg}")
        }
        if i + 1 >= args.length() {
          fail("encode-h264: \{arg} requires a value")
        }
        values[arg] = args[i + 1]
        i += 2
      }
      _ => {
        if arg.has_prefix("--") {
          fail("encode-h264: unknown option \{arg}")
        }
        if input != "" {
          fail("encode-h264: unexpected argument \{arg}")
        }
        input = arg
        i += 1
      }
    }
  }
  fn number(
    values : Map[String, String],
    key : String,
    fallback : Int32,
  ) -> Int32 raise {
    match values.get(key) {
      None => fallback
      Some(s) =>
        @string.parse_int(s) catch {
          _ => fail("encode-h264: \{key} expects an integer")
        }
    }
  }
  let output = values.get("--output").unwrap_or("")
  let width = number(values, "--width", 0)
  let height = number(values, "--height", 0)
  let qp = number(values, "--qp", 26)
  let aq_strength = number(values, "--aq-strength", 1)
  if aq_strength < 0 || aq_strength > 6 {
    fail("encode-h264: aq-strength must be in 0..=6")
  }
  let target_bytes = number(values, "--target-bytes", 0)
  let maxrate = number(values, "--vbv-maxrate", 0)
  let bufsize = number(values, "--vbv-bufsize", 0)
  let fps = number(values, "--fps", 0)
  if input == "" || output == "" {
    fail("encode-h264: input and --output are required")
  }
  if input == output {
    fail("encode-h264: input and output must differ")
  }
  if width < 2 ||
    height < 2 ||
    width > 16384 ||
    height > 16384 ||
    width % 2 != 0 ||
    height % 2 != 0 {
    fail("encode-h264: width/height must be even, in 2..=16384")
  }
  if qp < 0 || qp > 51 {
    fail("encode-h264: qp must be in 0..=51")
  }
  if target_bytes < 0 || maxrate < 0 || bufsize < 0 || fps < 0 {
    fail("encode-h264: rate parameters must be nonnegative")
  }
  if maxrate > 0 || bufsize > 0 || fps > 0 {
    if maxrate == 0 || bufsize == 0 || fps == 0 || target_bytes > 0 {
      fail(
        "encode-h264: VBV needs maxrate/bufsize/fps and excludes target-bytes",
      )
    }
  }
  {
    input,
    output,
    width,
    height,
    qp,
    cabac: values.contains("--cabac"),
    aq: values.contains("--aq"),
    aq_strength,
    aud: values.contains("--aud"),
    target_bytes,
    maxrate,
    bufsize,
    fps,
  }
}

///|
/// Raw 8-bit planar Y, U, V in display order, with no row padding.
/// Geometry is checked by parse_options before this function is called.
fn encode_raw(data : Bytes, opts : Options) -> (Bytes, Int32) raise {
  let luma = opts.width * opts.height
  let chroma = luma / 4
  let frame_size = luma + chroma * 2
  if data.length() == 0 || data.length() % frame_size != 0 {
    fail(
      "encode-h264: input must contain complete YUV420P frames (\{frame_size} bytes each)",
    )
  }
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for offset = 0; offset < data.length(); offset = offset + frame_size {
    frames.push(
      (
        data[offset:offset + luma].to_owned(),
        data[offset + luma:offset + luma + chroma].to_owned(),
        data[offset + luma + chroma:offset + frame_size].to_owned(),
      ),
    )
  }
  let result = if opts.cabac {
    @codec.h264_encode_frames_cabac(
      frames,
      width=opts.width,
      height=opts.height,
      qp=opts.qp,
      aq=opts.aq,
      aq_strength=opts.aq_strength,
      aud=opts.aud,
      target_bytes=opts.target_bytes,
      vbv_maxrate=opts.maxrate,
      vbv_bufsize=opts.bufsize,
      fps=opts.fps,
    )
  } else {
    @codec.h264_encode_frames(
      frames,
      width=opts.width,
      height=opts.height,
      qp=opts.qp,
      aq=opts.aq,
      aq_strength=opts.aq_strength,
      aud=opts.aud,
      target_bytes=opts.target_bytes,
      vbv_maxrate=opts.maxrate,
      vbv_bufsize=opts.bufsize,
      fps=opts.fps,
    )
  }
  match result {
    Ok(stream) => (stream, frames.length())
    Err(e) => fail("encode-h264: \{e}")
  }
}
