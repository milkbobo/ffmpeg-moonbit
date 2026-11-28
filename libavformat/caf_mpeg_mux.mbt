///|
fn caf_mpeg_header(
  data : Bytes,
  start : Int32,
  size : Int32,
) -> @libavcodec.MpaStreamInfo? {
  guard size >= 4 else { return None }
  let word = rb32(data, start)
  guard @libavcodec.avpriv_mpegaudio_decode_header(word) is Ok(header) &&
    !header.free_format &&
    header.frame_size == size &&
    @libavcodec.ff_mpa_decode_header(word) is Ok(info) else {
    return None
  }
  Some(info)
}

///|
/// Wrap native MPEG Layer I, II or III frames in CAF. When explicit sample
/// counts are absent, use the gapless timing from a leading MP3 Xing/Info tag.
pub fn av_caf_mux_mpeg_audio(
  data : Bytes,
  priming? : Int32,
  valid_frames? : Int64,
) -> Result[Bytes, String] {
  let track = match av_mp3_open(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let (source_head, source_tail) = mpeg_audio_gapless(data, track)
  let head = priming.unwrap_or(source_head)
  let available = track.total_samples - head.to_int64()
  let valid = valid_frames.unwrap_or(available - source_tail.to_int64())
  guard head >= 0 && valid > 0L && valid <= available else {
    return Err("caf: invalid MPEG audio presentation length")
  }
  let start = track.frames[0].pos.to_int()
  let end = if data.length() >= 128 &&
    data[data.length() - 128:data.length() - 125] == b"TAG"[:] {
    data.length() - 128
  } else {
    data.length()
  }
  let last = track.frames[track.frames.length() - 1]
  guard start == track.id3v2_size + track.info_frame_size &&
    last.pos + last.size.to_int64() == end.to_int64() else {
    return Err("caf: noncontiguous or truncated MPEG audio")
  }
  // A CAF remainder can trim the last packet. Omit whole trailing packets
  // whose samples all lie beyond the end of the presentation.
  let block = track.frame_size.to_int64()
  let coded = head.to_int64() + valid
  let count = ((coded + block - 1L) / block).to_int()
  guard count <= 16777216 else {
    return Err("caf: too many MPEG audio packets")
  }
  let pakt : Array[Byte] = []
  caf_mux_u64be(pakt, count.to_uint64())
  caf_mux_u64be(pakt, valid.reinterpret_as_uint64())
  caf_mux_u32be(pakt, head.reinterpret_as_uint())
  caf_mux_u32be(
    pakt,
    (count.to_int64() * block - coded).to_int().reinterpret_as_uint(),
  )
  let mut stop = start
  for i in 0..<count {
    let frame = track.frames[i]
    guard caf_mpeg_header(data, stop, frame.size) is Some(info) &&
      info.channels == track.channels else {
      return Err("caf: changing or invalid MPEG audio header")
    }
    caf_mux_descr_len(pakt, frame.size)
    stop += frame.size
  }
  let size = stop - start
  guard size.to_int64() + pakt.length().to_int64() <= 0x7fffffffL - 80L else {
    return Err("caf: MPEG audio output is too large")
  }
  let desc : Array[Byte] = []
  caf_mux_double(desc, track.sample_rate.to_double())
  caf_mux_tag(desc, "." + track.codec)
  caf_mux_u32be(desc, 0U)
  caf_mux_u32be(desc, 0U) // packet sizes vary with bitrate and padding
  caf_mux_u32be(desc, track.frame_size.reinterpret_as_uint())
  caf_mux_u32be(desc, track.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U)
  let out = b"caff\x00\x01\x00\x00".to_array()
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "pakt", pakt)
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, size.to_uint64() + 4UL)
  caf_mux_u32be(out, 0U)
  for byte in data[start:stop] {
    out.push(byte)
  }
  Ok(Bytes::from_array(out))
}

///|
/// Encode mono or stereo PCM as Layer II in CAF at the source sample rate.
pub fn DecodedAudio::to_caf_mp2(self : DecodedAudio) -> Bytes raise MediaError {
  let channels = self.channels
  guard channels == 1 || channels == 2 else {
    raise UnsupportedCodec("CAF MP2 export requires mono or stereo")
  }
  let encoder = match
    @libavcodec.mpa_encoder_new(
      @libavcodec.mpa_encode_config(
        self.sample_rate,
        channels,
        64000 * channels,
      ),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  self.encode_caf_mpeg(1152, 481, pcm => encoder.encode_frame(pcm), () => b"")
}

///|
/// Encode mono or stereo PCM as Layer III in CAF at the source sample rate.
pub fn DecodedAudio::to_caf_mp3(self : DecodedAudio) -> Bytes raise MediaError {
  let channels = self.channels
  guard channels == 1 || channels == 2 else {
    raise UnsupportedCodec("CAF MP3 export requires mono or stereo")
  }
  // Shine's MPEG-2.5 table ends at 64 kbit/s.
  let bit_rate = if self.sample_rate < 16000 { 64000 } else { 64000 * channels }
  let encoder = match
    @libavcodec.mp3_encoder_new(
      @libavcodec.mp3_encode_config(self.sample_rate, channels, bit_rate),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
  // Combined Shine analysis and Layer III synthesis delay, in PCM samples.
  self.encode_caf_mpeg(
    encoder.samples_per_pass(),
    1057,
    pcm => encoder.encode_frame(pcm),
    () => encoder.flush(),
  )
}

///|
fn DecodedAudio::encode_caf_mpeg(
  self : DecodedAudio,
  block : Int32,
  priming : Int32,
  encode : (Array[Int32]) -> Result[Bytes, String],
  flush : () -> Bytes,
) -> Bytes raise MediaError {
  let channels = self.channels
  let count = self.samples[0].length()
  guard count > 0 else { raise DecodeError("caf: no MPEG audio input samples") }
  let end = count.to_int64() + priming.to_int64()
  let raw : Array[Byte] = []
  for start = 0L; start < end; start = start + block.to_int64() {
    let remaining = (count.to_int64() - start).max(0L).to_int()
    let pcm = Array::makei(block * channels, i => {
      let frame = i / channels
      if frame < remaining {
        playback_pcm_quantize(
          self.samples[i % channels][start.to_int() + frame],
          16,
        )
      } else {
        0
      }
    })
    match encode(pcm) {
      Ok(packet) =>
        for byte in packet {
          raw.push(byte)
        }
      Err(error) => raise DecodeError(error)
    }
  }
  for byte in flush() {
    raw.push(byte)
  }
  match
    av_caf_mux_mpeg_audio(
      Bytes::from_array(raw),
      priming~,
      valid_frames=count.to_int64(),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
