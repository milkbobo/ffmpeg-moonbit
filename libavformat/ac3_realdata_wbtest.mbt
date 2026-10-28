///|
/// Raw AC-3 demuxer tests: FFmpeg 9.0.2 encodes (see the fixture commands in
/// `libavcodec/ac3_realdata_test.mbt`) are split into frames by
/// `av_ac3_open`, then decoded; 48 kHz mono output matches FFmpeg's s16le
/// reference exactly (MD5 `0b4d53cb6c20a3642b1b06b01546afae`).

///|
fn ac3_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let ac3_mono48_b64 : Bytes = ac3_concat([
  b"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",
])

///|
let ac3_mono44_b64 : Bytes = ac3_concat([
  b"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",
])

///|
let ac3_surround51_b64 : Bytes = ac3_concat([
  b"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",
])

///|
fn ac3_decode(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 1000000).unwrap()
}

///|
fn ac3_s16_md5(samples : Array[Double]) -> String {
  let bytes : Array[Byte] = []
  for v in samples {
    let q = if v >= 1.0 {
      32767
    } else if v <= -1.0 {
      -32768
    } else {
      (v * 32768.0).round().to_int()
    }
    bytes.push((q & 0xFF).to_byte())
    bytes.push(((q >> 8) & 0xFF).to_byte())
  }
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, Bytes::from_array(bytes), bytes.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "raw AC-3 demuxer: frame splitting at 48/44.1/32 kHz" {
  let mono = av_ac3_open(ac3_decode(ac3_concat([ac3_mono48_b64]))).unwrap()
  assert_eq(mono.codec, "ac3")
  assert_eq(mono.sample_rate, 48000)
  assert_eq(mono.channels, 1)
  assert_eq(mono.frame_size, 1536)
  assert_eq(mono.bit_rate, 96000)
  assert_eq(mono.frames.length(), 4)
  assert_eq(mono.total_samples, 6144L)
  for i = 0; i < 4; i = i + 1 {
    assert_eq(mono.frames[i].pos, (i * 384).to_int64())
    assert_eq(mono.frames[i].size, 384)
    assert_eq(mono.frames[i].pts, (i * 1536).to_int64())
    assert_eq(mono.frames[i].duration, 1536)
  }
  // 44.1 kHz alternates two frame size codes, so sizes differ per frame.
  let m44 = av_ac3_open(ac3_decode(ac3_concat([ac3_mono44_b64]))).unwrap()
  assert_eq(m44.sample_rate, 44100)
  assert_eq(m44.channels, 1)
  assert_eq(m44.frames.length(), 4)
  let sizes : Array[Int32] = [416, 418, 418, 418]
  for i = 0; i < 4; i = i + 1 {
    assert_eq(m44.frames[i].size, sizes[i])
  }
  let s51 = av_ac3_open(ac3_decode(ac3_concat([ac3_surround51_b64]))).unwrap()
  assert_eq(s51.sample_rate, 48000)
  assert_eq(s51.channels, 6)
  assert_eq(s51.bit_rate, 384000)
  assert_eq(s51.frames.length(), 4)
  assert_eq(s51.total_samples, 6144L)
  for frame in s51.frames {
    assert_eq(frame.size, 1536)
  }
}

///|
test "raw AC-3 demuxer: mono decode matches FFmpeg PCM" {
  let data = ac3_decode(ac3_concat([ac3_mono48_b64]))
  let track = av_ac3_open(data).unwrap()
  let dec = @libavcodec.ac3_decoder_new()
  let pcm : Array[Double] = []
  for frame in track.frames {
    let start = frame.pos.to_int()
    let bytes = data[start:start + frame.size].to_owned()
    let decoded = dec.decode_frame(bytes).unwrap()
    for v in decoded.samples[0] {
      pcm.push(v)
    }
  }
  assert_eq(pcm.length(), 6144)
  assert_eq(ac3_s16_md5(pcm), "0b4d53cb6c20a3642b1b06b01546afae")
}
