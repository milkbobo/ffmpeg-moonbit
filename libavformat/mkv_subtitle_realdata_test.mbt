///|
/// Real FFmpeg 9.0.2 Matroska subtitle file (`S_TEXT/UTF8`, two cues written
/// as BlockGroups with BlockDuration).

///|
fn mkvsub_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let mkvsub_b64 : Bytes = mkvsub_concat([
  b"GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAACCBFNm3TAv4Qtd4B3TbuLU6uEFUmpZlOsgaFNu4tTq4QWVK5rU6yB7027jFOrhBJUw2dTrIIBMk27jFOrhBxTu2tTrIIB",
  b"0uwBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZsm/hGruqZkq17GDD0JATYCMTGF2ZjYz",
  b"LjEuMTAyV0GMTGF2ZjYzLjEuMTAyc6SQ4k95RtnlFdiJ+Qc3n3tWS0SJiECjiAAAAAAAFlSua76/hDDjTzWuAQAAAAAAAC/XgQFzxYgSfdZzh24edJyBACK1nIN1bmSIgQCGi1NfVEVYVC9VVEY4g4ERVe6BABJU",
  b"w2fdv4QLeUL+c3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNzsmPAi2PFiBJ91nOHbh50Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMi41MDAwMDAwMDAAH0O2dbm/hOrrvp/ngQCgj6GJgQAAAEhl",
  b"bGxvm4ID6KCdoZeBBLAAU2Vjb25kIGxpbmUKd3JhcHBlZJuCBRQcU7trsb+Eet7KhruTs4EAt473gQHxggGU8IEJsoID6LuUs4IEsLeO94EB8YIBlPCBGrKCBRQ=",
])

///|
test "mkv subtitle: reads ffmpeg S_TEXT/UTF8 cues" {
  let data = @libavutil.av_base64_decode(mkvsub_b64, 100000).unwrap()
  let mh = @libavformat.av_matroska_open(data).unwrap()
  assert_eq(mh.tracks.length(), 1)
  assert_eq(mh.tracks[0].track_type, 17UL)
  assert_eq(mh.tracks[0].codec_id, Some("S_TEXT/UTF8"))
  assert_eq(mh.packets.length(), 2)
  assert_eq(mh.packets[0].pts, 0L)
  assert_eq(mh.packets[0].duration, 1000UL)
  assert_eq(mh.packets[0].data, b"Hello")
  assert_eq(mh.packets[1].pts, 1200L)
  assert_eq(mh.packets[1].duration, 1300UL)
  assert_eq(mh.packets[1].data, b"Second line\nwrapped")
}

///|
test "mkv subtitle: writer round-trips cues" {
  let mux = @libavformat.mkv_subtitle_muxer_new()
  // Written out of order to exercise the sort.
  mux.write_cue(40000L, 41000L, "Late cue").unwrap()
  mux.write_cue(1200L, 2500L, "Second line\nwrapped").unwrap()
  mux.write_cue(0L, 1000L, "Hello").unwrap()
  let file = mux.finish()
  let mh = @libavformat.av_matroska_open(file).unwrap()
  assert_eq(mh.tracks.length(), 1)
  assert_eq(mh.tracks[0].track_type, 17UL)
  assert_eq(mh.tracks[0].codec_id, Some("S_TEXT/UTF8"))
  assert_eq(mh.packets.length(), 3)
  assert_eq(mh.packets[0].data, b"Hello")
  assert_eq(mh.packets[0].pts, 0L)
  assert_eq(mh.packets[0].duration, 1000UL)
  assert_eq(mh.packets[1].data, b"Second line\nwrapped")
  assert_eq(mh.packets[1].pts, 1200L)
  assert_eq(mh.packets[1].duration, 1300UL)
  // A cue past the 16-bit timecode range starts a second Cluster.
  assert_eq(mh.packets[2].data, b"Late cue")
  assert_eq(mh.packets[2].pts, 40000L)
  assert_eq(mh.packets[2].duration, 1000UL)
}

///|
test "mkv subtitle: invalid cues are rejected" {
  let mux = @libavformat.mkv_subtitle_muxer_new()
  match mux.write_cue(1000L, 500L, "x") {
    Ok(_) => fail("expected end before start to be rejected")
    Err(_) => ()
  }
  match mux.write_cue(0L, 1000L, "") {
    Ok(_) => fail("expected empty text to be rejected")
    Err(_) => ()
  }
  match mux.write_cue(-1L, 1000L, "x") {
    Ok(_) => fail("expected a negative start to be rejected")
    Err(_) => ()
  }
}
