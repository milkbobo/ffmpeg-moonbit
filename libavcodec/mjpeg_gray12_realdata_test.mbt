///|
/// 12-bit lossless JPEG (SOF3, single component): decoded samples use the
/// 2^(P-1) initial prediction and are finalized MSB-aligned to gray16le,
/// byte-identical to `ffmpeg -pix_fmt gray16le`.

///|
let mjpeg_gray12_b64 : String = "/9j/xAAgAAAAAA0AAAAAAAAAAAAAAAAAAQIDBAUGBwgJCgsM/8MACwwACAAQAQERAP/aAAgBAQABAAAGlaVpWlaVpWlaVpWlaVpWlaVpX3tk2TZNk2TZNk2TZNk2TZNk2TZPvb9v2/b9v2/b9v2/b9v2/b9v2/fe8x5jzHmPMeY8x5jzHmPMeY8x5jzH3vZey9l7L2XsvZey9l7L2XsvZey9l975nzPmfM+Z8z5nzPmfM+Z8z5nzPmfe/N+b835vzfm/N+b835vzfm/N+b833xARARARARARARARARARARARARARARAf/9k="

///|
let mjpeg_gray12_ref_b64 : String = "AIBQgqCE8IZAiZCL4I0wkICS0JQgl3CZwJsQnmCgsKLwhhCKMI1QkHCTkJawmdCc8J8QozCmUKlwrJCvsLLQteCN0JHAlbCZoJ2QoYClcKlgrVCxQLUwuSC9EMEAxfDI0JSQmVCeEKPQp5CsULEQttC6kL9QxBDJ0M2Q0lDXENzAm1Ch4KZwrACykLcgvbDCQMjQzWDT8NiA3hDkoOkw77CiEKlwr9C1MLyQwvDIUM+w1RDccOLQ6DDvkPXw+1ACoKnQsAC4ML9gxpDNwNTw2yDjUOqA8bD44P8QB0AOcBWQsJC4kMCQyJDQkNiQ4JDokPCQ+JAAkAiQEJAYkCCQKA=="

///|
fn mjpeg_gray12_bytes(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i in 0..<s.length() {
    out.push((s[i].to_int() & 0xff).to_byte())
  }
  Bytes::from_array(out)
}

///|
test "mjpeg: 12-bit lossless grayscale matches ffmpeg gray16le" {
  let data = @libavutil.av_base64_decode(
    mjpeg_gray12_bytes(mjpeg_gray12_b64),
    10000,
  ).unwrap()
  let img = match @libavcodec.av_mjpeg_decode(data) {
    Ok(v) => v
    Err(e) => fail("12-bit decode failed: " + e)
  }
  assert_eq(img.pix_fmt, "gray16le")
  assert_eq(img.width, 16)
  assert_eq(img.height, 8)
  assert_eq(img.planes.length(), 1)
  let reference = @libavutil.av_base64_decode(
    mjpeg_gray12_bytes(mjpeg_gray12_ref_b64),
    10000,
  ).unwrap()
  assert_eq(img.planes[0].length(), reference.length())
  assert_eq(img.planes[0], reference)
}
