///|
/// The stereo fixtures contain the first few codes from two FATE blocks.
/// The mono fixture exercises DK4's high-nibble-first packing.
test "Duck IMA WAV playback matches FFmpeg PCM and block timestamps" {
  for
    (encoded, codec, channels, block_size, durations, hash) in [
      (
        b"UklGRloAAABXQVZFZm10IBIAAABiAAIARKwAAD51AQAaAAQAAABkYXRhNAAAAAAARKwAAJQKAACoDekDJiT/34yACIAACAgIAABErAAAlAoAAGcMBvQvNCoA2YCTkIkgMQo=",
        "adpcm_ima_dk3",
        2,
        26,
        [12, 12],
        "2421977e5aead1f497af004fde3e26e2",
      ),
      (
        b"UklGRkwAAABXQVZFZm10IBIAAABhAAIARKwAAMEQAQATAAQAAABkYXRhJgAAAOvwNAACCCwAfzyACIAIgAiACIiV/DAA9/otALzJmAMjMiCJm7iB",
        "adpcm_ima_dk4",
        2,
        19,
        [12, 12],
        "2adf11eb240c28b7f66576a2b10959bf",
      ),
      (
        b"UklGRjAAAABXQVZFZm10IBIAAABhAAEARKwAAI6PAAAKAAQAAABkYXRhCgAAABj8KAB4Eyr/HqM=",
        "adpcm_ima_dk4",
        1,
        10,
        [13],
        "415079f6b159b4ace562a46c120233c5",
      ),
    ] {
    let file = @libavutil.av_base64_decode(encoded, 256).unwrap()
    let demux = av_wav_open(file).unwrap()
    assert_eq(demux.format.codec, codec)
    assert_eq(demux.format.block_align, block_size)
    assert_eq(demux.packets.map(p => p.duration), durations)
    let mut pts = 0L
    for p in demux.packets {
      assert_eq(p.pts, pts)
      assert_eq(p.size, block_size)
      pts += p.duration.to_int64()
    }
    assert_eq(demux.sample_count, pts)
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, "wav")
    assert_eq(audio.codec_id, codec)
    assert_eq(audio.sample_rate, 44100)
    assert_eq(audio.channels, channels)
    let wave = audio.to_wav_s16()
    let wav = av_wav_open(wave).unwrap()
    assert_eq(wav.data_size, pts * channels.to_int64() * 2L)
    assert_eq(caf_md5(wave[wav.data_offset.to_int():].to_owned()), hash)
  }
}

///|
test "Duck IMA rejects invalid channel layout, short blocks and bad indexes" {
  assert_true(
    @libavcodec.adpcm_decoder_new("adpcm_ima_dk3", 1)
    is Err("adpcm: Duck IMA DK3 requires stereo"),
  )
  let dk3 = @libavcodec.adpcm_decoder_new("adpcm_ima_dk3", 2).unwrap()
  assert_true(
    dk3.decode_block(Bytes::make(17, 0))
    is Err("adpcm: invalid Duck IMA block or channel count"),
  )
  let dk4 = @libavcodec.adpcm_decoder_new("adpcm_ima_dk4", 1).unwrap()
  assert_true(
    dk4.decode_block(b"\x00\x00\xff\xff")
    is Err("adpcm: invalid Duck IMA step index"),
  )
  assert_eq(dk4.decode_block(b"\xff\xff\x00\x00").unwrap().samples, [-1])
}
