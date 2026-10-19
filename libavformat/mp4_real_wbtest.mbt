///|
/// Real-file cross-validation against FFmpeg 9.0.2 itself.
///
/// `sample.mp4` was produced by the `linuxserver/ffmpeg:9.0.2` image:
///
///   ffmpeg -f lavfi -i testsrc=size=64x64:rate=5 -t 1 -c:v mpeg4 -g 5 \
///          -qscale:v 12 -an sample.mp4
///
/// and the expected per-packet values below are that same file's `ffprobe`
/// output (`-show_entries packet=pts,dts,duration,pos,size,flags`), i.e. the
/// reference demuxer's own result rather than hand-derived numbers. To
/// regenerate: run the above, then base64 the file into `real_mp4_b64` and copy
/// the ffprobe rows into `real_mp4_expected`.

///| base64 of the reference `sample.mp4` (2155 bytes). */
let real_mp4_b64 : Bytes = b"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"

///| `(pos, size, dts, duration, keyframe)` per packet, from ffprobe. */
let real_mp4_expected : Array[(Int64, UInt, Int64, UInt, Bool)] = [
  (44, 790, 0, 2048, true),
  (834, 97, 2048, 2048, false),
  (931, 132, 4096, 2048, false),
  (1063, 123, 6144, 2048, false),
  (1186, 98, 8192, 2048, false),
]

///|
/// Parse the real MP4 and check every sample against ffprobe: offsets, sizes,
/// DTS/PTS, durations and keyframe flags must all agree.
test "mp4: real ffmpeg output cross-check (ffprobe packets)" {
  let bytes = @libavutil.av_base64_decode(real_mp4_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.timescale, 10240)
  assert_eq(t.codec, "mp4v")
  assert_eq(t.width, 64)
  assert_eq(t.height, 64)
  assert_eq(t.samples.length(), 5)
  for i = 0; i < 5; i = i + 1 {
    let (pos, size, dts, duration, keyframe) = real_mp4_expected[i]
    assert_eq(t.samples[i].offset, pos)
    assert_eq(t.samples[i].size, size)
    assert_eq(t.samples[i].dts, dts)
    assert_eq(t.samples[i].pts, dts)
    assert_eq(t.samples[i].duration, duration)
    assert_eq(t.samples[i].keyframe, keyframe)
  }
}

///| base64 of a fragmented reference MP4 (`-movflags frag_keyframe+empty_moov+default_base_moof`). */
let real_frag_b64 : Bytes = b"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"

///| `(pos, size, dts, duration, keyframe)` per packet from ffprobe of the fragmented file. */
let real_frag_expected : Array[(Int64, UInt, Int64, UInt, Bool)] = [
  (971, 790, 0, 2048, true),
  (1761, 97, 2048, 2048, false),
  (1858, 132, 4096, 2048, false),
  (1990, 123, 6144, 2048, false),
  (2113, 98, 8192, 2048, false),
]

///|
/// Fragmented MP4 cross-check: `moof`/`traf`/`tfhd`/`tfdt`/`trun` must yield the
/// same packets ffprobe reports for a real `frag_keyframe` output.
test "mp4: real fragmented ffmpeg output cross-check" {
  let bytes = @libavutil.av_base64_decode(real_frag_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let t = movie.tracks[0]
  assert_eq(t.timescale, 10240)
  assert_eq(t.samples.length(), 5)
  for i = 0; i < 5; i = i + 1 {
    let (pos, size, dts, duration, keyframe) = real_frag_expected[i]
    assert_eq(t.samples[i].offset, pos)
    assert_eq(t.samples[i].size, size)
    assert_eq(t.samples[i].dts, dts)
    assert_eq(t.samples[i].pts, dts)
    assert_eq(t.samples[i].duration, duration)
    assert_eq(t.samples[i].keyframe, keyframe)
  }
}

///|
/// base64 of a real cenc (AES-CTR) reference file: `sample.mp4`'s content muxed
/// with `-encryption_scheme cenc-aes-ctr -encryption_key 000102…0f`.
let real_enc_b64 : Bytes = b"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"

///|
/// Real cenc cross-check: decrypting `enc.mp4` with the known key must reproduce
/// the plaintext samples of `sample.mp4` (ffprobe reports the same packet layout
/// for both, and mp4 cenc-aes-ctr preserves sample sizes).
test "mp4: real cenc (AES-CTR) decryption reproduces plaintext" {
  let plain_bytes = @libavutil.av_base64_decode(real_mp4_b64, 100000).unwrap()
  let enc_bytes = @libavutil.av_base64_decode(real_enc_b64, 100000).unwrap()
  let key = Bytes::from_array([
    b'\x00', b'\x01', b'\x02', b'\x03', b'\x04', b'\x05', b'\x06', b'\x07',
    b'\x08', b'\x09', b'\x0a', b'\x0b', b'\x0c', b'\x0d', b'\x0e', b'\x0f',
  ])
  let tm = av_mov_open(enc_bytes).unwrap().tracks[0]
  let tp = av_mov_open(plain_bytes).unwrap().tracks[0]
  assert_eq(tm.cenc_scheme, 0x63656E63)
  assert_eq(tm.samples.length(), 5)
  assert_eq(tp.samples.length(), 5)

  let enc_arr = enc_bytes.to_array()
  let plain_arr = plain_bytes.to_array()
  for i = 0; i < 5; i = i + 1 {
    let m = tm.samples[i]
    let p = tp.samples[i]
    assert_eq(m.offset, p.offset)
    assert_eq(m.size, p.size)
    let start = m.offset.to_int()
    let end = (m.offset + m.size.to_int64()).to_int()
    let enc_payload = Bytes::from_array(enc_arr[start:end])
    let plain_payload = Bytes::from_array(plain_arr[start:end])
    let dec = mov_decrypt_sample(tm, i, key, enc_payload).unwrap()
    assert_eq(dec, plain_payload)
  }
}
