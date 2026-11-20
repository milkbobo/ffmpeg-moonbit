///|
/// `encode-av1` options. The pure-MoonBit AV1 encoder is 8-bit 4:2:0 and
/// requires 64-multiple geometry; the options expose the frame quality
/// (flat qindex or the §457 per-frame selector) and the §458 per-SB skip
/// threshold.
priv struct Options {
  input : String
  output : String
  width : Int32
  height : Int32
  qp : Int32
  /// §457: when >= 0, select the frame qindex by lambda*SAD+bits*1000
  /// over the candidate ladder (negative = off, use --qp).
  rd_lambda : Int32
  /// §458: per-SB skip SAD percentage (0 = off).
  skip_pct : Int32
  /// Full-pel ME search radius.
  me_range : Int32
  /// §460: allow non-zero-MV skip through the uniform motion chain.
  skip_uniform : Bool
}

///|
fn parse_options(args : Array[String]) -> Options raise {
  let values : Map[String, String] = Map([])
  let mut input = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--skip-uniform" => {
        if values.contains(arg) {
          fail("encode-av1: repeated option \{arg}")
        }
        values[arg] = "true"
        i += 1
      }
      "--output"
      | "--width"
      | "--height"
      | "--qp"
      | "--rd-lambda"
      | "--skip-pct"
      | "--me-range" => {
        if values.contains(arg) {
          fail("encode-av1: repeated option \{arg}")
        }
        if i + 1 >= args.length() {
          fail("encode-av1: \{arg} requires a value")
        }
        values[arg] = args[i + 1]
        i += 2
      }
      _ => {
        if arg.has_prefix("--") {
          fail("encode-av1: unknown option \{arg}")
        }
        if input != "" {
          fail("encode-av1: unexpected argument \{arg}")
        }
        input = arg
        i += 1
      }
    }
  }
  fn number(key : String, fallback : Int32) -> Int32 raise {
    match values.get(key) {
      None => fallback
      Some(s) =>
        @string.parse_int(s) catch {
          _ => fail("encode-av1: \{key} expects an integer")
        }
    }
  }
  let output = values.get("--output").unwrap_or("")
  let width = number("--width", 0)
  let height = number("--height", 0)
  let qp = number("--qp", 100)
  let rd_lambda = number("--rd-lambda", -1)
  let skip_pct = number("--skip-pct", 0)
  let me_range = number("--me-range", 8)
  if input == "" || output == "" {
    fail("encode-av1: input and --output are required")
  }
  if input == output {
    fail("encode-av1: input and output must differ")
  }
  if width < 64 || height < 64 || width % 64 != 0 || height % 64 != 0 {
    fail("encode-av1: width/height must be positive 64-multiples")
  }
  if qp < 1 || qp > 255 {
    fail("encode-av1: --qp must be 1..=255")
  }
  if skip_pct < 0 || skip_pct > 100 {
    fail("encode-av1: --skip-pct must be 0..=100")
  }
  if me_range < 0 || me_range > 1024 {
    fail("encode-av1: --me-range must be 0..=1024")
  }
  {
    input,
    output,
    width,
    height,
    qp,
    rd_lambda,
    skip_pct,
    me_range,
    skip_uniform: values.contains("--skip-uniform"),
  }
}

///|
/// One packed 8-bit 4:2:0 frame: Y (w*h) + U (w/2*h/2) + V (w/2*h/2).
fn raw_frame_size(opts : Options) -> Int32 {
  let luma = opts.width * opts.height
  luma + luma / 2
}

///|
/// Unpack one plane of `len` u8 samples at `offset`.
fn plane(data : Bytes, offset : Int32, len : Int32) -> FixedArray[Int32] {
  let p : FixedArray[Int32] = FixedArray::make(len, 0)
  for i in 0..<len {
    p[i] = data[offset + i].to_int()
  }
  p
}
