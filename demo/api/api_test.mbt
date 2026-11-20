// 黑盒：JSON 信封、稳定错误码、WAV 夹具端到端（probe/cover/thumbnail/
// decode-audio）。夹具为内联手搓的最小 PCM WAV（mono 8000 Hz s16le）。

///|
fn tiny_wav() -> Bytes {
  let out : Array[Byte] = []
  let str = fn(s : String) -> Unit {
    for i in 0..<s.length() {
      out.push((s[i].to_int() & 0xFF).to_byte())
    }
  }
  let u32 = fn(v : Int32) -> Unit {
    for i in 0..<4 {
      out.push(((v >> (8 * i)) & 0xFF).to_byte())
    }
  }
  let u16 = fn(v : Int32) -> Unit {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
  }
  let samples = 16
  let data_len = samples * 2
  str("RIFF")
  u32(36 + data_len)
  str("WAVE")
  str("fmt ")
  u32(16)
  u16(1) // PCM
  u16(1) // mono
  u32(8000)
  u32(16000) // byte rate
  u16(2) // block align
  u16(16) // bits
  str("data")
  u32(data_len)
  for i in 0..<samples {
    u16(if i % 2 == 0 { 1000 } else { -1000 })
  }
  Bytes::from_array(out)
}

///|
fn tiny_wav_u0100() -> String {
  let b = tiny_wav()
  let sb = StringBuilder()
  for i in 0..<b.length() {
    sb.write_char((b[i].to_int() + 0x100).unsafe_to_char())
  }
  sb.to_string()
}

///|
test "ff_probe: 空数据与非媒体数据 → FORMAT_NOT_FOUND 信封" {
  let r = @api.ff_probe("")
  inspect(
    r,
    content="{\"ok\":false,\"error\":{\"code\":\"FORMAT_NOT_FOUND\",\"message\":\"Format not found\"}}",
  )
  let r2 = @api.ff_probe(
    "not a media file at all, just text padding padding....",
  )
  assert_true(r2.contains("\"code\":\"FORMAT_NOT_FOUND\""))
}

///|
test "ff_probe: WAV 夹具 → ok 信封嵌 probe JSON" {
  let r = @api.ff_probe(tiny_wav_u0100())
  // probe_json 是 pretty JSON（换行缩进），只断言信封前缀与关键字段
  assert_true(r.has_prefix("{\"ok\":true,\"probe\":{"))
  assert_true(r.contains("\"format_name\": \"wav\""))
  assert_true(r.contains("\"codec_name\": \"pcm"))
}

///|
test "ff_cover: WAV 无封面 → cover:null" {
  let r = @api.ff_cover(tiny_wav_u0100())
  inspect(r, content="{\"ok\":true,\"cover\":null}")
}

///|
test "ff_thumbnail: 纯音频 → NO_VIDEO_STREAM 演示层失败码" {
  let r = @api.ff_thumbnail(tiny_wav_u0100(), 256)
  inspect(
    r,
    content="{\"ok\":false,\"error\":{\"code\":\"NO_VIDEO_STREAM\",\"message\":\"no video stream in this file\"}}",
  )
}

///|
test "ff_decode_audio: WAV → ok + 元数据字段" {
  let r = @api.ff_decode_audio(tiny_wav_u0100(), 0)
  // "RIFF" 的 U+0100 编码：0x52,0x49,0x46,0x46 → U+0152 U+0149 U+0146 U+0146
  assert_true(
    r.has_prefix("{\"ok\":true,\"wav\":\"\u{152}\u{149}\u{146}\u{146}"),
  )
  assert_true(r.contains("\"sample_rate\":8000,\"channels\":1"))
}

///|
test "ff_decode_audio: 重采样到 16000 → 采样率字段跟随" {
  let r = @api.ff_decode_audio(tiny_wav_u0100(), 16000)
  assert_true(r.contains("\"sample_rate\":16000,\"channels\":1"))
}

///|
test "MediaError::code: 五个稳定码" {
  inspect(
    @avf.MediaError::code(@avf.FormatNotFound),
    content="FORMAT_NOT_FOUND",
  )
  inspect(
    @avf.MediaError::code(@avf.UnsupportedFormat("mov")),
    content="UNSUPPORTED_FORMAT",
  )
  inspect(
    @avf.MediaError::code(@avf.DemuxError("truncated")),
    content="DEMUX_ERROR",
  )
  inspect(
    @avf.MediaError::code(@avf.UnsupportedCodec("flac")),
    content="UNSUPPORTED_CODEC",
  )
  inspect(
    @avf.MediaError::code(@avf.DecodeError("bad packet")),
    content="DECODE_ERROR",
  )
}
