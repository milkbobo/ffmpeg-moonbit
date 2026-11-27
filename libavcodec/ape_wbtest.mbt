///|
/// White-box tests for the APE decoder: constructor validation, silence
/// frames, and the compression-level paths the FATE suite has no sample for
/// (level 1000 `filter_fast_3320`).  Real-stream coverage lives in
/// `ape_realdata_*_wbtest.mbt` (nine FATE samples, bit-exact MD5).

///|
/// Extradata builder (fileversion, compression, flags), little-endian.
fn ape_test_extradata(version : Int32, comp : Int32, flags : Int32) -> Bytes {
  Bytes::from_array([
    (version & 0xFF).to_byte(),
    (version >> 8).to_byte(),
    (comp & 0xFF).to_byte(),
    (comp >> 8).to_byte(),
    (flags & 0xFF).to_byte(),
    (flags >> 8).to_byte(),
  ])
}

///|
/// Reverse every aligned 4-byte word, mirroring the decoder's `bswap_buf`
/// input transformation, so tests can author the byte stream the decoder
/// actually reads.
fn ape_test_word_swap(data : Array[Byte]) -> Bytes {
  let out : Array[Byte] = Array::make(data.length(), b'\x00')
  let mut w = 0
  while w + 4 <= data.length() {
    out[w] = data[w + 3]
    out[w + 1] = data[w + 2]
    out[w + 2] = data[w + 1]
    out[w + 3] = data[w]
    w = w + 4
  }
  Bytes::from_array(out)
}

///|
/// Push a big-endian u32.
fn ape_test_be32(out : Array[Byte], v : UInt32) -> Unit {
  out.push((v >> 24).to_byte())
  out.push((v >> 16).to_byte())
  out.push((v >> 8).to_byte())
  out.push(v.to_byte())
}

///|
/// Flatten a constructor result for inspection.
fn ape_test_new(
  version : Int32,
  comp : Int32,
  ch : Int32,
  bps : Int32,
) -> String {
  match ape_decoder_new(ape_test_extradata(version, comp, 0), ch, bps) {
    Err(e) => "err: " + e
    Ok(_) => "ok"
  }
}

///|
test "APE: constructor validation" {
  inspect(
    ape_test_new(3990, 2000, 3, 16),
    content="err: ape: only mono and stereo is supported",
  )
  inspect(
    ape_test_new(3990, 2000, 2, 12),
    content="err: ape: unsupported bits per coded sample 12",
  )
  inspect(
    ape_test_new(3990, 2500, 2, 16),
    content="err: ape: incorrect compression level 2500",
  )
  inspect(
    ape_test_new(3990, 6000, 2, 16),
    content="err: ape: incorrect compression level 6000",
  )
  // INSANE needs fileversion >= 3930
  inspect(
    ape_test_new(3910, 5000, 2, 16),
    content="err: ape: incorrect compression level 5000",
  )
  inspect(ape_test_new(3990, 5000, 2, 16), content="ok")
  // extradata must be exactly 6 bytes
  match ape_decoder_new(b"\x00", 2, 16) {
    Err(_) => inspect("err", content="err")
    Ok(_) => fail("expected short extradata to be rejected")
  }
}

///|
/// A v3.99 stereo silence frame: header words, CRC carrying the
/// STEREO_SILENCE frame code, then an all-zero range coder payload.  Every
/// unpack is skipped, so the output is nblocks zero samples per channel.
test "APE: stereo silence frame decodes to zeros" {
  let dec = ape_decoder_new(ape_test_extradata(3990, 2000, 0), 2, 16).unwrap()
  let stream : Array[Byte] = []
  ape_test_be32(stream, 16) // nblocks
  ape_test_be32(stream, 0) // offset
  ape_test_be32(stream, 0x80000000U | 3) // CRC with frame flags
  ape_test_be32(stream, ape_framecode_stereo_silence) // frameflags
  // Four range-coder bytes: skipped header byte + start byte + slack (the
  // v3990 frame body is word-aligned; there is no < 3950 pad).
  stream.push(0)
  stream.push(0)
  stream.push(0)
  stream.push(0)
  let packet = ape_test_word_swap(stream)
  let chunk = dec.decode_frame(packet).unwrap()
  inspect(chunk.packet_done, content="true")
  inspect(chunk.frame.nb_samples, content="16")
  inspect(chunk.frame.samples.length(), content="32")
  let mut nonzero = 0
  for v in chunk.frame.samples {
    if v != 0 {
      nonzero = nonzero + 1
    }
  }
  inspect(nonzero, content="0")
}

///|
/// Pseudo-stereo mono frame (APE_FRAMECODE_PSEUDO_STEREO): one channel of
/// entropy data is decoded and copied to both outputs.  With an all-zero
/// range coder payload the residuals are zero, so both channels are zero.
test "APE: pseudo-stereo mono frame copies channel" {
  let dec = ape_decoder_new(ape_test_extradata(3990, 2000, 0), 2, 16).unwrap()
  let stream : Array[Byte] = []
  ape_test_be32(stream, 8) // nblocks
  ape_test_be32(stream, 0) // offset
  ape_test_be32(stream, 0x80000000U | 4) // CRC with frame flags
  ape_test_be32(stream, ape_framecode_pseudo_stereo) // frameflags
  // Skipped byte + range coder start + a generous all-zero payload: with
  // low pinned at 0 the range coder decodes symbol 0 / base 0 forever
  // (x = 0), pulling ~10 bytes of normalization per sample.
  stream.push(0)
  for _ in [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0] {
    stream.push(0)
  }
  let packet = ape_test_word_swap(stream)
  let chunk = dec.decode_frame(packet).unwrap()
  inspect(chunk.frame.nb_samples, content="8")
  inspect(chunk.frame.samples.length(), content="16")
  let mut nonzero = 0
  for v in chunk.frame.samples {
    if v != 0 {
      nonzero = nonzero + 1
    }
  }
  inspect(nonzero, content="0")
}

///|
/// Offset guard and sample-count guard fire with the C's messages.
test "APE: invalid frame headers are rejected" {
  let dec = ape_decoder_new(ape_test_extradata(3990, 2000, 0), 2, 16).unwrap()
  let stream : Array[Byte] = []
  ape_test_be32(stream, 16)
  ape_test_be32(stream, 4) // offset > 3
  ape_test_be32(stream, 0)
  stream.push(0)
  stream.push(0)
  let packet = ape_test_word_swap(stream)
  match dec.decode_frame(packet) {
    Err(e) => inspect(e, content="ape: incorrect offset passed")
    Ok(_) => fail("expected offset guard to fire")
  }
  let stream2 : Array[Byte] = []
  ape_test_be32(stream2, 0) // nblocks == 0
  ape_test_be32(stream2, 0)
  ape_test_be32(stream2, 0)
  stream2.push(0)
  stream2.push(0)
  let packet2 = ape_test_word_swap(stream2)
  match dec.decode_frame(packet2) {
    Err(e) => inspect(e, content="ape: invalid sample count 0")
    Ok(_) => fail("expected sample-count guard to fire")
  }
  match dec.decode_frame(b"\x01") {
    Err(e) => inspect(e, content="ape: packet is too small")
    Ok(_) => fail("expected tiny packet to be rejected")
  }
}

///|
/// Level 1000 (`filter_fast_3320`) with a v3.80 stream: the FATE suite has
/// no `-c1000` sample, so drive the untested branch with a hand-built
/// all-zero residual frame over the bit-level (non-range-coder) entropy
/// path.  Rice codes with a leading stop bit decode x = 0, keeping outputs
/// zero through the fast predictor.
test "APE: level-1000 fast filter accepts a zero frame" {
  let dec = ape_decoder_new(ape_test_extradata(3800, 1000, 0), 2, 16).unwrap()
  let stream : Array[Byte] = []
  ape_test_be32(stream, 4) // nblocks (<= 5: only the k=10 first pass runs)
  ape_test_be32(stream, 0) // offset
  ape_test_be32(stream, 0) // CRC (no flag bit: no frameflags word)
  // rice-ook k=10: each value is one stop bit + ten 0 bits = 11 bits, giving
  // x = 0.  Both channels decode sequentially from one continuous bit stream
  // (entropy_decode_*_0000), so the eight codes (4 per channel) run back to
  // back over 88 bits.  The packet must stay word-aligned: the decoder
  // truncates to a multiple of four bytes and zeroes the remainder.
  for b in [0x80, 0x10, 0x02, 0x00, 0x40, 0x08, 0x01, 0x00, 0x20, 0x04] {
    stream.push(b.to_byte())
  }
  stream.push(0) // word-alignment pad (consumed as zero suffix bits)
  stream.push(0)
  let packet = ape_test_word_swap(stream)
  let chunk = dec.decode_frame(packet).unwrap()
  inspect(chunk.frame.nb_samples, content="4")
  let mut nonzero = 0
  for v in chunk.frame.samples {
    if v != 0 {
      nonzero = nonzero + 1
    }
  }
  inspect(nonzero, content="0")
}
