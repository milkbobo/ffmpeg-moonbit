///|
priv enum PlaybackOggCodec {
  Vorbis
  Flac
}

///|
fn playback_ogg_codec(data : Bytes) -> PlaybackOggCodec? {
  guard data.length() >= 28 && data[26] != b'\x00' else { return None }
  let start = 27 + data[26].to_int()
  guard start + 7 <= data.length() else { return None }
  let first_segment = data[27].to_int()
  if first_segment >= 7 && data[start:start + 7].to_owned() == b"\x01vorbis" {
    Some(Vorbis)
  } else if first_segment >= 5 &&
    data[start:start + 5].to_owned() == b"\x7fFLAC" {
    Some(Flac)
  } else {
    None
  }
}

///|
fn playback_ogg_open(
  data : Bytes,
  format_name : String,
  codec : PlaybackOggCodec,
) -> MediaFile raise MediaError {
  let (source, name, rate, channels, extradata) = match codec {
    Vorbis => {
      let d = match av_ogg_vorbis_open(data) {
        Ok(value) => value
        Err(e) => raise DemuxError(e)
      }
      let lace : Array[Byte] = [b'\x02']
      for size in [d.id_header.length(), d.comment_header.length()] {
        for _ in 0..<(size / 255) {
          lace.push(b'\xff')
        }
        lace.push((size % 255).to_byte())
      }
      let extra = Bytes::from_array(lace) +
        d.id_header +
        d.comment_header +
        d.setup_header
      (OggVorbis(d), "vorbis", d.sample_rate, d.channels, extra)
    }
    Flac => {
      let d = match av_ogg_flac_open(data) {
        Ok(value) => value
        Err(e) => raise DemuxError(e)
      }
      (OggFlac(d), "flac", d.sample_rate, d.channels, d.streaminfo)
    }
  }
  {
    format_name,
    streams: [
      {
        index: 0,
        media_type: Audio,
        codec_id: name,
        sample_rate: rate,
        channels,
        width: 0,
        height: 0,
        extradata: Some(extradata),
      },
    ],
    source,
    cursor: [0],
  }
}

///|
fn playback_ogg_audio_decoder(
  info : StreamInfo,
) -> AudioDecoder raise MediaError {
  guard info.extradata is Some(extra) else {
    raise UnsupportedCodec(info.codec_id + " without extradata")
  }
  let dec : AudioDec = if info.codec_id == "flac" {
    AudioDec::Flac(extra)
  } else {
    guard extra.length() >= 3 && extra[0] == b'\x02' else {
      raise DecodeError("vorbis: invalid Xiph header lacing")
    }
    let sizes = FixedArray::make(2, 0)
    let mut cursor = 1
    for index in 0..<2 {
      while true {
        guard cursor < extra.length() else {
          raise DecodeError("vorbis: truncated Xiph header lacing")
        }
        let value = extra[cursor].to_int()
        sizes[index] = sizes[index] + value
        cursor = cursor + 1
        if value < 255 {
          break
        }
      }
    }
    guard sizes[0] <= extra.length() - cursor &&
      sizes[1] < extra.length() - cursor - sizes[0] else {
      raise DecodeError("vorbis: truncated Xiph headers")
    }
    let id = extra[cursor:cursor + sizes[0]].to_owned()
    let setup = extra[cursor + sizes[0] + sizes[1]:].to_owned()
    match @libavcodec.vorbis_decoder_new(id, setup) {
      Ok(value) => Vorbis(value, { val: -1, })
      Err(e) => raise DecodeError(e)
    }
  }
  { dec, channels: info.channels, sample_rate: info.sample_rate, }
}
