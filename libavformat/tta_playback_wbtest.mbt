///|
/// FFmpeg 9.0.2 TTA encode of a two-channel, 800 Hz signal with small
/// impulses at samples 0/1 and 835/836. 24-bit samples, 848 frames.
let tta_playback_b64 = b"VFRBMQEAAgAYACADAABQAwAA4oVQcFEBAAAlAAAAiXg1zQwQAAIMSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIhSIx8MEAACDEigAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB7XnYTQVBFVEFHRVjQBwAAPAAAAAEAAAAAAACgAAAAAAAAAAAMAAAAAAAAAGVuY29kZXIATGF2ZjYzLjEuMTAyQVBFVEFHRVjQBwAAPAAAAAEAAAAAAACAAAAAAAAAAAA="

///|
test "native TTA matches the FFprobe index and FFmpeg PCM" {
  let data = @libavutil.av_base64_decode(tta_playback_b64, 1024).unwrap()
  let tagged = id3v2_add_tags(data, [("title", "TTA playback")]).unwrap()
  for file in [data, tagged] {
    let tag_size = file.length() - data.length()
    let track = av_tta_open(file).unwrap()
    assert_eq(track.header.bits, 24)
    assert_eq(track.header.total_samples, 848L)
    let media = MediaFile::open(file)
    assert_eq(media.format_name(), "tta")
    let decoder = media.audio_decoder(0)
    assert_eq(decoder.sample_rate(), 800)
    assert_eq(decoder.channels(), 2)
    for
      (i, pos, size, pts, count) in [
        (0, 34L, 337, 0L, 835),
        (1, 371L, 37, 835L, 13),
      ] {
      let frame = track.frames[i]
      assert_eq(frame.pos, pos + tag_size.to_int64())
      assert_eq(frame.size, size)
      assert_eq(frame.pts, pts)
      assert_eq(frame.duration, count)
      let packet = media.next_packet().unwrap()
      assert_eq(packet.pts, pts)
      assert_eq(packet.data.length(), size)
      assert_eq(decoder.decode(packet).unwrap().nb_samples, count)
    }
    assert_true(media.next_packet() is None)
    let audio = decode_audio_file(file)
    assert_eq(audio.duration_seconds, Some(1.06))
    let pcm : Array[Byte] = []
    for sample in 0..<848 {
      for row in audio.samples {
        let v = (row[sample] * 2147483648.0).to_int()
        for byte in 0..<4 {
          pcm.push((v >> (byte * 8)).to_byte())
        }
      }
    }
    // FFmpeg -c:a pcm_s32le -f md5
    assert_eq(
      caf_md5(Bytes::from_array(pcm)),
      "90e39592f10a145ab446ec8a032c5f9a",
    )
  }
}

///|
test "native TTA rejects a short seek table and an incomplete last packet" {
  let data = @libavutil.av_base64_decode(tta_playback_b64, 1024).unwrap()
  assert_true(
    av_tta_open(data[:33].to_owned()) is Err("tta: truncated seek table"),
  )
  assert_true(
    av_tta_open(data[:407].to_owned()) is Err("tta: invalid frame size"),
  )
  let track = av_tta_open(data).unwrap()
  assert_true(
    track.header.decode_frame(b"\x00\x00\x00\x00\x00", 835L)
    is Err("tta: frame too short"),
  )
}

///|
/// FFmpeg 9.0.2: -f lavfi -i sine=frequency=997:sample_rate=16000:duration=0.005
/// -c:a g722. The AU and WAV carry the same 40-byte payload.
test "AU and WAV G.722 playback matches FFmpeg s16 PCM" {
  for
    (container, b64) in [
      (
        "au", b"LnNuZAAAACAAAAAoAAAAGAAAPoAAAAABAAAAAAAAAAD6mCyOIZOgoGDvisjO3O7q7nrV0dSf8u5x+5fT17708PJ82JPX/7Tw",
      ),
      (
        "wav", b"UklGRnwAAABXQVZFZm10IBIAAACPAgEAgD4AAIA+AAABAAQAAABmYWN0BAAAAFAAAABMSVNUGgAAAElORk9JU0ZUDQAAAExhdmY2My4xLjEwMgAAZGF0YSgAAAD6mCyOIZOgoGDvisjO3O7q7nrV0dSf8u5x+5fT17708PJ82JPX/7Tw",
      ),
    ] {
    let file = @libavutil.av_base64_decode(b64, 256).unwrap()
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, container)
    assert_eq(audio.codec_id, "adpcm_g722")
    assert_eq(audio.sample_rate, 16000)
    assert_eq(audio.duration_seconds, Some(0.005))
    assert_eq(audio.samples[0].length(), 80)
    let wave = audio.to_wav_s16()
    let demux = av_wav_open(wave).unwrap()
    let start = demux.data_offset.to_int()
    let pcm = wave[start:start + demux.data_size.to_int()].to_owned()
    assert_eq(caf_md5(pcm), "2dcbbdcab3357e0122fa29c403a953f9")
  }
}
