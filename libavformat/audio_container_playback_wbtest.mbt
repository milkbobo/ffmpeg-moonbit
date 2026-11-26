///|
/// FFmpeg 9.0.2 generated each fixture from
/// `-f lavfi -i sine=frequency=997:sample_rate=8000:duration=0.004`.
/// References use `-c:a pcm_s16le -f md5`; the G.726LE encode uses `-b:a 32k`.
test "AU, CAF and Wave64 playback matches FFmpeg s16 PCM" {
  let cases = [
    (
      "au", "pcm_alaw", 32, b"LnNuZAAAACAAAAAgAAAAGwAAH0AAAAABAAAAAAAAAADVk5qT1xMaElCTmpLSEBoSXJCaktkQGhJbkJqdxRAaHQ==",
      "7ac5577768f3560e1742645f74b0243b",
    ),
    (
      "au", "pcm_mulaw", 32, b"LnNuZAAAACAAAAAgAAAAAQAAH0AAAAABAAAAAAAAAAD/uK+4+jgvN3W4r7fwOS83bbmvt+s5Lzdpua+25jkvNg==",
      "ed4add9209c9cc1af98bf47e262c2ad8",
    ),
    (
      "au", "adpcm_g726le", 32, b"LnNuZAAAACAAAAAQAAAAFwAAH0AAAAABAAAAAAAAAAB/d4GIfyfPy081v8pPRb/K",
      "68d244ad4c4c8a1596126bd54adeeab1",
    ),
    (
      "au", "pcm_f32be", 32, b"LnNuZAAAACAAAACAAAAABgAAH0AAAAABAAAAAAAAAAAAAAAAPbSAAD3/8AA9tkAAOpwAAL2y0AC9//AAvbgAALscAAA9sRAAPf/gAD25oAA7aAAAva9gAL3/0AC9u1AAu5sAAD2tkAA9/7AAPbzwADvBAAC9q8AAvf+gAL2+kAC75wAAPaoAAD3/cAA9wCAAPAeAAL2oMAC9/1AAvcGwAA==",
      "46f5842a9dee8206b0a65cd96e987772",
    ),
    (
      "au", "pcm_f64be", 32, b"LnNuZAAAACAAAAEAAAAABwAAH0AAAAABAAAAAAAAAAAAAAAAAAAAAD+2kAAAAAAAP7/+AAAAAAA/tsgAAAAAAD9TgAAAAAAAv7ZaAAAAAAC/v/4AAAAAAL+3AAAAAAAAv2OAAAAAAAA/tiIAAAAAAD+//AAAAAAAP7c0AAAAAAA/bQAAAAAAAL+17AAAAAAAv7/6AAAAAAC/t2oAAAAAAL9zYAAAAAAAP7WyAAAAAAA/v/YAAAAAAD+3ngAAAAAAP3ggAAAAAAC/tXgAAAAAAL+/9AAAAAAAv7fSAAAAAAC/fOAAAAAAAD+1QAAAAAAAP7/uAAAAAAA/uAQAAAAAAD+A8AAAAAAAv7UGAAAAAAC/v+oAAAAAAL+4NgAAAAAA",
      "46f5842a9dee8206b0a65cd96e987772",
    ),
    (
      "w64", "pcm_f32le", 32, b"cmlmZi6RzxGl1ijbBMEAABABAAAAAAAAd2F2ZfOs0xGM0QDAT47bimZtdCDzrNMRjNEAwE+O24owAAAAAAAAAAMAAQBAHwAAAH0AAAQAIAAAAAAAAAAAAGZhY3TzrNMRjNEAwE+O24ogAAAAAAAAACAAAAAAAAAAZGF0YfOs0xGM0QDAT47bipgAAAAAAAAAAAAAAACAtD0A8P89AEC2PQAAnDoA0LK9APD/vQAAuL0AABy7ABCxPQDg/z0AoLk9AABoOwBgr70A0P+9AFC7vQAAm7sAkK09ALD/PQDwvD0AAME7AMCrvQCg/70AkL69AADnuwAAqj0AcP89ACDAPQCABzwAMKi9AFD/vQCwwb0=",
      "46f5842a9dee8206b0a65cd96e987772",
    ),
    (
      "caf", "pcm_f64le", 32, b"Y2FmZgABAABkZXNjAAAAAAAAACBAv0AAAAAAAGxwY20AAAADAAAACAAAAAEAAAABAAAAQGNoYW4AAAAAAAAADABkAAEAAAAAAAAAAGluZm8AAAAAAAAAGQAAAAFlbmNvZGVyAExhdmY2My4xLjEwMgBkYXRhAAAAAAAAAQQAAAAAAAAAAAAAAAAAAAAAAJC2PwAAAAAA/r8/AAAAAADItj8AAAAAAIBTPwAAAAAAWra/AAAAAAD+v78AAAAAAAC3vwAAAAAAgGO/AAAAAAAitj8AAAAAAPy/PwAAAAAANLc/AAAAAAAAbT8AAAAAAOy1vwAAAAAA+r+/AAAAAABqt78AAAAAAGBzvwAAAAAAsrU/AAAAAAD2vz8AAAAAAJ63PwAAAAAAIHg/AAAAAAB4tb8AAAAAAPS/vwAAAAAA0re/AAAAAADgfL8AAAAAAEC1PwAAAAAA7r8/AAAAAAAEuD8AAAAAAPCAPwAAAAAABrW/AAAAAADqv78AAAAAADa4vw==",
      "46f5842a9dee8206b0a65cd96e987772",
    ),
    (
      "w64", "pcm_u8", 32, b"cmlmZi6RzxGl1ijbBMEAAIgAAAAAAAAAd2F2ZfOs0xGM0QDAT47bimZtdCDzrNMRjNEAwE+O24ooAAAAAAAAAAEAAQBAHwAAQB8AAAEACABkYXRh86zTEYzRAMBPjtuKOAAAAAAAAACAi4+LgHRwdH+Lj4uAdXB0f4qPi4B1cHR/io+MgXVwcw==",
      "0880962e23f4f4bfc28bbf3c84f5f85d",
    ),
  ]
  for (container, codec, count, b64, md5) in cases {
    let data = @libavutil.av_base64_decode(b64, 1024).unwrap()
    let decoded = decode_audio_file(data)
    assert_eq(decoded.format_name, container, msg=codec)
    assert_eq(decoded.codec_id, codec, msg=codec)
    assert_eq(decoded.sample_rate, 8000, msg=codec)
    assert_eq(decoded.channels, 1, msg=codec)
    assert_eq(
      decoded.duration_seconds,
      Some(count.to_double() / 8000.0),
      msg=codec,
    )
    assert_eq(decoded.samples[0].length(), count, msg=codec)
    let wav = decoded.to_wav_s16()
    let pcm = av_wav_open(wav).unwrap()
    let start = pcm.data_offset.to_int()
    let bytes = wav[start:start + pcm.data_size.to_int()].to_owned()
    assert_eq(caf_md5(bytes), md5, msg=codec)
  }
}
