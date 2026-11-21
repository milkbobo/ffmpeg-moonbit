// 白盒：U+0100 编码全 256 字节值双向无损 + json_escape 的 RFC 8259 覆盖。

///|
test "audio analysis measures relative loudness and leading and trailing silence" {
  let rate = 48000
  let pcm = Array::make(2 * rate, 0.0)
  for i in (rate / 2)..<(rate * 3 / 2) {
    pcm[i] = 0.1 * @math.cos(i.to_double() * 3.141592653589793 / 24.0)
  }
  let result = analyze_pcm([pcm], rate)
  assert_true(result.contains("\"silence\":[[0,0.5],[1.5,2]]"))
  let mono = @avfilter.integrated_loudness([pcm], rate).unwrap()
  let stereo = @avfilter.integrated_loudness([pcm, pcm], rate).unwrap()
  // FFmpeg ebur128, with a 1 kHz tone between 0.5 s and 1.5 s, reports -24.1 LUFS.
  assert_true((mono + 24.1).abs() < 0.05)
  assert_true((stereo - mono - 3.01029995664).abs() < 0.00001)
  assert_eq(@avfilter.integrated_loudness([pcm, pcm, pcm], rate), None)
  assert_eq(@avfilter.integrated_loudness([Array::make(rate, 0.0)], rate), None)
}

///|
test "u0100: 全 256 字节值双向无损" {
  let all : Array[Byte] = []
  for i in 0..<256 {
    all.push(i.to_byte())
  }
  let b = Bytes::from_array(all)
  let s = bytes_to_u0100(b)
  inspect(s.length(), content="256")
  // 每个码元都落在 U+0100..U+01FF，JSON 字符串字面量合法区间
  for i in 0..<s.length() {
    let n = s[i].to_int()
    assert_true(n >= 0x100 && n <= 0x1FF)
  }
  let back = u0100_to_bytes(s)
  inspect(back.length(), content="256")
  for i in 0..<256 {
    assert_eq(back[i], b[i])
  }
}

///|
test "u0100: 空串往返" {
  inspect(bytes_to_u0100(b""), content="")
  inspect(u0100_to_bytes("").length(), content="0")
}

///|
test "json_escape: 引号、反斜杠与控制符" {
  // " \ \n \r \t 与 0x00
  let s = "a\"b\\c\nd\re\tf\u{0}g"
  inspect(json_escape(s), content="a\\\"b\\\\c\\nd\\re\\tf\\u0000g")
  // DEL(0x7F) 不需要转义，原样保留
  inspect(json_escape("\u{7F}"), content="\u{7F}")
}

///|
fn demo_test_video(
  duration~ : Int32 = 3000,
  luma~ : Byte = b'\x50',
) -> Bytes raise {
  let y = Bytes::from_array(Array::make(64 * 64, luma))
  let uv = Bytes::from_array(Array::make(32 * 32, b'\x80'))
  let source_encoder = demo_video_encoder("h264", 64, 64)
  let units = source_encoder.push((y, uv, uv))
  units.append(source_encoder.finish())
  let config = demo_decoder_config(demo_annexb_nals(units[0]), false)
  let keyframe = demo_mp4_packet(units[0], false)
  let packets = [keyframe, keyframe]
  demo_mux_mp4("h264", config, 64, 64, packets, [duration, duration], None)
}

///|
test "MP4 and MKV text subtitle extraction preserves gaps, times and Unicode" {
  let mov = @avf.mp4_subtitle_muxer_new(language="eng")
  let mkv = @avf.mkv_subtitle_muxer_new(language="eng")
  for
    (start, end, text) in [
      (500L, 1500L, "First"),
      (2000L, 2750L, "字幕\n第二行"),
    ] {
    mov.write_cue(start, end, text).unwrap()
    mkv.write_cue(start, end, text).unwrap()
  }
  let expected : Json = [
    {
      "index": 0,
      "language": "eng",
      "cues": [
        { "start": 0.5, "end": 1.5, "text": "First" },
        { "start": 2, "end": 2.75, "text": "字幕\n第二行" },
      ],
    },
  ]
  assert_eq(Json(demo_subtitle_tracks(mov.finish().unwrap())), expected)
  assert_eq(Json(demo_subtitle_tracks(mkv.finish())), expected)
}

///|
test "video diagnostics reports black and frozen ranges through EOF" {
  let issues = demo_video_issues(demo_test_video(duration=90000, luma=b'\x10'))
  let expected : Json = {
    "black": [[0, 2]],
    "frozen": [[0, 2]],
    "estimated": false,
  }
  assert_eq(issues, expected)
}

///|
test "HEVC batch rejects pictures beyond the pixel budget" {
  let input = demo_transcode_mp4(demo_test_video(), "hevc")
  let media = @avf.MediaFile::open(input)
  let decoder = @avf.VideoDecoder::open(media.streams()[0])
  while media.next_packet() is Some(packet) {
    ignore(decoder.decode(packet))
  }
  let status = try {
    ignore(decoder.finish_video(pixel_budget=4096L))
    "unexpected success"
  } catch {
    error => error.message()
  }
  assert_true(status.contains("batch pixel budget"))
}

///|
test "MP4 clip editing aligns to IDR boundaries and copies packet bytes" {
  let source = clip_open(demo_test_video(duration=90000))
  let (trimmed, start, end) = clip_edit([source], Some((1.2, 1.7)))
  assert_eq(start, 1.0)
  assert_eq(end, 2.0)
  let cut = clip_open(trimmed)
  assert_eq(cut.video.samples.length(), 1)
  let original = demo_video_sample(source.data, source.video.samples[1])
  assert_eq(demo_video_sample(cut.data, cut.video.samples[0]), original)
  let (joined, _, _) = clip_edit([source, source], None)
  let joined = clip_open(joined)
  assert_eq(joined.video.samples.length(), 4)
  assert_eq(joined.end - joined.origin, 360000L)
  for i in 0..<4 {
    assert_eq(
      demo_video_sample(joined.data, joined.video.samples[i]),
      demo_video_sample(source.data, source.video.samples[i % 2]),
    )
  }
}

///|
test "MP4 conversion encodes H.264 and HEVC video-only outputs" {
  let source = demo_test_video()
  for codec in ["h264", "hevc"] {
    let output = @avf.MediaFile::open(demo_transcode_mp4(source, codec))
    assert_eq(output.streams().length(), 1)
    let stream = output.streams()[0]
    assert_eq(stream.codec_id, codec)
    let decoder = @avf.VideoDecoder::open(stream)
    guard first_video_frame(output, decoder, stream.index) is Some(frame) else {
      fail("converted MP4 has no decodable video frame")
    }
    assert_eq((frame.width(), frame.height()), (64, 64))
  }
}

///|
test "Wasm player reads sequential frames, seeks forward and reaches EOF" {
  let source = bytes_to_u0100(demo_test_video())
  assert_true(ff_player_open(source).has_prefix("{\"ok\":true"))
  let first = ff_player_frame(0.0, 32)
  let second = ff_player_frame(0.04, 32)
  assert_true(first.contains("\"width\":32,\"height\":32"))
  assert_true(second.contains("\"width\":32,\"height\":32"))
  assert_eq(ff_player_frame(0.08, 32), "{\"ok\":true,\"eof\":true}")
  ignore(ff_player_open(source))
  ignore(ff_player_seek(0.04))
  guard demo_playback.val is Some(player) else { fail("player is not open") }
  assert_eq(player.first_packet, 1)
  assert_eq(ff_player_locate(0.04, 32), second)
  demo_playback.val = None
}

///|
test "preview converts little-endian 10-bit samples to 8-bit pixels" {
  let pixels = b"\x00\x00\x40\x00\x00\x02\xff\x03"
  assert_eq(preview_plane(pixels, 1, 3, 10), b"\x10\x80\xff")
}
