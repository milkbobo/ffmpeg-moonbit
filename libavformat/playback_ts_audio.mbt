///|
fn ts_uses_audio_index(codec : String) -> Bool {
  codec == "aac" || codec == "aac_latm" ||
  codec == "ac3" ||
  codec == "eac3" ||
  codec == "mp1" ||
  codec == "mp2" ||
  codec == "mp3"
}

///|
fn playback_ts_index_adts(
  demux : TsDemux,
  stream_index : Int32,
  output : Map[Int32, TsAudioPes],
) -> (Bytes, Int32, Int32) raise MediaError {
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  let track = match adts_open(es, for_playback=true) {
    Ok(v) => v
    Err(e) => raise DemuxError("mpegts: ADTS: " + e)
  }
  let (asc, multiplier, channels) = playback_adts_config(es, track.frames[0])
  // ADTS frame lengths count AAC core samples. SBR doubles both samples
  // and sample rate, so the transport frame duration remains unchanged.
  ts_index_audio_frames(
    demux, stream_index, track.sample_rate, pes, ts_slice_audio_frames(es, track.frames), output,
  )
  (asc, track.sample_rate * multiplier, channels)
}

///|
fn ts_stream_uses_audio_index(info : StreamInfo) -> Bool {
  ts_uses_audio_index(info.codec_id) ||
  ((info.codec_id == "dts" || info.codec_id == "opus" || info.codec_id == "truehd") &&
    info.sample_rate > 0)
}

///|
fn playback_ts_index_dts(
  demux : TsDemux,
  stream_index : Int32,
  output : Map[Int32, TsAudioPes],
) -> DtsTrack? {
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  guard av_dts_open(es) is Ok(track) else { return None }
  ts_index_audio_frames(
    demux, stream_index, track.sample_rate, pes, ts_slice_audio_frames(es, track.frames), output,
    floor_duration=true,
  )
  Some(track)
}

///|
/// Reassemble each LATM stream so LOAS frames and StreamMuxConfig can span PES packets.
fn playback_ts_index_latm(
  demux : TsDemux,
  stream_index : Int32,
  output : Map[Int32, TsAudioPes],
) -> (@libavcodec.Mpeg4AudioConfig, Bytes) raise MediaError {
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  let track = match @libavcodec.latm_parse_stream(es) {
    Ok(v) if !v.frames.is_empty() => v
    Ok(_) => raise DemuxError("mpegts: LATM stream without AAC access units")
    Err(e) => raise DemuxError("mpegts: " + e)
  }
  let config = match @libavcodec.aac_parse_audio_specific_config(track.asc) {
    Ok(v) => v.config
    Err(e) => raise DemuxError("mpegts: " + e)
  }
  let frames = track.frames.mapi((i, data) => {
    let (start, end) = track.frame_ranges[i]
    TsAudioFrame::{ start, end, data, samples: config.frame_length, keyframe: true, }
  })
  ts_index_audio_frames(
    demux,
    stream_index,
    config.sample_rate,
    pes,
    frames,
    output,
  )
  (config, track.asc)
}

///|
fn playback_ts_index_raw_audio(
  demux : TsDemux,
  stream_index : Int32,
  output : Map[Int32, TsAudioPes],
  codec : String,
) -> RawAudioTrack raise MediaError {
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  let opened = if codec == "mp1" || codec == "mp2" || codec == "mp3" {
    mpa_open(es, for_transport=true)
  } else {
    ac3_open(es, fixed_format=true)
  }
  let track = match opened {
    Ok(v) => v
    Err(e) => raise DemuxError("mpegts: " + e)
  }
  ts_index_audio_frames(
    demux, stream_index, track.sample_rate, pes, ts_slice_audio_frames(es, track.frames), output,
    floor_duration=true,
  )
  track
}

///|
fn ts_slice_audio_frames(es : Bytes, frames : Array[RawAudioFrame]) -> Array[TsAudioFrame] {
  frames.map(frame => {
    let start = frame.pos.to_int()
    let end = start + frame.size
    TsAudioFrame::{
      start,
      end,
      data: es[start:end].to_owned(),
      samples: frame.duration,
      keyframe: frame.is_keyframe,
    }
  })
}

///|
priv struct TsAudioFrame {
  start : Int32
  end : Int32
  data : Bytes
  samples : Int32
  keyframe : Bool
}

///|
fn ts_join_audio_pes(
  demux : TsDemux,
  stream_index : Int32,
) -> (Bytes, Array[(Int32, Int32)]) {
  let es : Array[Byte] = []
  let pes : Array[(Int32, Int32)] = []
  for i, p in demux.packets {
    if p.stream_index == stream_index && !p.payload.is_empty() {
      pes.push((i, es.length()))
      for byte in p.payload {
        es.push(byte)
      }
    }
  }
  (Bytes::from_array(es), pes)
}

///|
/// A PES timestamp applies to the first access unit that begins in it.
/// Emit each indexed access unit when its last PES becomes available.
fn ts_index_audio_frames(
  demux : TsDemux,
  stream_index : Int32,
  sample_rate : Int32,
  pes : Array[(Int32, Int32)],
  frames : Array[TsAudioFrame],
  output : Map[Int32, TsAudioPes],
  floor_duration~ : Bool = false,
) -> Unit {
  let clock = @libavutil.av_make_q(1, 90000)
  let mut start_pes = 0
  let mut end_pes = 0
  let mut last_start_pes = -1
  let mut pts = 0L
  for frame in frames {
    while start_pes + 1 < pes.length() && pes[start_pes + 1].1 <= frame.start {
      start_pes += 1
    }
    while end_pes + 1 < pes.length() && pes[end_pes + 1].1 < frame.end {
      end_pes += 1
    }
    if start_pes != last_start_pes {
      let p = demux.packets[pes[start_pes].0]
      if p.pts != ts_nopts {
        pts = p.pts
      } else if p.dts != ts_nopts {
        pts = p.dts
      }
      last_start_pes = start_pes
    }
    let target = pes[end_pes].0
    let batch = match output.get(target) {
      Some(batch) => batch
      None => {
        let batch : TsAudioPes = { packets: [], end_pts: ts_nopts, }
        output[target] = batch
        batch
      }
    }
    batch.packets.push({ stream_index, pts, data: frame.data, keyframe: frame.keyframe, })
    // FFmpeg advances Dolby, MPEG audio and DTS by whole transport ticks
    // rounded down from each frame duration. LATM keeps the rational duration.
    pts = if floor_duration {
      pts + frame.samples.to_int64() * 90000L / sample_rate.to_int64()
    } else {
      let frame_time = @libavutil.av_make_q(frame.samples, sample_rate)
      @libavutil.av_add_stable(clock, pts, frame_time, 1L)
    }
    batch.end_pts = pts
  }
}
