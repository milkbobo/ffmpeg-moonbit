///|
/// `encode-hevc` option parsing (the `§459` CLI): a focused subset of
/// `encode-h264`'s vocabulary — geometry, quality (flat QP or CRF), chroma
/// format, bit depth, the B-slice schedule and the all-intra switch.
priv struct Options {
  input : String
  output : String
  width : Int32
  height : Int32
  qp : Int32
  /// `§458`: constant rate factor `--crf` (0..=51, decimals allowed;
  /// negative = unset — `qp` stays the quality selector).
  crf : Double
  /// `--all-intra`: every frame an IDR (the §448 schedule).
  all_intra : Bool
  b_slices : Bool
  bit_depth : Int32
  /// 1 (4:2:0, default), 2 (4:2:2), or 3 (4:4:4).
  chroma_format : Int32
}

///|
/// args excludes the executable name. Reject unknown/repeated switches and
/// invalid geometry before creating an output file.
fn parse_options(args : Array[String]) -> Options raise {
  let values : Map[String, String] = Map([])
  let mut input = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--b-slices" | "--all-intra" => {
        if values.contains(arg) {
          fail("encode-hevc: repeated option \{arg}")
        }
        values[arg] = "true"
        i += 1
      }
      "--output"
      | "--width"
      | "--height"
      | "--qp"
      | "--bit-depth"
      | "--chroma"
      | "--crf" => {
        if values.contains(arg) {
          fail("encode-hevc: repeated option \{arg}")
        }
        if i + 1 >= args.length() {
          fail("encode-hevc: \{arg} requires a value")
        }
        values[arg] = args[i + 1]
        i += 2
      }
      _ => {
        if arg.has_prefix("--") {
          fail("encode-hevc: unknown option \{arg}")
        }
        if input != "" {
          fail("encode-hevc: unexpected argument \{arg}")
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
          _ => fail("encode-hevc: \{key} expects an integer")
        }
    }
  }
  let output = values.get("--output").unwrap_or("")
  let width = number(values, "--width", 0)
  let height = number(values, "--height", 0)
  let qp = number(values, "--qp", 26)
  let bit_depth = number(values, "--bit-depth", 8)
  if bit_depth != 8 && bit_depth != 10 && bit_depth != 12 {
    fail("encode-hevc: bit-depth must be 8, 10 or 12")
  }
  let chroma_format = match values.get("--chroma") {
    None => 1
    Some("420") => 1
    Some("422") => 2
    Some("444") => 3
    Some(other) =>
      fail("encode-hevc: --chroma must be 420, 422 or 444 (got \{other})")
  }
  // NaN-safe range test (keeps "inf"/"nan" out with the invalid values).
  let crf = match values.get("--crf") {
    None => -1.0
    Some(s) => {
      let v = @string.parse_double(s) catch {
        _ => fail("encode-hevc: --crf expects a number")
      }
      if !(v >= 0.0 && v <= 51.0) {
        fail("encode-hevc: --crf must be in 0..=51")
      }
      v
    }
  }
  if input == "" || output == "" {
    fail("encode-hevc: input and --output are required")
  }
  if input == output {
    fail("encode-hevc: input and output must differ")
  }
  if width < 2 ||
    height < 2 ||
    width > 16384 ||
    height > 16384 ||
    width % 2 != 0 ||
    height % 2 != 0 {
    fail("encode-hevc: width/height must be even, in 2..=16384")
  }
  if qp < 0 || qp > 51 {
    fail("encode-hevc: qp must be in 0..=51")
  }
  {
    input,
    output,
    width,
    height,
    qp,
    crf,
    all_intra: values.contains("--all-intra"),
    b_slices: values.contains("--b-slices"),
    bit_depth,
    chroma_format,
  }
}

///|
/// Bytes per plane sample at the configured depth: 1 for 8-bit packed u8,
/// 2 for the 10/12-bit little-endian 16-bit layout.
fn sample_bytes(bit_depth : Int32) -> Int32 {
  if bit_depth > 8 {
    2
  } else {
    1
  }
}

///|
/// One packed frame's byte size (Y, Cb, Cr planes, no row padding; the
/// chroma planes double their rows at 4:2:2 and their columns at 4:4:4).
fn raw_frame_size(opts : Options) -> Int32 {
  let luma = opts.width * opts.height
  // Both chroma planes combined: half the luma budget at 4:2:0, the full
  // luma budget at 4:2:2 and twice it at 4:4:4.
  let chroma = if opts.chroma_format == 3 {
    luma * 2
  } else if opts.chroma_format == 2 {
    luma
  } else {
    luma / 2
  }
  (luma + chroma) * sample_bytes(opts.bit_depth)
}
