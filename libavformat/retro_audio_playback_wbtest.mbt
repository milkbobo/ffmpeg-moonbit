///|
/// FFmpeg 9.0.2 reference PCM: `-c:a pcm_s16le -f md5`. The SVX
/// cases contain an odd-sized ANNO chunk and distinct channel planes.
/// The PCM and G.711 VOC files use a stereo 8 kHz sine pair
/// (997/1201 Hz, 0.004 seconds). Each crafted SBPro VOC has a first
/// sound block, an intervening text block, and a continuation block.
let retro_audio_fixtures : Array[(String, String, Int32, Int32, Bytes, String)] = [
  (
    "iff", "pcm_s8_planar", 2, 5, b"Rk9STQAAAEo4U1ZYVkhEUgAAABQAAAAGAAAAAAAAAAAfQAEAAAEAAEFOTk8AAAADb2RkAENIQU4AAAAEAAAABkJPRFkAAAAKAH+A/0CAfwABwA==",
    "996baf5dadb0dd3084e26e0b7e659939",
  ),
  (
    "iff", "pcm_s16be_planar", 2, 3, b"Rk9STQAAAEwxNlNWVkhEUgAAABQAAAAGAAAAAAAAAAAfQAEAAAEAAEFOTk8AAAADb2RkAENIQU4AAAAEAAAABkJPRFkAAAAMAAB//4AAgABAAP//",
    "87c9ab2b9bf2967431161d0e6eabea6c",
  ),
  (
    "iff", "8svx_fib", 2, 8, b"Rk9STQAAAEw4U1ZYVkhEUgAAABQAAAAGAAAAAAAAAAAfQAEBAAEAAEFOTk8AAAADb2RkAENIQU4AAAAEAAAABkJPRFkAAAAMAHj/ABjKAJAA/3Kl",
    "031e1c0cad735945a927864558e41432",
  ),
  (
    "iff", "8svx_exp", 1, 10, b"Rk9STQAAADw4U1ZYVkhEUgAAABQAAAAGAAAAAAAAAAAfQAECAAEAAEFOTk8AAAADb2RkAEJPRFkAAAAHAED/AOH0agA=",
    "1ffb729b45ba54262214508afafb2e8a",
  ),
  (
    "voc", "pcm_u8", 2, 32, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEIBAAAgMEAAQFCAACDAICmpJezdKRbgGFcgE2fW6R/jKNps1qlaoGMXaVNn1uAfmGjXLN1ppeCpl6WTXRaW31hooGzoKakg4teaU1aWWoA",
    "cdf6bfa48713e34c6773a0125dbe8ddc",
  ),
  (
    "voc", "pcm_s16le", 2, 32, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEJjAAAQB8AABACBAAAAAAAAABmJh4kjBYzMxT0dSR023wAAeE63CcAzswsHzTbdCQJ/6MLbiM26TAzmtkhJbPpcwE2DOzcpCTUzNEeitqM/xL+p+C6IqTbJzOn9MolCBdpAmUmot0OFt7MgfPj2UXbG/1d4QIiwQAbM4UfbyZDJGADDwta3rro7syc2UDZMeoA",
    "e4b19049d5e2b8e091fc340e8cf3693d",
  ),
  (
    "voc", "pcm_alaw", 2, 32, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEJTAAAQB8AAAgCBgAAAAAA1ba3g7wStzfSCjTXPIo3t1qStAO8NrcDwp00tzyLN1JKCrQ3vBO3gva2NIM8HDY3cgu02byKtrf+kzUCPDY2AAA=",
    "2d617c1fa6d4c33e69c10cf743752fbb",
  ),
  (
    "voc", "pcm_mulaw", 2, 32, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEJTAAAQB8AAAgCBwAAAAAA/5ydqJY3nR3wIB36FqAdnWi3niiWHJ0p4LYenRagHXBcIJ4dljicqNicHqkWNRwdVCCe65agnJ3QuB4oFhwcKQA=",
    "215b9054544d7a4f3c84990c4d2ccaa5",
  ),
  (
    "voc", "adpcm_sbpro_2", 1, 33, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEBBwAAgwPA/xehzAUFAABub3RlAAIEAABC8QCXAA==",
    "7e9c5817f6875b41a6f7495b3792ecf4",
  ),
  (
    "voc", "adpcm_sbpro_3", 1, 25, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEBBwAAgwLA/xehzAUFAABub3RlAAIEAABC8QCXAA==",
    "f040f699421160cc092af29f06f06489",
  ),
  (
    "voc", "adpcm_sbpro_4", 2, 9, b"Q3JlYXRpdmUgVm9pY2UgRmlsZRoaABQBHxEIBAAAgMEBAQEIAACDAcAQ/xehzAUFAABub3RlAAIEAABC8QCXAA==",
    "c08a9c4060d9d2f6b09e8689c7b35e55",
  ),
]

///|
test "SVX and VOC playback matches FFmpeg PCM" {
  for (format, codec, channels, count, b64, md5) in retro_audio_fixtures {
    let file = @libavutil.av_base64_decode(b64, 512).unwrap()
    let decoded = decode_audio_file(file)
    assert_eq(decoded.format_name, format, msg=codec)
    assert_eq(decoded.codec_id, codec, msg=codec)
    assert_eq(decoded.channels, channels, msg=codec)
    assert_eq(decoded.sample_rate, 8000, msg=codec)
    assert_eq(decoded.samples[0].length(), count, msg=codec)
    assert_eq(
      decoded.duration_seconds,
      Some(count.to_double() / 8000.0),
      msg=codec,
    )
    let wav = decoded.to_wav_s16()
    let demux = av_wav_open(wav).unwrap()
    let start = demux.data_offset.to_int()
    assert_eq(
      caf_md5(wav[start:start + demux.data_size.to_int()].to_owned()),
      md5,
      msg=codec,
    )
  }
}

///|
test "VOC continuation timestamps account for the ADPCM seed once" {
  let (_, _, _, _, b64, _) = retro_audio_fixtures[10]
  let file = @libavutil.av_base64_decode(b64, 512).unwrap()
  let demux = av_voc_open(file).unwrap()
  assert_eq(demux.frames.map(p => (p.pts, p.duration, p.size)), [
    (0L, 5, 6),
    (5L, 4, 4),
  ])
  let truncated = file[:file.length() - 2].to_owned()
  assert_true(av_voc_open(truncated) is Err("voc: truncated block"))
  let (_, _, _, _, svx, _) = retro_audio_fixtures[0]
  let iff = @libavutil.av_base64_decode(svx, 512).unwrap()
  assert_true(
    av_svx_open(iff[:iff.length() - 1].to_owned())
    is Err("svx: invalid FORM size"),
  )
}
