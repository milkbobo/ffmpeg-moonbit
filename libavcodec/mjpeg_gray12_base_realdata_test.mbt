///|
/// 12-bit baseline JPEG (SOF0, single component, DCT 12-bit IDCT): the
/// decoded samples are MSB-aligned to gray16le and match
/// `ffmpeg -pix_fmt gray16le` byte for byte.

///|
let mjpeg_gray12_base_b64 : String = "/9j/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/xAAxAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAQAAAAAAAAAAAAAAAAAAAAD/wAALDAAIABABAREA/9oACAEBAAA/AB6A/9k="

///|
let mjpeg_gray12_base_ref_b64 : String = "AIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgACAAIAAgACAAIAAgACAAICAgICAgICAgICAgICAgICAAIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgACAAIAAgACAAIAAgACAAICAgICAgICAgICAgICAgICAAIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgA=="

///|
fn mjpeg_gray12_base_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "mjpeg: 12-bit baseline grayscale matches ffmpeg gray16le" {
  let data = @libavutil.av_base64_decode(
    mjpeg_gray12_base_bytes(mjpeg_gray12_base_b64),
    10000,
  ).unwrap()
  let img = match @libavcodec.av_mjpeg_decode(data) {
    Ok(v) => v
    Err(e) => fail("12-bit baseline decode failed: " + e)
  }
  assert_eq(img.pix_fmt, "gray16le")
  assert_eq(img.width, 16)
  assert_eq(img.height, 8)
  let reference = @libavutil.av_base64_decode(
    mjpeg_gray12_base_bytes(mjpeg_gray12_base_ref_b64),
    10000,
  ).unwrap()
  assert_eq(img.planes[0].length(), reference.length())
  assert_eq(img.planes[0], reference)
}
