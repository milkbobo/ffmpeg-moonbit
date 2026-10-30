///|
/// WAV A-law/mu-law muxer: the header matches FFmpeg's `wavenc.c`
/// (WAVE_FORMATEX cbSize=0 + `fact`) and the G.711 payload round-trips
/// through the existing WAV demuxer.

///|
let wav_compand_samples : Array[Int32] = [
  0, 1000, -1000, 32767, -32768, 1234, -2345, 5000, -5000, 100, -100, 30000, -30000,
  7, -7, 20000,
]

///|
test "wav muxer: A-law layout and payload match ffmpeg" {
  let mux = wav_muxer_new(8000, 1, 8, companding="alaw").unwrap()
  mux.write_samples(wav_compand_samples[:])
  let bytes = mux.finish()
  assert_eq(bytes.length(), 74)
  assert_eq(bytes[0:4], b"RIFF"[:])
  assert_eq(bytes[4:8], b"\x42\x00\x00\x00"[:])
  assert_eq(bytes[12:16], b"fmt "[:])
  assert_eq(bytes[16:20], b"\x12\x00\x00\x00"[:]) // WAVEFORMATEX
  assert_eq(bytes[20:22], b"\x06\x00"[:]) // WAVE_FORMAT_ALAW
  assert_eq(bytes[32:34], b"\x01\x00"[:]) // block align
  assert_eq(bytes[34:36], b"\x08\x00"[:]) // bits
  assert_eq(bytes[36:38], b"\x00\x00"[:]) // cbSize
  assert_eq(bytes[38:42], b"fact"[:])
  assert_eq(bytes[46:50], b"\x10\x00\x00\x00"[:]) // 16 frames
  assert_eq(bytes[50:54], b"data"[:])
  assert_eq(
    bytes[58:74].to_owned(),
    b"\xd5\xfa\x7a\xaa\x2a\xe6\x17\x86\x06\xd3\x53\xa8\x28\xd5\x55\xa6",
  )
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_alaw")
  assert_eq(demux.format.channels, 1)
  assert_eq(demux.format.sample_rate, 8000)
  assert_eq(demux.format.bits_per_sample, 8)
  assert_eq(demux.format.block_align, 1)
  assert_eq(demux.data_size, 16L)
  assert_eq(demux.sample_count, 16L)
}

///|
test "wav muxer: mu-law layout and payload match ffmpeg" {
  let mux = wav_muxer_new(8000, 1, 8, companding="mulaw").unwrap()
  mux.write_samples(wav_compand_samples[:])
  let bytes = mux.finish()
  assert_eq(bytes.length(), 74)
  assert_eq(bytes[20:22], b"\x07\x00"[:]) // WAVE_FORMAT_MULAW
  assert_eq(bytes[36:38], b"\x00\x00"[:]) // cbSize
  assert_eq(
    bytes[58:74].to_owned(),
    b"\xff\xce\x4e\x80\x00\xca\x3c\xab\x2b\xf2\x72\x82\x02\xfe\x7e\x8c",
  )
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_mulaw")
  assert_eq(demux.sample_count, 16L)
}

///|
test "wav muxer: 6-channel A-law uses the extensible subformat" {
  let mux = wav_muxer_new(48000, 6, 8, channel_mask=0x3FU, companding="alaw").unwrap()
  mux.write_samples(Array::make(12, 0)[:])
  let bytes = mux.finish()
  assert_eq(bytes[20:22], b"\xfe\xff"[:]) // WAVE_FORMAT_EXTENSIBLE
  assert_eq(bytes[36:38], b"\x16\x00"[:]) // cbSize = 22
  assert_eq(bytes[38:40], b"\x08\x00"[:]) // valid bits
  assert_eq(bytes[40:44], b"\x3f\x00\x00\x00"[:]) // channel mask
  assert_eq(bytes[44:48], b"\x06\x00\x00\x00"[:]) // A-law subformat
  let demux = av_wav_open(bytes).unwrap()
  assert_eq(demux.format.codec, "pcm_alaw")
  assert_eq(demux.format.channels, 6)
  assert_eq(demux.format.block_align, 6)
  assert_eq(demux.sample_count, 2L)
}

///|
fn wav_compand_rejects(result : Result[WavMuxer, String]) -> Unit raise {
  match result {
    Ok(_) => fail("expected companding parameter error")
    Err(_) => ()
  }
}

///|
test "wav muxer: invalid companding parameters are rejected" {
  wav_compand_rejects(wav_muxer_new(8000, 1, 16, companding="alaw"))
  wav_compand_rejects(wav_muxer_new(8000, 1, 8, companding="ima"))
  wav_compand_rejects(wav_muxer_new(8000, 1, 8, float=true, companding="mulaw"))
  wav_compand_rejects(
    wav_muxer_new(8000, 1, 8, big_endian=true, companding="alaw"),
  )
}
