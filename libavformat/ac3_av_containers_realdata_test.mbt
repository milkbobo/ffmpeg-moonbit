///|
/// AC-3 A/V container tests: the real 64x48 x264 stream from the fMP4 tests
/// plus the AC-3 mono fixture are muxed as two tracks into MP4, MPEG-TS and
/// Matroska.  Files are parsed back (`av_mov_open`/`av_mpegts_open`/
/// `av_matroska_open`), the video payloads decode to the FFmpeg frame MD5s,
/// and external FFmpeg 9.0.2 decodes both streams byte-identically to the
/// raw streams.

///|
let av_h264_avcc_b64 : Bytes = b"AWQACv/hABdnZAAKrLII9gIgAAADACAAAAMCgeJEyQEABmjrw8siwP34+AA="

///|
let av_h264_samples_b64 : Bytes = b"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"

///|
let av_h264_sizes : Array[Int32] = [1555, 53, 65, 40, 26]

///|
let av_h264_refs : Array[String] = [
  "67209b5b9f9f453b541ba569d470bf06", "4c68e9b9ab2953cdecf58ec39bdcb731", "bb1a50b7f8162369de23870524586f00",
  "0b3917a80f0ad951e4b841f6de258213", "5f67aea83c2fccc3403eca53df9b2740",
]

///|
let av_ac3_b64 : Bytes = b"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"

///|
fn av_split_h264() -> Array[Bytes] {
  let joined = @libavutil.av_base64_decode(av_h264_samples_b64, 8192).unwrap()
  let out : Array[Bytes] = []
  let mut off = 0
  for size in av_h264_sizes {
    out.push(joined[off:off + size].to_owned())
    off = off + size
  }
  out
}

///|
fn av_split_ac3() -> Array[Bytes] {
  let data = @libavutil.av_base64_decode(av_ac3_b64, 100000).unwrap()
  let out : Array[Bytes] = []
  let mut pos = 0
  while pos + 8 <= data.length() {
    let hdr = @libavcodec.ac3_parse_header(data[pos:].to_owned()).unwrap()
    out.push(data[pos:pos + hdr.frame_size].to_owned())
    pos = pos + hdr.frame_size
  }
  out
}

///|
fn av_h264_avcc_params(avcc : Bytes) -> Bytes {
  let out : Array[Byte] = []
  let mut p = 6
  let num_sps = avcc[5].to_int() & 0x1F
  for _i = 0; _i < num_sps; _i = _i + 1 {
    let len = (avcc[p].to_int() << 8) | avcc[p + 1].to_int()
    p = p + 2
    out.push(((len >> 24) & 0xFF).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push((len & 0xFF).to_byte())
    for k = 0; k < len; k = k + 1 {
      out.push(avcc[p + k])
    }
    p = p + len
  }
  let num_pps = avcc[p].to_int()
  p = p + 1
  for _i = 0; _i < num_pps; _i = _i + 1 {
    let len = (avcc[p].to_int() << 8) | avcc[p + 1].to_int()
    p = p + 2
    out.push(((len >> 24) & 0xFF).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push((len & 0xFF).to_byte())
    for k = 0; k < len; k = k + 1 {
      out.push(avcc[p + k])
    }
    p = p + len
  }
  Bytes::from_array(out)
}

///|
fn av_h264_annexb(avcc : Bytes, samples : Array[Bytes]) -> Bytes {
  let nalu_len = (avcc[4].to_int() & 3) + 1
  let out : Array[Byte] = []
  for sample in samples {
    let mut p = 0
    while p + nalu_len <= sample.length() {
      let mut len = 0
      for k = 0; k < nalu_len; k = k + 1 {
        len = (len << 8) | sample[p + k].to_int()
      }
      p = p + nalu_len
      out.push(b'\x00')
      out.push(b'\x00')
      out.push(b'\x01')
      for k = 0; k < len; k = k + 1 {
        out.push(sample[p + k])
      }
      p = p + len
    }
  }
  Bytes::from_array(out)
}

///|
fn av_h264_md5(frame : @libavcodec.H264Frame) -> String {
  let yuv = frame.yuvp()
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
fn av_check_video(samples : Array[Bytes]) -> Unit raise {
  let payload : Array[Byte] = []
  for p in samples {
    for b in p {
      payload.push(b)
    }
  }
  let annexb = av_h264_annexb(
    @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap(),
    [
      av_h264_avcc_params(
        @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap(),
      ),
      Bytes::from_array(payload),
    ],
  )
  let dec = @libavcodec.new_h264_decoder()
  let frames = match dec.decode_annexb(annexb, false) {
    Ok(v) => @libavcodec.h264_display_order(v)
    Err(_) => fail("h264 decode failed")
  }
  assert_eq(frames.length(), 5)
  for i = 0; i < frames.length(); i = i + 1 {
    assert_eq(av_h264_md5(frames[i]), av_h264_refs[i])
  }
}

///|
test "A/V MP4: H.264 + AC-3 tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_ac3()
  let mux = @libavformat.mp4_av_ac3_muxer_new(64, 48, avcc, audio[0]).unwrap()
  for i, p in video {
    mux.write_video(p, duration=9000, keyframe=i == 0).unwrap()
  }
  for p in audio {
    mux.write_audio(p, duration=1536).unwrap()
  }
  let bytes = mux.finish()
  let movie = @libavformat.av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  let vt = movie.tracks[0]
  assert_eq(vt.codec, "avc1")
  assert_eq(vt.samples.length(), 5)
  let at = movie.tracks[1]
  assert_eq(at.codec, "ac-3")
  assert_eq(at.sample_rate, 48000U)
  assert_eq(at.channels, 1U)
  assert_eq(at.samples.length(), 4)
  for i, sample in at.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytes[start:end].to_owned(), audio[i])
  }
  av_check_video(video)
}

///|
test "A/V MPEG-TS: H.264 + AC-3 stream types" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_ac3()
  let ts = @libavformat.ts_muxer_new(
    video_stream_type=0x1B,
    audio_stream_type=0x81,
  )
  let video_au : Array[Bytes] = []
  let mut vpts = 0L
  for i, p in video {
    let list : Array[Bytes] = []
    if i == 0 {
      list.push(av_h264_avcc_params(avcc))
    }
    list.push(p)
    let au = av_h264_annexb(avcc, list)
    video_au.push(au)
    ts.write_video(vpts, au)
    vpts = vpts + 9000L
  }
  let mut apts = 0L
  for p in audio {
    ts.write_audio(apts, p)
    apts = apts + 2880L
  }
  let bytes = ts.finish()
  // PAT/PMT carry the byte-swapped MPEG-2 CRC used by mpegtsenc (FFmpeg
  // rejects the tables and falls back to payload probing otherwise). The SDT
  // occupies the first packet, so PAT/PMT start at 188/376.
  assert_eq(bytes[205:209].to_owned(), b"\x2a\xb1\x04\xb2")
  assert_eq(bytes[403:407].to_owned(), b"\xd1\xd7\xf4\xb8")
  let demux = @libavformat.av_mpegts_open(bytes).unwrap()
  assert_eq(demux.streams.length(), 2)
  let mut have_video = false
  let mut have_audio = false
  for s in demux.streams {
    if s.codec == "h264" {
      have_video = true
    }
    if s.codec == "ac3" {
      have_audio = true
    }
  }
  assert_true(have_video)
  assert_true(have_audio)
  let vpkts : Array[Bytes] = []
  let apkts : Array[Bytes] = []
  for packet in demux.packets {
    if packet.pid == 0x100 {
      vpkts.push(packet.payload)
    } else if packet.pid == 0x101 {
      apkts.push(packet.payload)
    }
  }
  assert_eq(vpkts.length(), 5)
  for i, p in vpkts {
    assert_eq(p, video_au[i])
  }
  assert_eq(apkts.length(), 4)
  for i, p in apkts {
    assert_eq(p, audio[i])
  }
  av_check_video(video)
}

///|
test "A/V Matroska: H.264 + AC-3 tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_ac3()
  let mux = @libavformat.mkv_av_ac3_muxer_new(64, 48, avcc, 48000, 1).unwrap()
  for i, p in video {
    mux.write_video(p, (i * 100).to_int64(), 100, keyframe=i == 0).unwrap()
  }
  for i, p in audio {
    mux.write_audio(p, (i * 32).to_int64(), 32).unwrap()
  }
  let mkv = @libavformat.av_matroska_open(mux.finish()).unwrap()
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_AC3")
  let mut vcount = 0
  let mut acount = 0
  for packet in mkv.packets {
    if packet.stream_index == 0 {
      assert_eq(packet.data, video[vcount])
      vcount = vcount + 1
    } else {
      assert_eq(packet.data, audio[acount])
      acount = acount + 1
    }
  }
  assert_eq(vcount, 5)
  assert_eq(acount, 4)
}

///|
let av_eac3_mono48_b64 : Bytes = b"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"

///|
fn av_split_eac3() -> Array[Bytes] {
  let data = @libavutil.av_base64_decode(av_eac3_mono48_b64, 100000).unwrap()
  let track = @libavformat.av_ac3_open(data).unwrap()
  let out : Array[Bytes] = []
  for frame in track.frames {
    let start = frame.pos.to_int()
    out.push(data[start:start + frame.size].to_owned())
  }
  out
}

///|
test "A/V MP4: H.264 + E-AC-3 tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_eac3()
  let mux = @libavformat.mp4_av_eac3_muxer_new(64, 48, avcc, audio[0]).unwrap()
  for i, p in video {
    mux.write_video(p, duration=9000, keyframe=i == 0).unwrap()
  }
  for p in audio {
    mux.write_audio(p, duration=1536).unwrap()
  }
  let bytes = mux.finish()
  let movie = @libavformat.av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 2)
  assert_eq(movie.tracks[0].codec, "avc1")
  let at = movie.tracks[1]
  assert_eq(at.codec, "ec-3")
  assert_eq(at.sample_rate, 48000U)
  assert_eq(at.channels, 1U)
  assert_eq(at.samples.length(), 4)
  for i, sample in at.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    assert_eq(bytes[start:end].to_owned(), audio[i])
  }
  av_check_video(video)
}

///|
test "A/V MPEG-TS: H.264 + E-AC-3 stream type 0x87" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_eac3()
  let ts = @libavformat.ts_muxer_new(
    video_stream_type=0x1B,
    audio_stream_type=0x87,
  )
  let mut vpts = 0L
  for i, p in video {
    let list : Array[Bytes] = []
    if i == 0 {
      list.push(av_h264_avcc_params(avcc))
    }
    list.push(p)
    ts.write_video(vpts, av_h264_annexb(avcc, list))
    vpts = vpts + 9000L
  }
  let mut apts = 0L
  for p in audio {
    ts.write_audio(apts, p)
    apts = apts + 2880L
  }
  let demux = @libavformat.av_mpegts_open(ts.finish()).unwrap()
  let codecs : Array[String] = []
  for s in demux.streams {
    codecs.push(s.codec)
  }
  assert_true(codecs.contains("h264"))
  assert_true(codecs.contains("eac3"))
  let apkts : Array[Bytes] = []
  for packet in demux.packets {
    if packet.pid == 0x101 {
      apkts.push(packet.payload)
    }
  }
  assert_eq(apkts.length(), 4)
  for i, p in apkts {
    assert_eq(p, audio[i])
  }
}

///|
test "A/V Matroska: H.264 + E-AC-3 tracks round-trip" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_eac3()
  let mux = @libavformat.mkv_av_eac3_muxer_new(64, 48, avcc, 48000, 1).unwrap()
  for i, p in video {
    mux.write_video(p, (i * 100).to_int64(), 100, keyframe=i == 0).unwrap()
  }
  for i, p in audio {
    mux.write_audio(p, (i * 32).to_int64(), 32).unwrap()
  }
  let mkv = @libavformat.av_matroska_open(mux.finish()).unwrap()
  assert_eq(mkv.tracks.length(), 2)
  assert_eq(mkv.tracks[0].codec_id.unwrap(), "V_MPEG4/ISO/AVC")
  assert_eq(mkv.tracks[1].codec_id.unwrap(), "A_EAC3")
  let mut acount = 0
  for packet in mkv.packets {
    if packet.stream_index == 1 {
      assert_eq(packet.data, audio[acount])
      acount = acount + 1
    }
  }
  assert_eq(acount, 4)
}

///|
test "A/V Matroska: H.264 + AC-3 + SRT subtitles" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_ac3()
  let mux = @libavformat.mkv_av_ac3_muxer_new(64, 48, avcc, 48000, 1).unwrap()
  for i, p in video {
    mux.write_video(p, (i * 100).to_int64(), 100, keyframe=i == 0).unwrap()
  }
  for i, p in audio {
    mux.write_audio(p, (i * 32).to_int64(), 32).unwrap()
  }
  mux.write_subtitle(50L, 150L, "First cue").unwrap()
  mux.write_subtitle(200L, 400L, "Second cue").unwrap()
  mux.set_tags([("TITLE", "Av Title"), ("ARTIST", "Av Artist")])
  mux.set_chapters([
    @libavformat.mkv_chapter_new(0L, Some(100000000L), "One"),
    @libavformat.mkv_chapter_new(100000000L, None, "Two"),
  ])
  let mkv = @libavformat.av_matroska_open(mux.finish()).unwrap()
  assert_eq(mkv.tracks.length(), 3)
  assert_eq(mkv.metadata.length(), 2)
  assert_eq(mkv.chapters.length(), 2)
  assert_eq(mkv.chapters[1].title, "Two")
  assert_eq(mkv.chapters[1].start_ns, 100000000L)
  assert_eq(mkv.tracks[2].track_type, 17UL)
  assert_eq(mkv.tracks[2].codec_id.unwrap(), "S_TEXT/UTF8")
  let subs : Array[@libavformat.MkvPacket] = []
  let mut vcount = 0
  let mut acount = 0
  for packet in mkv.packets {
    if packet.stream_index == 0 {
      assert_eq(packet.data, video[vcount])
      vcount = vcount + 1
    } else if packet.stream_index == 1 {
      assert_eq(packet.data, audio[acount])
      acount = acount + 1
    } else {
      subs.push(packet)
    }
  }
  assert_eq(vcount, 5)
  assert_eq(acount, 4)
  assert_eq(subs.length(), 2)
  assert_eq(subs[0].data, b"First cue")
  assert_eq(subs[0].pts, 50L)
  assert_eq(subs[0].duration, 100UL)
  assert_eq(subs[1].data, b"Second cue")
  assert_eq(subs[1].pts, 200L)
  assert_eq(subs[1].duration, 200UL)
  av_check_video(video)
}

///|
test "A/V MP4: H.264 + AC-3 + mov_text subtitles" {
  let avcc = @libavutil.av_base64_decode(av_h264_avcc_b64, 1024).unwrap()
  let video = av_split_h264()
  let audio = av_split_ac3()
  let mux = @libavformat.mp4_av_ac3_muxer_new(64, 48, avcc, audio[0]).unwrap()
  for i, p in video {
    mux.write_video(p, duration=9000, keyframe=i == 0).unwrap()
  }
  for p in audio {
    mux.write_audio(p, duration=1536).unwrap()
  }
  mux.write_subtitle(50L, 150L, "First cue").unwrap()
  mux.write_subtitle(200L, 400L, "Second cue").unwrap()
  mux.set_tags([("title", "Av Title"), ("artist", "Av Artist")])
  mux.set_chapters([
    @libavformat.mp4_chapter_new(0L, "One"),
    @libavformat.mp4_chapter_new(5000000L, "Two"),
  ])
  let bytes = mux.finish()
  let movie = @libavformat.av_mov_open(bytes).unwrap()
  assert_eq(movie.tracks.length(), 3)
  assert_eq(movie.metadata.length(), 2)
  assert_eq(movie.chapters.length(), 2)
  assert_eq(movie.chapters[1].title, "Two")
  assert_eq(movie.chapters[1].start_100ns, 5000000L)
  let st = movie.tracks[2]
  assert_eq(st.codec, "tx3g")
  assert_eq(st.timescale, 1000)
  // leading gap, cue, gap, cue, flush
  assert_eq(st.samples.length(), 5)
  assert_eq(st.samples[0].duration, 50U)
  assert_eq(st.samples[1].duration, 100U)
  assert_eq(st.samples[2].duration, 50U)
  assert_eq(st.samples[3].duration, 200U)
  assert_eq(st.samples[4].duration, 0U)
  let texts : Array[String] = []
  for i = 0; i < st.samples.length(); i = i + 1 {
    let sample = st.samples[i]
    let start = sample.offset.to_int()
    let size = sample.size.reinterpret_as_int()
    texts.push(
      @libavformat.mp4_tx3g_text(bytes[start:start + size].to_owned()).unwrap(),
    )
  }
  assert_eq(texts[0], "")
  assert_eq(texts[1], "First cue")
  assert_eq(texts[2], "")
  assert_eq(texts[3], "Second cue")
  // Video and audio payloads are byte-identical to a subtitle-less file.
  let plain = @libavformat.mp4_av_ac3_muxer_new(64, 48, avcc, audio[0]).unwrap()
  for i, p in video {
    plain.write_video(p, duration=9000, keyframe=i == 0).unwrap()
  }
  for p in audio {
    plain.write_audio(p, duration=1536).unwrap()
  }
  let pbytes = plain.finish()
  let pmovie = @libavformat.av_mov_open(pbytes).unwrap()
  for t = 0; t < 2; t = t + 1 {
    let a = movie.tracks[t]
    let b = pmovie.tracks[t]
    assert_eq(a.samples.length(), b.samples.length())
    for i = 0; i < a.samples.length(); i = i + 1 {
      let sa = a.samples[i]
      let sb = b.samples[i]
      let a0 = sa.offset.to_int()
      let a1 = a0 + sa.size.reinterpret_as_int()
      let b0 = sb.offset.to_int()
      let b1 = b0 + sb.size.reinterpret_as_int()
      assert_eq(bytes[a0:a1].to_owned(), pbytes[b0:b1].to_owned())
    }
  }
  av_check_video(video)
}
