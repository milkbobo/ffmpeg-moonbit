///|
test "PNG encoding round-trips packed 8- and 16-bit pixel formats with valid CRCs" {
  for
    (format, channels) in [
      ("gray", 1),
      ("gray16be", 2),
      ("ya8", 2),
      ("ya16be", 4),
      ("rgb24", 3),
      ("rgb48be", 6),
      ("rgba", 4),
      ("rgba64be", 8),
    ] {
    let pixels = Bytes::from_array(
      Array::makei(19 * 11 * channels, i => ((i * 73 + i / 5) & 255).to_byte()),
    )
    let png = @libavcodec.av_png_encode(19, 11, pixels, format~).unwrap()
    let decoded = @libavcodec.av_png_decode_ex(png, true).unwrap()
    assert_eq(decoded.pix_fmt, format)
    assert_eq(decoded.pixels, pixels)
  }
}

///|
test "PNG handles incompressible scanlines and compresses repetitive scanlines" {
  let mut random = 1U
  let pixels = Bytes::from_array(
    Array::makei(511 * 149, _ => {
      random = random * 1664525U + 1013904223U
      (random >> 24).to_byte()
    }),
  )
  let encoded = @libavcodec.av_png_encode(511, 149, pixels, format="gray").unwrap()
  assert_eq(@libavcodec.av_png_decode_ex(encoded, true).unwrap().pixels, pixels)
  let uniform = Bytes::from_array(Array::make(511 * 149, b'\x2a'))
  let compressed = @libavcodec.av_png_encode(511, 149, uniform, format="gray").unwrap()
  assert_true(compressed.length() < uniform.length() / 10)
}

///|
test "APNG preserves RGBA, delays and loop count" {
  let a = b"\xff\x00\x00\xff\xff\x00\x00\x00"
  let b = b"\x00\x00\xff\x80\x00\x00\x00\xff"
  let encoded = @libavcodec.av_apng_encode(
    2,
    1,
    [
      { pixels: a, delay_num: 1, delay_den: 12, },
      { pixels: b, delay_num: 3, delay_den: 20, },
    ],
    loop_count=2,
  ).unwrap()
  assert_eq(@libavcodec.av_png_decode_ex(encoded, true).unwrap().pixels, a)
  let movie = @libavcodec.av_apng_decode(encoded).unwrap()
  assert_eq(movie.loop_count, 2)
  assert_eq(movie.frames.length(), 2)
  assert_eq(movie.frames[0].rgba, a)
  assert_eq(movie.frames[1].rgba, b)
  assert_eq(movie.frames[0].delay_den, 12)
  assert_eq(movie.frames[1].delay_num, 3)
  assert_eq(movie.frames[1].delay_den, 20)
}

///|
test "baseline JPEG encodes odd-sized grayscale and planar 4:2:0" {
  let gray = Bytes::from_array(
    Array::makei(19 * 11, i => ((i * 11 + i / 19) & 255).to_byte()),
  )
  let jpeg = @libavcodec.av_mjpeg_encode(
    19,
    11,
    gray,
    format="gray",
    quality=100,
  ).unwrap()
  let picture = @libavcodec.av_mjpeg_decode(jpeg).unwrap()
  assert_eq(picture.width, 19)
  assert_eq(picture.height, 11)
  assert_eq(picture.pix_fmt, "gray")
  for i in 0..<gray.length() {
    assert_true((gray[i].to_int() - picture.planes[0][i].to_int()).abs() <= 3)
  }
  let packed = gray + Bytes::from_array(Array::make(2 * 10 * 6, b'\x80'))
  let encoded = @libavcodec.av_mjpeg_encode(19, 11, packed, format="yuvj420p").unwrap()
  let decoded = @libavcodec.av_mjpeg_decode(encoded).unwrap()
  assert_eq(decoded.pix_fmt, "yuvj420p")
  assert_eq(decoded.width, 19)
  assert_eq(decoded.height, 11)
}

///|
test "image encoders reject malformed dimensions and input layouts" {
  assert_true(@libavcodec.av_png_encode(0, 1, b"") is Err(_))
  assert_true(@libavcodec.av_png_encode(1, 1, b"\x00", format="pal8") is Err(_))
  assert_true(@libavcodec.av_apng_encode(1, 1, []) is Err(_))
  assert_true(@libavcodec.av_mjpeg_encode(1, 1, b"\x00", quality=0) is Err(_))
  assert_true(
    @libavcodec.av_mjpeg_encode(1, 1, b"\x00", format="rgb24") is Err(_),
  )
}
