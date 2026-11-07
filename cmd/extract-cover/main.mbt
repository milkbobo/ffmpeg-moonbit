///|
/// `extract-cover` - the fifth JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/extract-cover -- <media-file> [--output cover.jpg]
///
/// Extracts the container-level cover art (`MediaFile::cover`: MKV
/// Attachments image/* or MP4 ilst/covr), writes the raw image bytes to
/// `--output` (default extension chosen from the MIME type) and prints a
/// JSON summary. Files without artwork fail with a non-zero exit.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println("usage: extract-cover <media-file> [--output cover.jpg]")
    println("  extracts the embedded cover art (MKV attachment / MP4 covr)")
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
      fail("extract-cover: --output requires a value")
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      fail("extract-cover: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    fail("extract-cover: no input file")
  }
  let data = @fs.read_file_to_bytes(path)
  let mf = @avf.MediaFile::open(data) catch {
    e => fail("extract-cover: \{path}: \{e.message()}")
  }
  let cover = match mf.cover() {
    Some(c) => c
    None => fail("extract-cover: \{path}: no embedded cover art")
  }
  if output == "" {
    output = if cover.mime() == "image/png" { "cover.png" } else { "cover.jpg" }
  }
  @fs.write_bytes_to_file(output, cover.data())
  println(
    "{\n  \"mime\": \"\{cover.mime()}\",\n  \"bytes\": \{cover.data().length()},\n  \"output\": \"\{output}\"\n}",
  )
}
