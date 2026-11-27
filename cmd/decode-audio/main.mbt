///|
/// `decode-audio` - the third JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/decode-audio -- <media-file> [--output out.wav]
///                               [--format wav|dfpwm|g722|g726|g726le|aptx|aptxhd|roq|tta|alp]
///                               [--rate 8000..192000] [--g722-bits 6..8] [--g726-bits 2..5]
///
/// Decodes the first audio stream all the way to float PCM through the
/// unified playback API (every container/codec combination the audio line
/// supports), prints a JSON summary on stdout (codec, rates, decoded
/// lengths and durations). With `--output` it can also encode raw audio.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println(
      "usage: decode-audio <media-file> [--output FILE] [--format wav|dfpwm|g722|g726|g726le|aptx|aptxhd|roq|tta|alp] [--rate N]",
    )
    println("  decodes the first audio stream, prints a JSON summary,")
    println("  optionally writing 16-bit PCM WAV to --output")
    println("  --format dfpwm exports mono 48 kHz DFPWM to --output")
    println("  --format g722 exports mono 16 kHz G.722 to --output")
    println("  --format g726 or g726le exports mono 8 kHz audio to --output")
    println(
      "  --format aptx or aptxhd exports stereo audio, defaulting to 48 kHz",
    )
    println("  --format roq exports mono or stereo RoQ at 22.05 kHz")
    println(
      "  --format tta exports TTA with --tta-bits 8, 16 or 24 (default: 24)",
    )
    println("  --tta-crc verifies CRCs in native TTA input")
    println(
      "  --format alp exports ALP .tun (22.05 kHz) or .pcm (up to 44.1 kHz)",
    )
    println("  --aptx-rate N supplies the sample rate of a raw aptX input")
    println(
      "  --g722-bits 6..8 sets the width for byte-aligned raw G.722 input (default: 8)",
    )
    println(
      "  --g726-bits 2..5 sets the code width for raw G.726 input and output (default: 4)",
    )
    return
  }
  let mut path = ""
  let mut output = ""
  let mut format = "wav"
  let mut rate : Int32 = 0
  let mut g722_bits = 8
  let mut g726_bits = 4
  let mut aptx_rate = 48000
  let mut tta_bits = 24
  let mut tta_verify_crc = false
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--output" && i + 1 < args.length() {
      output = args[i + 1]
      i = i + 2
    } else if a == "--output" {
      fail("decode-audio: --output requires a value")
    } else if a == "--format" {
      if i + 1 >= args.length() {
        fail("decode-audio: --format requires a value")
      }
      format = args[i + 1]
      i = i + 2
    } else if a == "--rate" && i + 1 < args.length() {
      rate = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --rate expects a number")
      }
      i = i + 2
    } else if a == "--rate" {
      fail("decode-audio: --rate requires a value")
    } else if a == "--tta-crc" {
      tta_verify_crc = true
      i = i + 1
    } else if a == "--tta-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --tta-bits requires a value")
      }
      tta_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --tta-bits expects a number")
      }
      i = i + 2
    } else if a == "--aptx-rate" {
      if i + 1 >= args.length() {
        fail("decode-audio: --aptx-rate requires a value")
      }
      aptx_rate = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --aptx-rate expects a number")
      }
      i = i + 2
    } else if a == "--g722-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --g722-bits requires a value")
      }
      g722_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --g722-bits expects a number")
      }
      i = i + 2
    } else if a == "--g726-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --g726-bits requires a value")
      }
      g726_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --g726-bits expects a number")
      }
      i = i + 2
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      fail("decode-audio: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    fail("decode-audio: no input file")
  }
  let alp_pcm = format == "alp" && output.to_lower().has_suffix(".pcm")
  let raw_rate = match format {
    "wav" => 0
    "tta" => {
      guard output != "" else { fail("decode-audio: tta requires --output") }
      0
    }
    "dfpwm" => 48000
    "g722" => 16000
    "g726" | "g726le" => 8000
    "aptx" | "aptxhd" => if rate == 0 { 48000 } else { rate }
    "roq" => 22050
    "alp" => {
      guard output != "" else { fail("decode-audio: alp requires --output") }
      if alp_pcm {
        0
      } else {
        22050
      }
    }
    _ => fail("decode-audio: unsupported output format \{format}")
  }
  if raw_rate != 0 {
    if output == "" || (rate != 0 && rate != raw_rate) {
      fail(
        "decode-audio: \{format} requires --output and a \{raw_rate} Hz rate",
      )
    }
    rate = raw_rate
  }
  let data = @fs.read_file_to_bytes(path)
  let decoded = @avf.decode_audio_file(
    data,
    filename=path,
    g726_bits~,
    g722_bits~,
    aptx_rate~,
    tta_verify_crc~,
  ) catch {
    e => fail("decode-audio: \{path}: \{e.message()}")
  }
  let audio = if rate != 0 {
    decoded.resample_to(rate) catch {
      e => fail("decode-audio: \{e.message()}")
    }
  } else {
    decoded
  }
  if output != "" {
    let bytes = try {
      match format {
        "dfpwm" => audio.to_dfpwm()
        "g722" => audio.to_g722()
        "aptx" | "aptxhd" => audio.to_aptx(hd=format == "aptxhd")
        "roq" => audio.to_roq()
        "tta" => audio.to_tta(bits=tta_bits)
        "alp" => audio.to_alp(pcm=alp_pcm)
        "g726" | "g726le" =>
          audio.to_g726(g726_bits, little_endian=format == "g726le")
        _ => audio.to_wav_s16()
      }
    } catch {
      e => fail("decode-audio: \{format} export: \{e.message()}")
    }
    @fs.write_bytes_to_file(output, bytes)
  }
  println(audio.summary_json())
}
