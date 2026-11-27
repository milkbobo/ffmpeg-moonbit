///|
/// Byte offsets from the IEC preamble to each MAT data band.
let spdif_mat_first_data : Int32 = 28

///|
let spdif_mat_second_data : Int32 = 30728

///|
let spdif_mat_band_size : Int32 = 30688

///|
fn spdif_mat_endian(data : BytesView, pos : Int32) -> Bool? {
  guard data.length() - pos >= 8 + spdif_mat_payload_size &&
    spdif_preamble_endian(data, pos) is Some(big_endian) &&
    (wav_u16(data, pos + 4, big_endian) & 0xff) == 0x16 &&
    wav_u16(data, pos + 6, big_endian) == spdif_mat_payload_size else {
    return None
  }
  let swap = if big_endian { 0 } else { 1 }
  for (offset, marker) in spdif_mat_markers {
    for i in 0..<marker.length() {
      if data[pos + 8 + offset + (i ^ swap)] != marker[i] {
        return None
      }
    }
  }
  Some(big_endian)
}

///|
/// A view of the two data bands in each burst, without MAT markers.
priv struct SpdifMatData {
  source : BytesView
  start : Int32
  big_endian : Bool
}

///|
fn SpdifMatData::file_pos(self : SpdifMatData, offset : Int32) -> Int32 {
  let band = offset / spdif_mat_band_size
  let base = if band % 2 == 0 {
    spdif_mat_first_data
  } else {
    spdif_mat_second_data
  }
  self.start +
  band / 2 * spdif_mat_burst_size +
  base +
  offset % spdif_mat_band_size
}

///|
fn SpdifMatData::coded_byte(self : SpdifMatData, offset : Int32) -> Byte {
  self.source[self.file_pos(if self.big_endian { offset } else { offset ^ 1 })]
}

///|
fn SpdifMatData::unit_size(self : SpdifMatData, offset : Int32) -> Int32 {
  let pos = self.file_pos(offset)
  (wav_u16(self.source, pos, self.big_endian) & 0xfff) * 2
}

///|
fn SpdifMatData::major_sync(self : SpdifMatData, offset : Int32) -> Bool {
  self.coded_byte(offset + 4) == 0xf8 &&
  self.coded_byte(offset + 5) == 0x72 &&
  self.coded_byte(offset + 6) == 0x6f &&
  self.coded_byte(offset + 7) == 0xba
}

///|
fn SpdifMatData::read(
  self : SpdifMatData,
  offset : Int32,
  size : Int32,
) -> Bytes {
  if size <= spdif_mat_band_size - offset % spdif_mat_band_size {
    let pos = self.file_pos(offset)
    let view = self.source[pos:pos + size]
    if self.big_endian {
      view.to_owned()
    } else {
      spdif_swap_words(view, size)
    }
  } else {
    Bytes::makei(size, i => self.coded_byte(offset + i))
  }
}

///|
fn spdif_mat_packet_data(
  source : BytesView,
  start : Int32,
  big_endian : Bool,
  packet_pos : Int64,
  size : Int32,
) -> Result[Bytes, String] {
  guard start >= 0 &&
    packet_pos >= start.to_int64() &&
    packet_pos < source.length().to_int64() &&
    size > 0 &&
    size % 2 == 0 else {
    return Err("spdif: invalid TrueHD MAT packet span")
  }
  let pos = packet_pos.to_int() - start
  guard pos % 2 == 0 else {
    return Err("spdif: invalid TrueHD MAT packet span")
  }
  let inside = pos % spdif_mat_burst_size
  let band_offset = if inside >= spdif_mat_first_data &&
    inside < spdif_mat_first_data + spdif_mat_band_size {
    inside - spdif_mat_first_data
  } else if inside >= spdif_mat_second_data &&
    inside < spdif_mat_second_data + spdif_mat_band_size {
    inside - spdif_mat_second_data + spdif_mat_band_size
  } else {
    return Err("spdif: packet begins outside a TrueHD MAT data band")
  }
  let offset = pos / spdif_mat_burst_size * 2 * spdif_mat_band_size +
    band_offset
  let bursts = (source.length().to_int64() - start.to_int64() + 8L) /
    spdif_mat_burst_size.to_int64()
  guard offset.to_int64() + size.to_int64() <=
    bursts * (2 * spdif_mat_band_size).to_int64() else {
    return Err("spdif: TrueHD MAT packet extends past end of file")
  }
  let mat : SpdifMatData = { source, start, big_endian, }
  Ok(mat.read(offset, size))
}

///|
fn SpdifMatData::find_sync(
  self : SpdifMatData,
  limit : Int32,
) -> (Int32, Int32, Int32, Int32)? {
  for offset = 0; offset <= limit - 10; offset = offset + 2 {
    if self.major_sync(offset) {
      let size = self.unit_size(offset)
      if size >= 10 && size <= limit - offset {
        let decoder = @libavcodec.MlpDecoder::new(true)
        if decoder.decode_packet(self.read(offset, size)) is Ok(Some(audio)) {
          return Some(
            (
              offset,
              audio.sample_rate,
              audio.channels,
              audio.samples.length() / audio.channels,
            ),
          )
        }
      }
    }
  }
  None
}

///|
fn spdif_index_mat(
  source : BytesView,
  start : Int32,
  big_endian : Bool,
  wave_padding~ : Int32?,
) -> Result[SpdifTrack, String] {
  let mut bursts = 0
  let mut end = start
  while end < source.length() {
    let remaining = source.length() - end
    if wave_padding is Some(limit) &&
      remaining <= limit &&
      source[end:].iter().all(byte => byte == 0) {
      break
    }
    guard spdif_mat_endian(source, end) == Some(big_endian) &&
      (wave_padding is None || remaining >= spdif_mat_burst_size) else {
      return Err("spdif: invalid or truncated TrueHD MAT burst")
    }
    bursts += 1
    end += remaining.min(spdif_mat_burst_size)
  }
  if wave_padding is Some(_) && bursts < 2 {
    return Err("spdif: expected at least two WAV bursts")
  }
  let mat : SpdifMatData = { source, start, big_endian, }
  let length = bursts * 2 * spdif_mat_band_size
  guard mat.find_sync(length) is Some((first, sample_rate, channels, samples)) else {
    return Err("spdif: TrueHD MAT has no decodable major sync")
  }
  let frames : Array[RawAudioFrame] = []
  let mut pts = 0L
  for offset = first; offset < length; {
    let size = mat.unit_size(offset)
    if size == 0 {
      continue offset + 2
    }
    guard size >= 10 else {
      return Err("spdif: invalid TrueHD MAT access unit")
    }
    if size > length - offset {
      break // A final access unit can cross into a burst the writer never emitted.
    }
    frames.push({
      pos: mat.file_pos(offset).to_int64(),
      size,
      pts,
      duration: samples,
      is_keyframe: mat.major_sync(offset),
    })
    pts += samples.to_int64()
    continue offset + size
  }
  Ok({
    codec: "truehd",
    sample_rate,
    channels,
    frames,
    total_samples: pts,
    big_endian,
    data_end: end,
    mat_start: Some(start),
  })
}
