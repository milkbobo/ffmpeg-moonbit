///|
/// End-to-end decode of the TS writer's HEVC + MP3 output: the muxer's own
/// elementary payloads are demuxed back and decoded, and the framemd5/PCM
/// hashes match FFmpeg 9.0.2 decoding the elementary streams (which itself
/// was checked to equal FFmpeg decoding the emitted `.ts`).

///|
fn ts_mux_decode_md5(yuv : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, yuv, yuv.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
test "ts muxer: HEVC/MP3 output decodes to FFmpeg references" {
  let video : Array[Bytes] = []
  for b in ts_hevc_au_b64 {
    video.push(@libavutil.av_base64_decode(b, 4096).unwrap())
  }
  let audio : Array[Bytes] = []
  for b in ts_mp3_frame_b64 {
    audio.push(@libavutil.av_base64_decode(b, 512).unwrap())
  }
  let mux = ts_muxer_new(video_stream_type=0x24, audio_stream_type=0x03)
  for i, au in video {
    mux.write_video(i.to_int64() * 9000L, au)
  }
  let audio_pts = [0L, 2351L, 4702L, 7053L]
  for j, fr in audio {
    mux.write_audio(audio_pts[j], fr)
  }
  let bytes = mux.finish()
  let demux = av_mpegts_open(bytes).unwrap()
  let video_stream : Array[Byte] = []
  let audio_stream : Array[Byte] = []
  for packet in demux.packets {
    if packet.pid == 0x100 {
      for b in packet.payload {
        video_stream.push(b)
      }
    } else if packet.pid == 0x101 {
      for b in packet.payload {
        audio_stream.push(b)
      }
    }
  }
  let frames = @libavcodec.ff_hevc_decode_frames(
    Bytes::from_array(video_stream),
    false,
    0,
  ).unwrap()
  let sorted = frames.copy()
  sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  let expected = [
    "7fbf921cf1f680c20ff78bbbb21d23dd", "7520cf7cac4a6700507ed4c67520f67b", "cd002e07bc26c9ca6dc8efafe06c9454",
  ]
  assert_eq(sorted.length(), 3)
  for i = 0; i < expected.length(); i = i + 1 {
    assert_eq(ts_mux_decode_md5(sorted[i].yuvp(8)), expected[i])
  }
  let pcm = @libavcodec.decode_mp3_stream(Bytes::from_array(audio_stream)).unwrap()
  assert_eq(
    ts_mux_decode_md5(pcm.pcm_bytes()),
    "5d4390204e323f95f419174d5276c9dd",
  )
}
