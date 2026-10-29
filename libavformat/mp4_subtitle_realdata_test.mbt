///|
/// Real FFmpeg 9.0.2 mov_text MP4: one `tx3g` subtitle track with the two
/// cues, gap and flush samples FFmpeg writes.

///|
fn mp4sub_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mp4sub_b64 : Bytes = mp4sub_concat([
  b"AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAIG1kYXQABUhlbGxvAAAAC1NlY29uZCBsaW5lAAAAAALdbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAA9CQAAmJaAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA",
  b"AAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAgh0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAmJaAAAAAAAAAAAAAAAAMAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA",
  b"AABAAAAAAAAAAAAAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAJiWgAAAAAAABAAAAAAGAbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAA9CQAAmJaBVxAAAAAAAMGhkbHIAAAAAAAAAAHNidGwAAAAAAAAAAAAAAABTdWJ0aXRsZUhhbmRs",
  b"ZXIAAAABKG1pbmYAAAAMbm1oZAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAADwc3RibAAAAGRzdHNkAAAAAAAAAAEAAABUdHgzZwAAAAAAAAABAAAAAAH/AAAA/wAAAAAAAAAAAAAAAAABABD/////AAAAEmZ0",
  b"YWIAAQABBUFyaWFsAAAAFGJ0cnQAAAAAAAAATAAAAEwAAAAwc3R0cwAAAAAAAAAEAAAAAQAPQkAAAAABAAMNQAAAAAEAE9YgAAAAAQAAAAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAQAAAABAAAAJHN0c3oAAAAAAAAAAAAAAAQAAAAHAAAA",
  b"AgAAAA0AAAACAAAAFHN0Y28AAAAAAAAAAQAAACwAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAy",
])

///|
fn mp4sub_sample_text(
  data : Bytes,
  track : @libavformat.Mp4Track,
  i : Int32,
) -> String {
  let sample = track.samples[i]
  let start = sample.offset.to_int()
  let size = sample.size.reinterpret_as_int()
  match @libavformat.mp4_tx3g_text(data[start:start + size].to_owned()) {
    Ok(text) => text
    Err(_) => ""
  }
}

///|
test "mp4 subtitle: reads mov_text samples" {
  let data = @libavutil.av_base64_decode(mp4sub_b64, 100000).unwrap()
  let movie = @libavformat.av_mov_open(data).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "tx3g")
  assert_eq(track.timescale, 1000000)
  // FFmpeg appends a zero-duration flush sample; the edit list trims it.
  assert_eq(track.samples.length(), 3)
  assert_eq(track.samples[0].duration, 1000000U)
  assert_eq(track.samples[1].duration, 200000U)
  assert_eq(track.samples[2].duration, 1300000U)
  assert_eq(mp4sub_sample_text(data, track, 0), "Hello")
  assert_eq(mp4sub_sample_text(data, track, 1), "")
  assert_eq(mp4sub_sample_text(data, track, 2), "Second line")
}

///|
test "mp4 subtitle: writer round-trips cues" {
  let mux = @libavformat.mp4_subtitle_muxer_new()
  mux.write_cue(0L, 1000L, "Hello").unwrap()
  mux.write_cue(1200L, 2500L, "Second line").unwrap()
  let file = mux.finish().unwrap()
  let movie = @libavformat.av_mov_open(file).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(track.codec, "tx3g")
  assert_eq(track.timescale, 1000000)
  assert_eq(track.samples.length(), 4)
  assert_eq(track.samples[0].duration, 1000000U)
  assert_eq(track.samples[1].duration, 200000U)
  assert_eq(track.samples[2].duration, 1300000U)
  assert_eq(track.samples[3].duration, 0U)
  assert_eq(mp4sub_sample_text(file, track, 0), "Hello")
  assert_eq(mp4sub_sample_text(file, track, 1), "")
  assert_eq(mp4sub_sample_text(file, track, 2), "Second line")
}

///|
test "mp4 subtitle: invalid cues are rejected" {
  let mux = @libavformat.mp4_subtitle_muxer_new()
  match mux.write_cue(1000L, 500L, "x") {
    Ok(_) => fail("expected end before start to be rejected")
    Err(_) => ()
  }
  match mux.write_cue(0L, 1000L, "") {
    Ok(_) => fail("expected empty text to be rejected")
    Err(_) => ()
  }
  mux.write_cue(1000L, 2000L, "a").unwrap()
  match mux.write_cue(1500L, 2500L, "b") {
    Ok(_) => fail("expected overlapping cues to be rejected")
    Err(_) => ()
  }
}
