///|
fn abbreviated_jpeg(
  color : Bool,
  custom~ : Bool = false,
  dc_step~ : Bool = false,
  wide_quant~ : Bool = false,
  omit_tables~ : Bool = false,
) -> Bytes {
  let bytes : Array[Byte] = []
  let prefix = if omit_tables {
    b"\xff\xd8"
  } else if wide_quant {
    b"\xff\xd8\xff\xdb\x00\x83\x10"
  } else {
    b"\xff\xd8\xff\xdb\x00\x43\x00"
  }
  for b in prefix {
    bytes.push(b)
  }
  for _ in 0..<(if omit_tables { 0 } else { 64 }) {
    if wide_quant {
      bytes.push(b'\x00')
    }
    bytes.push(b'\x01')
  }
  if custom && !omit_tables {
    for b in b"\xff\xc4\x00\x26" {
      bytes.push(b)
    }
    for table in [0, 16] {
      bytes.push(table.to_byte())
      bytes.push(b'\x01')
      for _ in 0..<15 {
        bytes.push(b'\x00')
      }
      bytes.push(b'\x00')
    }
  }
  let scan = if color {
    // Four zero Y blocks (DC 00 + EOB 1010), then zero Cb/Cr (00 + 00).
    b"\xff\xc0\x00\x11\x08\x00\x10\x00\x10\x03\x01\x22\x00\x02\x11\x00\x03\x11\x00" +
    b"\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00\x28\xa2\x8a\x00"
  } else {
    b"\xff\xc0\x00\x0b\x08\x00\x08\x00\x08\x01\x01\x11\x00" +
    b"\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00" +
    (if custom { b"\x3f" } else if dc_step { b"\xb1\x5f" } else { b"\x2b" })
  }
  for b in scan {
    bytes.push(b)
  }
  bytes.push(b'\xff')
  bytes.push(b'\xd9')
  Bytes::from_array(bytes)
}

///|
test "MJPEG without DHT uses standard luminance Huffman tables" {
  let image = @libavcodec.av_mjpeg_decode(abbreviated_jpeg(false)).unwrap()
  assert_eq((image.width, image.height, image.pix_fmt), (8, 8, "gray"))
  assert_eq(image.planes[0], Bytes::make(64, b'\x80'))
}

///|
test "MJPEG standard DC category reconstructs a nonzero coefficient" {
  // Luma category 4 = 101, magnitude 8 = 1000, AC EOB = 1010.
  // Quantized DC +8 raises every output sample by one at quantizer 1.
  let image = @libavcodec.av_mjpeg_decode(abbreviated_jpeg(false, dc_step=true)).unwrap()
  assert_eq(image.planes[0], Bytes::make(64, b'\x81'))
}

///|
test "MJPEG 16-bit DQT retains the same decoded coefficient scaling" {
  let image = @libavcodec.av_mjpeg_decode(
    abbreviated_jpeg(false, dc_step=true, wide_quant=true),
  ).unwrap()
  assert_eq(image.planes[0], Bytes::make(64, b'\x81'))
}

///|
test "MJPEG without DHT uses standard chrominance Huffman tables" {
  let image = @libavcodec.av_mjpeg_decode(abbreviated_jpeg(true)).unwrap()
  assert_eq((image.width, image.height, image.pix_fmt), (16, 16, "yuvj420p"))
  assert_eq(image.planes[0], Bytes::make(256, b'\x80'))
  assert_eq(image.planes[1], Bytes::make(64, b'\x80'))
  assert_eq(image.planes[2], Bytes::make(64, b'\x80'))
}

///|
test "MJPEG explicit DHT overrides the standard tables" {
  let image = @libavcodec.av_mjpeg_decode(abbreviated_jpeg(false, custom=true)).unwrap()
  assert_eq(image.planes[0], Bytes::make(64, b'\x80'))
  // A new decoder call reinstalls defaults; custom tables do not leak between calls.
  assert_eq(
    @libavcodec.av_mjpeg_decode(abbreviated_jpeg(false)).unwrap().planes[0],
    image.planes[0],
  )
}

///|
test "MJPEG session inherits quantization tables across geometry changes" {
  let decoder = @libavcodec.MjpegDecoder::new()
  decoder.decode(abbreviated_jpeg(false)).unwrap() |> ignore
  let packet = abbreviated_jpeg(true, omit_tables=true)
  let image = decoder.decode(packet).unwrap()
  assert_eq((image.width, image.height), (16, 16))
  assert_eq(image.planes[0], Bytes::make(256, b'\x80'))
  assert_eq(image.planes[1], Bytes::make(64, b'\x80'))
  assert_true(
    @libavcodec.av_mjpeg_decode(packet) is Err("mjpeg: missing quant table"),
  )
  assert_true(
    @libavcodec.MjpegDecoder::new().decode(packet)
    is Err("mjpeg: missing quant table"),
  )
}

///|
test "MJPEG session inherits custom Huffman tables from a successful frame" {
  let decoder = @libavcodec.MjpegDecoder::new()
  let first = decoder.decode(abbreviated_jpeg(false, custom=true)).unwrap()
  let next = decoder
    .decode(abbreviated_jpeg(false, custom=true, omit_tables=true))
    .unwrap()
  assert_eq(next.planes, first.planes)
}

///|
test "MJPEG failed frames do not commit replacement DQT or DHT" {
  let decoder = @libavcodec.MjpegDecoder::new()
  decoder.decode(abbreviated_jpeg(false, dc_step=true)).unwrap() |> ignore
  let bad_quant : Array[Byte] = []
  for b in b"\xff\xd8\xff\xdb\x00\x43\x00" {
    bad_quant.push(b)
  }
  for _ in 0..<64 {
    bad_quant.push(b'\x02')
  }
  bad_quant.push(b'\xff')
  bad_quant.push(b'\xd9')
  assert_true(
    decoder.decode(Bytes::from_array(bad_quant)) is Err("mjpeg: missing SOF"),
  )
  assert_eq(
    decoder
    .decode(abbreviated_jpeg(false, dc_step=true, omit_tables=true))
    .unwrap().planes[0],
    Bytes::make(64, b'\x81'),
  )
  let custom = abbreviated_jpeg(false, custom=true)
  // SOI + DQT (69 bytes) + two one-symbol DHT definitions (40 bytes).
  let bad_huffman = custom[0:111].to_owned() + b"\xff\xd9"
  assert_true(decoder.decode(bad_huffman) is Err("mjpeg: missing SOF"))
  let recovered = decoder
    .decode(abbreviated_jpeg(false, dc_step=true, omit_tables=true))
    .unwrap()
  assert_eq(recovered.planes[0], Bytes::make(64, b'\x81'))
}
