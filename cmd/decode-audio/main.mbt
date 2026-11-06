///|
/// `decode-audio` - the third JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/decode-audio -- <media-file> [--output out.wav]
///
/// Decodes the first audio stream all the way to float PCM through the
/// unified playback API (every container/codec combination the audio line
/// supports), prints a JSON summary on stdout (codec, rates, decoded
/// lengths and durations) and - with `--output` - writes a 16-bit PCM WAV.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: decode-audio <media-file> [--output out.wav]")
    println("  decodes the first audio stream, prints a JSON summary,")
    println("  optionally writing 16-bit PCM WAV to --output")
    return
  }
  let mut path = ""
  let mut output = ""
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--output" && i + 1 < args.length() {
      output = args[i + 1]
      i = i + 2
    } else if a == "--output" {
      fail("decode-audio: --output requires a value")
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
  let data = @fs.read_file_to_bytes(path)
  let audio = @avf.decode_audio_file(data) catch {
    e => fail("decode-audio: \{path}: \{e.message()}")
  }
  if output != "" {
    let wav = audio.to_wav_s16() catch {
      e => fail("decode-audio: wav export: \{e.message()}")
    }
    @fs.write_bytes_to_file(output, wav)
  }
  println(audio.summary_json())
}
