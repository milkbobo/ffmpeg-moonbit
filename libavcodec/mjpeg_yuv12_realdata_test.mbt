///|
/// 12-bit baseline JPEG, 4:2:0 YCbCr: planes are MSB-aligned 16-bit LE
/// (`yuv420p16le`) and match `ffmpeg -pix_fmt yuv420p16le` byte for byte.

///|
let mjpeg_yuv12_b64 : String = "/9j/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/xAAxAAABBQEBAQEBAQAAAAAAAAAAAQIDBAUGBwgJCgsQAQAAAAAAAAAAAAAAAAAAAAD/wAARDAAQABADASIAAhEAAxEA/9oADAMBAAIAAwAAPwAegOfegAP/2Q=="

///|
let mjpeg_yuv12_ref_b64 : String = "AIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgACAAIAAgACAAIAAgACAAICAgICAgICAgICAgICAgICAAIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgACAAIAAgACAAIAAgACAAICAgICAgICAgICAgICAgICAAIAAgACAAIAAgACAAIAAgICAgICAgICAgICAgICAgIAAgACAAIAAgACAAIAAgACAgICAgICAgICAgICAgICAgECAQIBAgECAQIBAgECAQIDAgMCAwIDAgMCAwIDAgMCAQIBAgECAQIBAgECAQIBAgMCAwIDAgMCAwIDAgMCAwIBAgECAQIBAgECAQIBAgECAwIDAgMCAwIDAgMCAwIDAgECAQIBAgECAQIBAgECAQIDAgMCAwIDAgMCAwIDAgMCAQIBAgECAQIBAgECAQIBAgMCAwIDAgMCAwIDAgMCAwIBAgECAQIBAgECAQIBAgECAwIDAgMCAwIDAgMCAwIDAgECAQIBAgECAQIBAgECAQIDAgMCAwIDAgMCAwIDAgMCAQIBAgECAQIBAgECAQIBAgMCAwIDAgMCAwIDAgMCAwIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgACA"

///|
fn mjpeg_yuv12_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "mjpeg: 12-bit baseline 4:2:0 matches ffmpeg yuv420p16le" {
  let data = @libavutil.av_base64_decode(
    mjpeg_yuv12_bytes(mjpeg_yuv12_b64),
    10000,
  ).unwrap()
  let img = match @libavcodec.av_mjpeg_decode(data) {
    Ok(v) => v
    Err(e) => fail("12-bit 4:2:0 decode failed: " + e)
  }
  assert_eq(img.pix_fmt, "yuv420p16le")
  assert_eq(img.width, 16)
  assert_eq(img.height, 16)
  assert_eq(img.planes.length(), 3)
  assert_eq(img.plane_widths[0], 16)
  assert_eq(img.plane_widths[1], 8)
  assert_eq(img.plane_widths[2], 8)
  let reference = @libavutil.av_base64_decode(
    mjpeg_yuv12_bytes(mjpeg_yuv12_ref_b64),
    10000,
  ).unwrap()
  // ffmpeg raw planes are Y then Cb then Cr, each 2 bytes/sample.
  let y_end = 16 * 16 * 2
  let c_end = y_end + 8 * 8 * 2
  assert_eq(img.planes[0], reference[0:y_end].to_owned())
  assert_eq(img.planes[1], reference[y_end:c_end].to_owned())
  assert_eq(img.planes[2], reference[c_end:768].to_owned())
}
