///|
priv struct ShortenTestWriter {
  bytes : Array[Byte]
  mut position : Int32
}

///|
fn ShortenTestWriter::put(
  self : ShortenTestWriter,
  width : Int32,
  value : Int32,
) -> Unit {
  for i = width - 1; i >= 0; i = i - 1 {
    let octet = self.position / 8
    if self.position % 8 == 0 {
      self.bytes.push(b'\x00')
    }
    let bit = ((value >> i) & 1) << (7 - self.position % 8)
    self.bytes[octet] = (self.bytes[octet].to_int() | bit).to_byte()
    self.position += 1
  }
}

///|
fn ShortenTestWriter::rice(
  self : ShortenTestWriter,
  width : Int32,
  value : Int32,
) -> Unit {
  for _ in 0..<(value >> width) {
    self.put(1, 0)
  }
  self.put(1, 1)
  self.put(width, value)
}

///|
fn ShortenTestWriter::signed(
  self : ShortenTestWriter,
  width : Int32,
  value : Int32,
) -> Unit {
  self.rice(width + 1, if value < 0 { -2 * value - 1 } else { 2 * value })
}

///|
fn ShortenTestWriter::start(
  version : Int32,
  kind : Int32,
  channels : Int32,
  means : Int32,
  header : Bytes,
) -> ShortenTestWriter {
  let writer : ShortenTestWriter = { bytes: [], position: 0, }
  writer.put(32, 0x616a6b67)
  writer.put(8, version)
  if version == 0 {
    writer.rice(4, kind)
    writer.rice(0, channels)
  } else {
    for value in [kind, channels, 3, 3, means, 1] {
      writer.rice(2, 5)
      writer.rice(5, value)
    }
    writer.put(8, 0x5A)
  }
  writer.rice(2, 9)
  writer.rice(5, header.length())
  for byte in header {
    writer.rice(8, byte.to_int())
  }
  writer
}

///|
let shorten_test_wav16 : Bytes = b"RIFF\x30\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x02\x00\x44\xac\x00\x00\x10\xb1\x02\x00\x04\x00\x10\x00data\x0c\x00\x00\x00"

///|
let shorten_test_wav8 : Bytes = b"RIFF\x27\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x44\xac\x00\x00\x44\xac\x00\x00\x01\x00\x08\x00data\x03\x00\x00\x00"

///|
test "shorten: stereo fixed/LPC predictors, means and block shrink" {
  let writer = ShortenTestWriter::start(2, 5, 2, 2, shorten_test_wav16)
  writer.rice(2, 6)
  writer.rice(2, 1)
  writer.rice(2, 0)
  writer.rice(3, 2)
  for sample in [2, 3, 4] {
    writer.signed(2, sample)
  }
  writer.rice(2, 1)
  writer.rice(3, 2)
  for sample in [1, -1, 2] {
    writer.signed(2, sample)
  }
  writer.rice(2, 6)
  writer.rice(2, 0)
  writer.rice(2, 7)
  writer.rice(3, 2)
  writer.rice(2, 1)
  writer.signed(5, 32)
  for _ in 0..<3 {
    writer.signed(2, 0)
  }
  writer.rice(2, 2)
  writer.rice(3, 2)
  for sample in [-1, 0, 1] {
    writer.signed(2, sample)
  }
  writer.rice(2, 5)
  writer.rice(2, 1)
  writer.rice(1, 1)
  writer.rice(2, 8)
  writer.rice(2, 8)
  writer.rice(2, 4)
  let coded = Bytes::from_array(writer.bytes)
  let pcm = @libavcodec.ff_shorten_decode(coded).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.channels, 2)
  assert_eq(pcm.bits, 16)
  assert_eq(pcm.samples, [4, 2, 6, 0, 8, 4, 5, 3, 6, 4, 7, 6, 0, 0])
  assert_true(@libavcodec.ff_shorten_decode(coded, sample_budget=12L) is Err(_))
}

///|
test "shorten: U8 and incomplete stream recovery" {
  let writer = ShortenTestWriter::start(2, 2, 1, 0, shorten_test_wav8)
  writer.rice(2, 0)
  writer.rice(3, 7)
  for sample in [-128, 0, 127] {
    writer.signed(7, sample)
  }
  let truncated = Bytes::from_array(writer.bytes)
  assert_true(@libavcodec.ff_shorten_decode(truncated) is Err(_))
  let pcm = @libavcodec.ff_shorten_decode(truncated, allow_truncated=true).unwrap()
  assert_eq(pcm.bits, 8)
  assert_eq(pcm.pcm_bytes(), b"\x00\x80\xff")
  writer.rice(2, 4)
  assert_eq(
    @libavcodec.ff_shorten_decode(Bytes::from_array(writer.bytes)).unwrap().samples,
    [0, 128, 255],
  )
}

///|
test "shorten: version 0 with embedded AIFF" {
  let aiff = b"FORM\x00\x00\x00\x30AIFFCOMM\x00\x00\x00\x12\x00\x01\x00\x00\x00\x02\x00\x10\x40\x0e\xac\x44\x00\x00\x00\x00\x00\x00SSND\x00\x00\x00\x0c\x00\x00\x00\x00\x00\x00\x00\x00"
  let writer = ShortenTestWriter::start(0, 3, 1, 0, aiff)
  writer.rice(2, 5)
  writer.rice(8, 2)
  writer.rice(2, 0)
  writer.rice(3, 9)
  writer.signed(8, -512)
  writer.signed(8, 511)
  writer.rice(2, 4)
  let pcm = @libavcodec.ff_shorten_decode(Bytes::from_array(writer.bytes)).unwrap()
  assert_eq(pcm.sample_rate, 44100)
  assert_eq(pcm.pcm_bytes(), b"\x00\xfe\xff\x01")
  assert_true(@libavcodec.ff_shorten_decode(b"ajkg\x00") is Err(_))
}
