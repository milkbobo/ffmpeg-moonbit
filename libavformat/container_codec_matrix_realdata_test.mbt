///|
/// Codec x container integration tests for the still-image and MP3 paths
/// that were previously only reachable through raw elementary streams:
///
///   * MOV/MJPEG (`jpeg` sample entry) and MOV/PNG (`png ` sample entry)
///   * Matroska MJPEG (`V_MJPEG`) and PNG through `V_MS/VFW/FOURCC` (`MPNG`),
///     mirroring FFmpeg's Matroska muxer
///   * WAV carrying MP3 (`0x0055`) and AAC (`0x1610`) payloads
///   * MKV/MP3 (`A_MPEG/L3`) and MKV MJPEG/PNG writing
///
/// Fixtures are FFmpeg 9.0.2 encodings; frame MD5s equal `ffmpeg -f framemd5`
/// for the same decoded frames.

///|
let cmx_mjpeg_mov : Bytes = b64_concat([
  b"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",
])

///|
let cmx_png_mov : Bytes = b64_concat([
  b"AAAAFGZ0eXBxdCAgAAACAHF0ICAAAAAId2lkZQAAB9NtZGF0iVBORw0KGgoAAAANSUhEUgAAAEAAAAAwCAIAAAAuKetIAAAACXBIWXMAAAABAAAAAQBPJcTWAAADkklEQVR4nO1Zb0hTURz9OYVEKiPSKSpGooUfioVRFG4aKOrAjDJBMgb2oVgwkAjEetueimQw2IdhH6ykoNAsKTPFQKcjKBJMCYn1V0JSg8iiMNLZ795rd29zPoOCl+sdxuXcc//snnvvzhu8CCv4IBQE0HAeGbrLIuYX5Foj5QdT+EBuCs2CRqY1asXZ/3EsGrgCOUEN/dJKcGMAcmRPYIXBFAbZEwBDhExjuJzA6kV4GYiHYSzv2dKwjIZULCts41imfSGtPeVJvGfB9QksX60LPWnCd1I6S7RYzud9w3K38Jy3Pha3cf5L14WcZyOMYOk1JnOl6OYU5/dLtcEGEA11DTDXXG17GgNQb0uttx+vsTajXlV1BCYfOhwTlCdh1eFoC718CpMpHz6NtLRMDXmnnGKWs9FpOWMhrhqdMNtkEYYIl+jLQTgrAFx2ucaQm82ZZrPZ5XJRbobpdtSjWN6zzHFbAX6cyrEvDi62jbutzXestPKyTYOd0glt6pzw5badLAYNHaabweVuR9LSMjocS5TWQoCpXkMfgBY8Xv1tAXzWykNsnq+VGrseAD/AdQP9xi3gEc4dQyLWXn0N2Ug6rJ8BTmu69LCZ9Hd2gS9XtBjpPG9FTT/Rw+s3wJBKLs9+JDW2Pqme/x4vzx4kDscjqY67PtwxSlhswDzsZGaLMi3VF6X6Lhh0NpxAEqTjrptq31CaLdULPgyazYeRuFztS/VwPAHMnaOBe8/Qmwi9N+jeJwboLHMYJtf4OTsZj2cDvfGDXH8C+r3VY5QG6CxzGD7CDs574vQ9bdOExQX0Z/rfOQGSOeRH3PuH89DMAbFO/P0hAQYO2AFz867tQQ2Nf4zRZxF5GKNjOhKjL9b6Y7QpYR+J0WWeA2XdxFJrIYnROLzxYtat6Es8Rt+J/hhletoyiztoX4+WvEZ/jDrjBR6jXiON0aAxuNxrGP+2VF5lBJebX47xn8Sr0lFL9x4VXYnWZNJWzKVglYc9EnyQ4dJ5VTpq6d6jcuF8Mi6dVdnqGTGWalEPMDBDy2K6/VKwJ25654Rfkuy99N5LlbJu8tT0eLZSbSdvTRGkfYmeRv+NSu89A1MyuiT/RmM2cZrRRcpwTKHVBdWA0lANKA3VgNJQDSgN1YDSUA0oDdWA0lANKA3VgNIIFwP9sp0i3XKt7hXeUsoOphiQf0s58D+8pVy9UA0oDdWA0lANKI1Vb+AnVQdAgm5kZXsAAAAASUVORK5CYIKJUE5HDQoaCgAAAA1JSERSAAAAQAAAADAIAgAAAC4p60gAAAAJcEhZcwAAAAEAAAABAE8lxNYAAAOdSURBVHic7VltSFNRGH6dQiKVEekUFaWhhT8KwygKNxUUdWBGmSAZA/tRLBhIBGLd3V0VyWCwH8N+WElB4bKkzBQDv0bQh2BKSKxPCUkNIpPCSGfvOYfu7nV6DQxuk/v8eHnO855zOO85Z88Z3LAFWB3hfqXswqLiWOXBFH5QmkK3qFPIRqw6+3+OCAHIDl2D7CWJFBgMNJYmZchWPIFVBlOYFE8ATGEKydA/AbUXsFasrwJiYRjjA96AMRKSMVbw4xgNsyTbXZ4g9iy4OYHx7ablJ437SaKrRI9xIe8Hxn3cKzH7VNgp8j96xrLzbIURjD5zoqgU3Z4S+cNS/dICEA11DTDfXM2/iAKo55PrHSdr7M2oV1Udg8nHTucE5QnYdDo9yy+fwmLJh68jLS1TQ74pl5DpanTZztlIVY0umGuycUOES/SVwJ3nAK663WPIrdZ0q9Xqdrspt8J0G+qyAp7ZZ+HXmRSHEcCILlTMj/fbm+/Zae6NR9cHkEpoU8eEP8dzuhiIgrs3g8vdhaSlZXQ4miithQBTPaZeAD14fca7HPjtlUfYPN8rdXR+pKJucpDMdvByF04gEWqvv4MsJO32bwBndZ1GSCH9XZ3gzxFsZjrPB0HXR/TQ/w1wQN65PolkgsF6Phcgt4bvlXbN/4SXZz8Sp/OJVMddH24fJSxaNjU7mbmidFv1Zam+FwZdDaeQLNFx1y217ynNkuoFnwet1qNI3O62YD30TyBYQt85Lt97hp546LlF9z5epjPPYZjcEODsZLzeLfTGB97152A8UD1GqUxnnsPwBXaLvDvG2O2ZJixG1p/p/+YEiOeQH3HPGuehngNCnfD3Q2QFHHIA+uZ9/lENtX+00ZdheWijYxnERl9vDNhoU9xBYqMrvANlXaSk1kJiozF444XMO5FXRBv9KARslOmGFRZ32LEZS/KZAzbqiuVEG/WZg2wUgcu9gfbPJ4tNRnC5+eVo/wliUzoqeO9RySjRWyz6ivkkbIpmjwQfMly62JSOCt57VC5dTMSlsyZbPSPmUj3qsgJmaCym2y8Fe3FTOyYCkmTvpfdeqpR1kVfT691BtT1iNomT9iW6gf4bld57BqakdUr+jUZtE2laJ4nr0YVCC1oBakMrQG1oBagNrQC1oRWgNrQC1IZWgNrQClAbWgFqY70U0KfYKbxfKdu/yldKxcEUA8pfKQfW91dKtRewVmgFqA2tALWhFaA2Qr6A37zHRIToK8oUAAAAAElFTkSuQmCCAAACyW1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAADIAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAAI1dHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAMAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAAAyAAAAAAAAQAAAAABrW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAKAAAAAgAf/8AAAAAAC1oZGxyAAAAAG1obHJ2aWRlAAAAAAAAAAAAAAAADFZpZGVvSGFuZGxlcgAAAVhtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAsaGRscgAAAABkaGxydXJsIAAAAAAAAAAAAAAAAAtEYXRhSGFuZGxlcgAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAOxzdGJsAAAAgHN0c2QAAAAAAAAAAQAAAHBwbmcgAAAAAAAAAAEAAAAARkZNUAAAAgAAAAIAAEAAMABIAAAASAAAAAAAAAABEExhdmM2My4xLjEwMiBwbmcAAAAAAAAAAAAAAAAAAAAAGP//AAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEAAAAYc3R0cwAAAAAAAAABAAAAAgAABAAAAAAcc3RzYwAAAAAAAAABAAAAAQAAAAIAAAABAAAAHHN0c3oAAAAAAAAAAAAAAAIAAAPgAAAD6wAAABRzdGNvAAAAAAAAAAEAAAAkAAAAIHVkdGEAAAAYqXN3cgAMVcRMYXZmNjMuMS4xMDI=",
])

///|
let cmx_mjpeg_mkv : Bytes = b64_concat([
  b"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",
])

///|
let cmx_png_mkv : Bytes = b64_concat([
  b"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",
])

///|
let cmx_mp3_mkv : Bytes = b64_concat([
  b"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",
])

///|
let cmx_mp3_wav : Bytes = b64_concat([
  b"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",
])

///|
let cmx_aac_wav : Bytes = b64_concat([
  b"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",
])

///|
fn b64_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b in part {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
fn cmx_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
fn cmx_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for p in parts {
    for b in p {
      out.push(b)
    }
  }
  Bytes::from_array(out)
}

///|
let cmx_mjpeg_refs : Array[String] = [
  "165c0e0814efb9df232c034768399071", "9cc1f45c44c82d2d1d02dcceeaf642bc",
]

///|
let cmx_png_refs : Array[String] = [
  "84cf7e4fa6b4f5e6c037b2f465ce8199", "87a8e6c7103ff4c292ff462780e80d86",
]

///|
fn cmx_check_mjpeg_frame(data : Bytes, reference : String) -> Unit raise {
  let img = @libavcodec.av_mjpeg_decode(data).unwrap()
  assert_eq(img.pix_fmt, "yuvj420p")
  assert_eq(img.width, 64)
  assert_eq(img.height, 48)
  assert_eq(cmx_md5(cmx_concat(img.planes)), reference)
}

///|
fn cmx_check_png_frame(data : Bytes, reference : String) -> Unit raise {
  let img = @libavcodec.av_png_decode(data).unwrap()
  assert_eq(img.pix_fmt, "rgb24")
  assert_eq(img.width, 64)
  assert_eq(img.height, 48)
  let packed : Bytes = if img.stride == img.width * 3 {
    img.pixels
  } else {
    let out : Array[Byte] = []
    for y = 0; y < img.height; y = y + 1 {
      let row = y * img.stride
      for x = 0; x < img.width * 3; x = x + 1 {
        out.push(img.pixels[row + x])
      }
    }
    Bytes::from_array(out)
  }
  assert_eq(cmx_md5(packed), reference)
}

///|
fn cmx_mov_samples(data : Bytes, codec : String) -> Array[Bytes] raise {
  let movie = @libavformat.av_mov_open(data).unwrap()
  assert_eq(movie.tracks.length(), 1)
  let track = movie.tracks[0]
  assert_eq(@libavformat.mov_codec_name(track.codec, track.codec_id), codec)
  assert_eq(track.width, 64)
  assert_eq(track.height, 48)
  assert_eq(track.sample_count, 2)
  assert_eq(track.samples.length(), 2)
  let out : Array[Bytes] = []
  for sample in track.samples {
    let start = sample.offset.to_int()
    out.push(data[start:start + sample.size.reinterpret_as_int()].to_owned())
  }
  out
}

///|
test "MOV MJPEG and PNG sample entries decode" {
  let mjpeg = @libavutil.av_base64_decode(cmx_mjpeg_mov, 200000).unwrap()
  let mj = cmx_mov_samples(mjpeg, "mjpeg")
  for i, frame in mj {
    cmx_check_mjpeg_frame(frame, cmx_mjpeg_refs[i])
  }
  let png = @libavutil.av_base64_decode(cmx_png_mov, 200000).unwrap()
  let pn = cmx_mov_samples(png, "png")
  for i, frame in pn {
    cmx_check_png_frame(frame, cmx_png_refs[i])
  }
}

///|
test "Matroska MJPEG and VFW MPNG tracks decode" {
  let mjpeg = @libavutil.av_base64_decode(cmx_mjpeg_mkv, 200000).unwrap()
  let header = @libavformat.av_matroska_open(mjpeg).unwrap()
  assert_eq(header.tracks.length(), 1)
  assert_eq(header.tracks[0].codec_id.unwrap(), "V_MJPEG")
  assert_eq(header.packets.length(), 2)
  for i, packet in header.packets {
    cmx_check_mjpeg_frame(packet.data, cmx_mjpeg_refs[i])
  }
  let png = @libavutil.av_base64_decode(cmx_png_mkv, 200000).unwrap()
  let h2 = @libavformat.av_matroska_open(png).unwrap()
  assert_eq(h2.tracks[0].codec_id.unwrap(), "png")
  assert_eq(h2.tracks[0].codec_priv.unwrap().length(), 40)
  assert_eq(h2.packets.length(), 2)
  for i, packet in h2.packets {
    cmx_check_png_frame(packet.data, cmx_png_refs[i])
  }
}

///|
test "WAV MP3 and AAC payloads demux and decode" {
  let mp3_wav = @libavutil.av_base64_decode(cmx_mp3_wav, 200000).unwrap()
  let wav = @libavformat.av_wav_open(mp3_wav).unwrap()
  assert_eq(wav.format.codec, "mp3")
  assert_eq(wav.format.channels, 1)
  assert_eq(wav.format.sample_rate, 44100)
  assert_eq(wav.format.extradata.length(), 12)
  let start = wav.data_offset.to_int()
  let mp3_data = mp3_wav[start:start + wav.data_size.to_int()].to_owned()
  let track = @libavformat.av_mp3_open(mp3_data).unwrap()
  assert_eq(track.sample_rate, 44100)
  assert_eq(track.channels, 1)
  assert_true(track.frames.length() > 0)
  let dec = @libavcodec.new_mp3_decoder()
  let mut total = 0
  for frame in track.frames {
    let begin = frame.pos.to_int()
    let pcm = dec
      .decode_frame(mp3_data[begin:begin + frame.size].to_owned())
      .unwrap()
    assert_eq(pcm.sample_rate, 44100)
    assert_eq(pcm.channels, 1)
    total = total + pcm.samples.length()
  }
  assert_true(total > 0)
  let aac_wav = @libavutil.av_base64_decode(cmx_aac_wav, 200000).unwrap()
  let awav = @libavformat.av_wav_open(aac_wav).unwrap()
  assert_eq(awav.format.codec, "aac")
  assert_eq(awav.format.channels, 1)
  assert_eq(awav.format.sample_rate, 44100)
  assert_eq(awav.format.extradata.length(), 5)
  assert_eq(awav.packets.length(), 3)
  // WAV raw AAC is stored in fixed-size chunks (block_align), so only the
  // first packet starts on a frame boundary; splitting the remaining chunks
  // needs the AAC parser, which this port does not implement.
  let adec = @libavcodec.new_aac_decoder_from_asc(awav.format.extradata).unwrap()
  let first = awav.packets[0]
  let begin = first.pos.to_int()
  let frames = adec
    .decode_frame(aac_wav[begin:begin + first.size].to_owned())
    .unwrap()
  assert_eq(frames.length(), 1)
  assert_eq(frames[0].samples.length(), 1024)
}

///|
test "MKV MP3 muxer round-trips A_MPEG/L3" {
  let ffmpeg_mkv = @libavutil.av_base64_decode(cmx_mp3_mkv, 200000).unwrap()
  let ff_header = @libavformat.av_matroska_open(ffmpeg_mkv).unwrap()
  assert_eq(ff_header.tracks[0].codec_id.unwrap(), "A_MPEG/L3")
  assert_eq(ff_header.packets.length(), 9)
  let probe = @libavcodec.new_mp3_decoder()
  let probe_pcm = probe.decode_frame(ff_header.packets[0].data).unwrap()
  assert_eq(probe_pcm.samples.length(), 1152)
  let mp3_wav = @libavutil.av_base64_decode(cmx_mp3_wav, 200000).unwrap()
  let wav = @libavformat.av_wav_open(mp3_wav).unwrap()
  let start = wav.data_offset.to_int()
  let mp3_data = mp3_wav[start:start + wav.data_size.to_int()].to_owned()
  let track = @libavformat.av_mp3_open(mp3_data).unwrap()
  let mux = @libavformat.mkv_mp3_muxer_new(44100, 1).unwrap()
  let frames : Array[Bytes] = []
  for frame in track.frames {
    let begin = frame.pos.to_int()
    let payload = mp3_data[begin:begin + frame.size].to_owned()
    let pts = frame.pts * 1000L / 44100L
    mux.write_packet(payload, pts, 26).unwrap()
    frames.push(payload)
  }
  let bytes = mux.finish()
  let header = @libavformat.av_matroska_open(bytes).unwrap()
  assert_eq(header.tracks.length(), 1)
  assert_eq(header.tracks[0].codec_id.unwrap(), "A_MPEG/L3")
  assert_eq(header.packets.length(), frames.length())
  for i, packet in header.packets {
    assert_eq(packet.data, frames[i])
  }
  let dec = @libavcodec.new_mp3_decoder()
  let pcm = dec.decode_frame(header.packets[0].data).unwrap()
  assert_eq(pcm.samples.length(), 1152)
  assert_eq(pcm.sample_rate, 44100)
}

///|
test "MKV MJPEG and PNG muxers round-trip and decode" {
  let mjpeg_mov = @libavutil.av_base64_decode(cmx_mjpeg_mov, 200000).unwrap()
  let mj = cmx_mov_samples(mjpeg_mov, "mjpeg")
  let mj_mux = @libavformat.mkv_mjpeg_muxer_new(64, 48).unwrap()
  for i, frame in mj {
    mj_mux.write_packet(frame, (i * 100).to_int64(), 100).unwrap()
  }
  let mj_bytes = mj_mux.finish()
  let mj_header = @libavformat.av_matroska_open(mj_bytes).unwrap()
  assert_eq(mj_header.tracks[0].codec_id.unwrap(), "V_MJPEG")
  assert_eq(mj_header.packets.length(), 2)
  for i, packet in mj_header.packets {
    assert_eq(packet.data, mj[i])
    cmx_check_mjpeg_frame(packet.data, cmx_mjpeg_refs[i])
  }
  let png_mov = @libavutil.av_base64_decode(cmx_png_mov, 200000).unwrap()
  let pn = cmx_mov_samples(png_mov, "png")
  let pn_mux = @libavformat.mkv_png_muxer_new(64, 48).unwrap()
  for i, frame in pn {
    pn_mux.write_packet(frame, (i * 100).to_int64(), 100).unwrap()
  }
  let pn_bytes = pn_mux.finish()
  let pn_header = @libavformat.av_matroska_open(pn_bytes).unwrap()
  assert_eq(pn_header.tracks[0].codec_id.unwrap(), "png")
  assert_eq(pn_header.tracks[0].codec_priv.unwrap().length(), 40)
  assert_eq(pn_header.packets.length(), 2)
  for i, packet in pn_header.packets {
    assert_eq(packet.data, pn[i])
    cmx_check_png_frame(packet.data, cmx_png_refs[i])
  }
}

///|
test "MP4 MJPEG and PNG muxers round-trip and decode" {
  let mjpeg_mov = @libavutil.av_base64_decode(cmx_mjpeg_mov, 200000).unwrap()
  let mj = cmx_mov_samples(mjpeg_mov, "mjpeg")
  let mj_mux = @libavformat.mp4_mjpeg_muxer_new(64, 48).unwrap()
  for frame in mj {
    mj_mux.write_packet(frame, duration=3000).unwrap()
  }
  let mj_bytes = mj_mux.finish()
  let mj_movie = @libavformat.av_mov_open(mj_bytes).unwrap()
  assert_eq(mj_movie.tracks.length(), 1)
  let mj_track = mj_movie.tracks[0]
  assert_eq(
    @libavformat.mov_codec_name(mj_track.codec, mj_track.codec_id),
    "mjpeg",
  )
  assert_eq(mj_track.width, 64)
  assert_eq(mj_track.height, 48)
  assert_eq(mj_track.sample_count, 2)
  for i, sample in mj_track.samples {
    let start = sample.offset.to_int()
    let frame = mj_bytes[start:start + sample.size.reinterpret_as_int()].to_owned()
    assert_eq(frame, mj[i])
    cmx_check_mjpeg_frame(frame, cmx_mjpeg_refs[i])
  }
  let png_mov = @libavutil.av_base64_decode(cmx_png_mov, 200000).unwrap()
  let pn = cmx_mov_samples(png_mov, "png")
  let pn_mux = @libavformat.mp4_png_muxer_new(64, 48).unwrap()
  for frame in pn {
    pn_mux.write_packet(frame, duration=3000).unwrap()
  }
  let pn_bytes = pn_mux.finish()
  let pn_movie = @libavformat.av_mov_open(pn_bytes).unwrap()
  let pn_track = pn_movie.tracks[0]
  assert_eq(
    @libavformat.mov_codec_name(pn_track.codec, pn_track.codec_id),
    "png",
  )
  assert_eq(pn_track.width, 64)
  assert_eq(pn_track.height, 48)
  assert_eq(pn_track.sample_count, 2)
  for i, sample in pn_track.samples {
    let start = sample.offset.to_int()
    let frame = pn_bytes[start:start + sample.size.reinterpret_as_int()].to_owned()
    assert_eq(frame, pn[i])
    cmx_check_png_frame(frame, cmx_png_refs[i])
  }
}
