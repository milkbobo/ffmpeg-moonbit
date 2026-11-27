///|
fn ts_truehd_major_sync(data : Bytes, pos : Int32) -> Bool {
  data.length() - pos >= 8 && data[pos + 4:pos + 8] == b"\xf8\x72\x6f\xba"[:]
}

///|
/// A capture can start between major syncs. Start the frame index at a
/// decodable restart unit and remember its source offset for PES timestamps.
fn playback_ts_index_truehd(
  demux : TsDemux,
  stream_index : Int32,
  output : Map[Int32, TsAudioPes],
) -> (Int32, Int32)? {
  let (es, pes) = ts_join_audio_pes(demux, stream_index)
  for first in 0..<(es.length() - 7) {
    if !ts_truehd_major_sync(es, first) {
      continue
    }
    let size = @libavcodec.mlp_access_unit_size(es[first:])
    if size < 8 || size > es.length() - first {
      continue
    }
    let decoder = @libavcodec.MlpDecoder::new(true)
    guard decoder.decode_packet(es[first:first + size].to_owned())
      is Ok(Some(info)) else {
      continue
    }
    let samples = info.samples.length() / info.channels
    let frames : Array[TsAudioFrame] = []
    let mut pos = first
    while pos < es.length() {
      let size = @libavcodec.mlp_access_unit_size(es[pos:])
      if size < 4 || size > es.length() - pos {
        break
      }
      let end = pos + size
      frames.push({
        start: pos,
        end,
        data: es[pos:end].to_owned(),
        samples,
        keyframe: ts_truehd_major_sync(es, pos),
      })
      pos = end
    }
    ts_index_audio_frames(
      demux,
      stream_index,
      info.sample_rate,
      pes,
      frames,
      output,
      floor_duration=true,
    )
    return Some((info.sample_rate, info.channels))
  }
  None
}
