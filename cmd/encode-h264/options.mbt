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
  /// `§435`: constant rate factor `--crf` (0..=51, decimals allowed;
  /// negative = unset — `qp` stays the quality selector).
  crf : Double
  /// `§436`: scene-cut threshold `--scenecut` (0..=100, 0 = off).
  scenecut : Int32
  /// `§437`: open-GOP cuts (`--open-gop`; requires `--scenecut`).
  open_gop : Bool
  stream : Bool
  b_slices : Bool
  b_parts : Bool
  intra_in_b : Bool
  intra4x4_in_b : Bool
  /// `§410`: explicit P weighted prediction (opt-in).
  weightp : Bool
  /// `§434`: explicit B weighted prediction (opt-in).
  weightp_b : Bool
  /// Sample bit depth (8 / 9 / 10 / 12 / 14). Above 8 the input uses
  /// planar little-endian 16-bit samples; profile follows depth and chroma.
  bit_depth : Int32
  /// `§414`: selected codec (the facade's `VideoCodec`; only `h264`
  /// exists today, so the flag's value space is "h264").
  codec : @codec.VideoCodec
  /// `§415`: P-slice multi-reference history depth (1 = single reference;
  /// `§418` extends 2..=16 to the B schedule).
  multi_ref : Int32
  /// Chroma format, 420 (default), 422, or 444.
  chroma_format : Int32
  /// `§432`: Cb/Cr chroma QP offset -12..12 (`--chroma-qp-offset`).
  chroma_qp_offset : Int32
  keyint : Int32
  /// `§423`: in-loop deblocking (batch and streaming).
  deblock : Bool
  /// `§433`: slice deblocking alpha/beta offsets -6..=6 in div2 units
  /// (`--deblock-alpha` / `--deblock-beta`, x264 `--deblock alpha:beta`).
  deblock_alpha : Int32
  deblock_beta : Int32
  /// `§426`: sample aspect ratio `--sar NUM:DEN` (0/0 = unset).
  sar : (Int32, Int32)
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
      | "--weightp-b"
      | "--deblock"
      | "--no-deblock"
      | "--no-cabac"
      | "--no-cabac-rd"
      | "--no-dct8x8"
      | "--no-b-slices"
      | "--no-b-parts"
      | "--no-intra-in-b"
      | "--no-intra4x4-in-b"
      | "--no-weightp"
      | "--no-weightp-b"
      | "--open-gop" => {
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
      | "--chroma-qp-offset"
      | "--deblock-alpha"
      | "--deblock-beta"
      | "--keyint"
      | "--sar"
      | "--aq-strength"
      | "--target-bytes"
      | "--vbv-maxrate"
      | "--vbv-bufsize"
      | "--fps"
      | "--crf"
      | "--scenecut" => {
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
    Some("444") => 3
    Some(other) =>
      fail("encode-h264: --chroma must be 420, 422 or 444 (got \{other})")
  }
  let keyint = number(values, "--keyint", 0)
  if keyint < 0 {
    fail("encode-h264: keyint must be nonnegative")
  }
  let chroma_qp_offset = number(values, "--chroma-qp-offset", 0)
  if chroma_qp_offset < -12 || chroma_qp_offset > 12 {
    fail("encode-h264: --chroma-qp-offset must be in -12..=12")
  }
  let deblock_alpha = number(values, "--deblock-alpha", 0)
  if deblock_alpha < -6 || deblock_alpha > 6 {
    fail("encode-h264: --deblock-alpha must be in -6..=6")
  }
  let deblock_beta = number(values, "--deblock-beta", 0)
  if deblock_beta < -6 || deblock_beta > 6 {
    fail("encode-h264: --deblock-beta must be in -6..=6")
  }
  let sar = match values.get("--sar") {
    None => (0, 0)
    Some(spec) => {
      // Split NUM:DEN by hand: core's split returns an iterator without
      // indexing, and the two-component shape is all we accept anyway.
      let mut cut = -1
      for i, c in spec {
        if c == ':' && cut < 0 {
          cut = i
        }
      }
      if cut < 0 {
        fail("encode-h264: --sar must be NUM:DEN (got \{spec})")
      }
      let num_s = spec[:cut].to_owned()
      let den_s = spec[cut + 1:].to_owned()
      if num_s.is_empty() || den_s.is_empty() {
        fail("encode-h264: --sar must be NUM:DEN (got \{spec})")
      }
      let num = @string.parse_int(num_s) catch {
        _ => fail("encode-h264: --sar must be NUM:DEN (got \{spec})")
      }
      let den = @string.parse_int(den_s) catch {
        _ => fail("encode-h264: --sar must be NUM:DEN (got \{spec})")
      }
      if num <= 0 || den <= 0 {
        fail("encode-h264: --sar components must be positive (got \{spec})")
      }
      (num, den)
    }
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
  // `§435`: CRF replaces the bitrate target as the quality selector (the
  // NaN-safe range test keeps "inf"/"nan" out with the invalid values).
  let crf = match values.get("--crf") {
    None => -1.0
    Some(s) => {
      let v = @string.parse_double(s) catch {
        _ => fail("encode-h264: --crf expects a number")
      }
      if !(v >= 0.0 && v <= 51.0) {
        fail("encode-h264: --crf must be in 0..=51")
      }
      v
    }
  }
  if crf >= 0.0 && target_bytes > 0 {
    fail("encode-h264: --crf and --target-bytes are mutually exclusive")
  }
  // `§436`: 0 disables; 100 cuts on any inter activity.
  let scenecut = number(values, "--scenecut", 0)
  if scenecut < 0 || scenecut > 100 {
    fail("encode-h264: --scenecut must be in 0..=100")
  }
  // `§437`: open-GOP cuts ride the detector.
  let open_gop = values.contains("--open-gop")
  if open_gop && scenecut <= 0 {
    fail("encode-h264: --open-gop requires --scenecut")
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
    crf,
    scenecut,
    open_gop,
    stream: values.contains("--stream"),
    b_slices: !no_b,
    b_parts: !no_b && !values.contains("--no-b-parts"),
    intra_in_b: !no_b && !values.contains("--no-intra-in-b"),
    intra4x4_in_b: !no_b && !values.contains("--no-intra4x4-in-b"),
    // Since §413 weighted P prediction defaults on; the positive spelling
    // stays accepted as a no-op and `--no-weightp` opts out.
    weightp: !values.contains("--no-weightp"),
    // `§434`: opt-in B weights; disabled when B slices are off.
    weightp_b: !no_b && values.contains("--weightp-b"),
    bit_depth,
    codec,
    multi_ref,
    chroma_format,
    chroma_qp_offset,
    keyint,
    // Default on since §424; the positive spelling stays accepted as a no-op.
    deblock: !values.contains("--no-deblock"),
    deblock_alpha,
    deblock_beta,
    sar,
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
  // Both chroma planes combined: half the luma budget at 4:2:0, the full
  // luma budget at 4:2:2 and twice it at 4:4:4 (§421).
  let chroma = if opts.chroma_format == 3 {
    luma * 2
  } else if opts.chroma_format == 2 {
    luma
  } else {
    luma / 2
  }
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
    weightp_b: opts.weightp_b,
    bit_depth: opts.bit_depth,
    multi_ref: opts.multi_ref,
    chroma_format: opts.chroma_format,
    chroma_qp_offset: opts.chroma_qp_offset,
    keyint: opts.keyint,
    aud: opts.aud,
    aq: opts.aq,
    aq_strength: opts.aq_strength,
    target_bytes: opts.target_bytes,
    crf: opts.crf,
    scenecut: opts.scenecut,
    open_gop: opts.open_gop,
    vbv_maxrate: opts.maxrate,
    vbv_bufsize: opts.bufsize,
    fps: opts.fps,
    deblock: opts.deblock,
    deblock_alpha: opts.deblock_alpha,
    deblock_beta: opts.deblock_beta,
    sar: opts.sar,
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
  let chroma = if opts.chroma_format == 3 {
    luma
  } else if opts.chroma_format == 2 {
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
  let chroma = if opts.chroma_format == 3 {
    luma
  } else if opts.chroma_format == 2 {
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
