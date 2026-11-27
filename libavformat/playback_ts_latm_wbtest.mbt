///|
test "TS LATM access units can cross PES boundaries without losing timestamp anchors" {
  let data = @libavutil.av_base64_decode(loas_mono_b64, 1024).unwrap()
  let demux : TsDemux = {
    packet_size: 188,
    sync_offset: 0,
    programs: [],
    streams: [],
    pcrs: [],
    network_name: "",
    packets: [
      {
        stream_index: 0,
        pid: 256,
        pos: 0L,
        pts: 1000L,
        dts: ts_nopts,
        is_keyframe: false,
        payload: data[:2].to_owned(),
      },
      {
        stream_index: 0,
        pid: 256,
        pos: 188L,
        pts: 5000L,
        dts: ts_nopts,
        is_keyframe: false,
        payload: data[2:300].to_owned(),
      },
      {
        stream_index: 0,
        pid: 256,
        pos: 376L,
        pts: ts_nopts,
        dts: ts_nopts,
        is_keyframe: false,
        payload: data[300:].to_owned(),
      },
    ],
  }
  let batches : Map[Int32, TsAudioPes] = Map([])
  let (config, _) = playback_ts_index_latm(demux, 0, batches)
  assert_eq(config.sample_rate, 32000)
  assert_true(batches.get(0) is None)
  let frames0 = batches.get(1).unwrap()
  let frames1 = batches.get(2).unwrap()
  assert_eq(frames0.packets.map(p => p.pts), [1000L])
  assert_eq(frames1.packets.map(p => p.pts), [5000L, 7880L, 10760L])
  assert_eq(frames1.end_pts, 13640L)
  assert_eq(
    (frames0.packets + frames1.packets).map(p => p.data),
    @libavcodec.latm_parse_stream(data).unwrap().frames,
  )
}
