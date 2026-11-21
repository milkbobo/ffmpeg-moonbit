// 白盒：U+0100 编码全 256 字节值双向无损 + json_escape 的 RFC 8259 覆盖。

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
fn demo_test_video() -> Bytes raise {
  let y = Bytes::from_array(Array::make(64 * 64, b'\x50'))
  let uv = Bytes::from_array(Array::make(32 * 32, b'\x80'))
  let source_encoder = demo_video_encoder("h264", 64, 64)
  let units = source_encoder.push((y, uv, uv))
  units.append(source_encoder.finish())
  let config = demo_decoder_config(demo_annexb_nals(units[0]), false)
  let keyframe = demo_mp4_packet(units[0], false)
  let packets = [keyframe, keyframe]
  demo_mux_mp4("h264", config, 64, 64, packets, [3000, 3000], None)
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
