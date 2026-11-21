// 浏览器演示导出面（申报书⑤）：wasm-gc foreign_library + #export_name。
// `use-js-builtin-string` 下 String 直通 JS 字符串；二进制载荷（文件字节、
// WAV、RGB24）以 U+0100 偏移编码过界——每字节 b ↔ UTF-16 码元 b+0x100，
// 落在 Latin-1 Supplement（U+0100..U+01FF），天然避开 JSON 特殊字符与
// 控制符，信封可被 JSON.parse 严格解析且零膨胀（Node 全 256 值往返实测）。
//
// 统一 JSON 信封（申报书①错误码体系的浏览器呈现）：
//   成功 {"ok":true, "<fields>"}
//   失败 {"ok":false,"error":{"code":"...","message":"..."}}
// MediaError 的 code() 提供 5 个稳定码；信封层另有 NO_VIDEO_STREAM /
// THUMBNAIL_UNSUPPORTED 两个演示层失败码（不对应 MediaError 构造器）。
//
// JS 侧实例化（需 WasmGC + JS String Builtins 浏览器）：
//   WebAssembly.compile(bytes, { builtins: ["js-string"],
//                               importedStringConstants: "_" })

///|
/// U+0100 编码 String（每码元 0x100..0x1FF）→ Bytes。
fn u0100_to_bytes(s : String) -> Bytes {
  let n = s.length()
  let out : Array[Byte] = []
  out.resize(n, b'0')
  for i in 0..<n {
    out[i] = (s[i].to_int() - 0x100).to_byte()
  }
  Bytes::from_array(out)
}

///|
/// Bytes → U+0100 编码 String（码元 = 字节 + 0x100，可直接内嵌 JSON）。
fn bytes_to_u0100(b : Bytes) -> String {
  let sb = StringBuilder()
  for i in 0..<b.length() {
    sb.write_char((b[i].to_int() + 0x100).unsafe_to_char())
  }
  sb.to_string()
}

///|
/// RFC 8259 字符串转义（`"`、`\`、C0 控制符；本仓库手写 JSON 的既有风格）。
fn json_escape(s : String) -> String {
  let sb = StringBuilder()
  for i in 0..<s.length() {
    let n = s[i].to_int()
    if n >= 0x20 && n != 0x22 && n != 0x5C {
      sb.write_char(n.unsafe_to_char())
      continue
    }
    match n {
      0x22 => sb.write_string("\\\"")
      0x5C => sb.write_string("\\\\")
      0x0A => sb.write_string("\\n")
      0x0D => sb.write_string("\\r")
      0x09 => sb.write_string("\\t")
      _ => {
        let hex = "0123456789abcdef"
        sb.write_string("\\u")
        sb.write_char(hex.get_char((n >> 12) & 15).unwrap())
        sb.write_char(hex.get_char((n >> 8) & 15).unwrap())
        sb.write_char(hex.get_char((n >> 4) & 15).unwrap())
        sb.write_char(hex.get_char(n & 15).unwrap())
      }
    }
  }
  sb.to_string()
}

///|
/// 成功信封：`fields` 是若干 `"key":value` 逗号串（值需自转义）。
fn env_ok(fields : String) -> String {
  "{\"ok\":true," + fields + "}"
}

///|
/// 失败信封（演示层自有失败码，非 MediaError）。
fn env_err_code(code : String, msg : String) -> String {
  let m = json_escape(msg)
  "{\"ok\":false,\"error\":{\"code\":\"" +
  code +
  "\",\"message\":\"" +
  m +
  "\"}}"
}

///|
/// 失败信封（MediaError：稳定码 + 人类可读信息）。
fn env_err(e : @avf.MediaError) -> String {
  let m = json_escape(e.message())
  "{\"ok\":false,\"error\":{\"code\":\"" +
  e.code() +
  "\",\"message\":\"" +
  m +
  "\"}}"
}

///|
/// 元数据：probe 的 ffprobe 风格 JSON（format/streams），整体作为
/// `probe` 字段嵌入信封。
#export_name("ff_probe")
pub fn ff_probe(data : String) -> String {
  let mf = @avf.MediaFile::open(u0100_to_bytes(data)) catch {
    e => return env_err(e)
  }
  env_ok("\"probe\":" + mf.probe_json())
}

///|
/// 封面：MKV Attachments / MP4 ilst-covr；无封面时 `cover:null`。
#export_name("ff_cover")
pub fn ff_cover(data : String) -> String {
  let mf = @avf.MediaFile::open(u0100_to_bytes(data)) catch {
    e => return env_err(e)
  }
  match mf.cover() {
    Some(c) => {
      let mime = json_escape(c.mime())
      let data = bytes_to_u0100(c.data())
      env_ok("\"mime\":\"" + mime + "\",\"data\":\"" + data + "\"")
    }
    None => env_ok("\"cover\":null")
  }
}

///|
/// 解码到首个视频帧（解码序），HEVC 这类冲刷型解码器在 EOF 后经
/// `finish_video` 取帧。
fn first_video_frame(
  mf : @avf.MediaFile,
  dec : @avf.VideoDecoder,
  vidx : Int32,
) -> @avf.VideoFrame? raise @avf.MediaError {
  let mut frame : @avf.VideoFrame? = None
  let mut go = true
  while go {
    match mf.next_packet() {
      Some(pkt) =>
        if pkt.stream_index == vidx {
          for f in dec.decode(pkt) {
            frame = Some(f)
            go = false
            break
          }
        }
      None => go = false
    }
  }
  if frame is None {
    for f in dec.finish_video() {
      frame = Some(f)
      break
    }
  }
  frame
}

///|
/// 视频首帧缩略图：planar YUV 经 `SwsRgbScaler` 转为 RGB24。
/// PNG 和 RGB JPEG 以原始尺寸转换。
#export_name("ff_thumbnail")
pub fn ff_thumbnail(data : String, max_w : Int32) -> String {
  let mf = @avf.MediaFile::open(u0100_to_bytes(data)) catch {
    e => return env_err(e)
  }
  let mut vinfo : @avf.StreamInfo? = None
  for s in mf.streams() {
    if s.media_type == @avf.MediaType::Video {
      vinfo = Some(s)
      break
    }
  }
  let vinfo = match vinfo {
    Some(v) => v
    None =>
      return env_err_code("NO_VIDEO_STREAM", "no video stream in this file")
  }
  let dec = @avf.VideoDecoder::open(vinfo) catch { e => return env_err(e) }
  let frame = first_video_frame(mf, dec, vinfo.index) catch {
    e => return env_err(e)
  }
  let frame = match frame {
    Some(f) => f
    None => return env_err_code("NO_VIDEO_STREAM", "no decodable video frame")
  }
  render_video_rgb(frame, max_w)
}

///|
fn render_video_rgb(
  frame : @avf.VideoFrame,
  max_w : Int32,
  fields~ : String = "",
) -> String {
  let w = frame.width()
  let h = frame.height()
  if frame.image_rgb24() is Some(pixels) {
    let rgb = bytes_to_u0100(pixels)
    return env_ok(
      fields +
      "\"width\":" +
      w.to_string() +
      ",\"height\":" +
      h.to_string() +
      ",\"rgb24\":\"" +
      rgb +
      "\"",
    )
  }
  let bits = frame.bit_depth()
  let stride = if bits > 8 { 2 } else { 1 }
  let payload = frame.pixel_bytes()
  let ylen = w * h
  let c420 = (w + 1) / 2 * ((h + 1) / 2)
  let c422 = (w + 1) / 2 * h
  let layout : (@sws.SwsChromaFmt, Int32)? = match frame.chroma_shifts() {
    Some((1, 1)) => Some((Yuv420, c420))
    Some((1, 0)) => Some((Yuv422, c422))
    Some((0, 0)) => Some((Yuv444, ylen))
    _ => None
  }
  guard layout is Some((src_fmt, clen)) &&
    payload.length() == (ylen + 2 * clen) * stride else {
    return env_err_code(
      "THUMBNAIL_UNSUPPORTED", "unsupported planar frame layout",
    )
  }
  let py = preview_plane(payload, 0, ylen, bits)
  let pu = preview_plane(payload, ylen, clen, bits)
  let pv = preview_plane(payload, ylen + clen, clen, bits)
  let mw = if max_w <= 0 { 256 } else { max_w }
  let mut dw = if w <= mw { w } else { mw }
  dw -= dw % 2
  if dw < 2 {
    dw = 2
  }
  // 等比缩放高度，四舍五入并对齐到偶数（缩放器两侧都要求 4:2:0 几何）。
  let mut dh = (h * dw + w / 2) / w
  if dh < 2 {
    dh = 2
  }
  dh -= dh % 2
  let full_range = match frame.image_pixel_format() {
    Some(fmt) => fmt.has_prefix("yuvj")
    None => false
  }
  let rs = @sws.SwsRgbScaler::new(
    src_w=w,
    src_h=h,
    dst_w=dw,
    dst_h=dh,
    src_fmt~,
    full_range~,
  ) catch {
    InvalidScaleConfig(m) => return env_err_code("THUMBNAIL_UNSUPPORTED", m)
  }
  let rgb = rs.scale(py, pu, pv) catch {
    InvalidScaleConfig(m) => return env_err_code("THUMBNAIL_UNSUPPORTED", m)
  }
  let rgb_s = bytes_to_u0100(rgb)
  env_ok(
    fields +
    "\"width\":" +
    dw.to_string() +
    ",\"height\":" +
    dh.to_string() +
    ",\"rgb24\":\"" +
    rgb_s +
    "\"",
  )
}

///|
fn preview_plane(
  pixels : Bytes,
  start : Int32,
  count : Int32,
  bits : Int32,
) -> Bytes {
  if bits <= 8 {
    return pixels[start:start + count].to_owned()
  }
  // Decoders pack >8-bit samples as little-endian words. Canvas needs 8 bits.
  let shift = bits - 8
  let round = 1 << (shift - 1)
  Bytes::from_array(
    FixedArray::makei(count, i => {
      let pos = (start + i) * 2
      let word = pixels[pos].to_int() | (pixels[pos + 1].to_int() << 8)
      ((word + round) >> shift).min(255).to_byte()
    }),
  )
}

///|
fn decode_audio_at_rate(
  data : String,
  rate : Int32,
) -> @avf.DecodedAudio raise @avf.MediaError {
  let audio = @avf.decode_audio_file(u0100_to_bytes(data))
  if rate > 0 && rate != audio.sample_rate() {
    audio.resample_to(rate)
  } else {
    audio
  }
}

///|
fn audio_result(
  audio : @avf.DecodedAudio,
  field : String,
  bytes : Bytes,
) -> String {
  let dur = match audio.duration_seconds() {
    Some(d) => d.to_string()
    None => "null"
  }
  env_ok(
    "\"" +
    field +
    "\":\"" +
    bytes_to_u0100(bytes) +
    "\",\"sample_rate\":" +
    audio.sample_rate().to_string() +
    ",\"channels\":" +
    audio.channels().to_string() +
    ",\"duration_seconds\":" +
    dur,
  )
}

///|
/// 音频轨 → 16-bit WAV，采样率为 0 时保留源采样率。
#export_name("ff_decode_audio")
pub fn ff_decode_audio(data : String, rate : Int32) -> String {
  let audio = decode_audio_at_rate(data, rate) catch { e => return env_err(e) }
  let wav = audio.to_wav_s16() catch { e => return env_err(e) }
  audio_result(audio, "wav", wav)
}

///|
/// 音频轨 → 16-bit FLAC，采样率为 0 时保留源采样率。
#export_name("ff_encode_flac")
pub fn ff_encode_flac(data : String, rate : Int32) -> String {
  let audio = decode_audio_at_rate(data, rate) catch { e => return env_err(e) }
  let samples = @swr.swr_flt_planar_to_s16(audio.samples(), audio.channels()) catch {
    e => return env_err_code("AUDIO_CONVERSION_FAILED", e.to_string())
  }
  match @avc.flac_encode(samples, audio.channels(), audio.sample_rate(), 16) {
    Ok(flac) => audio_result(audio, "flac", flac.file())
    Err(e) => env_err_code("FLAC_ENCODE_FAILED", e)
  }
}
