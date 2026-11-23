///|
priv enum DemoVideoEncoder {
  Avc(@avc.VideoEncoder)
  Hevc(@avc.HevcStreamEncoder)
  Av1(@avc.Av1Encoder, Int32, Int32)
}

///|
fn[T] demo_result(result : Result[T, String]) -> T raise {
  match result {
    Ok(value) => value
    Err(message) => fail(message)
  }
}

///|
fn demo_video_encoder(
  codec : String,
  width : Int32,
  height : Int32,
) -> DemoVideoEncoder raise {
  match codec {
    "h264" => {
      let config = @avc.VideoEncConfig::new(width~, height~)
      Avc(
        demo_result(
          @avc.VideoEncoder::open(codec=H264, config={
            ..config,
            b_slices: false,
            dct8x8: false,
            keyint: 60,
          }),
        ),
      )
    }
    "hevc" =>
      Hevc(
        demo_result(
          @avc.HevcStreamEncoder::open(
            width~,
            height~,
            inter=true,
            b_slices=false,
          ),
        ),
      )
    "av1" =>
      Av1(
        @avc.Av1Encoder::new(@avc.Av1SeqEncConfig::default(width~, height~)),
        width,
        height,
      )
    _ => fail("unsupported output codec: " + codec)
  }
}

///|
fn demo_video_planes(
  frame : @avf.VideoFrame,
  width : Int32,
  height : Int32,
) -> (Bytes, Bytes, Bytes) raise {
  let w = frame.width()
  let h = frame.height()
  let bits = frame.bit_depth()
  let (fmt, cw, ch) : (@sws.SwsChromaFmt, Int32, Int32) = match
    frame.chroma_shifts() {
    Some((1, 1)) => (Yuv420, (w + 1) / 2, (h + 1) / 2)
    Some((1, 0)) => (Yuv422, (w + 1) / 2, h)
    Some((0, 0)) => (Yuv444, w, h)
    _ => fail("unsupported source pixel format")
  }
  let stride = if bits > 8 { 2 } else { 1 }
  let ylen = w * h * stride
  let clen = cw * ch * stride
  let pixels = frame.pixel_bytes()
  guard pixels.length() == ylen + 2 * clen else {
    fail("unsupported source frame layout")
  }
  let y = pixels[:ylen].to_owned()
  let u = pixels[ylen:ylen + clen].to_owned()
  let v = pixels[ylen + clen:].to_owned()
  if w == width &&
    h == height &&
    bits == 8 &&
    frame.chroma_shifts() == Some((1, 1)) {
    (y, u, v)
  } else {
    let scaler = @sws.SwsPlanarScaler::new(
      src_w=w,
      src_h=h,
      dst_w=width,
      dst_h=height,
      src_fmt=fmt,
      dst_fmt=Yuv420,
      src_bits=bits,
      dst_bits=8,
    )
    scaler.scale(y, u, v)
  }
}

///|
fn demo_int_plane(bytes : Bytes) -> FixedArray[Int32] {
  FixedArray::makei(bytes.length(), i => bytes[i].to_int())
}

///|
fn demo_av1_plane(
  bytes : Bytes,
  width : Int32,
  height : Int32,
  stride : Int32,
  rows : Int32,
  fill : Int32,
) -> FixedArray[Int32] {
  let plane = FixedArray::make(stride * rows, fill)
  let x = (stride - width) / 2
  let y = (rows - height) / 2
  for row in 0..<height {
    for col in 0..<width {
      plane[(y + row) * stride + x + col] = bytes[row * width + col].to_int()
    }
  }
  plane
}

///|
fn DemoVideoEncoder::push(
  self : DemoVideoEncoder,
  planes : (Bytes, Bytes, Bytes),
  content_size? : (Int32, Int32),
) -> Array[Bytes] raise {
  let (y, u, v) = planes
  match self {
    Avc(enc) => {
      demo_result(enc.push_frame(y, u, v))
      enc.drain()
    }
    Hevc(enc) => {
      demo_result(
        enc.push_frame(demo_int_plane(y), demo_int_plane(u), demo_int_plane(v)),
      )
      enc.drain()
    }
    Av1(enc, width, height) => {
      let (w, h) = content_size.unwrap_or((width, height))
      let (packet, _) = demo_result(
        enc.encode_frame(
          {
            y: demo_av1_plane(y, w, h, width, height, 16),
            y_stride: width,
            u: demo_av1_plane(u, w / 2, h / 2, width / 2, height / 2, 128),
            uv_stride: width / 2,
            v: demo_av1_plane(v, w / 2, h / 2, width / 2, height / 2, 128),
          },
          split_margin=0,
          drl=true,
        ),
      )
      [demo_result(@avc.av1_enc_mp4_sample(packet))]
    }
  }
}

///|
fn DemoVideoEncoder::finish(self : DemoVideoEncoder) -> Array[Bytes] raise {
  match self {
    Avc(enc) => demo_result(enc.finish())
    Hevc(enc) => demo_result(enc.finish())
    Av1(_, _, _) => []
  }
}

///|
fn demo_put_length(out : Array[Byte], length : Int32, size : Int32) -> Unit {
  for i = size - 1; i >= 0; i = i - 1 {
    out.push((length >> (8 * i)).to_byte())
  }
}

///|
fn demo_append(out : Array[Byte], bytes : Bytes) -> Unit {
  for byte in bytes {
    out.push(byte)
  }
}

///|
fn demo_annexb_nals(bytes : Bytes) -> Array[Bytes] {
  let nals = []
  let mut start = 0
  let mut zeros = 0
  for i in 0..<bytes.length() {
    let byte = bytes[i]
    if byte == b'\x01' && zeros >= 2 {
      if i - zeros > start {
        nals.push(bytes[start:i - zeros].to_owned())
      }
      start = i + 1
    }
    zeros = if byte == b'\x00' { zeros + 1 } else { 0 }
  }
  if bytes.length() - zeros > start {
    nals.push(bytes[start:bytes.length() - zeros].to_owned())
  }
  nals
}

///|
fn demo_nal_kind(nal : Bytes, hevc : Bool) -> Int32 {
  if hevc {
    (nal[0].to_int() >> 1) & 63
  } else {
    nal[0].to_int() & 31
  }
}

///|
fn demo_decoder_config(nals : Array[Bytes], hevc : Bool) -> Bytes raise {
  let kinds = if hevc { [32, 33, 34] } else { [7, 8] }
  let params : Array[Bytes] = []
  for kind in kinds {
    let n = for nal in nals {
      if demo_nal_kind(nal, hevc) == kind {
        break Some(nal)
      }
    } nobreak {
      None
    }
    guard n is Some(nal) else { fail("missing encoder parameter sets") }
    params.push(nal)
  }
  if hevc {
    let vps = @avc.ff_h2645_extract_rbsp(params[0][2:].to_owned()).data
    guard vps.length() >= 16 else { fail("truncated HEVC VPS") }
    let out : Array[Byte] = [b'\x01']
    demo_append(out, vps[4:16].to_owned()) // General profile, constraints, and level.
    demo_append(out, b"\xf0\x00\xfc\xfd\xf8\xf8\x00\x00\x0f\x03")
    for i in 0..<params.length() {
      out.push((0x80 | kinds[i]).to_byte())
      demo_append(out, b"\x00\x01")
      demo_put_length(out, params[i].length(), 2)
      demo_append(out, params[i])
    }
    Bytes::from_array(out)
  } else {
    let sps = params[0]
    guard sps.length() >= 4 else { fail("truncated H.264 SPS") }
    let out = [b'\x01', sps[1], sps[2], sps[3], b'\xff', b'\xe1']
    demo_put_length(out, sps.length(), 2)
    demo_append(out, sps)
    out.push(b'\x01')
    demo_put_length(out, params[1].length(), 2)
    demo_append(out, params[1])
    Bytes::from_array(out)
  }
}

///|
fn demo_mp4_packet(unit : Bytes, hevc : Bool) -> (Bytes, Bool) {
  let out : Array[Byte] = []
  let mut key = false
  for nal in demo_annexb_nals(unit) {
    let kind = demo_nal_kind(nal, hevc)
    if (if hevc { kind >= 32 && kind <= 34 } else { kind == 7 || kind == 8 }) {
      continue
    }
    key = key || (if hevc { kind >= 16 && kind <= 23 } else { kind == 5 })
    demo_put_length(out, nal.length(), 4)
    demo_append(out, nal)
  }
  (Bytes::from_array(out), key)
}

///|
fn demo_write_aac(
  mux : @avf.Mp4AvMuxer,
  audio : @avf.DecodedAudio,
) -> Unit raise {
  let samples = audio.samples()
  let size = samples[0].length()
  guard size > 0 else { fail("audio track has no decoded samples") }
  let encoder = demo_result(
    @avc.aac_encoder_new(
      @avc.aac_encode_config_perceptual(
        48000,
        audio.channels(),
        64000 * audio.channels(),
      ),
    ),
  )
  for offset = 0; offset < size; offset = offset + 1024 {
    let block = samples.map(fn(plane) {
      Array::makei(1024, i => {
        if offset + i < size {
          plane[offset + i]
        } else {
          0.0
        }
      })
    })
    if demo_result(encoder.encode_frame(block)) is Some(packet) {
      demo_result(mux.write_audio(packet))
    }
  }
  let tail = demo_result(encoder.flush())
  for i in 0..<tail.length() {
    let duration = if i == tail.length() - 1 {
      (size - 1) % 1024 + 1
    } else {
      1024
    }
    demo_result(mux.write_audio(tail[i], duration~))
  }
}

///|
fn demo_mux_mp4(
  codec : String,
  config : Bytes,
  width : Int32,
  height : Int32,
  packets : Array[(Bytes, Bool)],
  durations : Array[Int32],
  audio : @avf.DecodedAudio?,
) -> Bytes raise {
  match audio {
    Some(audio) => {
      let mux = demo_result(
        @avf.mp4_av_muxer_new(
          width,
          height,
          config,
          48000,
          audio.channels(),
          aac_priming=1024,
          video_codec=codec,
        ),
      )
      for i in 0..<packets.length() {
        let (packet, keyframe) = packets[i]
        demo_result(mux.write_video(packet, duration=durations[i], keyframe~))
      }
      demo_write_aac(mux, audio)
      mux.finish()
    }
    None =>
      match codec {
        "h264" => {
          let mux = demo_result(@avf.mp4_h264_muxer_new(width, height, config))
          for i in 0..<packets.length() {
            let (packet, keyframe) = packets[i]
            demo_result(
              mux.write_packet(packet, duration=durations[i], keyframe~),
            )
          }
          mux.finish()
        }
        "av1" => {
          let mux = demo_result(@avf.mp4_av1_muxer_new(width, height, config))
          for i in 0..<packets.length() {
            let (packet, keyframe) = packets[i]
            demo_result(
              mux.write_packet(packet, duration=durations[i], keyframe~),
            )
          }
          mux.finish()
        }
        _ => {
          let mux = demo_result(@avf.mp4_hevc_muxer_new(width, height, config))
          for i in 0..<packets.length() {
            let (packet, keyframe) = packets[i]
            demo_result(
              mux.write_packet(packet, duration=durations[i], keyframe~),
            )
          }
          mux.finish()
        }
      }
  }
}

///|
/// MOV samples are read in decode order. Their presentation times determine
/// both the order to feed a new encoder and the output MP4 sample durations.
fn demo_mov_track(
  data : Bytes,
  file : @avf.MediaFile,
  track_index : Int32,
) -> @avf.Mp4Track? {
  guard file.format_name().has_prefix("mov,") &&
    @avf.av_mov_open(data) is Ok(movie) &&
    track_index < movie.tracks.length() else {
    return None
  }
  let track = movie.tracks[track_index]
  guard track.timescale > 0U && !track.samples.is_empty() else { return None }
  Some(track)
}

///|
fn demo_mov_timeline_for(track : @avf.Mp4Track) -> (Array[Int32], Array[Int32]) {
  let order = Array::makei(track.samples.length(), i => i)
  order.sort_by((a, b) => {
    let cmp = track.samples[a].pts.compare(track.samples[b].pts)
    if cmp == 0 {
      a.compare(b)
    } else {
      cmp
    }
  })
  let scale = track.timescale.to_int64()
  let durations = Array::makei(order.length(), fn(i) {
    let sample = track.samples[order[i]]
    let start = sample.pts
    let end = if i + 1 < order.length() {
      track.samples[order[i + 1]].pts
    } else {
      start + sample.duration.to_int64()
    }
    (end * 90000L / scale - start * 90000L / scale).to_int().max(1)
  })
  (order, durations)
}

///|
fn demo_mov_timeline(
  data : Bytes,
  file : @avf.MediaFile,
  track_index : Int32,
) -> (Array[Int32], Array[Int32])? {
  demo_mov_track(data, file, track_index).map(demo_mov_timeline_for)
}

///|
#export_name("ff_transcode_mp4")
pub fn ff_transcode_mp4(data : String, codec : String) -> String {
  let mp4 = demo_transcode_mp4(u0100_to_bytes(data), codec) catch {
    error => return env_err_code("VIDEO_CONVERSION_FAILED", error.to_string())
  }
  env_ok("\"mp4\":\"" + bytes_to_u0100(mp4) + "\"")
}

///|
fn demo_transcode_mp4(data : Bytes, codec : String) -> Bytes raise {
  let file = @avf.MediaFile::open(data)
  let video = for stream in file.streams() {
    if stream.media_type == @avf.MediaType::Video {
      break Some(stream)
    }
  } nobreak {
    None
  }
  guard video is Some(video) else { fail("input has no video stream") }
  demo_check_video_size(video.width, video.height)
  let decoder = @avf.VideoDecoder::open(video)
  let (content_w, content_h) = if codec == "av1" {
    let scale = 512.0 / video.width.max(video.height).max(512).to_double()
    let even = fn(value : Int32) {
      (value.to_double() * scale / 2.0 + 0.5).to_int().max(1) * 2
    }
    (even(video.width), even(video.height))
  } else {
    ((video.width + 1) / 2 * 2, (video.height + 1) / 2 * 2)
  }
  // Each AV1 tile holds one 64x64 superblock. The tile grid requires
  // power-of-two dimensions, so pad the scaled image without stretching it.
  let (width, height) = if codec == "av1" {
    let align = value => {
      if value <= 64 {
        64
      } else if value <= 128 {
        128
      } else if value <= 256 {
        256
      } else {
        512
      }
    }
    (align(content_w), align(content_h))
  } else {
    (content_w, content_h)
  }
  let content_size = (content_w, content_h)
  let encoder = demo_video_encoder(codec, width, height)
  let push_frame = fn(frame : @avf.VideoFrame) -> Array[Bytes] raise {
    encoder.push(demo_video_planes(frame, content_w, content_h), content_size~)
  }
  let units : Array[Bytes] = []
  let timeline = demo_mov_timeline(data, file, video.index)
  // The H.264 decoder emits an image for each access unit in decode order.
  // Keep just the pictures waiting behind an earlier presentation time.
  let h264_order = match timeline {
    Some((order, _)) if video.codec_id == "h264" => order
    _ => []
  }
  let pending : Map[Int32, @avf.VideoFrame] = Map([])
  let mut decode_index = 0
  let mut display_index = 0
  let mut decoded_pixels = 0L
  for ;; {
    guard file.next_packet() is Some(packet) else { break }
    if packet.stream_index == video.index {
      let frames = decoder.decode(packet)
      decoded_pixels = demo_count_video(frames, decoded_pixels)
      guard codec != "av1" ||
        units.length() + pending.length() + frames.length() <= 120 else {
        fail("AV1 演示最多处理 120 帧。")
      }
      if h264_order.is_empty() {
        for frame in frames {
          units.append(push_frame(frame))
        }
      } else {
        guard frames.length() == 1 else {
          fail("unsupported H.264 sample layout")
        }
        pending[decode_index] = frames[0]
        while display_index < h264_order.length() {
          let next = h264_order[display_index]
          guard pending.get(next) is Some(frame) else { break }
          pending.remove(next)
          units.append(push_frame(frame))
          display_index += 1
        }
      }
      decode_index += 1
    }
  }
  guard pending.is_empty() else {
    fail("incomplete H.264 presentation timeline")
  }
  let tail = decoder.finish_video(pixel_budget=demo_hevc_batch_pixels)
  ignore(demo_count_video(tail, decoded_pixels))
  guard codec != "av1" || units.length() + tail.length() <= 120 else {
    fail("AV1 演示最多处理 120 帧。")
  }
  for frame in tail {
    units.append(push_frame(frame))
  }
  units.append(encoder.finish())
  guard units.length() > 0 else { fail("input has no decodable frames") }
  let (config, packets) = match encoder {
    Av1(enc, _, _) =>
      (enc.av1c(), Array::makei(units.length(), i => (units[i], i == 0)))
    _ => {
      let hevc = codec == "hevc"
      (
        demo_decoder_config(demo_annexb_nals(units[0]), hevc),
        units.map(unit => demo_mp4_packet(unit, hevc)),
      )
    }
  }
  let count = packets.length()
  let durations = match timeline {
    Some((_, durations)) if durations.length() == count => durations
    _ => {
      let total = match file.duration_seconds() {
        Some(seconds) if seconds > 0.0 => (seconds * 90000.0).to_int64()
        _ => count.to_int64() * 3000L
      }
      Array::makei(count, fn(i) {
        let a = i.to_int64() * total / count.to_int64()
        let b = (i + 1).to_int64() * total / count.to_int64()
        (b - a).to_int().max(1)
      })
    }
  }
  let audio = if file.streams().any(s => s.media_type == @avf.MediaType::Audio) {
    let audio = demo_decode_audio(data)
    guard audio.channels() <= 2 else {
      fail("MP4 conversion currently supports mono or stereo audio")
    }
    Some(
      if audio.sample_rate() == 48000 {
        audio
      } else {
        demo_resample_audio(audio, 48000)
      },
    )
  } else {
    None
  }
  demo_mux_mp4(codec, config, width, height, packets, durations, audio)
}
