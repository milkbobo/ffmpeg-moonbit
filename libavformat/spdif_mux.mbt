///|
/// IEC 61937 wrapping adapted from FFmpeg `libavformat/spdifenc.c`
/// (LGPL-2.1-or-later, copyright Bartlomiej Wolowiec, Anssi Hannula,
/// and Carl Eugen Hoyos).
fn spdif_write_burst(
  out : Array[Byte],
  payload : BytesView,
  kind : Int32,
  big_endian~ : Bool,
  payload_little_endian~ : Bool = false,
) -> Result[Unit, String] {
  let data_type = kind & 0xff
  let period = if data_type == 0x16 {
    spdif_mat_burst_size
  } else {
    guard spdif_burst_period(kind) is Some(period) else {
      return Err("spdif: unsupported burst type")
    }
    period
  }
  let size = payload.length()
  let aligned_size = (size + 1) & -2
  guard aligned_size <= period - 8 else {
    return Err("spdif: payload exceeds burst capacity")
  }
  let length_code = match data_type {
    // Align the preamble plus the type IV payload to 16 bytes.
    0x11 => ((size + 8 + 15) & -16) - 8
    0x15 | 0x16 => size
    _ => aligned_size * 8
  }
  guard length_code <= 0xffff else {
    return Err("spdif: payload exceeds length field")
  }
  guard out.length() <= 0x7fffffff - period else {
    return Err("spdif: output too large")
  }
  wav_mux_w16(out, 0xf872, big_endian)
  wav_mux_w16(out, 0x4e1f, big_endian)
  wav_mux_w16(out, kind, big_endian)
  wav_mux_w16(out, length_code, big_endian)
  let swap = if big_endian == payload_little_endian { 1 } else { 0 }
  for i in 0..<(size & -2) {
    out.push(payload[i ^ swap])
  }
  if size % 2 != 0 {
    wav_mux_w16(out, payload[size - 1].to_int() << 8, big_endian)
  }
  for _ in 0..<(period - 8 - aligned_size) {
    out.push(0)
  }
  Ok(())
}

///|
/// Wrap contiguous AC-3, independent E-AC-3, DTS core, MPEG audio, or ADTS AAC
/// as IEC 61937. The default carrier is little-endian. E-AC-3 frames must fill
/// bursts of 1536 samples.
/// A positive `dtshd_rate` up to 768000 Hz writes DTS type IV.
/// It accepts 16-bit BE DTS cores with optional EXSS and uses the core alone
/// for packets whose extensions exceed the selected burst capacity.
/// `codec="truehd"` emits complete Dolby MAT bursts and omits any partial tail.
pub fn av_spdif_mux(
  data : Bytes,
  codec~ : String,
  big_endian~ : Bool = false,
  dtshd_rate~ : Int32 = 0,
) -> Result[Bytes, String] {
  if dtshd_rate != 0 {
    guard codec == "dts" && dtshd_rate > 0 && dtshd_rate <= 768000 else {
      return Err(
        "spdif: DTS type IV requires DTS and a carrier rate of 1 to 768000 Hz",
      )
    }
    return spdif_mux_dtshd(data, dtshd_rate, big_endian)
  }
  if codec == "truehd" {
    return spdif_mux_truehd(data, big_endian)
  }
  let indexed = match codec {
    "dts" => dts_open(data[:], max_tail_padding=0).map(track => track.frames)
    "aac" => adts_open(data, for_playback=false).map(track => track.frames)
    "ac3" | "eac3" =>
      match ac3_open(data, fixed_format=true) {
        Ok(track) if track.codec == codec => Ok(track.frames)
        Ok(_) => Err("spdif: stream does not match requested codec")
        Err(e) => Err(e)
      }
    "mp1" | "mp2" | "mp3" =>
      match mpa_open(data, for_transport=true) {
        Ok(track) if track.codec == codec => Ok(track.frames)
        Ok(_) => Err("spdif: stream does not match requested codec")
        Err(e) => Err(e)
      }
    _ => return Err("spdif: unsupported codec")
  }
  let frames = match indexed {
    Ok(frames) => frames
    Err(e) => return Err(e)
  }
  let out : Array[Byte] = []
  let mut end = 0
  let mut burst_start = 0
  let mut burst_samples = 0
  let mut aac_config = None
  for frame in frames {
    let start = end
    guard frame.pos == start.to_int64() else {
      return Err("spdif: expected contiguous frames")
    }
    end += frame.size
    let payload = data[start:end]
    let written = match codec {
      "ac3" => {
        let bitstream_mode = payload[5].to_int() & 7
        spdif_write_burst(
          out,
          payload,
          0x01 | (bitstream_mode << 8),
          big_endian~,
        )
      }
      "dts" => {
        let kind = match frame.duration {
          512 => 0x0b
          1024 => 0x0c
          2048 => 0x0d
          _ => return Err("spdif: unsupported DTS frame duration")
        }
        let payload_little_endian = match payload {
          [0xfe, 0x7f, 0x01, 0x80, ..] | [0xff, 0x1f, 0x00, 0xe8, ..] => true
          _ => false
        }
        spdif_write_burst(
          out,
          payload,
          kind,
          big_endian~,
          payload_little_endian~,
        )
      }
      "eac3" => {
        burst_samples += frame.duration
        guard burst_samples <= 1536 else {
          return Err("spdif: E-AC-3 frames exceed burst duration")
        }
        if burst_samples < 1536 {
          continue
        }
        let written = spdif_write_burst(
          out,
          data[burst_start:end],
          0x15,
          big_endian~,
        )
        burst_samples = 0
        burst_start = end
        written
      }
      "aac" => {
        let prefix = payload[:@libavcodec.av_aac_adts_header_size].to_owned()
        guard spdif_adts_header(prefix) is Some(header) &&
          spdif_aac_kind(header.num_aac_frames) is Some(kind) else {
          return Err("spdif: unsupported ADTS header")
        }
        let config = (header.sample_rate, header.chan_config)
        if aac_config is Some(first) && config != first {
          return Err("spdif: changing ADTS stream format")
        }
        aac_config = Some(config)
        spdif_write_burst(out, payload, kind, big_endian~)
      }
      _ =>
        spdif_write_burst(out, payload, spdif_mpeg_kind(payload), big_endian~)
    }
    if written is Err(e) {
      return Err(e)
    }
  }
  guard end == data.length() else { return Err("spdif: trailing coded data") }
  guard burst_samples == 0 else { return Err("spdif: incomplete E-AC-3 burst") }
  Ok(Bytes::from_array(out))
}
