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
  /// §464: which past reconstruction to predict from (0 = previous frame,
  /// k = k frames back). Negative means "unset" (use 0).
  ref_age : Int32
  /// §465: when non-empty, jointly choose q × skip × reference age by
  /// trial encoding. Comma-separated ages, e.g. "0,1,2".
  rd_ref_ages : Array[Int32]
  /// §462/§465: comma-separated skip thresholds for the joint search,
  /// e.g. "50,100". Empty means the caller's --skip-pct only.
  rd_skip_pcts : Array[Int32]
  /// §498: per-SB 64x64-vs-32x32 partition SAD margin (0 = off). Positive
  /// values require zero loop-filter levels.
  split_margin : Int32
  /// §499: NEARMV stack hits through the drl bools.
  drl : Bool
}

///|
fn parse_options(args : Array[String]) -> Options raise {
  let values : Map[String, String] = Map([])
  let mut input = ""
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    match arg {
      "--skip-uniform" | "--drl" => {
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
      | "--me-range"
      | "--ref-age"
      | "--rd-ref-ages"
      | "--rd-skip-pcts"
      | "--split-margin" => {
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
  let ref_age = number("--ref-age", 0)
  if ref_age < 0 {
    fail("encode-av1: --ref-age must be nonnegative")
  }
  // Comma-separated integer list, used by the joint RD search.
  let int_list = fn(key : String) -> Array[Int32] raise {
    let out : Array[Int32] = []
    match values.get(key) {
      None => ()
      Some(s) =>
        for part in s.split(",") {
          let t = part.trim().to_owned()
          if t != "" {
            let v = @string.parse_int(t) catch {
              _ => fail("encode-av1: \{key} expects comma-separated integers")
            }
            out.push(v)
          }
        }
    }
    out
  }
  let rd_ref_ages = int_list("--rd-ref-ages")
  let rd_skip_pcts = int_list("--rd-skip-pcts")
  for a in rd_ref_ages {
    if a < 0 || a > 7 {
      fail("encode-av1: --rd-ref-ages entries must be 0..=7")
    }
  }
  for p in rd_skip_pcts {
    if p < 0 || p > 100 {
      fail("encode-av1: --rd-skip-pcts entries must be 0..=100")
    }
  }
  let split_margin = number("--split-margin", 0)
  if split_margin < 0 {
    fail("encode-av1: --split-margin must be nonnegative")
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
    ref_age,
    rd_ref_ages,
    rd_skip_pcts,
    split_margin,
    drl: values.contains("--drl"),
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
