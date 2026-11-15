///|
priv struct Options {
  input : String
  output : String
  width : Int32
  height : Int32
  qp : Int32
  cabac : Bool
  cabac_rd : Bool
  dct8x8 : Bool
  aq : Bool
  aq_strength : Int32
  aud : Bool
  target_bytes : Int32
  maxrate : Int32
  bufsize : Int32
  fps : Int32
  stream : Bool
  b_slices : Bool
  b_parts : Bool
  intra_in_b : Bool
  intra4x4_in_b : Bool
  /// `§410`: explicit P weighted prediction (opt-in).
  weightp : Bool
  /// `§412`: sample bit depth (8 / 9 / 10). Above 8 the input is planar
  /// little-endian 16-bit samples (`yuv420p10le` layout) and the parameter
  /// sets switch to High 10 (profile_idc 110).
  bit_depth : Int32
  /// `§414`: selected codec (the facade's `VideoCodec`; only `h264`
  /// exists today, so the flag's value space is "h264").
  codec : @codec.VideoCodec
  /// `§415`: P-slice multi-reference history depth (1 = single reference;
  /// `§418` extends 2..=16 to the B schedule).
  multi_ref : Int32
  /// `§420`: chroma format, 420 (default) or 422.
  chroma_format : Int32
  keyint : Int32
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
      "--cabac"
      | "--cabac-rd"
      | "--dct8x8"
      | "--aq"
      | "--aud"
      | "--stream"
      | "--b-slices"
      | "--b-parts"
      | "--intra-in-b"
      | "--intra4x4-in-b"
      | "--weightp"
      | "--no-cabac"
      | "--no-cabac-rd"
      | "--no-dct8x8"
      | "--no-b-slices"
      | "--no-b-parts"
      | "--no-intra-in-b"
      | "--no-intra4x4-in-b"
      | "--no-weightp" => {
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
      | "--bit-depth"
      | "--codec"
      | "--multi-ref"
      | "--chroma"
      | "--keyint"
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
  let bit_depth = number(values, "--bit-depth", 8)
  if bit_depth != 8 &&
    bit_depth != 9 &&
    bit_depth != 10 &&
    bit_depth != 12 &&
    bit_depth != 14 {
    fail("encode-h264: bit-depth must be 8, 9, 10, 12 or 14")
  }
  let codec = match values.get("--codec") {
    None => @codec.VideoCodec::default()
    Some("h264") => @codec.VideoCodec::H264
    Some(other) => fail("encode-h264: unsupported codec \{other} (h264)")
  }
  let multi_ref = number(values, "--multi-ref", 1)
  let chroma_format = match values.get("--chroma") {
    None => 1
    Some("420") => 1
    Some("422") => 2
    Some(other) =>
      fail("encode-h264: --chroma must be 420 or 422 (got \{other})")
  }
  let keyint = number(values, "--keyint", 0)
  if keyint < 0 {
    fail("encode-h264: keyint must be nonnegative")
  }
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
  if values.contains("--cabac-rd") &&
    !values.contains("--cabac") &&
    !values.contains("--no-cabac") {
    fail("encode-h264: cabac-rd requires CABAC")
  }
  if values.contains("--stream") && target_bytes > 0 {
    fail("encode-h264: streaming ABR is not supported")
  }
  // b-slices × rate controls is supported since §398 (B×VBV/ABR); no
  // exclusion here anymore.
  // Since §403 the B-line and transform flags default on; the positive
  // spellings stay accepted as no-ops and each `--no-*` spelling opts out.
  // The sub-flags only reject an explicit `--no-b-slices`.
  let no_b = values.contains("--no-b-slices")
  if values.contains("--b-parts") && no_b {
    fail("encode-h264: b-parts requires b-slices")
  }
  if values.contains("--intra-in-b") && no_b {
    fail("encode-h264: intra-in-b requires b-slices")
  }
  if values.contains("--intra4x4-in-b") && no_b {
    fail("encode-h264: intra4x4-in-b requires b-slices")
  }
  let cabac = values.contains("--cabac") && !values.contains("--no-cabac")
  {
    input,
    output,
    width,
    height,
    qp,
    cabac,
    cabac_rd: cabac && !values.contains("--no-cabac-rd"),
    dct8x8: !values.contains("--no-dct8x8"),
    aq: values.contains("--aq"),
    aq_strength,
    aud: values.contains("--aud"),
    target_bytes,
    maxrate,
    bufsize,
    fps,
    stream: values.contains("--stream"),
    b_slices: !no_b,
    b_parts: !no_b && !values.contains("--no-b-parts"),
    intra_in_b: !no_b && !values.contains("--no-intra-in-b"),
    intra4x4_in_b: !no_b && !values.contains("--no-intra4x4-in-b"),
    // Since §413 weighted P prediction defaults on; the positive spelling
    // stays accepted as a no-op and `--no-weightp` opts out.
    weightp: !values.contains("--no-weightp"),
    bit_depth,
    codec,
    multi_ref,
    chroma_format,
    keyint,
  }
}

///|
/// Split one packed YUV420P frame into its three display-order planes.
fn frame_planes(
  data : Bytes,
  offset : Int32,
  luma : Int32,
  chroma : Int32,
) -> (Bytes, Bytes, Bytes) {
  (
    data[offset:offset + luma].to_owned(),
    data[offset + luma:offset + luma + chroma].to_owned(),
    data[offset + luma + chroma:offset + luma + chroma * 2].to_owned(),
  )
}

///|
/// Bytes per plane sample at the configured depth: 1 for 8-bit packed u8,
/// 2 for the 9/10-bit little-endian 16-bit layout.
fn sample_bytes(bit_depth : Int32) -> Int32 {
  if bit_depth > 8 {
    2
  } else {
    1
  }
}

///|
/// One packed frame's byte size (Y, Cb, Cr planes, no row padding; the
/// chroma planes double their rows at 4:2:2).
fn raw_frame_size(opts : Options) -> Int32 {
  let luma = opts.width * opts.height
  let chroma = if opts.chroma_format == 2 { luma } else { luma / 2 }
  (luma + chroma) * sample_bytes(opts.bit_depth)
}

///|
/// The parsed options' encoder configuration (`§414` facade): geometry,
/// quality, entropy and feature flags in one value shared by the batch
/// and streaming paths.
fn video_config(opts : Options) -> @codec.VideoEncConfig {
  {
    ..@codec.VideoEncConfig::new(width=opts.width, height=opts.height),
    qp: opts.qp,
    cabac: opts.cabac,
    cabac_rd: opts.cabac_rd,
    dct8x8: opts.dct8x8,
    b_slices: opts.b_slices,
    b_parts: opts.b_parts,
    intra_in_b: opts.intra_in_b,
    intra4x4_in_b: opts.intra4x4_in_b,
    weightp: opts.weightp,
    bit_depth: opts.bit_depth,
    multi_ref: opts.multi_ref,
    chroma_format: opts.chroma_format,
    keyint: opts.keyint,
    aud: opts.aud,
    aq: opts.aq,
    aq_strength: opts.aq_strength,
    target_bytes: opts.target_bytes,
    vbv_maxrate: opts.maxrate,
    vbv_bufsize: opts.bufsize,
    fps: opts.fps,
  }
}

///|
/// Open the streaming encoder shared by the in-memory and chunked host
/// paths, so both feed exactly the same configuration.
fn open_stream_encoder(opts : Options) -> @codec.VideoEncoder raise {
  match @codec.VideoEncoder::open(codec=opts.codec, config=video_config(opts)) {
    Ok(enc) => enc
    Err(e) => fail("encode-h264: \{e}")
  }
}

///|
/// Raw planar Y, U, V in display order, with no row padding: 8-bit packed
/// u8 samples, or little-endian 16-bit samples above 8 bits. Geometry is
/// checked by parse_options before this function is called.
fn encode_raw(data : Bytes, opts : Options) -> (Bytes, Int32) raise {
  let bpp = sample_bytes(opts.bit_depth)
  let luma = opts.width * opts.height * bpp
  let chroma = if opts.chroma_format == 2 {
    opts.width / 2 * opts.height * bpp
  } else {
    opts.width * opts.height / 4 * bpp
  }
  let frame_size = raw_frame_size(opts)
  if data.length() == 0 || data.length() % frame_size != 0 {
    fail(
      "encode-h264: input must contain complete \{@codec.video_pixel_format(opts.bit_depth, chroma_format~=opts.chroma_format)} frames (\{frame_size} bytes each)",
    )
  }
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for offset = 0; offset < data.length(); offset = offset + frame_size {
    frames.push(frame_planes(data, offset, luma, chroma))
  }
  match
    @codec.video_encode(frames, codec=opts.codec, config=video_config(opts)) {
    Ok(stream) => (stream, frames.length())
    Err(e) => fail("encode-h264: \{e}")
  }
}

///|
/// `--stream` host path: read one frame at a time and append every finished
/// access unit immediately. The frame/AU sequence is exactly the one
/// `encode_raw` produces, so native builds are byte-identical while never
/// holding the whole input or output; wasm/js fall back to whole-file host
/// buffers (see host_io_wasm.mbt). The input size is checked before the
/// output is opened, so a partial trailing frame cannot truncate an
/// existing output file.
fn encode_stream_file(opts : Options) -> (Int32, Int32) raise {
  let bpp = sample_bytes(opts.bit_depth)
  let luma = opts.width * opts.height * bpp
  let chroma = if opts.chroma_format == 2 {
    opts.width / 2 * opts.height * bpp
  } else {
    opts.width * opts.height / 4 * bpp
  }
  let frame_size = raw_frame_size(opts)
  let reader = FrameReader::open(@utf8.encode(opts.input))
  let input_size = reader.size()
  if input_size == 0 || input_size % frame_size.to_int64() != 0 {
    reader.close()
    fail(
      "encode-h264: input must contain complete \{@codec.video_pixel_format(opts.bit_depth, chroma_format~=opts.chroma_format)} frames (\{frame_size} bytes each)",
    )
  }
  let enc = open_stream_encoder(opts)
  let writer = FrameWriter::open(@utf8.encode(opts.output))
  let mut count = 0
  let mut written = 0
  let mut running = true
  while running {
    match reader.read(frame_size) {
      None => running = false
      Some(frame) => {
        let (y, u, v) = frame_planes(frame, 0, luma, chroma)
        match enc.push_frame(y, u, v) {
          Ok(_) => ()
          Err(e) => {
            reader.close()
            fail("encode-h264: \{e}")
          }
        }
        for au in enc.drain() {
          writer.write(au)
          written = written + au.length()
        }
        count = count + 1
      }
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        writer.write(au)
        written = written + au.length()
      }
    Err(e) => {
      reader.close()
      fail("encode-h264: \{e}")
    }
  }
  reader.close()
  writer.close()
  (count, written)
}
