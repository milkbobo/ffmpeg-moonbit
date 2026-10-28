///|
/// Real-data fMP4/H.264 test: an x264 64x48 five-frame stream (avcC and
/// length-prefixed samples taken from ffmpeg's MP4) is written as an fMP4
/// init + media segment, parsed back by `av_mov_open`, converted to Annex B
/// and decoded. Frame MD5s match FFmpeg 9.0.2 single-thread decode.

///|
let fmp4_h264_avcc_b64 : Bytes = b"AWQACv/hABdnZAAKrLII9gIgAAADACAAAAMCgeJEyQEABmjrw8siwP34+AA="

///|
let fmp4_h264_samples_b64 : Bytes = b"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"

///|
let fmp4_h264_sample_sizes : Array[Int32] = [1555, 53, 65, 40, 26]

///|
let fmp4_h264_refs : Array[String] = [
  "67209b5b9f9f453b541ba569d470bf06", "4c68e9b9ab2953cdecf58ec39bdcb731", "bb1a50b7f8162369de23870524586f00",
  "0b3917a80f0ad951e4b841f6de258213", "5f67aea83c2fccc3403eca53df9b2740",
]

///|
fn fmp4_h264_md5(frame : @libavcodec.H264Frame) -> String {
  let yuv = frame.yuvp()
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
/// 4-byte length-prefixed SPS/PPS NALs taken from the avcC records.
fn fmp4_h264_avcc_params(avcc : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut p = 6
  let num_sps = avcc[5].to_int() & 0x1F
  for _ in 0..<num_sps {
    let len = (avcc[p].to_int() << 8) | avcc[p + 1].to_int()
    p = p + 2
    out.push(((len >> 24) & 0xFF).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push((len & 0xFF).to_byte())
    for k = 0; k < len; k = k + 1 {
      out.push(avcc[p + k])
    }
    p = p + len
  }
  let num_pps = avcc[p].to_int()
  p = p + 1
  for _ in 0..<num_pps {
    let len = (avcc[p].to_int() << 8) | avcc[p + 1].to_int()
    p = p + 2
    out.push(((len >> 24) & 0xFF).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push((len & 0xFF).to_byte())
    for k = 0; k < len; k = k + 1 {
      out.push(avcc[p + k])
    }
    p = p + len
  }
  Bytes::from_array(out)
}

///|
fn fmp4_h264_annexb(avcc : Bytes, samples : Array[Bytes]) -> Bytes {
  let nalu_len = (avcc[4].to_int() & 3) + 1
  let out : Array[Byte] = []
  for sample in samples {
    let mut p = 0
    while p + nalu_len <= sample.length() {
      let mut len = 0
      for k = 0; k < nalu_len; k = k + 1 {
        len = (len << 8) | sample[p + k].to_int()
      }
      p = p + nalu_len
      out.push(b'\x00')
      out.push(b'\x00')
      out.push(b'\x01')
      for k = 0; k < len; k = k + 1 {
        out.push(sample[p + k])
      }
      p = p + len
    }
  }
  Bytes::from_array(out)
}

///|
test "fmp4 muxer: real H.264 init/media segments decode round-trip" {
  let avcc = @libavutil.av_base64_decode(fmp4_h264_avcc_b64, 1024).unwrap()
  let joined = @libavutil.av_base64_decode(fmp4_h264_samples_b64, 8192).unwrap()
  let samples : Array[Bytes] = []
  let mut off = 0
  for size in fmp4_h264_sample_sizes {
    samples.push(joined[off:off + size].to_owned())
    off = off + size
  }
  assert_eq(off, joined.length())
  let init = fmp4_h264_init_segment(64, 48, 90000, avcc).unwrap()
  let media = fmp4_media_segment(1, 1, 0L, [
    fmp4_sample(samples[0], 9000, true),
    fmp4_sample(samples[1], 9000, false),
    fmp4_sample(samples[2], 9000, false),
    fmp4_sample(samples[3], 9000, false),
    fmp4_sample(samples[4], 9000, false),
  ]).unwrap()
  let bytes : Array[Byte] = []
  for b in init {
    bytes.push(b)
  }
  for b in media {
    bytes.push(b)
  }
  let movie = av_mov_open(Bytes::from_array(bytes)).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "avc1")
  assert_eq(track.extradata.unwrap(), avcc)
  assert_eq(track.samples.length(), 5)
  let payload : Array[Byte] = []
  let out_bytes = Bytes::from_array(bytes)
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in out_bytes[start:end] {
      payload.push(b)
    }
  }
  let annexb = fmp4_h264_annexb(avcc, [
    fmp4_h264_avcc_params(avcc),
    Bytes::from_array(payload),
  ])
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(e) => fail("h264 decode failed: \{e}")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(fmp4_h264_md5(frames[i]), fmp4_h264_refs[i])
  }
}
