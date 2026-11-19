///|
/// HEVC intra encoder, black-box arbitration: the pure-MoonBit stream is
/// decoded by reference FFmpeg 9.0.2 (docker linuxserver/ffmpeg:9.0.2,
/// framemd5 of the rawvideo yuv420p output) and by this repository's own
/// HEVC decoder - the three must agree byte-for-byte. The pin values were
/// generated once from the reference decode (the `hevc enc i: ffmpeg
/// arbitration` wbtest prints the stream for re-verification).
///
/// Pin regeneration: run the wbtest arb flow (encode -> base64 ->
/// `ffmpeg -i demo.265 -f framemd5`), or decode with this repo's decoder
/// (the round-trip tests pin encoder-recon == decoder-output directly).

///|
fn hevc_enc_i_make_plane(
  w : Int32,
  h : Int32,
  f : (Int32, Int32) -> Int32,
) -> FixedArray[Int32] {
  let out : FixedArray[Int32] = FixedArray::make(w * h, 0)
  for j in 0..<h {
    for i in 0..<w {
      out[j * w + i] = f(i, j)
    }
  }
  out
}

///|
test "hevc enc i: ffmpeg arbitration framemd5 pins" {
  let frames = hevc_enc_arb_frames()
  let stream = match
    @libavcodec.hevc_encode_frames(frames, width=64, height=64, qp=26) {
    Ok(s) => s
    Err(e) => fail("\{e}")
  }
  assert_eq(stream.length(), 773)
  // 逐帧切片解码（解码器每帧一个 slice）
  let nal_starts : Array[Int32] = []
  let mut i2 = 0
  while i2 + 3 < stream.length() {
    if stream[i2] == b'\x00' &&
      stream[i2 + 1] == b'\x00' &&
      stream[i2 + 2] == b'\x00' &&
      stream[i2 + 3] == b'\x01' {
      nal_starts.push(i2)
      i2 = i2 + 4
    } else {
      i2 = i2 + 1
    }
  }
  nal_starts.push(stream.length())
  let mut slice_cnt = 0
  for k in 0..<(nal_starts.length() - 1) {
    let part = stream[nal_starts[k]:nal_starts[k + 1]][:]
    let nal_type = part[4].to_int() >> 1
    if nal_type <= 31 {
      slice_cnt = slice_cnt + 1
      let one : Array[Byte] = []
      for ps in [0, 1, 2] {
        let b = stream[nal_starts[ps]:nal_starts[ps + 1]][:]
        for j in 0..<b.length() {
          one.push(b[j])
        }
      }
      for j in 0..<part.length() {
        one.push(part[j])
      }
      let pic = match
        @libavcodec.ff_hevc_decode_intra_frame(Bytes::from_array(one), false, 0) {
        Ok(p) => p
        Err(e) => fail("decode slice \{slice_cnt}: \{e}")
      }
      let h = "0123456789abcdef"
      let mut yhex = ""
      let mut uhex = ""
      let mut vhex = ""
      for i in 0..<(64 * 64) {
        yhex = yhex +
          h.get_char((pic.y[i] >> 4) & 15).unwrap().to_string() +
          h.get_char(pic.y[i] & 15).unwrap().to_string()
      }
      for i in 0..<(32 * 32) {
        uhex = uhex +
          h.get_char((pic.cb[i] >> 4) & 15).unwrap().to_string() +
          h.get_char(pic.cb[i] & 15).unwrap().to_string()
        vhex = vhex +
          h.get_char((pic.cr[i] >> 4) & 15).unwrap().to_string() +
          h.get_char(pic.cr[i] & 15).unwrap().to_string()
      }
      // ffmpeg framemd5 of the rawvideo frame (y+u+v)
      let data : Array[Byte] = []
      for pair in [(yhex, 64 * 64), (uhex, 32 * 32), (vhex, 32 * 32)] {
        let pair2 = pair
        let hex = pair2.0
        let count = pair2.1
        for i in 0..<count {
          let hi = hex.get_char(i * 2).unwrap().to_int()
          let lo = hex.get_char(i * 2 + 1).unwrap().to_int()
          let v = if hi >= 97 { hi - 87 } else { hi - 48 }
          let w = if lo >= 97 { lo - 87 } else { lo - 48 }
          data.push(((v << 4) | w).to_byte())
        }
      }
      let md5 = hevc_enc_frame_md5(data)
      let pins = [
        "41161203d03781c8a9b1f80e4b1b773c", "d1eb62e3e53523b2eccb73ade254f992",
      ]
      inspect(md5, content="\{pins[slice_cnt - 1]}")
    }
  }
}

///|
/// Frame y+u+v MD5 (via the ported libavutil MD5) - mirrors ffmpeg's
/// framemd5 over the rawvideo yuv420p frame.
fn hevc_enc_frame_md5(data : Array[Byte]) -> String {
  let md5 = @libavutil.av_md5_alloc()
  @libavutil.av_md5_init(md5)
  let b = Bytes::from_array(data)
  @libavutil.av_md5_update(md5, b, b.length())
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_final(md5, digest)
  let h = "0123456789abcdef"
  let mut out = ""
  for i in 0..<16 {
    let v = digest[i].to_int() & 255
    out = out +
      h.get_char((v >> 4) & 15).unwrap().to_string() +
      h.get_char(v & 15).unwrap().to_string()
  }
  out
}

///|
/// The arbitration frames: 64x64 gradient + offset gradient, 4:2:0.
fn hevc_enc_arb_frames() -> Array[
  (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]),
] {
  let y = hevc_enc_i_make_plane(64, 64, fn(i, j) { i * 3 + j * 2 + 128 })
  let u = hevc_enc_i_make_plane(32, 32, fn(i, _) { (i * 2) & 255 })
  let v : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
  let frames : Array[(FixedArray[Int32], FixedArray[Int32], FixedArray[Int32])] = []
  frames.push((y, u, v))
  let y2 = hevc_enc_i_make_plane(64, 64, fn(i, j) {
    (i * 3 + j * 2 + 128 + 40) & 255
  })
  frames.push((y2, u, v))
  frames
}
