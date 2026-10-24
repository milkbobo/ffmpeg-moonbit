///|
/// VP9 profile-1/3 real streams, generated with docker
/// `linuxserver/ffmpeg:9.0.2`.  Expected values are the reference decoder's
/// per-frame MD5s.
///
/// - `vp9_444_8`: profile-1 8-bit 4:4:4 keyframe + P frames (3808 bytes, yuv444p)
/// - `vp9_422_8`: profile-1 8-bit 4:2:2 keyframe + P frames (3085 bytes, yuv422p)
/// - `vp9_444_10`: profile-3 10-bit 4:4:4 keyframe + P frames (3749 bytes, yuv444p10le)
/// - `vp9_444_12`: profile-3 12-bit 4:4:4 keyframe + P frames (3805 bytes, yuv444p12le)
///
/// Reproduce each stream from its `testsrc2` pipeline in the stream list
/// above, then run `ffmpeg -threads 1 -i <stem>.ivf -f framemd5 <stem>.md5`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; the vectors are libre test data.

///|
/// base64 of the concatenated IVF files (14447 bytes total). */
let vp9_444_vectors_b64 : Bytes = b"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"

///|
/// IVF byte lengths of `vp9_444_vectors_b64`, in stream order. */
let vp9_444_sizes : Array[Int] = [3808, 3085, 3749, 3805]

///|
fn vp9_444_vectors() -> Bytes {
  @libavutil.av_base64_decode(vp9_444_vectors_b64, 1000000).unwrap()
}

///|
/// Split the concatenated blob into the IVF streams.
fn vp9_444_streams() -> Array[Bytes] {
  let all = vp9_444_vectors()
  let out : Array[Bytes] = []
  let mut off = 0
  for n in vp9_444_sizes {
    out.push(all[off:off + n].to_owned())
    off = off + n
  }
  out
}

///|
/// Split an IVF file into per-frame VP9 payloads (12-byte frame headers).
fn vp9_444_ivf_frames(ivf : Bytes) -> Array[Bytes] {
  let frames : Array[Bytes] = []
  let mut pos = 32
  while pos < ivf.length() {
    let size = (ivf[pos].to_int() | (ivf[pos + 1].to_int() << 8) |
      (ivf[pos + 2].to_int() << 16)) |
      (ivf[pos + 3].to_int() << 24)
    frames.push(ivf[pos + 12:pos + 12 + size].to_owned())
    pos = pos + 12 + size
  }
  frames
}

///|
fn vp9_444_hex(bytes : FixedArray[Byte], n : Int32) -> String {
  let digits : Bytes = b"0123456789abcdef"
  let chars : Array[Char] = []
  for i = 0; i < n; i = i + 1 {
    let v = bytes[i].to_uint().reinterpret_as_int()
    chars.push(digits[(v >> 4) & 0xF].to_char())
    chars.push(digits[v & 0xF].to_char())
  }
  String::from_array(chars[:])
}

///|
fn vp9_444_frame_md5(dec : @libavcodec.Vp9Decoder) -> String {
  let yuv = dec.frame_bytes()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  vp9_444_hex(digest, 16)
}

///|
fn vp9_444_decode(index : Int) -> (Array[Bytes], @libavcodec.Vp9Decoder) {
  let streams = vp9_444_streams()
  (vp9_444_ivf_frames(streams[index]), @libavcodec.vp9_decoder_new())
}

///|
let vp9_444_8_md5 : Array[String] = [
  "def9dab2697e3a1c0eac64f2d1b3ea1d", "def9dab2697e3a1c0eac64f2d1b3ea1d", "def9dab2697e3a1c0eac64f2d1b3ea1d",
  "06b6778ca5912124bb8c57bd150df594", "d4a88de1c5cb0a49e0d83189e70fc8b5", "d4a88de1c5cb0a49e0d83189e70fc8b5",
]

///|
let vp9_422_8_md5 : Array[String] = [
  "1753c97769c2fc537311df9be4f8b917", "1753c97769c2fc537311df9be4f8b917", "1753c97769c2fc537311df9be4f8b917",
  "f360f4eab5db68d06d2c95526f12470f", "e32195626b5b923d72ae86ddf484db3e", "e32195626b5b923d72ae86ddf484db3e",
]

///|
let vp9_444_10_md5 : Array[String] = [
  "cd09c0cc63dc3348faa7fb440f2817a6", "cd09c0cc63dc3348faa7fb440f2817a6", "cd09c0cc63dc3348faa7fb440f2817a6",
  "69d6c32c8d9a54da07310f3554881c38", "3b105bbce3b5a9db20ee9598c61be8de", "3b105bbce3b5a9db20ee9598c61be8de",
]

///|
let vp9_444_12_md5 : Array[String] = [
  "a9c78c185f1f9127f7805e2266ef42b2", "a9c78c185f1f9127f7805e2266ef42b2", "a9c78c185f1f9127f7805e2266ef42b2",
  "e73a1b7653292c36598fa1f5c4ae8cc7", "7c1df28e065b9789f4898029a4928fb3", "7c1df28e065b9789f4898029a4928fb3",
]

///|
test "vp9 444 8-bit: profile-1 keyframes and P frames match FFmpeg YUV" {
  let (frames, dec) = vp9_444_decode(0)
  assert_eq(frames.length(), vp9_444_8_md5.length())
  for i in 0..<frames.length() {
    let out = match dec.decode_packet(frames[i]) {
      Ok(fs) => fs
      Err(e) => fail("frame \{i}: \{e}")
    }
    assert_eq(out.length(), 1)
    inspect(vp9_444_frame_md5(dec), content=vp9_444_8_md5[i])
  }
}

///|
test "vp9 422 8-bit: profile-1 keyframes and P frames match FFmpeg YUV" {
  let (frames, dec) = vp9_444_decode(1)
  assert_eq(frames.length(), vp9_422_8_md5.length())
  for i in 0..<frames.length() {
    let out = match dec.decode_packet(frames[i]) {
      Ok(fs) => fs
      Err(e) => fail("frame \{i}: \{e}")
    }
    assert_eq(out.length(), 1)
    inspect(vp9_444_frame_md5(dec), content=vp9_422_8_md5[i])
  }
}

///|
test "vp9 444 10-bit: profile-3 keyframes and P frames match FFmpeg YUV" {
  let (frames, dec) = vp9_444_decode(2)
  assert_eq(frames.length(), vp9_444_10_md5.length())
  for i in 0..<frames.length() {
    let out = match dec.decode_packet(frames[i]) {
      Ok(fs) => fs
      Err(e) => fail("frame \{i}: \{e}")
    }
    assert_eq(out.length(), 1)
    inspect(vp9_444_frame_md5(dec), content=vp9_444_10_md5[i])
  }
}

///|
test "vp9 444 12-bit: profile-3 keyframes and P frames match FFmpeg YUV" {
  let (frames, dec) = vp9_444_decode(3)
  assert_eq(frames.length(), vp9_444_12_md5.length())
  for i in 0..<frames.length() {
    let out = match dec.decode_packet(frames[i]) {
      Ok(fs) => fs
      Err(e) => fail("frame \{i}: \{e}")
    }
    assert_eq(out.length(), 1)
    inspect(vp9_444_frame_md5(dec), content=vp9_444_12_md5[i])
  }
}
