///|
/// MKV/HEVC muxer tests: emitted files are parsed back by `av_matroska_open`
/// and the read-back packets (4-byte length-prefixed NALs) decode to the same
/// frames as the source stream. The hvcC comes from ffmpeg's MP4 remux of the
/// same HM 16.8 stream.

///|
let mkv_hevc_stream_b64 : Bytes = b"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"

///|
let mkv_hevc_hvcc_b64 : Bytes = b"AQQIAAAADggAAAAAXfAA/P/4+AAADwMgAAEAF0ABDAH//wQIAAADAA4IAAADAABdlwJAIQABACxCAQEECAAAAwAOCAAAAwAAXZAEECD/LL3I2w8vJJJ/PP55f///5/P5+fztkCIAAQAJRAHBkJGBFgLg"

///|
let mkv_hevc_refs : Array[String] = [
  "29549224810d12835215ed747fe6f34a", "0104019f0da9da4b31f8b2b6846c5783", "e96f5fe27807f2b2f644262958a8ac91",
  "d7d00024914921f30bf09b4b0634e332", "bff8341416c0d957d37979f83ecf4c60",
]

///|
let mkv_hevc_unfiltered_refs : Array[String] = [
  "2da725a89a5cf9f585594036dfe94d9f", "947ff4fa7c13d9b91408d3ae17512e65", "7b90f47d27d28043926246d984ccd347",
  "0e6a92f76618b95e153d38f1b2fa33a3", "abd47734f7266a2eba099fcb9944e411",
]

///|
fn mkv_hevc_nals(data : Bytes) -> Array[Bytes] {
  let codes : Array[Int32] = []
  let n = data.length()
  let mut i = 0
  while i + 2 < n {
    if data[i] == b'\x00' && data[i + 1] == b'\x00' && data[i + 2] == b'\x01' {
      codes.push(i)
      i = i + 3
    } else {
      i = i + 1
    }
  }
  let out : Array[Bytes] = []
  for k = 0; k < codes.length(); k = k + 1 {
    let start = codes[k] + 3
    let mut stop = if k + 1 < codes.length() { codes[k + 1] } else { n }
    if stop > start && data[stop - 1] == b'\x00' {
      stop = stop - 1
    }
    if stop > start {
      out.push(data[start:stop].to_owned())
    }
  }
  out
}

///|
fn mkv_hevc_au_packets(data : Bytes) -> Array[Bytes] {
  let nals = mkv_hevc_nals(data)
  let aus : Array[Array[Bytes]] = []
  let mut cur : Array[Bytes] = []
  let mut cur_has_vcl = false
  for nal in nals {
    let nal_type = (nal[0].to_int() >> 1) & 0x3F
    let vcl = nal_type <= 31
    let first_slice = vcl && nal.length() > 2 && (nal[2].to_int() & 0x80) != 0
    if vcl && first_slice && cur_has_vcl {
      aus.push(cur)
      cur = []
      cur_has_vcl = false
    }
    cur.push(nal)
    if vcl {
      cur_has_vcl = true
    }
  }
  if cur.length() > 0 {
    aus.push(cur)
  }
  let packets : Array[Bytes] = []
  for au in aus {
    let buf : Array[Byte] = []
    for nal in au {
      let len = nal.length()
      buf.push(((len >> 24) & 0xFF).to_byte())
      buf.push(((len >> 16) & 0xFF).to_byte())
      buf.push(((len >> 8) & 0xFF).to_byte())
      buf.push((len & 0xFF).to_byte())
      for b in nal {
        buf.push(b)
      }
    }
    packets.push(Bytes::from_array(buf))
  }
  packets
}

///|
fn mkv_hevc_md5(yuv : Bytes) -> String {
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
test "mkv muxer: HEVC hvcC and decode round-trip" {
  let stream = @libavutil.av_base64_decode(mkv_hevc_stream_b64, 1000000).unwrap()
  let hvcc = @libavutil.av_base64_decode(mkv_hevc_hvcc_b64, 1024).unwrap()
  let packets = mkv_hevc_au_packets(stream)
  assert_eq(packets.length(), 5)
  let mux = mkv_hevc_muxer_new(64, 64, hvcc).unwrap()
  for i, packet in packets {
    mux.write_packet(packet, duration=33, keyframe=i == 0).unwrap()
  }
  let bytes = mux.finish()
  let mkv = match av_matroska_open(bytes) {
    Ok(v) => v
    Err(e) => fail("open failed: \{e}")
  }
  assert_false(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let track = mkv.tracks[0]
  assert_eq(track.codec_id.unwrap(), "V_MPEGH/ISO/HEVC")
  assert_eq(track.codec_priv.unwrap(), hvcc)
  assert_eq(track.video.pixel_width, 64UL)
  assert_eq(track.video.pixel_height, 64UL)
  assert_eq(mkv.packets.length(), 5)
  assert_eq(mkv.packets[0].pts, 0L)
  assert_eq(mkv.packets[1].pts, 33L)
  assert_eq(mkv.packets[4].pts, 132L)
  assert_true(mkv.packets[0].is_keyframe)
  assert_false(mkv.packets[1].is_keyframe)
  let all : Array[Byte] = []
  for packet in mkv.packets {
    for b in packet.data {
      all.push(b)
    }
  }
  let joined = Bytes::from_array(all)
  for filtered in [false, true] {
    let frames = @libavcodec.ff_hevc_decode_frames_ex(joined, true, 4, filtered).unwrap()
    let sorted = frames.copy()
    sorted.sort_by((a, b) => a.poc().compare(b.poc()))
    let expected = if filtered {
      mkv_hevc_refs
    } else {
      mkv_hevc_unfiltered_refs
    }
    assert_eq(sorted.length(), expected.length())
    for i = 0; i < expected.length(); i = i + 1 {
      let got = mkv_hevc_md5(sorted[i].yuvp(8))
      assert_eq(got, expected[i], msg="frame \{i} filtered=\{filtered}")
    }
  }
}
