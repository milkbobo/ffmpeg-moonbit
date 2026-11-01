///|
/// 9-bit baseline JPEG (SOF0, single component, 10-bit IDCT): samples are
/// MSB-aligned to gray16le and match `ffmpeg -pix_fmt gray16le`.

///|
let mjpeg_gray9_b64 : String = "/9j/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/xAAxAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAQAAAAAAAAAAAAAAAAAAAAD/wAALCQAQABABAREA/9oACAEBAAA/AB6A596A/9k="

///|
let mjpeg_gray9_ref_b64 : String = "AIAAgACAAIAAgACAAIAAgACEAIQAhACEAIQAhACEAIQAgACAAIAAgACAAIAAgACAAIQAhACEAIQAhACEAIQAhACAAIAAgACAAIAAgACAAIAAhACEAIQAhACEAIQAhACEAIAAgACAAIAAgACAAIAAgACEAIQAhACEAIQAhACEAIQAgACAAIAAgACAAIAAgACAAIQAhACEAIQAhACEAIQAhACAAIAAgACAAIAAgACAAIAAhACEAIQAhACEAIQAhACEAIAAgACAAIAAgACAAIAAgACEAIQAhACEAIQAhACEAIQAgACAAIAAgACAAIAAgACAAIQAhACEAIQAhACEAIQAhACCAIIAggCCAIIAggCCAIIAhgCGAIYAhgCGAIYAhgCGAIIAggCCAIIAggCCAIIAggCGAIYAhgCGAIYAhgCGAIYAggCCAIIAggCCAIIAggCCAIYAhgCGAIYAhgCGAIYAhgCCAIIAggCCAIIAggCCAIIAhgCGAIYAhgCGAIYAhgCGAIIAggCCAIIAggCCAIIAggCGAIYAhgCGAIYAhgCGAIYAggCCAIIAggCCAIIAggCCAIYAhgCGAIYAhgCGAIYAhgCCAIIAggCCAIIAggCCAIIAhgCGAIYAhgCGAIYAhgCGAIIAggCCAIIAggCCAIIAggCGAIYAhgCGAIYAhgCGAIY="

///|
fn mjpeg_gray9_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "mjpeg: 9-bit baseline grayscale matches ffmpeg gray16le" {
  let data = @libavutil.av_base64_decode(
    mjpeg_gray9_bytes(mjpeg_gray9_b64),
    10000,
  ).unwrap()
  let img = match @libavcodec.av_mjpeg_decode(data) {
    Ok(v) => v
    Err(e) => fail("9-bit baseline decode failed: " + e)
  }
  assert_eq(img.pix_fmt, "gray16le")
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  let reference = @libavutil.av_base64_decode(
    mjpeg_gray9_bytes(mjpeg_gray9_ref_b64),
    10000,
  ).unwrap()
  assert_eq(img.planes[0].length(), reference.length())
  assert_eq(img.planes[0], reference)
}
