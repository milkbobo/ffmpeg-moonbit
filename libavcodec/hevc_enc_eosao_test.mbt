///|
/// HEVC encoder edge-offset SAO black-box arbitration. The 64x64 two-frame
/// 1-pixel-stripe stream (phase-shifted in frame 2, qp 38) runs with both
/// SAO flags on; FFmpeg 9.0.2 decodes it with zero warnings and the
/// raw-HEVC framemd5 values are pinned below. Whether a CTB's EO candidate
/// beats its band candidate is the decision's business (pinned at unit
/// level in hevc_enc_eosao_wbtest); the stream contract is that either way
/// stays legal.
///
/// Regenerate the stream with:
/// `moon run --target wasm-gc cmd/generate-hevc-crf <existing scratch dir>`,
/// then decode `eosao_seq.265` using the linuxserver/ffmpeg:9.0.2 image with
/// `-hide_banner -loglevel error -xerror -f framemd5 -`.

///|
fn hevc_enc_eosao_test_md5(data : Bytes) -> String {
  let md5 = @libavutil.av_md5_alloc()
  @libavutil.av_md5_init(md5)
  @libavutil.av_md5_update(md5, data, data.length())
  let digest : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_final(md5, digest)
  let h = "0123456789abcdef"
  let mut out = ""
  for b in digest {
    let v = b.to_int()
    out = out +
      h.get_char((v >> 4) & 15).unwrap().to_string() +
      h.get_char(v & 15).unwrap().to_string()
  }
  out
}

///|
fn hevc_enc_eosao_test_plane(
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
test "hevc enc eosao: ffmpeg stripe framemd5 pins" {
  let stripe = fn(
    phase : Int32,
  ) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
    let y = hevc_enc_eosao_test_plane(64, 64, fn(_i, j) {
      if ((j + phase) & 1) == 0 {
        172
      } else {
        84
      }
    })
    let c : FixedArray[Int32] = FixedArray::make(32 * 32, 128)
    (y, c, c.copy())
  }
  let seq = match
    @libavcodec.hevc_encode_sequence(
      [stripe(0), stripe(1)],
      width=64,
      height=64,
      qp=38,
      sao_chroma=true,
      sao_eo=true,
    ) {
    Ok(s) => s
    Err(e) => fail("eosao encode: \{e}")
  }
  let decoded = match
    @libavcodec.ff_hevc_decode_frames_ex(seq.annexb, false, 0, true) {
    Ok(d) => d
    Err(e) => fail("eosao decode: \{e}")
  }
  let pins = [
    "47ed933777b48d814ee50c0713480c50", "0978e4e361c2487d97fd36bff56060ea",
  ]
  assert_eq(decoded.length(), pins.length())
  for k in 0..<decoded.length() {
    assert_eq(decoded[k].poc(), k)
    assert_eq(hevc_enc_eosao_test_md5(decoded[k].yuvp(8)), pins[k])
  }
}
