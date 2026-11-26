///|
let wsaud_snd1_fixture = b"IlYsAAAAIAAAAAABDgAXAK/eAAAB5BtB8KavtIL+CP+vxAIABQCv3gAAocMEAAQAr94AAACA/3I="

///|
let wsaud_stereo_fixture = b"IlYgAAAAQAAAAANjCAAgAK/eAABwd3d3d5d3/wgAIACv3gAAqRPcAby5q8w="

///|
/// References from FFmpeg 9.0.2. IMA includes two shortened chunks from
/// the FATE excellent.aud sample and from an FFmpeg-encoded stereo file.
/// The SND1 payload exercises both ADPCM widths, deltas, literals and runs.
test "Westwood AUD IMA and SND1 playback match FFmpeg PCM" {
  for (encoded, codec, channels, durations, md5) in [
    (
      b"IlYgAAAAQAAAAAJjCAAgAK/eAABvx4qBjjPZUQgAIACv3gAASNooBI2BmOs=",
      "adpcm_ima_ws", 1, [16, 16], "8585f27d33193c81762a261277c217b4",
    ),
    (
      wsaud_stereo_fixture, "adpcm_ima_ws", 2, [8, 8], "037be432df98827f4e6890cb9e997655",
    ),
    (
      wsaud_snd1_fixture, "ws_snd1", 1, [23, 5, 4], "7d2379d53adf64672e2bc43d60975b55",
    ),
  ] {
    let file = @libavutil.av_base64_decode(encoded, 256).unwrap()
    let demux = av_wsaud_open(file).unwrap()
    assert_eq(demux.frames.map(p => p.duration), durations)
    let mut pts = 0L
    for p in demux.frames {
      assert_eq(p.pts, pts)
      pts += p.duration.to_int64()
    }
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, "wsaud")
    assert_eq(audio.codec_id, codec)
    assert_eq(audio.channels, channels)
    assert_eq(audio.sample_rate, 22050)
    assert_eq(audio.read_error, "")
    let wave = audio.to_wav_s16()
    let wav = av_wav_open(wave).unwrap()
    assert_eq(wav.data_size, pts * channels.to_int64() * 2L)
    assert_eq(caf_md5(wave[wav.data_offset.to_int():].to_owned()), md5)
  }
}

///|
test "Westwood AUD preserves SND1 packet headers and ignores incomplete stereo pairs" {
  let file = @libavutil.av_base64_decode(wsaud_snd1_fixture, 256).unwrap()
  let media = MediaFile::open(file)
  let first = media.next_packet().unwrap()
  assert_eq(first.data[:4].to_owned(), b"\x17\x00\x0e\x00")
  assert_eq(media.next_packet().unwrap().pts, 23L)
  assert_eq(media.next_packet().unwrap().pts, 28L)
  assert_true(
    av_wsaud_open(file[:file.length() - 1].to_owned()) is Err("wsaud: invalid chunk size"),
  )
  assert_true(
    @libavcodec.decode_ws_snd1(b"\x04\x00\x02\x00\x82\x00")
    is Err("ws_snd1: invalid command length"),
  )
  assert_eq(@libavcodec.decode_ws_snd1(b"\x02\x00\x02\x00\x00\x80").unwrap(), [-32768, 0])

  let stereo = @libavutil.av_base64_decode(wsaud_stereo_fixture, 256).unwrap()
  let odd = stereo.to_array()
  odd[2] = 33
  odd[28] = 9
  odd.push(0xff)
  let audio = decode_audio_file(Bytes::from_array(odd))
  assert_eq(audio.samples, decode_audio_file(stereo).samples)
}
