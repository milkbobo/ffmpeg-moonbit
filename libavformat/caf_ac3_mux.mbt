///|
/// AC-3 acmod to native speaker mask, in the decoder's sample order.
fn ac3_channel_mask(header : @libavcodec.Ac3Header) -> UInt32 {
  let base = match header.channel_mode {
    1 => 4U
    3 => 7U
    4 => 0x103U
    5 => 0x107U
    6 => 0x603U
    7 => 0x607U
    _ => 3U
  }
  base | (if header.lfe_on { 8U } else { 0U })
}

///|
/// Wrap contiguous AC-3 syncframes in CAF. Optional priming and valid frame
/// counts describe the PCM samples to skip before and after presentation.
pub fn av_caf_mux_ac3(
  data : Bytes,
  priming~ : Int32 = 0,
  valid_frames? : Int64,
) -> Result[Bytes, String] {
  let track = match ac3_open(data, fixed_format=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  guard track.codec == "ac3" && priming >= 0 && priming < 1536 else {
    return Err("caf: expected AC-3 and a valid priming count")
  }
  let frames = valid_frames.unwrap_or(track.total_samples - priming.to_int64())
  guard frames > 0L && frames <= track.total_samples - priming.to_int64() else {
    return Err("caf: invalid AC-3 presentation sample count")
  }
  let tail = track.total_samples - priming.to_int64() - frames
  guard tail < 1536L else { return Err("caf: invalid AC-3 tail padding") }
  let first = track.frames[0]
  let start = first.pos.to_int()
  let header = match
    @libavcodec.ac3_parse_header(data[start:start + first.size].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let lengths : Array[Byte] = []
  let mut end = start
  for packet in track.frames {
    guard packet.pos == end.to_int64() else {
      return Err("caf: AC-3 syncframes must be contiguous")
    }
    let prefix = data[end:end + packet.size.min(128)].to_owned()
    guard @libavcodec.ac3_parse_header(prefix) is Ok(current) &&
      current.channel_mode == header.channel_mode &&
      current.lfe_on == header.lfe_on else {
      return Err("caf: changing AC-3 channel layout")
    }
    caf_mux_descr_len(lengths, packet.size)
    end += packet.size
  }
  guard start == track.id3v2_size &&
    end == data.length() &&
    (end - start).to_int64() + lengths.length().to_int64() <= 0x7fffffffL - 128L else {
    return Err("caf: truncated, noncontiguous or oversized AC-3 data")
  }

  let desc : Array[Byte] = []
  caf_mux_double(desc, track.sample_rate.to_double())
  caf_mux_tag(desc, "ac-3")
  caf_mux_u32be(desc, 0U)
  caf_mux_u32be(desc, 0U) // frame sizes vary at 44.1 kHz
  caf_mux_u32be(desc, 1536U)
  caf_mux_u32be(desc, track.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U)
  let mask = ac3_channel_mask(header)
  let layout = match mask {
    4U => 0x00640001U
    3U => 0x00650002U
    7U => 0x00710003U
    0x103U => 0x00830003U
    0x107U => 0x00730004U
    0x603U => 0x00840004U
    0x607U => 0x00750005U
    0x60fU => 0x00790006U
    _ => 0x10000U
  }
  let chan : Array[Byte] = []
  caf_mux_u32be(chan, layout)
  caf_mux_u32be(chan, if layout == 0x10000U { mask } else { 0U })
  caf_mux_u32be(chan, 0U)
  let out = b"caff\x00\x01\x00\x00".to_array()
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "chan", chan)
  caf_mux_tag(out, "data")
  caf_mux_u64be(out, ((end - start).to_int64() + 4L).reinterpret_as_uint64())
  caf_mux_u32be(out, 0U)
  for byte in data[start:end] {
    out.push(byte)
  }
  let pakt : Array[Byte] = []
  caf_mux_u64be(pakt, track.frames.length().reinterpret_as_uint().to_uint64())
  caf_mux_u64be(pakt, frames.reinterpret_as_uint64())
  caf_mux_u32be(pakt, priming.reinterpret_as_uint())
  caf_mux_u32be(pakt, tail.to_int().reinterpret_as_uint())
  pakt.append(lengths)
  caf_mux_chunk(out, "pakt", pakt)
  Ok(Bytes::from_array(out))
}

///|
/// Encode PCM as AC-3 in CAF, with the encoder delay and padding in the packet table.
pub fn DecodedAudio::to_caf_ac3(self : DecodedAudio) -> Bytes raise MediaError {
  let raw = self.to_ac3()
  match
    av_caf_mux_ac3(
      raw,
      priming=ac3_pcm_priming,
      valid_frames=self.samples[0].length().to_int64(),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}

///|
let ac3_pcm_priming : Int32 = 256

///|
/// Encode planar PCM as raw AC-3 syncframes at the source sample rate.
/// The output includes 256 samples of encoder delay and final frame padding.
pub fn DecodedAudio::to_ac3(self : DecodedAudio) -> Bytes raise MediaError {
  let defaults : FixedArray[UInt32] = [4U, 3U, 7U, 0x107U, 0x607U, 0x60fU]
  guard self.channels >= 1 && self.channels <= defaults.length() else {
    raise UnsupportedCodec("AC-3 export requires 1–6 channels")
  }
  let channels = self.channels
  let mask = if self.channel_mask.popcnt() == channels {
    self.channel_mask
  } else {
    defaults[channels - 1]
  }
  let frames = self.samples[0].length()
  guard frames > 0 && frames <= 0x7fffffff - ac3_pcm_priming - 1535 else {
    raise DecodeError("ac3: invalid PCM length")
  }
  let padded = (frames + ac3_pcm_priming + 1535) / 1536 * 1536
  let pcm = self.samples.map(plane => {
    FixedArray::makei(padded, i => {
      if i < frames {
        playback_pcm_quantize(plane[i], 32)
      } else {
        0
      }
    })
  })
  match
    @libavcodec.ff_ac3_fixed_encode_stream(
      pcm,
      self.sample_rate,
      0,
      mask.reinterpret_as_int(),
    ) {
    Ok(value) => value
    Err(error) => raise DecodeError(error)
  }
}
