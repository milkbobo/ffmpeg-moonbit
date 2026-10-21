///|
/// MP4 demux -> ASC/PCE bootstrap -> raw AAC-LC packets -> PCM, compared
/// to FFmpeg 9.0.2 and ffprobe. References retain complete encoded frames
/// (-flags2 +skip_manual), so no second priming offset is applied.
/// LGPL-2.1-or-later.
fn aac_check_asc_mp4(
  movie_b64 : Bytes,
  config_b64 : Bytes,
  pcm_b64 : Bytes,
  packets : Array[(Int64, UInt32)],
  positions : Array[Int32],
  frame_length~ : Int32 = 1024,
) -> Unit raise {
  let data = @libavutil.av_base64_decode(movie_b64, 16384).unwrap()
  let asc = @libavutil.av_base64_decode(config_b64, 1024).unwrap()
  let pcm = @libavutil.av_base64_decode(pcm_b64, 196608).unwrap()
  let movie = av_mov_open(data).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.extradata.unwrap(), asc)
  assert_eq(track.channels.reinterpret_as_int(), positions.length())
  assert_eq(track.sample_rate, 48000U)
  assert_eq(track.frame_length, frame_length)
  assert_eq(track.samples.length(), packets.length())
  let parameters = mp4_track_codec_parameters(track)
  assert_true(parameters.extradata_parsed)
  assert_eq(parameters.channels, positions.length())
  assert_eq(parameters.sample_rate, 48000)
  assert_eq(parameters.frame_size, frame_length)
  // Also exercise the container-independent bridge with no channel-count
  // fallback, as used by Matroska's CodecPrivate path.
  let parameters = codec_parameters_from_extradata("aac", Some(asc), 0, 0, 0, 0)
  assert_true(parameters.extradata_parsed)
  assert_eq(parameters.channels, positions.length())
  let decoder = @libavcodec.new_aac_decoder_from_asc(asc).unwrap()
  assert_eq(decoder.layout.map(channel => channel.position), positions)
  assert_eq(decoder.config.channels, positions.length())
  let mut max_diff = 0
  let mut exact = 0
  for frame = 0; frame < track.samples.length(); frame = frame + 1 {
    let sample = track.samples[frame]
    let (offset, size) = packets[frame]
    assert_eq(sample.offset, offset)
    assert_eq(sample.size, size)
    let start = sample.offset.to_int()
    let out = decoder
      .decode_frame(
        data
        .clamped_view(start~, end=start + sample.size.reinterpret_as_int())
        .to_owned(),
      )
      .unwrap()
    assert_eq(out.length(), positions.length())
    for channel = 0; channel < out.length(); channel = channel + 1 {
      assert_eq(out[channel].samples.length(), frame_length)
      for i = 0; i < frame_length; i = i + 1 {
        let index = ((frame * frame_length + i) * out.length() + channel) * 2
        assert_true(index + 1 < pcm.length())
        let raw = pcm[index].to_int() | (pcm[index + 1].to_int() << 8)
        let want = if raw >= 32768 { raw - 65536 } else { raw }
        let x = out[channel].samples[i]
        assert_true(x.abs() < 1.0)
        let got = (x * 32768.0).round().to_int()
        let diff = if got > want { got - want } else { want - got }
        if diff > max_diff {
          max_diff = diff
        }
        if diff == 0 {
          exact = exact + 1
        }
      }
    }
  }
  let samples = track.samples.length() * frame_length * positions.length()
  assert_eq(samples * 2, pcm.length())
  assert_true(max_diff <= 1)
  assert_true(exact * 1000 >= samples * 999)
}

///|
test "aac ASC: indexed MP4 stereo bootstraps and matches FFmpeg PCM" {
  aac_check_asc_mp4(
    aac_asc_stereo_mp4_b64,
    aac_asc_stereo_config_b64,
    aac_asc_stereo_pcm_b64,
    aac_asc_stereo_packets,
    [0, 1],
  )
}

///|
test "aac ASC: MP4 PCE-only 5.1 populates metadata and decodes raw packets" {
  aac_check_asc_mp4(
    aac_asc_pce51_mp4_b64,
    aac_asc_pce51_config_b64,
    aac_asc_pce51_pcm_b64,
    aac_asc_pce51_packets,
    [0, 1, 2, 3, 4, 5],
  )
}

///|
test "aac ASC: MP4 PCE-only 7.1 populates metadata and decodes raw packets" {
  aac_check_asc_mp4(
    aac_asc_pce71_mp4_b64,
    aac_asc_pce71_config_b64,
    aac_asc_pce71_pcm_b64,
    aac_asc_pce71_packets,
    [0, 1, 2, 3, 4, 5, 9, 10],
  )
}

///|
test "aac ASC: malformed PCE extradata preserves container fallback parameters" {
  let asc = @libavutil.av_base64_decode(aac_asc_pce51_config_b64, 1024).unwrap()
  // Keep the generic AAC header but truncate PCE before its comment length.
  let truncated = asc.clamped_view(end=9).to_owned()
  let parameters = codec_parameters_from_extradata(
    "aac",
    Some(truncated),
    0,
    0,
    32000,
    7,
  )
  assert_true(!parameters.extradata_parsed)
  assert_eq(parameters.sample_rate, 32000)
  assert_eq(parameters.channels, 7)
  assert_eq(parameters.profile, 0)
}
