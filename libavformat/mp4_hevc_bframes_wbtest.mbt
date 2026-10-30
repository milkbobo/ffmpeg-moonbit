///|
/// Real HEVC MP4 with B-frames (x265 bf=3, 64x48, 6 frames). Remuxing
/// through `Mp4HevcMuxer` must preserve PTS/DTS via `ctts` and decode to
/// the same frames.

///|
let mp4_hevc_bframes_src_b64 : Bytes = b"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QAEMAf//AWAAAAMAkAAAAwAAAwAelZQJIQABAClCAQEBYAAAAwCQAAADAAADAB6gIIMWWVluTK8BaAgAAAMACAAAAwAoQCIAAQAGRAHBc9CJJwABCQhOAQX///////////8DLKLeCbUXR9u7VaT+f8L8TngyNjUgKGJ1aWxkIDIxNikgLSA0LjIrMS1lNDQ0NzQ0OltMaW51eF1bR0NDIDE1LjIuMF1bNjQgYml0XSA4Yml0KzEwYml0KzEyYml0IC0gSC4yNjUvSEVWQyBjb2RlYyAtIENvcHlyaWdodCAyMDEzLTIwMTggKGMpIE11bHRpY29yZXdhcmUsIEluYyAtIGh0dHA6Ly94MjY1Lm9yZyAtIG9wdGlvbnM6IGNwdWlkPTExMTEwMzkgZnJhbWUtdGhyZWFkcz0xIG5vLXdwcCBuby1wbW9kZSBuby1wbWUgbm8tcHNuciBuby1zc2ltIGxvZy1sZXZlbD0tMSBiaXRkZXB0aD04IGlucHV0LWNzcD0xIGZwcz01LzEgaW5wdXQtcmVzPTY0eDQ4IGludGVybGFjZT0wIHRvdGFsLWZyYW1lcz0wIGxldmVsLWlkYz0wIGhpZ2gtdGllcj0xIHVoZC1iZD0wIHJlZj0zIG5vLWFsbG93LW5vbi1jb25mb3JtYW5jZSBuby1yZXBlYXQtaGVhZGVycyBhbm5leGIgbm8tYXVkIG5vLWVvYiBuby1lb3Mgbm8taHJkIGluZm8gaGFzaD0wIHRlbXBvcmFsLWxheWVycz0wIG9wZW4tZ29wIG1pbi1rZXlpbnQ9NiBrZXlpbnQ9NiBnb3AtbG9va2FoZWFkPTAgYmZyYW1lcz0zIGItYWRhcHQ9MiBiLXB5cmFtaWQgYmZyYW1lLWJpYXM9MCByYy1sb29rYWhlYWQ9MjAgbG9va2FoZWFkLXNsaWNlcz0wIHNjZW5lY3V0PTAgbm8taGlzdC1zY2VuZWN1dCByYWRsPTAgbm8tc3BsaWNlIG5vLWludHJhLXJlZnJlc2ggY3R1PTMyIG1pbi1jdS1zaXplPTggbm8tcmVjdCBuby1hbXAgbWF4LXR1LXNpemU9MzIgdHUtaW50ZXItZGVwdGg9MSB0dS1pbnRyYS1kZXB0aD0xIGxpbWl0LXR1PTAgcmRvcS1sZXZlbD0wIGR5bmFtaWMtcmQ9MC4wMCBuby1zc2ltLXJkIHNpZ25oaWRlIG5vLXRza2lwIG5yLWludHJhPTAgbnItaW50ZXI9MCBuby1jb25zdHJhaW5lZC1pbnRyYSBzdHJvbmctaW50cmEtc21vb3RoaW5nIG1heC1tZXJnZT0zIGxpbWl0LXJlZnM9MSBuby1saW1pdC1tb2RlcyBtZT0xIHN1Ym1lPTIgbWVyYW5nZT01NyB0ZW1wb3JhbC1tdnAgbm8tZnJhbWUtZHVwIG5vLWhtZSB3ZWlnaHRwIG5vLXdlaWdodGIgbm8tYW5hbHl6ZS1zcmMtcGljcyBkZWJsb2NrPTA6MCBzYW8gbm8tc2FvLW5vbi1kZWJsb2NrIHJkPTMgc2VsZWN0aXZlLXNhbz00IGVhcmx5LXNraXAgcnNraXAgbm8tZmFzdC1pbnRyYSBuby10c2tpcC1mYXN0IG5vLWN1LWxvc3NsZXNzIGItaW50cmEgbm8tc3BsaXRyZC1za2lwIHJkcGVuYWx0eT0wIHBzeS1yZD0yLjAwIHBzeS1yZG9xPTAuMDAgbm8tcmQtcmVmaW5lIG5vLWxvc3NsZXNzIGNicXBvZmZzPTAgY3JxcG9mZnM9MCByYz1jcmYgY3JmPTI4LjAgcWNvbXA9MC42MCBxcHN0ZXA9NCBzdGF0cy13cml0ZT0wIHN0YXRzLXJlYWQ9MCBpcHJhdGlvPTEuNDAgcGJyYXRpbz0xLjMwIGFxLW1vZGU9MiBhcS1zdHJlbmd0aD0xLjAwIGN1dHJlZSB6b25lLWNvdW50PTAgbm8tc3RyaWN0LWNiciBxZy1zaXplPTMyIG5vLXJjLWdyYWluIHFwbWF4PTY5IHFwbWluPTAgbm8tY29uc3QtdmJ2IHNhcj0xIG92ZXJzY2FuPTAgdmlkZW9mb3JtYXQ9NSByYW5nZT0wIGNvbG9ycHJpbT0yIHRyYW5zZmVyPTIgY29sb3JtYXRyaXg9MiBjaHJvbWFsb2M9MCBkaXNwbGF5LXdpbmRvdz0wIGNsbD0wLDAgbWluLWx1bWE9MCBtYXgtbHVtYT0yNTUgbG9nMi1tYXgtcG9jLWxzYj04IHZ1aS10aW1pbmctaW5mbyB2dWktaHJkLWluZm8gc2xpY2VzPTEgbm8tb3B0LXFwLXBwcyBuby1vcHQtcmVmLWxpc3QtbGVuZ3RoLXBwcyBuby1tdWx0aS1wYXNzLW9wdC1ycHMgc2NlbmVjdXQtYmlhcz0wLjA1IG5vLW9wdC1jdS1kZWx0YS1xcCBuby1hcS1tb3Rpb24gbm8taGRyMTAgbm8taGRyMTAtb3B0IG5vLWRoZHIxMC1vcHQgbm8taWRyLXJlY292ZXJ5LXNlaSBhbmFseXNpcy1yZXVzZS1sZXZlbD0wIGFuYWx5c2lzLXNhdmUtcmV1c2UtbGV2ZWw9MCBhbmFseXNpcy1sb2FkLXJldXNlLWxldmVsPTAgc2NhbGUtZmFjdG9yPTAgcmVmaW5lLWludHJhPTAgcmVmaW5lLWludGVyPTAgcmVmaW5lLW12PTEgcmVmaW5lLWN0dS1kaXN0b3J0aW9uPTAgbm8tbGltaXQtc2FvIGN0dS1pbmZvPTAgbm8tbG93cGFzcy1kY3QgcmVmaW5lLWFuYWx5c2lzLXR5cGU9MCBjb3B5LXBpYz0xIG1heC1hdXNpemUtZmFjdG9yPTEuMCBuby1keW5hbWljLXJlZmluZSBuby1zaW5nbGUtc2VpIG5vLWhldmMtYXEgbm8tc3Z0IG5vLWZpZWxkIHFwLWFkYXB0YXRpb24tcmFuZ2U9MS4wMCBzY2VuZWN1dC1hd2FyZS1xcD0wY29uZm9ybWFuY2Utd2luZG93LW9mZnNldHMgcmlnaHQ9MCBib3R0b209MCBkZWNvZGVyLW1heC1yYXRlPTAgbm8tdmJ2LWxpdmUtbXVsdGktcGFzcyBuby1tY3N0ZiBuby1zYnJjIG5vLWZyYW1lLXJjgAAAAApmaWVsAQAAAAAQcGFzcAAAAAEAAAABAAAAFGJ0cnQAAAAAAAAffAAAAAAAAAAYc3R0cwAAAAAAAAABAAAABgAACAAAAAAUc3RzcwAAAAAAAAABAAAAAQAAABJzZHRwAAAAACAQGBAQGAAAAEBjdHRzAAAAAAAAAAYAAAABAAAQAAAAAAEAABgAAAAAAQAACAAAAAABAAAgAAAAAAEAABAAAAAAAQAAAAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAYAAAABAAAALHN0c3oAAAAAAAAAAAAAAAYAAAOqAAAAPwAAABoAAAB7AAAAKwAAABAAAAAUc3RjbwAAAAAAAAABAAAALAAAAGF1ZHRhAAAAWW1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALGlsc3QAAAAkqXRvbwAAABxkYXRhAAAAAQAAAABMYXZmNjMuMS4xMDI="

///|
test "mp4: HEVC B-frames round-trip PTS through ctts" {
  let src = @libavutil.av_base64_decode(mp4_hevc_bframes_src_b64, 100000).unwrap()
  let movie = av_mov_open(src).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_true(track.codec == "hvc1" || track.codec == "hev1")
  let hvcc = track.extradata.unwrap()
  let mux = mp4_hevc_muxer_new(
    track.width,
    track.height,
    hvcc,
    timescale=track.timescale.reinterpret_as_int(),
  ).unwrap()
  let src_payloads : Array[Bytes] = []
  let mut reordered = false
  for sample in track.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    let payload = src[start:end].to_owned()
    src_payloads.push(payload)
    if sample.pts != sample.dts {
      reordered = true
    }
    mux
    .write_packet(
      payload,
      duration=sample.duration.reinterpret_as_int(),
      keyframe=sample.keyframe,
      cts=(sample.pts - sample.dts).to_int(),
    )
    .unwrap()
  }
  assert_true(reordered, msg="fixture must contain B-frames")
  let out = mux.finish()
  let remux = av_mov_open(out).unwrap()
  let rt = remux.tracks[0]
  assert_eq(rt.samples.length(), track.samples.length())
  // The video edit list trims the reorder delay: presentation starts at 0.
  assert_eq(rt.samples[0].pts, 0L)
  assert_true(rt.samples[0].dts < 0L)
  let src_base = track.samples[0].dts
  let out_base = rt.samples[0].dts
  for i in 0..<track.samples.length() {
    let a = track.samples[i]
    let b = rt.samples[i]
    assert_eq(b.pts - b.dts, a.pts - a.dts, msg="cts \{i}")
    assert_eq(b.dts - out_base, a.dts - src_base, msg="dts \{i}")
    assert_eq(b.duration, a.duration, msg="duration \{i}")
    assert_eq(b.keyframe, a.keyframe, msg="key \{i}")
  }
  let src_all : Array[Byte] = []
  for b in mkv_av_hvcc_params(hvcc) {
    src_all.push(b)
  }
  for p in src_payloads {
    for b in p {
      src_all.push(b)
    }
  }
  let out_all : Array[Byte] = []
  for b in mkv_av_hvcc_params(hvcc) {
    out_all.push(b)
  }
  for sample in rt.samples {
    let start = sample.offset.to_int()
    let end = start + sample.size.reinterpret_as_int()
    for b in out[start:end] {
      out_all.push(b)
    }
  }
  let src_frames = match
    @libavcodec.ff_hevc_decode_frames_ex(
      Bytes::from_array(src_all),
      true,
      4,
      true,
    ) {
    Ok(v) => v
    Err(e) => fail("src decode: \{e}")
  }
  let out_frames = match
    @libavcodec.ff_hevc_decode_frames_ex(
      Bytes::from_array(out_all),
      true,
      4,
      true,
    ) {
    Ok(v) => v
    Err(e) => fail("out decode: \{e}")
  }
  let src_sorted = src_frames.copy()
  src_sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  let out_sorted = out_frames.copy()
  out_sorted.sort_by((a, b) => a.poc().compare(b.poc()))
  assert_eq(out_sorted.length(), src_sorted.length())
  for i in 0..<src_sorted.length() {
    assert_eq(
      mkv_hevc_md5(out_sorted[i].yuvp(8)),
      mkv_hevc_md5(src_sorted[i].yuvp(8)),
      msg="frame \{i}",
    )
  }
}
