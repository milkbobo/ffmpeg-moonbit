///|
/// Tests for the WebM/MP4 codec-parameter bridge for VP9, AV1 and Opus.
///
/// Real files from `linuxserver/ffmpeg:9.0.2`:
///   ffmpeg ... -c:v libvpx-vp9 -f webm vp9_only.webm
///   ffmpeg ... -c:v libaom-av1 -f webm webm_av1.webm
///   ffmpeg ... -c:a libopus -f webm opus_only.webm
///   ffmpeg ... -c:a libopus mp4_opus_only.mp4
///
/// ffprobe reports for the WebM VP9 file: vp9 64x48; AV1: Main 64x48 yuv420p
/// with a 16-byte av1C; Opus: 48000 Hz mono, initial_padding 312 (both WebM
/// OpusHead and the MP4 dOps -> OpusHead conversion).

///|
let webm_vp9_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAaDEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggEyTbuMU6uEHFO7a1OsggZt7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAaQAAAAAAABZUrmvXrgEAAAAAAABO14EBc8WI5L5+dsxSWXOcgQAitZyDdW5k",
  b"iIEAhoVWX1ZQOYOBASPjg4QL68IA4JCwgUC6gTCagQJVsIRVuYEBVe6BAOwBAAAAAAAAAgAAElTDZ/5zc59jwIBnyJlFo4dFTkNP",
  b"REVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WI5L5+dsxSWXNnyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYnZweC12cDln",
  b"yKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIwMDAwMDAwMAAfQ7Z1RLLngQCjRKyBAACAgkmDQgAD8AL2BDgkHBhCAAMQfLF6f02J",
  b"uker9g9Z6j0Xr+n9G0Xdj380C/f8/5H59H+m6buv02jPV+m3T6e7HvsAAH/Dmc5Ywiozez4rJK/koYcpfSJ2NT6cU8llQVPf8goJ",
  b"RqzP3MdyefOlT/0WlAMcXBh1/nM7yeMm9hjV1VC4SM5ED+cuiKxbip0JUpppKXuNR/3d+888FB0lBBS4UhUwmOsZCWSFPylu4vn2",
  b"akF+6Z3hmdbttmQLMSkuXKHVtHVHTGR1naA6s+/q0RPTFVROAaY4mFuyXi58rAVFX+E9yf0e/qDIHCen8h//MuvCNsYSii4f//br",
  b"rZcyTrM0cLLTeaWcKmy+8+0SQ1I0sEv54lw2GAl8a8kSyyrJ9AgO572+IpMB1RCrDlH8P8ouRxqk46pNslBZfkGwCNYStGHoQas2",
  b"lzPb804vsQhJvEG4+SnZKSVEa27WP++FxlXv9Epz0nVOMDXlHHX5+FNcG+YCdyUlfmDgRyu+c+s00Ogys4q2QJ0SrAwIV1rYWuR/",
  b"P/cf0lL2yCmIkleDE0pCuIyu2e/AN0HX/bbebxAuj5gxg0SngHdtP6Gi+EbR4J2FjM7lUehmrHT7lUiPhG0PiZLU80t4Otd7Wgdk",
  b"lIkbl4Fcvu/d+83atwGcmqZ/48DOCy/5HniOf+/KKsR5wLBDnTg7gNeaksZlSCEj+s1YrC33aLMZ3KeAXmGmbt/5mwUax2hrVnMf",
  b"Wpslp/QJl3uGMHgi4/u2I6Qh1xJKBBxnBTRMp6pJr8/irPSq6d8ZEJSg281+R667I/syc6iJKQVYmqL5at3v//rmL/+Tb/aZav9c",
  b"a/x9//moUeO7IN7d6f//6ZhzI3+iVpT/Toz//7bLbAukVI8HfgShbMMmHxMZm/wAsouwskg4mS2zEtAwgPhiAjHfPlcvcWtfWhBj",
  b"D0mwmP01fqt0av7KGtWaChxI6nzPb7iUYSRBTImjZpNM84alRKjtVDuYex0GHahXCAkSvGVo37i0NDp6Uvo/G4azbIf75/Itcr66",
  b"4ZqOHfIabC65eFEQ0qsY7XawaEQc3UdVkN2JtPaJ5nmN0aOY5a3INtIjFCGieY7r98wvMgUX/iLMgTE5OUg58Im+MN2U9pzPs0UJ",
  b"Bz49nlgP9g//DK5r6LVgytqOHr/C9ZHEjX9+6vH7Ewd2eu1Izp9jPyoDKL6oZNM8QV/+YsP+wf8bs/0w/3A/+WKo3/JY3mx///Vm",
  b"Iqz6WF0PXZlD+B0M2wF8hOXByGlDMLGroaatXeYnIKT8Wcyixg//7Fq/8ADszqd4GgtRblsKBe6reN7EOwawIkNbUKtiIhoYZIkD",
  b"l5wtJfaYxep5NVycsIeTXZa+qYuby4nD06f2cePDVWdBi/sTLIPUhYRdUkz11DkNe41NHc41v76WR/KJEoes/5jCXJ6sloefh3m6",
  b"T7lpNKg5WnWCzVNwtHGCl6Y3mLi1GZYKtb0gpgMRRumewS2GmoMjxPndV9X6fld/eQHwzPMtOikVg6rcVHz4hK32ZSyY8nYle9tg",
  b"qUGyapiSHv/H2NPFuuJnWDhCUjIo0OlL4QRsW8Eq6ODWQpeptIyFSjUsABxTu2uRu4+zgQC3iveBAfGCAbXwgQM=",
])

///|
let webm_av1_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAVyEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggMkTbuMU6uEHFO7a1OsggVc7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAgsAAAAAAABZUrmtCSK4BAAAAAAACP9eBAXPFiIJAbt83Gk+MnIEAIrWcg3Vu",
  b"ZIiBAIaFVl9BVjGDgQEj44OEC+vCAOCQsIFAuoEwmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOikIEADAAKCgAAAAKv95tfIAjs",
  b"AQAAAAAAAdUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElTDZ/5zc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WI",
  b"gkBu3zcaT4xnyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYmFvbS1hdjFnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjYw",
  b"MDAwMDAwMAAfQ7Z1Qa/ngQCjQWOBAACACgoAAAACr/ebXyAIMtACFAAvQAAAkAug23GkLM5N83gvC7U5r4Tnb7SAfGY3pPLGQFmY",
  b"HMuZvqWqXjBNjkiaQIwtZ52qNnrAYEAvyQ3AigL5PukCfQoLX4K23r0ThYKazmQSCJX6/9MrEkWCfEVCH4+0X2AK1GFHZLsCAhz3",
  b"7r1eoZVp74fHS1eJEwYzcz1t8ofyVFLQAg4SAj8BdIDbo9csUKTpoi4ajaYwoDXCAtnlA+Bg0q7UXFApMtxvkJubuFqDlxjNxPzE",
  b"ELOLhBZbPRwv2k+6MDJZCkqDKbxD9Gx47fuibhaH7QIyfSwORSY+IgtwES8CuSF/JyQWms7w6AFBLY/Dvp9vLjYuQ+z5BG4mAFBU",
  b"HYwOG6BblVQ1cUiS8ytDVQSwxdXPHZ30Co2U5/3fVbNnsiamEsZo+UdS9n3pkYD3lLEVlbkOHkLToDlxE383N5mMyPlHu//HTkPI",
  b"o6qBAMgAMiQyAeBAAAADZ8AQQgAUXWEA3Tlr0oD7tFzj141syeAMsTFPZfijmIEBkAAyEjIC4IIAAANoABBCABQAAQCZEBxTu2uR",
  b"u4+zgQC3iveBAfGCA6fwgQM=",
])

///|
let webm_opus_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQRChYECGFOAZwEAAAAAAAQEEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggFMTbuMU6uEHFO7a1OsggPu7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAWwAAAAAAABZUrmvxrgEAAAAAAABo14EBc8WIuSDhzNY3U5mcgQAitZyDdW5k",
  b"iIEAhoZBX09QVVNWqoNjLqBWu4QExLQAg4ECI+ODhAExLQDhkZ+BAbWIQOdwAAAAAABiZIEQVe6BAGOik09wdXNIZWFkAQE4AYC7",
  b"AAAAAAASVMNn+3Nzn2PAgGfImUWjh0VOQ09ERVJEh4xMYXZmNjMuMS4xMDJzc9ZjwItjxYi5IOHM1jdTmWfIoUWjh0VOQ09ERVJE",
  b"h5RMYXZjNjMuMS4xMDIgbGlib3B1c2fIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMTA4MDAwMDAwAB9DtnVCHOeBAKP3gQAAgHiB",
  b"e8YRdvR1AAAHjspp27vMSNwWvZvTWCd4k7w3RF7PLZcAaYARgCwDOKtFYf2Jt34NF78gpSu16ite06dI0RjyC1wBT1+hliGu3uBT",
  b"ANZlZT8fpsu5d7+XYsESz43Cff0AgP/6xoi23hC4T8Yja+qHyQWjzYEAFYB4nh6h5/yVTU6qGArKXQdkRDSURT5mZspE7R8NRGvz",
  b"T8ylVUVBnrTz/BM4ZXntmfAbf708knPV7o/rq3YypfShDDW+q7thmb+9o9GBACmAeJnCX3Wc/Es6Ratafn17N3wCtEph8Iknh85Q",
  b"++PDBMuvmWR8Fxozjeuuuhmb2+HXGbXIoXnWHLNo5SslmAxcvWQIEbsU0LsIDfn/2wWj04EAPYB4mcJfcy3SLe3Xf8RynuTrJ1ej",
  b"FvOztiwD/EkZg3hknUFMahb8gOoTxgNJv6UZRpFGjMYePYbZbleolVWQOJ3zA4hxkINvgIqWRblkw7ZNo9WBAFGAeJnCX3Mt0jEz",
  b"v3s0inEPd9XU6LWLeMVtG4+LaEvkaY4a3rjGH3j/UjY4L8PZT39GCiKWdrbcgt3eRZz7pgkox/JRmfaG+V+ZJD/wbAt7DsUMoNCh",
  b"xIEAZQB4BYqXOi7/6TufNhidAufO3u14YQE12iyGuRbAFmINpoHpbG3v4it9pHtBFTNL0zBKJrc6kBctejkjRUwjyNtcm4EHdaKE",
  b"AM3+YBxTu2uRu4+zgQC3iveBAfGCAczwgQM=",
])

///|
let mp4_opus_b64 : Bytes = bcat([
  b"AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAB8W1kYXR4gXvGEXb0dQAAB47Kadu7zEjcFr2b01gneJO8N0Re",
  b"zy2XAGmAEYAsAzirRWH9ibd+DRe/IKUrteorXtOnSNEY8gtcAU9foZYhrt7gUwDWZWU/H6bLuXe/l2LBEs+Nwn39AID/+saItt4Q",
  b"uE/GI2vqh8kFeJ4eoef8lU1OqhgKyl0HZEQ0lEU+ZmbKRO0fDURr80/MpVVFQZ608/wTOGV57ZnwG3+9PJJz1e6P66t2MqX0oQw1",
  b"vqu7YZm/vXiZwl91nPxLOkWrWn59ezd8ArRKYfCJJ4fOUPvjwwTLr5lkfBcaM43rrroZm9vh1xm1yKF51hyzaOUrJZgMXL1kCBG7",
  b"FNC7CA35/9sFeJnCX3Mt0i3t13/Ecp7k6ydXoxbzs7YsA/xJGYN4ZJ1BTGoW/IDqE8YDSb+lGUaRRozGHj2G2W5XqJVVkDid8wOI",
  b"cZCDb4CKlkW5ZMO2TXiZwl9zLdIxM797NIpxD3fV1Oi1i3jFbRuPi2hL5GmOGt64xh94/1I2OC/D2U9/Rgoilna23ILd3kWc+6YJ",
  b"KMfyUZn2hvlfmSQ/8GwLew7FDHgFipc6Lv/pO582GJ0C587e7XhhATXaLIa5FsAWYg2mgelsbe/iK32ke0EVM0vTMEomtzqQFy16",
  b"OSNFTCPI21wAAAMLbW9vdgAAAGxtdmhkAAAAAAAAAAAAAAAAAAC7gAAAEsAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA",
  b"AAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAjZ0cmFrAAAAXHRraGQAAAADAAAAAAAA",
  b"AAAAAAABAAAAAAAAEsAAAAAAAAAAAAAAAAEBAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAA",
  b"AAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAABLAAAABOAABAAAAAAGubWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAC7gAAAE/hVxAAA",
  b"AAAALWhkbHIAAAAAAAAAAHNvdW4AAAAAAAAAAAAAAABTb3VuZEhhbmRsZXIAAAABWW1pbmYAAAAQc21oZAAAAAAAAAAAAAAAJGRp",
  b"bmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABHXN0YmwAAABbc3RzZAAAAAAAAAABAAAAS09wdXMAAAAAAAAAAQAAAAAA",
  b"AAAAAAEAEAAAAAC7gAAAAAAAE2RPcHMAAQE4AAC7gAAAAAAAABRidHJ0AAAAAAAAj3wAAI98AAAAIHN0dHMAAAAAAAAAAgAAAAUA",
  b"AAPAAAAAAQAAATgAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAYAAAABAAAALHN0c3oAAAAAAAAAAAAAAAYAAABzAAAASQAAAE0AAABP",
  b"AAAAUQAAAEAAAAAUc3RjbwAAAAAAAAABAAAALAAAABpzZ3BkAQAAAHJvbGwAAAACAAAAAf/8AAAAJHNiZ3AAAAAAcm9sbAAAAAIA",
  b"AAAEAAAAAAAAAAIAAAABAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAsaWxz",
  b"dAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==",
])

///|
test "codec params: WebM VP9 track" {
  let bytes = @libavutil.av_base64_decode(webm_vp9_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_true(mkv.is_webm)
  assert_eq(mkv.tracks.length(), 1)
  let p = mkv_track_codec_parameters(mkv.tracks[0])
  assert_eq(p.codec, "vp9")
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  // WebM carries no vpcC for VP9; the decoder learns the profile from frames.
  assert_false(p.extradata_parsed)
}

///|
test "codec params: WebM AV1 av1C" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let p = mkv_track_codec_parameters(mkv.tracks[0])
  assert_eq(p.codec, "av1")
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  assert_eq(p.profile, 0)
  assert_eq(p.level, 0)
  assert_eq(p.bit_depth, 8)
  assert_eq(p.chroma_format, 1)
  assert_eq(p.pix_fmt, "yuv420p")
  assert_true(p.extradata_parsed)
}

///|
test "codec params: WebM Opus OpusHead" {
  let bytes = @libavutil.av_base64_decode(webm_opus_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_eq(mkv.tracks.length(), 1)
  assert_eq(mkv.tracks[0].codec_priv.unwrap().length(), 19)
  let p = mkv_track_codec_parameters(mkv.tracks[0])
  assert_eq(p.codec, "opus")
  assert_eq(p.sample_rate, 48000)
  assert_eq(p.channels, 1)
  assert_eq(p.initial_padding, 312)
  assert_true(p.extradata_parsed)
}

///|
test "codec params: MP4 Opus dOps is converted to OpusHead" {
  let bytes = @libavutil.av_base64_decode(mp4_opus_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let mut found = false
  for track in movie.tracks {
    let p = mp4_track_codec_parameters(track)
    if p.codec == "opus" {
      found = true
      assert_eq(p.sample_rate, 48000)
      assert_eq(p.channels, 1)
      assert_eq(p.initial_padding, 312)
      assert_true(p.extradata_parsed)
      let extra = track.extradata.unwrap()
      assert_eq(extra.length(), 19)
      assert_eq(extra[0], b'O')
      assert_eq(extra[7], b'd')
      assert_eq(extra[8], b'\x01')
      assert_eq(extra[10].to_int() | (extra[11].to_int() << 8), 312)
    }
  }
  assert_true(found)
}

///|
test "codec params: synthetic vpcC and av1C bit depths" {
  // vpcC: version 1, profile 2, level 51, packed = depth 10 | chroma 1 | range 0.
  let vpcc : Bytes = b"\x01\x02\x33\xa2"
  let vp = codec_parameters_from_extradata("vp9", Some(vpcc), 1920, 1080, 0, 0)
  assert_eq(vp.profile, 2)
  assert_eq(vp.level, 51)
  assert_eq(vp.bit_depth, 10)
  assert_eq(vp.chroma_format, 1)
  assert_eq(vp.pix_fmt, "yuv420p10le")
  assert_true(vp.extradata_parsed)
  // av1C: marker/version, profile 0 level 8, high_bitdepth + 4:2:0.
  let av1c : Bytes = b"\x81\x08\x4c\x00"
  let av = codec_parameters_from_extradata("av1", Some(av1c), 1280, 720, 0, 0)
  assert_eq(av.profile, 0)
  assert_eq(av.level, 8)
  assert_eq(av.bit_depth, 10)
  assert_eq(av.chroma_format, 1)
  assert_eq(av.pix_fmt, "yuv420p10le")
  // Monochrome 8-bit: av1C byte2 bit 4 set.
  let mono : Bytes = b"\x81\x00\x10\x00"
  let m = codec_parameters_from_extradata("av1", Some(mono), 640, 480, 0, 0)
  assert_eq(m.chroma_format, 0)
  assert_eq(m.pix_fmt, "gray")
}

///|
let mp4_av1_b64 : Bytes = bcat([
  b"AAAAIGZ0eXBpc29tAAACAGlzb21hdjAxaXNvMm1wNDEAAAAIZnJlZQAAAVBtZGF0CgoAAAACr/ebXyAIMrkCFAA0AAAAoAug23Gk",
  b"LM5N83gvC7U5r4Tnb7SAfGY3pPLGQFmYHMuZvqWqXjBNjkiaQIwtZ52qNnrAYEAvyQ3AigL5PukCfQoKFq4lreqOi0zAZ0btsdwK",
  b"AGlP2/Gjt60IWiteZlfpjWzMg8efm+sE3lvn23n7YYmUbjzTSz7fWo8g7YR2HnTGLeFaBCfsdUQbdUcpMtxvkJhJY3n3UtcAIVSY",
  b"FSqHwSEqU2g/1DD+cSXmGPrYbvXvktxcWGXwkB+VAtcOLLf49uugT1QFSsbl7iBFpG5MSFpwd2RyHIrsroXiI4E6YbInPiqauI4p",
  b"7gNJS04fupEUHHnTqiYO4lwsdt7ziY9+VmyFcIwVQQetB66/EF8pHqVYuQW9JPFT7JXD9fT+F83FekDMY4sY4EZ2eVGK1rsbcR27",
  b"cgAAAwJtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAyAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAA",
  b"AAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAACLXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEA",
  b"AAAAAAAAyAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAADAAAAAAACRlZHRz",
  b"AAAAHGVsc3QAAAAAAAAAAQAAAMgAAAAAAAEAAAAAAaVtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAIAFXEAAAAAAAtaGRs",
  b"cgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAFQbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYA",
  b"AAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABEHN0YmwAAACsc3RzZAAAAAAAAAABAAAAnGF2MDEAAAAAAAAAAQAAAAAAAAAA",
  b"AAAAAAAAAAAAQAAwAEgAAABIAAAAAAAAAAEXTGF2YzYzLjEuMTAyIGxpYmFvbS1hdjEAAAAAAAAAAAAY//8AAAAYYXYxQ4EADAAK",
  b"CgAAAAKv95tfIAgAAAAKZmllbAEAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAM0AAAAAAAAAAGHN0dHMAAAAAAAAAAQAA",
  b"AAEAAAgAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAABAAAAAQAAABRzdHN6AAAAAAAAAUgAAAABAAAAFHN0Y28AAAAAAAAAAQAAADAA",
  b"AABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxpbHN0AAAAJKl0b28AAAAcZGF0",
  b"YQAAAAEAAAAATGF2ZjYzLjEuMTAy",
])

///|
let mp4_vp9_b64 : Bytes = bcat([
  b"AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAEsG1kYXSCSYNCAAPwAvYEOCQcGEIAAxB8sXp/TYm6R6v2D1nq",
  b"PRev6f0bRd2PfzQL9/z/kfn0f6bpu6/TaM9X6bdPp7se+wAAf8OZzljCKjN7Piskr+Shhyl9InY1PpxTyWVBU9/yCglGrM/cx3J5",
  b"86VP/RaUAxxcGHX+czvJ4yb2GNXVULhIzkQP5y6IrFuKnQlSmmkpe41H/d37zzwUHSUEFLhSFTCY6xkJZIU/KW7i+fZqQX7pneGZ",
  b"1u22ZAsxKS5codW0dUdMZHWdoDqz7+rRE9MVVE4BpjiYW7JeLnysBUVf4T3J/R7+oMgcJ6fyH/8y68I2xhKKLh//9uutlzJOszRw",
  b"stN5pZwqbL7z7RJDUjSwS/niXDYYCXxryRLLKsn0CA7nvb4ikwHVEKsOUfw/yi5HGqTjqk2yUFl+QbAI1hK0YehBqzaXM9vzTi+x",
  b"CEm8Qbj5KdkpJURrbtY/74XGVe/0SnPSdU4wNeUcdfn4U1wb5gJ3JSV+YOBHK75z6zTQ6DKzirZAnRKsDAhXWtha5H8/9x/SUvbI",
  b"KYiSV4MTSkK4jK7Z78A3Qdf9tt5vEC6PmDGDRKeAd20/oaL4RtHgnYWMzuVR6GasdPuVSI+EbQ+JktTzS3g613taB2SUiRuXgVy+",
  b"7937zdq3AZyapn/jwM4LL/keeI5/78oqxHnAsEOdODuA15qSxmVIISP6zVisLfdosxncp4BeYaZu3/mbBRrHaGtWcx9amyWn9AmX",
  b"e4YweCLj+7YjpCHXEkoEHGcFNEynqkmvz+Ks9Krp3xkQlKDbzX5Hrrsj+zJzqIkpBViaovlq3e//+uYv/5Nv9plq/1xr/H3/+ahR",
  b"47sg3t3p///pmHMjf6JWlP9OjP//tstsC6RUjwd+BKFswyYfExmb/ACyi7CySDiZLbMS0DCA+GICMd8+Vy9xa19aEGMPSbCY/TV+",
  b"q3Rq/soa1ZoKHEjqfM9vuJRhJEFMiaNmk0zzhqVEqO1UO5h7HQYdqFcICRK8ZWjfuLQ0OnpS+j8bhrNsh/vn8i1yvrrhmo4d8hps",
  b"Lrl4URDSqxjtdrBoRBzdR1WQ3Ym09onmeY3Ro5jlrcg20iMUIaJ5juv3zC8yBRf+IsyBMTk5SDnwib4w3ZT2nM+zRQkHPj2eWA/2",
  b"D/8MrmvotWDK2o4ev8L1kcSNf37q8fsTB3Z67UjOn2M/KgMovqhk0zxBX/5iw/7B/xuz/TD/cD/5Yqjf8ljebH//9WYirPpYXQ9d",
  b"mUP4HQzbAXyE5cHIaUMwsauhpq1d5icgpPxZzKLGD//sWr/wAOzOp3gaC1FuWwoF7qt43sQ7BrAiQ1tQq2IiGhhkiQOXnC0l9pjF",
  b"6nk1XJywh5Ndlr6pi5vLicPTp/Zx48NVZ0GL+xMsg9SFhF1STPXUOQ17jU0dzjW/vpZH8okSh6z/mMJcnqyWh5+HebpPuWk0qDla",
  b"dYLNU3C0cYKXpjeYuLUZlgq1vSCmAxFG6Z7BLYaagyPE+d1X1fp+V395AfDM8y06KRWDqtxUfPiErfZlLJjydiV722CpQbJqmJIe",
  b"/8fY08W64mdYOEJSMijQ6UvhBGxbwSro4NZCl6m0jIVKNSwAAAAC/m1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAADIAAEA",
  b"AAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAIAAAIpdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAA",
  b"AQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAMAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAyAAAAAAAAQAAAAABoW1kaWEAAAAg",
  b"bWRoZAAAAAAAAAAAAAAAAAAAKAAAAAgAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAA",
  b"AUxtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAEMc3RibAAAAKhz",
  b"dHNkAAAAAAAAAAEAAACYdnAwOQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAABAADAASAAAAEgAAAAAAAAAARdMYXZjNjMuMS4xMDIg",
  b"bGlidnB4LXZwOQAAAAAAAAAAABj//wAAABR2cGNDAQAAAAAKggICAgAAAAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRy",
  b"dAAAAAAAAMNQAAAAAAAAABhzdHRzAAAAAAAAAAEAAAABAAAIAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAQAAAAEAAAAUc3RzegAA",
  b"AAAAAASoAAAAAQAAABRzdGNvAAAAAAAAAAEAAAAsAAAAYXVkdGEAAABZbWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwA",
  b"AAAAAAAAAAAAAAAsaWxzdAAAACSpdG9vAAAAHGRhdGEAAAABAAAAAExhdmY2My4xLjEwMg==",
])

///|
test "codec params: MP4 AV1 av1C" {
  let bytes = @libavutil.av_base64_decode(mp4_av1_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let p = mp4_track_codec_parameters(movie.tracks[0])
  assert_eq(p.codec, "av1")
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  assert_eq(p.profile, 0)
  assert_eq(p.level, 0)
  assert_eq(p.bit_depth, 8)
  assert_eq(p.chroma_format, 1)
  assert_eq(p.pix_fmt, "yuv420p")
  assert_true(p.extradata_parsed)
}

///|
test "codec params: MP4 VP9 dimensions without vpcC" {
  let bytes = @libavutil.av_base64_decode(mp4_vp9_b64, 100000).unwrap()
  let movie = av_mov_open(bytes).unwrap()
  let p = mp4_track_codec_parameters(movie.tracks[0])
  assert_eq(p.codec, "vp9")
  assert_eq(p.width, 64)
  assert_eq(p.height, 48)
  assert_false(p.extradata_parsed)
}
