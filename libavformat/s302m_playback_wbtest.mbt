///|
fn s302m_test_ts(payload : Bytes) -> Bytes {
  let pmt = b"\x00\x02\xb0\x18\x00\x01\xc1\x00\x00\xe1\x01\xf0\x00\x06\xe1\x01\xf0\x06\x05\x04BSSD\x00\x00\x00\x00"
  let packets = [
    ts_test_pat(0x1000),
    ts_test_packet(0x1000, true, 0, pmt),
    ts_test_pes(0x101, 0xbd, payload),
  ]
  for i in 0..<6 {
    packets.push(ts_test_packet(0x1fff, false, i, b""))
  }
  ts_test_concat(packets)
}

///|
test "SMPTE 302M MPEG-TS playback preserves all PCM bits" {
  // First four samples from 48 kHz FFmpeg 9.0.2 s302m sine fixtures.
  // References use -af atrim=end_sample=4 -c:a pcm_s32le -f md5.
  for
    (b64, width, channels, md5) in [
      (
        b"FAAAAAAAEAAAKhAMCgAhCAZ5ADYYBRcA", 16, 2, "ce108a189fe9f36509ed86fcb6f0a667",
      ),
      (
        b"MABAEAAAAQAAAAAAAQAAAEKhAJQKAHuIANZQAAIQgBp5APXEAEsoAANhgPkXABasAPT4AA==",
        20, 4, "c89c92786e109a7447975d2b5f3cb8ad",
      ),
      (
        b"cADAIAAAABAAAAAAAAAQAAAAAAAAEAAAAAAAABAAAACUKhAIlAoAh7iADNZQAFG0gA5p8ABy8gACt4AA8CEICBp5AF9cQABLKAChGkAJ0PgAoXkABlvAADA2GAL5FwBBasAP9PgAFn7ABHx0ALG3AArjoAA=",
        24, 8, "7bd22774fc7ee2b4a02613f39eef843e",
      ),
    ] {
    let payload = @libavutil.av_base64_decode(b64, 256).unwrap().to_array()
    payload[0] = 0
    payload[1] = (payload.length() - 4).to_byte()
    let packet = Bytes::from_array(payload)
    assert_eq(@libavcodec.parse_s302m_header(packet).unwrap().bits, width)
    let data = s302m_test_ts(packet)
    let media = MediaFile::open(data)
    let info = media.streams()[0]
    assert_eq(info.codec_id, "s302m")
    assert_eq(info.channels, channels)
    assert_eq(info.sample_rate, 48000)
    assert_true(media.next_packet().unwrap().keyframe)
    let audio = decode_audio_file(data)
    assert_eq(audio.samples[0].length(), 4)
    let pcm : Array[Byte] = []
    for i in 0..<4 {
      for row in audio.samples {
        let word = (row[i] * 2147483648.0).to_int()
        for byte in 0..<4 {
          pcm.push((word >> (8 * byte)).to_byte())
        }
      }
    }
    assert_eq(caf_md5(Bytes::from_array(pcm)), md5)
  }
}

///|
test "SMPTE 302M rejects inconsistent lengths and non-PCM bursts" {
  assert_true(
    @libavcodec.parse_s302m_header(b"\x00\x05\x00\x00\x01")
    is Err("s302m: incorrect payload length"),
  )
  assert_true(
    @libavcodec.parse_s302m_header(b"\x00\x01\x00\x00\x00")
    is Err("s302m: incomplete sample frame"),
  )
  let burst = b"\x00\x14\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x4e\x1f\x0f\x87\x20\x00\x00\x00\x00\x00"
  assert_true(
    @libavcodec.decode_s302m_pcm(burst)
    is Err("s302m: unsupported non-PCM burst"),
  )
}
