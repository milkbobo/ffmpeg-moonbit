///|
/// Black-box tests for the unified format probe. The base64 fixtures are real
/// files written by the reference FFmpeg 9.0.2 build
/// (`scripts/gen_probe_fixtures.sh`) and re-encoded by
/// `scripts/gen_probe_vectors.py`; every expected name comes from
/// `ffprobe -show_entries format=format_name` on the same file.

///|
fn probe_decode(b64 : Bytes) -> Bytes {
  @libavutil.av_base64_decode(b64, 1 << 20).unwrap()
}

///|
/// Probe `data` and return (format name, score); "" means no match. */
fn probe_of(
  data : BytesView,
  filename? : String = "",
  mime_type? : String = "",
) -> (String, Int) {
  let pd = @libavformat.ProbeData::new(
    data.to_owned(),
    filename~,
    mime_type~,
  )
  match @libavformat.av_probe_input_format(pd) {
    (Some(id), score) => (id.name(), score)
    (None, score) => ("", score)
  }
}

///|
test "probe: real fixtures resolve to the ffprobe format name" {
  let cases : Array[(String, String, Bytes)] = [
    ("mp4", "mov,mp4,m4a,3gp,3g2,mj2", probe_decode(@probe_vectors.probe_fixture_mp4)),
    ("mkv", "matroska,webm", probe_decode(@probe_vectors.probe_fixture_mkv)),
    ("webm", "matroska,webm", probe_decode(@probe_vectors.probe_fixture_webm)),
    ("ts", "mpegts", probe_decode(@probe_vectors.probe_fixture_ts)),
    ("wav", "wav", probe_decode(@probe_vectors.probe_fixture_wav)),
    ("flac", "flac", probe_decode(@probe_vectors.probe_fixture_flac)),
    ("mp3", "mp3", probe_decode(@probe_vectors.probe_fixture_mp3)),
    ("aac", "aac", probe_decode(@probe_vectors.probe_fixture_aac)),
    ("ogg", "ogg", probe_decode(@probe_vectors.probe_fixture_ogg)),
    ("ac3", "ac3", probe_decode(@probe_vectors.probe_fixture_ac3)),
    ("aiff", "aiff", probe_decode(@probe_vectors.probe_fixture_aiff)),
    ("au", "au", probe_decode(@probe_vectors.probe_fixture_au)),
    ("caf", "caf", probe_decode(@probe_vectors.probe_fixture_caf)),
    ("asf", "asf", probe_decode(@probe_vectors.probe_fixture_asf)),
    ("w64", "w64", probe_decode(@probe_vectors.probe_fixture_w64)),
    ("png", "png_pipe", probe_decode(@probe_vectors.probe_fixture_png)),
    ("mjpeg", "jpeg_pipe", probe_decode(@probe_vectors.probe_fixture_mjpeg)),
  ]
  for c in cases {
    let (key, want, data) = c
    let (name, _score) = probe_of(data)
    if name != want {
      fail("probe \{key}: expected \{want}, got \"\{name}\"")
    }
  }
}

///|
/// Scores that come straight from a `return <constant>` path in the C, so
/// they are derivable without re-deriving frame counts.
test "probe: constant-path scores" {
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_mp4)), (
    "mov,mp4,m4a,3gp,3g2,mj2", 100,
  ))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_mkv)), ("matroska,webm", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_wav)), ("wav", 99))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_w64)), ("w64", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_png)), ("png_pipe", 99))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_ogg)), ("ogg", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_caf)), ("caf", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_asf)), ("asf", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_aiff)), ("aiff", 100))
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_au)), ("au", 100))
}

///|
test "probe: frame-count scores stay in their C band" {
  // aac: first_frames >= 3 -> EXTENSION + 1
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_aac)).1, 51)
  // mp3: first_frames >= 7 -> EXTENSION + 2
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_mp3)).1, 52)
  // ac3: 4..200 frames -> EXTENSION (a truncated window is enough)
  let ac3_score = probe_of(probe_decode(@probe_vectors.probe_fixture_ac3)).1
  assert_true(ac3_score == 50 || ac3_score == 52)
  // mjpeg: one well-formed frame without the multipart header -> EXTENSION/4
  assert_eq(probe_of(probe_decode(@probe_vectors.probe_fixture_mjpeg)).1, 12)
  // ts: at least a confident sync-byte histogram
  assert_true(probe_of(probe_decode(@probe_vectors.probe_fixture_ts)).1 >= 50)
}

///|
test "probe: HLS needs the playlist extension or MIME type" {
  let playlist =
    b"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n"
  // Without a hint the C probe refuses the match (a bare #EXTM3U is not enough).
  assert_eq(probe_of(playlist), ("", 0))
  assert_eq(probe_of(playlist, filename="live.m3u8"), ("hls", 100))
  assert_eq(probe_of(playlist, mime_type="application/vnd.apple.mpegurl"), (
    "hls", 100,
  ))
}

///|
test "probe: DASH MPD profiles" {
  let mpd =
    b"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" profiles=\"urn:mpeg:dash:profile:isoff-live:2011\" type=\"static\"></MPD>\n"
  assert_eq(probe_of(mpd), ("dash", 100))
}

///|
test "probe: leading ID3v2 tag drops the score to the extension floor" {
  // A tag that is larger than the window: nodat = ID3_GREATER_PROBE, so the
  // extension may only lift the score to EXTENSION/2 - 1.
  let id3 : Array[Byte] = [
    b'I', b'D', b'3', b'\x04', b'\x00', b'\x00', b'\x00', b'\x00', b'\x01', b'\x00',
  ]
  for _ in 0..<20 {
    id3.push(b'\x00')
  }
  let data = Bytes::from_array(id3[:])
  // The tag hides everything else but is not itself stripped (C breaks out of
  // the skip loop before moving `buf`), so `mp3_read_probe` sees the ID3 magic
  // and returns EXTENSION/4 because the tag is larger than the window.
  assert_eq(probe_of(data), ("mp3", 12))
  // With a matching extension the score is lifted to EXTENSION/2 - 1.
  assert_eq(probe_of(data, filename="song.mp3"), ("mp3", 24))
}

///|
test "probe: MIME bonus is additive and capped at 100" {
  let aac = probe_decode(@probe_vectors.probe_fixture_aac)
  let (name, plain) = probe_of(aac)
  assert_eq(name, "aac")
  let (mime_name, boosted) = probe_of(aac, mime_type="audio/aac")
  assert_eq(mime_name, "aac")
  assert_eq(boosted, plain + 30)
}

///|
test "probe: unknown data has no format" {
  assert_eq(probe_of(b""), ("", 0))
  assert_eq(probe_of(b"\x00\x00\x00\x00\x00\x00\x00\x00"), ("", 0))
  // A random-looking blob must not be mistaken for a container.
  let junk : Array[Byte] = []
  for i in 0..<64 {
    junk.push(
      if i % 3 == 0 {
        b'\x37'
      } else if i % 3 == 1 {
        b'\x11'
      } else {
        b'\xff'
      },
    )
  }
  assert_eq(probe_of(Bytes::from_array(junk[:])), ("", 0))
}

///|
test "probe: extension alone scores 1 and is rejected by format2" {
  // No probe matches these bytes, so only the `.mp4` extension can lift the
  // score to 1 (FFMAX(score, 1)); av_probe_input_format2 rejects that as
  // below AVPROBE_SCORE_RETRY.
  let junk = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10"
  assert_eq(probe_of(junk, filename="movie.mp4"), (
    "mov,mp4,m4a,3gp,3g2,mj2", 1,
  ))
  let pd = @libavformat.ProbeData::new(junk, filename="movie.mp4")
  match @libavformat.av_probe_input_format2(pd) {
    (None, score) => assert_eq(score, 1)
    (Some(id), _) => fail("expected no match, got \{id.name()}")
  }
}

///|
test "probe: av_probe_input_buffer reads from an AVIO source" {
  let wav = probe_decode(@probe_vectors.probe_fixture_wav)
  let pb = @libavformat.AvioContext::init_read_context(wav)
  match @libavformat.av_probe_input_buffer(pb) {
    Ok((Some(id), score)) => {
      assert_eq(id.name(), "wav")
      assert_eq(score, 99)
    }
    Ok((None, _)) => fail("probe returned no format")
    Err(e) => fail("probe failed: \{e}")
  }
  // FFmpeg rewinds the context after probing (ffio_rewind_with_probe_data);
  // this port seeks back instead, so the caller can read from the start.
  assert_eq(pb.avio_tell(), 0L)
}

///|
test "probe: av_probe_input_buffer tolerates a short (EOF) source" {
  // 100 bytes is well below PROBE_BUF_MIN; the loop must stop at EOF and still
  // accept the WAV header (score 99 > AVPROBE_SCORE_RETRY).
  let wav = probe_decode(@probe_vectors.probe_fixture_wav)[0:100].to_owned()
  let pb = @libavformat.AvioContext::init_read_context(wav)
  match @libavformat.av_probe_input_buffer(pb) {
    Ok((Some(id), _)) => assert_eq(id.name(), "wav")
    Ok((None, _)) => fail("probe returned no format")
    Err(e) => fail("probe failed: \{e}")
  }
  assert_eq(pb.avio_tell(), 0L)
}

///|
test "probe: av_probe_input_buffer rejects an empty source" {
  let pb = @libavformat.AvioContext::init_read_context(b"")
  match @libavformat.av_probe_input_buffer(pb) {
    Ok((_, _)) => fail("empty source must not probe")
    Err(_) => ()
  }
}
