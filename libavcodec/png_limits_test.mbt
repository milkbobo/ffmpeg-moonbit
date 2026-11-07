///|
fn png_limits_header(
  width : Int32,
  height : Int32,
  depth : Int32,
  color : Int32,
  interlace~ : Int32 = 0,
) -> Bytes {
  let bytes : Array[Byte] = []
  for b in b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" {
    bytes.push(b)
  }
  for value in [width, height] {
    for shift in [24, 16, 8, 0] {
      bytes.push(((value >> shift) & 255).to_byte())
    }
  }
  for value in [depth, color, 0, 0, interlace] {
    bytes.push(value.to_byte())
  }
  // CRC checking is disabled for these malformed-header tests.
  for b in b"\x00\x00\x00\x00\x00\x00\x00\x00IEND\x00\x00\x00\x00" {
    bytes.push(b)
  }
  Bytes::from_array(bytes)
}

///|
test "PNG and APNG reject illegal color and bit-depth combinations" {
  for
    (color, depth) in [
      (2, 1),
      (2, 2),
      (2, 4),
      (3, 16),
      (4, 1),
      (4, 2),
      (4, 4),
      (6, 1),
      (6, 2),
      (6, 4),
    ] {
    let image = png_limits_header(1, 1, depth, color)
    assert_true(
      @libavcodec.av_png_decode(image)
      is Err("png: invalid bit depth for color type"),
    )
    assert_true(
      @libavcodec.av_apng_decode(image)
      is Err("apng: invalid bit depth for color type"),
    )
  }
}

///|
test "PNG and APNG reject wrapped image sizes before allocation" {
  for interlace in [0, 1] {
    for (color, depth) in [(0, 8), (2, 16), (6, 16)] {
      let image = png_limits_header(65536, 65536, depth, color, interlace~)
      assert_true(
        @libavcodec.av_png_decode(image)
        is Err("png: image buffer size overflow"),
      )
      assert_true(
        @libavcodec.av_apng_decode(image)
        is Err("apng: image buffer size overflow"),
      )
    }
  }
}

///|
test "PNG and APNG reject chunk lengths that wrap Int32 addition" {
  for length in [b"\x7f\xff\xff\xf0", b"\xff\xff\xff\xff"] {
    let image = b"\x89PNG\r\n\x1a\n" + length + b"IDAT\x00\x00\x00\x00"
    assert_true(
      @libavcodec.av_png_decode(image) is Err("png: truncated chunk IDAT"),
    )
    assert_true(
      @libavcodec.av_apng_decode(image) is Err("apng: truncated chunk IDAT"),
    )
  }
}

///|
test "APNG rejects overflowing frame rectangle coordinates" {
  for (x, y) in [(2147483647, 0), (0, 2147483647)] {
    let header = png_limits_header(1, 1, 8, 6)
    let chunk : Array[Byte] = []
    for byte in b"\x00\x00\x00\x1afcTL" {
      chunk.push(byte)
    }
    for value in [1, 1, 1, x, y] {
      for shift in [24, 16, 8, 0] {
        chunk.push(((value >> shift) & 255).to_byte())
      }
    }
    // Delay numerator/denominator, dispose, blend, and ignored chunk CRC.
    for _ in 0..<10 {
      chunk.push(b'\x00')
    }
    let image = header[0:header.length() - 12].to_owned() +
      Bytes::from_array(chunk) +
      header[header.length() - 12:].to_owned()
    assert_true(
      @libavcodec.av_apng_decode(image)
      is Err("apng: frame rectangle outside canvas"),
    )
  }
}
