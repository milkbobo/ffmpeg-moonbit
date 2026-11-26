///|
/// FFmpeg 9.0.2 `-c:a adpcm_adx` from 997/1201 Hz stereo sine waves:
/// 0.003 seconds at 44100 Hz stereo and downmixed at 22050 Hz mono.
let adx_stereo_fixture = b"gAAAIAMSBAIAAKxEAAAAoAH0AwAAAAAAAAAAAAAAKGMpQ1JJAWwHEhAgEADw8O/+/+/+//DwAU4HEgEB8eD+/+/v4OD/EBARAEriEkRlZ3dnd2REMQD928qpAF90VWVUNCEA/dzLu6u73O/hAEqoqKqq3N/xA0NlZnd3d2RTAEgiNlZ3d3ZVMy8N3KuZmZqrAEFBL/3buaiYiIiqvM/hEkRlAEjN/wJDVmd3d2VEIfDOq6maAa8RIGgAAAAAAAAAAAAAAAAABB/wD3wAAAAAAAAAAAAAAAAAgAEADgAAAAAAAAAAAAAAAAAA"

///|
let adx_mono_fixture = b"gAAAIAMSBAEAAFYiAAAAgAH0AwAAAAAAAAAAAAAAKGMpQ1JJAd8nQi/+3NztDyEzMzEQ/+3uAFuJwDVndlMgDu/gAAD+3MrMAr8AewAAAAAAAAAAAAAAAAAAgAEADgAAAAAAAAAAAAAAAAAA"

///|
/// FFmpeg 9.0.2 `-c:a g726` at 16/24/32/40 kb/s from the same 8 kHz,
/// 997 Hz, 0.008-second mono sine. Reference format: pcm_s16le.
let g726_wav_fixtures : Array[(Bytes, String)] = [
  (
    b"UklGRmQAAABXQVZFZm10IBIAAABFAAEAQB8AANAHAAABAAIAAABmYWN0BAAAAEAAAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2My4xLjEwMgAAZGF0YRAAAAAVKtUqFO/U+wT7BPsE+9D7",
    "707dc88f8e25ec2bc54882f1df2b75c0",
  ),
  (
    b"UklGRmwAAABXQVZFZm10IBIAAABFAAEAQB8AALgLAAADAAMAAABmYWN0BAAAAEAAAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2My4xLjEwMgAAZGF0YRgAAADtsyTNvyXpL23pL23pL23pLW3pH2blH20=",
    "b15e5c885f4af1912cbb4091ef9417c1",
  ),
  (
    b"UklGRnQAAABXQVZFZm10IBIAAABFAAEAQB8AAKAPAAABAAQAAABmYWN0BAAAAEAAAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2My4xLjEwMgAAZGF0YSAAAAD3dxiI93L8vPRT+6z0VPus9VP7rPVT+6z0U/ud9ETrrA==",
    "825a9afc1d1c2e3e4aa53487518d9049",
  ),
  (
    b"UklGRnwAAABXQVZFZm10IBIAAABFAAEAQB8AAIgTAAAFAAUAAABmYWN0BAAAAEAAAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2My4xLjEwMgAAZGF0YSgAAAD73vHCEPvez1KX+hJ/4tj6EH/i2foSb+LZ+hB/4tkJ0m/i2QnSb+LZ",
    "c81f8872496d317c483c50a116adfe62",
  ),
]

///|
fn adx_g726_pcm_md5(audio : DecodedAudio) -> String raise MediaError {
  let wav = audio.to_wav_s16()
  let demux = av_wav_open(wav).unwrap()
  let start = demux.data_offset.to_int()
  caf_md5(wav[start:start + demux.data_size.to_int()].to_owned())
}

///|
test "ADX mono and stereo match FFmpeg PCM with terminal blocks skipped" {
  for
    (b64, rate, channels, frame_count, md5) in [
      (adx_mono_fixture, 22050, 1, 3, "7e220ff427ef99112458a80f2a7dd7ce"),
      (adx_stereo_fixture, 44100, 2, 5, "1ef18754605d1791b614696d76543111"),
    ] {
    let bytes = @libavutil.av_base64_decode(b64, 512).unwrap()
    let track = av_adx_open(bytes).unwrap()
    assert_eq(track.frames.length(), frame_count)
    for i, packet in track.frames {
      assert_eq(packet.pos, (36 + i * 18 * channels).to_int64())
      assert_eq(packet.size, channels * 18)
      assert_eq(packet.pts, i.to_int64() * 32L)
      assert_eq(packet.duration, 32)
    }
    let audio = decode_audio_file(bytes)
    assert_eq(audio.format_name, "adx")
    assert_eq(audio.codec_id, "adpcm_adx")
    assert_eq(audio.sample_rate, rate)
    assert_eq(audio.channels, channels)
    assert_eq(audio.samples[0].length(), frame_count * 32)
    assert_eq(adx_g726_pcm_md5(audio), md5)
  }
}

///|
test "ADX rejects a partial channel group and encrypted stream" {
  let file = @libavutil.av_base64_decode(adx_stereo_fixture, 512).unwrap()
  assert_true(
    av_adx_open(file[:71].to_owned()) is Err("adx: truncated channel block"),
  )
  let encrypted = file.to_array()
  encrypted[19] = 8
  assert_true(
    av_adx_open(Bytes::from_array(encrypted))
    is Err("adx: unsupported encoding or encryption"),
  )
}

///|
test "WAV G.726 matches FFmpeg in all four code widths" {
  for i, fixture in g726_wav_fixtures {
    let (b64, md5) = fixture
    let file = @libavutil.av_base64_decode(b64, 256).unwrap()
    let demux = av_wav_open(file).unwrap()
    assert_eq(demux.format.bits_per_sample, i + 2)
    assert_eq(demux.packets[0].duration, 64)
    let audio = decode_audio_file(file)
    assert_eq(audio.codec_id, "adpcm_g726")
    assert_eq(audio.sample_rate, 8000)
    assert_eq(audio.samples[0].length(), 64)
    assert_eq(adx_g726_pcm_md5(audio), md5)
  }
}

///|
test "WAV G.726 preserves odd-width codewords across packets" {
  for width in [3, 5] {
    let (b64, _) = g726_wav_fixtures[width - 2]
    let original = @libavutil.av_base64_decode(b64, 256).unwrap()
    let payload = original[92:]
    let out = original[:92].to_owned().to_array()
    out[32] = 1 // Even with a declared byte alignment, align the codewords.
    for _ in 0..<16 {
      for byte in payload {
        out.push(byte)
      }
    }
    for
      (offset, word) in [
        (4, out.length() - 8),
        (46, 16 * 64),
        (88, 16 * payload.length()),
      ] {
      for i in 0..<4 {
        out[offset + i] = (word >> (i * 8)).to_byte()
      }
    }
    let data = Bytes::from_array(out)
    let demux = av_wav_open(data).unwrap()
    assert_true(demux.packets.length() > 1)
    let mut pts = 0L
    for packet in demux.packets {
      assert_eq(packet.size % width, 0)
      assert_eq(packet.pts, pts)
      pts += packet.duration.to_int64()
    }
    assert_eq(pts, 1024L)
    assert_eq(decode_audio_file(data).samples[0].length(), 1024)
  }
}
