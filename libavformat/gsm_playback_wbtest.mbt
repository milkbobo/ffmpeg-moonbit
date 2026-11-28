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

///|
test "GSM AIFF-C exports complete blocks with independent IFF padding" {
  let input = wav_muxer_new(8000, 1, 16).unwrap()
  input.write_samples(Array::makei(641, i => i * 7919 % 65536 - 32768)[:])
  let audio = decode_audio_file(input.finish())
  let file = audio.to_aifc_gsm()
  let layout = av_aiff_open(file).unwrap()
  let start = layout.data_offset.to_int()
  assert_eq(layout.format.codec, "gsm")
  assert_eq(layout.format.block_align, 33)
  assert_eq(layout.sample_count, 800L)
  assert_eq(layout.data_size, 165L)
  assert_eq(file.length(), start + 165 + 1)
  assert_eq(file[start + 165], b'\x00')
  let chunks = aiff_chunks(file, 12, file.length())
  let (comm, _) = aiff_chunk(chunks, "COMM").unwrap()
  assert_eq(aiff_u32be(file, comm + 2), 5U)
  let native = audio.to_gsm()
  assert_eq(file[start:start + 165], native)
  assert_eq(
    decode_audio_file(file).samples(),
    decode_audio_file(native, filename="track.gsm").samples(),
  )

  let unknown_count = file.to_array()
  unknown_count[comm + 5] = 0
  assert_eq(
    av_aiff_open(Bytes::from_array(unknown_count)).unwrap().sample_count,
    800L,
  )
  let invalid_frame = file.to_array()
  invalid_frame[start + 33] = 0
  assert_true(
    av_aiff_open(Bytes::from_array(invalid_frame))
    is Err("aiff: missing GSM frame magic"),
  )
  let partial_block = file.to_array()
  let (ssnd, _) = aiff_chunk(chunks, "SSND").unwrap()
  partial_block[ssnd - 1] = partial_block[ssnd - 1] - 1
  assert_true(
    av_aiff_open(Bytes::from_array(partial_block))
    is Err("aiff: incomplete GSM block"),
  )
}

///|
test "GSM WAV49 export and readback trim partial blocks and Wave64 alignment" {
  let input = wav_muxer_new(8000, 1, 16).unwrap()
  input.write_samples(Array::makei(641, i => i * 7919 % 65536 - 32768)[:])
  let audio = decode_audio_file(input.finish())
  let native = audio.to_gsm()
  assert_eq(native.length(), 5 * 33)
  let raw_pcm = decode_audio_file(native, filename="track.gsm").samples()[0]
  assert_eq(raw_pcm.length(), 800)
  for wave64 in [false, true] {
    let file = audio.to_wav_gsm_ms(wave64~)
    let demux = if wave64 {
      av_w64_open(file).unwrap()
    } else {
      av_wav_open(file).unwrap()
    }
    assert_eq(demux.format.codec, "gsm_ms")
    assert_eq(demux.data_size, 195L)
    assert_eq(demux.sample_count, 641L)
    assert_eq(demux.packets.map(p => (p.pts, p.size, p.duration)), [
      (0L, 65, 320),
      (320L, 65, 320),
      (640L, 65, 1),
    ])
    let decoded = decode_audio_file(file)
    assert_eq(decoded.duration_seconds(), Some(641.0 / 8000.0))
    assert_eq(decoded.samples()[0], raw_pcm[:641].to_owned())
    let start = demux.data_offset.to_int()
    assert_eq(
      caf_md5(file[start:start + 195].to_owned()),
      "155770eaaaebf39654bd20ac7c7ba1de",
    )
    if wave64 {
      assert_eq(wav_u64(file, start - 8), 219L)
      let padded = file.to_array()
      padded[start - 8] = 224
      assert_eq(av_w64_open(Bytes::from_array(padded)).unwrap().data_size, 195L)
      padded[file.length() - 1] = 1
      assert_true(
        av_w64_open(Bytes::from_array(padded))
        is Err("wav: incomplete WAV49 block"),
      )
    }
  }
  let file = audio.to_wav_gsm_ms().to_array()
  // Invalid fact counts that would remove a whole packet are ignored.
  for i in 48..<52 {
    file[i] = if i == 48 { 1 } else { 0 }
  }
  let file = Bytes::from_array(file)
  assert_eq(decode_audio_file(file).samples()[0].length(), 960)
  let truncated = file[:file.length() - 2].to_owned()
  assert_true(av_wav_open(truncated) is Err("wav: incomplete WAV49 block"))
}
