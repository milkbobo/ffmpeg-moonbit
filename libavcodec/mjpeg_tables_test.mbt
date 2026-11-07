///|
fn jpeg_table_segment(marker : Byte, body : Bytes) -> Bytes {
  let size = body.length() + 2
  let bytes : Array[Byte] = [
    b'\xff',
    b'\xd8',
    b'\xff',
    marker,
    ((size >> 8) & 255).to_byte(),
    (size & 255).to_byte(),
  ]
  for b in body {
    bytes.push(b)
  }
  bytes.push(b'\xff')
  bytes.push(b'\xd9')
  Bytes::from_array(bytes)
}

///|
test "MJPEG rejects illegal DQT precision before reading table entries" {
  for precision in 2..<16 {
    let body = Bytes::from_array([(precision << 4).to_byte()])
    assert_true(
      @libavcodec.av_mjpeg_decode(jpeg_table_segment(b'\xdb', body))
      is Err("mjpeg: invalid quant table precision"),
    )
  }
}

///|
test "MJPEG detects truncated 8 and 16 bit quantization tables" {
  for precision in [0, 1] {
    let table : Array[Byte] = [(precision << 4).to_byte()]
    for _ in 0..<(64 * (precision + 1) - 1) {
      table.push(b'\x01')
    }
    assert_true(
      @libavcodec.av_mjpeg_decode(
        jpeg_table_segment(b'\xdb', Bytes::from_array(table)),
      )
      is Err("mjpeg: truncated DQT"),
    )
  }
}

///|
test "MJPEG rejects oversubscribed Huffman trees at short and long lengths" {
  for
    counts in [
      [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3],
      [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255],
    ] {
    // The final example is not oversubscribed: it has too many symbols.
    let body : Array[Byte] = [b'\x00']
    for count in counts {
      body.push(count.to_byte())
    }
    let result = @libavcodec.av_mjpeg_decode(
      jpeg_table_segment(b'\xc4', Bytes::from_array(body)),
    )
    if counts[0] > 0 {
      assert_true(result is Err("mjpeg: oversubscribed Huffman table"))
    } else {
      assert_true(result is Err("mjpeg: too many Huffman symbols"))
    }
  }
}

///|
test "MJPEG DHT truncated symbol values are rejected after valid code counts" {
  let body = b"\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_true(
    @libavcodec.av_mjpeg_decode(jpeg_table_segment(b'\xc4', body))
    is Err("mjpeg: truncated DHT values"),
  )
}
