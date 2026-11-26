///|
/// Wrap a short reference LPCM payload in an M2TS program registered HDMV.
fn bluray_lpcm_test_m2ts(lpcm : Bytes) -> Bytes {
  let pmt = b"\x00\x02\xb0\x18\x00\x01\xc1\x00\x00\xe1\x01\xf0\x06\x05\x04HDMV\x80\xe1\x01\xf0\x00\x00\x00\x00\x00"
  let length = lpcm.length() + 8
  let pes : Array[Byte] = [
    0,
    0,
    1,
    0xbd,
    (length >> 8).to_byte(),
    length.to_byte(),
    0x80,
    0x80,
    5,
    0x21,
    0,
    1,
    0,
    1,
  ]
  pes.append(lpcm.to_array())
  let packets = [
    ts_test_pat(0x1000),
    ts_test_packet(0x1000, true, 0, pmt),
    ts_test_packet(0x101, true, 0, Bytes::from_array(pes)),
  ]
  for i in 0..<6 {
    packets.push(ts_test_packet(0x1fff, false, i, b""))
  }
  let out : Array[Byte] = []
  for packet in packets {
    out.append([0, 0, 0, 0])
    out.append(packet)
  }
  Bytes::from_array(out)
}

///|
test "HDMV LPCM player matches FFmpeg mono padding and 7.1 channel order" {
  // The first four frames from FFmpeg's pcm_bluray encoder at 48 kHz s16
  // mono and 192 kHz s24 7.1, shortened by rewriting the audio byte count.
  for
    (b64, rate, channels, md5) in [
      (
        b"A8ARQAAAAAACFAAABCEAAAYaAAA=", 48000, 1, "61400d3cc34d6ad368c34e585c1f8452",
      ),
      (
        b"IcC1wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAECtViehgQGB57YYVuDzLaCtiGBmgRWpOYEDSk7gagKd/Wugm8FtrED4GcB3fytSY8Cqk3VaQwLumSAJLqD3DuB8+x/dxED7bg==",
        192000, 8, "9250135514e8bd964c438e30df1f79e9",
      ),
    ] {
    let payload = @libavutil.av_base64_decode(b64, 256).unwrap().to_array()
    payload[0] = 0
    payload[1] = (payload.length() - 4).to_byte()
    let data = bluray_lpcm_test_m2ts(Bytes::from_array(payload))
    let media = MediaFile::open(data)
    assert_eq(media.format_name(), "mpegts")
    let info = media.streams()[0]
    assert_eq(info.codec_id, "pcm_bluray")
    assert_eq(info.sample_rate, rate)
    assert_eq(info.channels, channels)
    let packet = media.next_packet().unwrap()
    assert_eq(packet.pts, 0L)
    assert_true(packet.keyframe)
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
    // FFmpeg on each source M2TS: -af atrim=end_sample=4 -c:a pcm_s32le.
    assert_eq(caf_md5(Bytes::from_array(pcm)), md5)
  }
}

///|
test "Blu-ray LPCM rejects a truncated body and an unsupported depth" {
  assert_true(
    @libavcodec.decode_bluray_lpcm(b"\x00\x04\x11\x40\x00\x01")
    is Err("pcm_bluray: incorrect payload length"),
  )
  assert_true(
    @libavcodec.parse_bluray_lpcm_header(b"\x00\x06\x11\x80")
    is Err("pcm_bluray: unsupported sample depth"),
  )
}
