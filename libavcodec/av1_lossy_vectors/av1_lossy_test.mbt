///|
/// 8-bit 4:2:0 lossy key frames: libaom `-crf 30 -deadline good -cpu-used 8
/// -g 1 -enable-cdef 0 -enable-restoration 0`, testsrc2 128x96, 8 frames.
/// Exercises the lossy reconstruction path (tx size/txtp, DCT/ADST kernels,
/// dequant) plus the in-loop deblocking filter.
///
/// Expected MD5s are libdav1d's framemd5 over packed `yuv420p` planes
/// (docker `linuxserver/ffmpeg:9.0.2`, `-c:v libdav1d -f framemd5`).
let av1_lossy8_stream_b64 : Bytes = b"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"

///|
let av1_lossy8_md5 : Array[String] = [
  "0d7f8479de7420cefc09907fb7f52889",
  "d6d46870a4158cb2e6cf2f4c3db28901",
  "5356343c6d6c0a325e8923b294d027b1",
  "75717412306cba671dc844130a62ecf0",
  "7caa2db96f5af29a854c7253ac432033",
  "2e0d96c6ee56f982f9e5c84d59e3c905",
  "b346b68bef70913f39cf9812ae3608d3",
  "36104da0adbf958eda0322289210e5bb",]

///|
/// IVF: 32-byte header, then per frame a 12-byte header and the OBU payload.
fn av1_lossy8_ivf_frames(ivf : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos + 12 <= ivf.length() {
    let size = (ivf[pos].to_int() | (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16)) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }
  frames
}

///|
fn av1_lossy8_hex(digest : FixedArray[Byte]) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i in 0..<16 {
    let v = digest[i].to_uint().reinterpret_as_int()
    chars.push(digits[v >> 4].to_char())
    chars.push(digits[v & 15].to_char())
  }
  String::from_array(chars[:])
}

///|
fn av1_lossy8_frame_md5(packed : Bytes) -> String {
  let digest : FixedArray[Byte] = FixedArray::make(16, b' ')
  @libavutil.av_md5_sum(digest, packed, packed.length())
  av1_lossy8_hex(digest)
}

///|
test "av1 lossy: 8-bit 4:2:0 keyframes match libdav1d framemd5" {
  let ivf = @libavutil.av_base64_decode(av1_lossy8_stream_b64, 1048576).unwrap()
  let frames = av1_lossy8_ivf_frames(ivf)
  assert_eq(frames.length(), av1_lossy8_md5.length())
  let mut seq : @libavcodec.Av1SequenceParameters? = None
  let md5s : Array[String] = []
  for obus in frames {
    if seq is None {
      match @libavcodec.av1_parse_sequence_header(obus) {
        Ok(s) => seq = Some(s)
        Err(e) => fail(e)
      }
    }
    let s = match seq {
      Some(s) => s
      None => fail("no sequence header")
    }
    let hdr = match @libavcodec.av1_parse_frame_header(obus, s) {
      Ok(h) => h
      Err(e) => fail(e)
    }
    let tiles = match @libavcodec.av1_extract_tiles(obus, hdr) {
      Ok(t) => t
      Err(e) => fail(e)
    }
    let out = match @libavcodec.av1_decode_keyframe(s, hdr, tiles[0].data()) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    md5s.push(av1_lossy8_frame_md5(out.packed()))
  }
  for i in 0..<md5s.length() {
    if md5s[i] != av1_lossy8_md5[i] {
      fail(
        "lossy8 frame " +
        i.to_string() +
        ": got " +
        md5s[i] +
        " want " +
        av1_lossy8_md5[i],
      )
    }
  }
}
