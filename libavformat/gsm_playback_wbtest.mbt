///|
/// FFmpeg FATE gsm/sample-gsm-8000.mov, remuxed with
/// `-c:a copy -t 0.64 -f gsm` and `-c:a copy -t 0.64` (MOV).
let gsm_raw_fixture = b"12OK4ZupzClSbkoYVIq8vuKYM4LqWnrNxeHQyZrW5Uqc2CaC2WSB6hbwdikdfOjg685Ymq0qxnOlphTTaWkBQ9uM1h6DZZyCxi4huMpKosZR60Sz4+xn6N4s+9rUqLbXnTqT1V+DYmOCp8faTIakfMew2LC7FIDl2Nz9VpFyxfldqqZW1CCEKlO5Zd1QrmrC7sS5anU+zljj03pmCNx646pkET9y0yKsYiOChDaZvsar10KE6+2I2b6D3IRqpuypBCvCblqr02OTZqpqpDVVkT6JvKQ+2xHHZFCiuNQqaSjqo4ak7ESp02SMYmJ65E7TjSb1pqKlHBl5lb9ilvzR9o3vQzXZblKt0uO0YtJ5IhQiTekW7oG021WagLViF10SGXN5IjEequis1CGDnqN5AgaxzkiWtSRFHJKY5+/jIxwmuCSKw0Ij7aCU06F75qJ5I7eYlQykeqLDY2LLBb7DVx+tZqp5Iset4Gcv02WMplLwgibeTH0NquOWm+2kinjCoyOGot+xQlKrLkyZ0uSMJhrxAYiNnc0jtMI73G5bFrjDNxmRy0XuwbhlqEpw1CKD4mNuwatyIUUVYUMywpLNGlKCtQm0hyrrQ8dVuL7l1CKTnitpQeaDf1rvkqJLJU2tsNyiespN1DFWwdjTcIfi1SSSkdqqghYoSJOUpsELWGq65GsCTOzYpzfeoahe1ZsD1V9zopGDYm8Vpzc0mMI6W62k0FkCJrQArRFkgqlS6cbU0+KTolrIwcTz6s1klyGpHJQpY4lDZ2SxONvNQiczLyy70t58meJXAy7BahUTbMMy4kXPW9ajV9yOOMKE4roa8sUR0t1zETLTRCiTUcrfW6Q58qzJVGsDh4NsIhHh5ljnbjrj01pzodNjBFbQsMbh24OjHGxFgdsk0O/xw5tTZDbUrE9D0qCTYYzVSNCsajlrfoWY3PojJuTlXKJw4DDu52Asxnca0qia3gtQhmrRrcT+0sVIT6miM/Dk6LLV9Vl4xuSU8tkb0upq4VHkpSjDZajmpKTOxrEaU/CFm2J+lhp5RCRE28ri0quK4Rpq5W6D0Ejr8WL0Coqi0fFDu7Pym415JDuLd6ti0qxjYRK3JKtQFZQd1OOZ4vsWnLTDKdN7CN7xJhaaU9kk0qxrHZB65Evi0ybfxsTL0VYFVfEkpSdvWR2kpDSqOfsb0mxy4VLVZDmbDhlf8IW1pUr3U6KjtG9aZmDxYzDQctke0qyCpVHxA3a1gdbceMVJLVJkWNUjVitGUznxBPrbpMub0ut7XVHxw7ZcBQRbUMdI4253I9SlZRtl+yPxRFQDRU1s0qyLHZLxREd8zUiz8QNO3MS7mfFDlIuRvuzxQ85laMch0m2LYNLWw+bcYObL1KNGkaY/ZLTjWuSMeLHTBU8jjKjz0uecHVHxo7tc+dUD0qOH1qydHPCGGoMtCRzTBRtrfSmc"

///|
/// FFmpeg FATE gsm/ciao.wav, remuxed with `-c:a copy -frames:a 2`.
let gsm_wav_fixture = b"UklGRtgAAABXQVZFZm10IBQAAAAxAAEAQB8AAFkGAABBAAAAAgBAAWZhY3QEAAAAgAIAAExJU1QaAAAASU5GT0lTRlQNAAAATGF2ZjYzLjEuMTAyAABkYXRhggAAAFgoncGCAgMatXHcFMyBGUcSvfTl4SBlviOLSmFWx24oVY2VkSjcGrasshJY+By0lEOmWcYU1tD0vL6oFOj1jDyqlEndhBCvQdu6WcN4DwFa5GGlNstgH1lPtqyNoXw1k+tEmfXNSKgayGT1hmW1FESoCqWhyhZEj9tqt+EQGLuVeso="

///|
let gsm_mov_fixture = b"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"

///|
test "GSM native, WAV49 and MOV audio agree with FFmpeg PCM" {
  for
    (b64, format, codec, count, md5) in [
      (gsm_raw_fixture, "gsm", "gsm", 5280, "e0d448ff7e8f8440193aa637b08514da"),
      (
        gsm_wav_fixture, "wav", "gsm_ms", 640, "44641cb80fc7e5318a063a571b90deec",
      ),
      (
        gsm_mov_fixture, "mov,mp4,m4a,3gp,3g2,mj2", "gsm", 5184, "72f461faf359cea930de1aa408a22e5b",
      ),
    ] {
    let file = @libavutil.av_base64_decode(b64, 4096).unwrap()
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, format)
    assert_eq(audio.codec_id, codec)
    assert_eq(audio.sample_rate, 8000)
    assert_eq(audio.channels, 1)
    assert_eq(audio.samples[0].length(), count)
    let wave = audio.to_wav_s16()
    let demux = av_wav_open(wave).unwrap()
    let start = demux.data_offset.to_int()
    let pcm = wave[start:start + demux.data_size.to_int()].to_owned()
    assert_eq(caf_md5(pcm), md5)
  }
}

///|
test "GSM packets preserve WAV49 block boundaries and sample timestamps" {
  let file = @libavutil.av_base64_decode(gsm_wav_fixture, 1024).unwrap()
  let demux = av_wav_open(file).unwrap()
  assert_eq(demux.sample_count, 640L)
  assert_eq(demux.packets.map(p => (p.pos, p.pts, p.size, p.duration)), [
    (94L, 0L, 65, 320),
    (159L, 320L, 65, 320),
  ])
  let raw = @libavutil.av_base64_decode(gsm_raw_fixture, 4096).unwrap()
  let track = av_gsm_open(raw).unwrap()
  assert_eq(track.frames.length(), 33)
  assert_eq(track.total_samples, 5280L)
  assert_eq(track.frames[32].pts, 5120L)
  assert_eq(track.frames[32].pos, 1056L)
  assert_true(
    av_gsm_open(raw[:1088].to_owned()) is Err("gsm: incomplete block"),
  )
}
