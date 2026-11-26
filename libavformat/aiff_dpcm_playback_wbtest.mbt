///|
/// FFmpeg 9.0.2 references for synthetic SDX2/CBD2 codes and the first
/// few bytes of FFmpeg-encoded ADP4, wrapped as mono and stereo AIFF-C.
test "AIFF-C SDX2, CBD2 and ADP4 match FFmpeg and retain packet state" {
  for
    (encoded, codec, channels, count, md5) in [
      (
        b"Rk9STQAAAFBBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAABAACEANrEQAAAAAAABTRFgyAABTU05EAAAAGAAAAAAAAAAAAoEDf39/f4GBgYABAAFvgw==",
        "sdx2_dpcm", 1, 16, "3c8e0a4f904d273ffc8505dccd2770ad",
      ),
      (
        b"Rk9STQAAAFBBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAgAAAAgACEANrEQAAAAAAABTRFgyAABTU05EAAAAGAAAAAAAAAAAAoEDf39/f4GBgYABAAFvgw==",
        "sdx2_dpcm", 2, 8, "5009a72ebba4a11dee6cec7ec94edc75",
      ),
      (
        b"Rk9STQAAAFBBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAABAACEANrEQAAAAAAABDQkQyAABTU05EAAAAGAAAAAAAAAAAAoEDf39/f4GBgYABAAFvgw==",
        "cbd2_dpcm", 1, 16, "7ec0cbff502c086fa3594deddf57a351",
      ),
      (
        b"Rk9STQAAAFBBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAgAAAAgACEANrEQAAAAAAABDQkQyAABTU05EAAAAGAAAAAAAAAAAAoEDf39/f4GBgYABAAFvgw==",
        "cbd2_dpcm", 2, 8, "0a85d7f8e5ee6c9522c95d12dfe690ce",
      ),
      (
        b"Rk9STQAAAExBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAQAAAAwABEANrEQAAAAAAABBRFA0AABTU05EAAAAFAAAAAAAAAAAd3d3F9u6qwkwNTUz",
        "adpcm_ima_ws", 1, 24, "241bd3d51718bb5c2803c687617df380",
      ),
      (
        b"Rk9STQAAAExBSUZDRlZFUgAAAASigFFAQ09NTQAAABgAAgAAAAYABEANrEQAAAAAAABBRFA0AABTU05EAAAAFAAAAAAAAAAAcHd3d3cHd/+Hn8qI",
        "adpcm_ima_ws", 2, 12, "952274cc2c8c84dadaa27ba993f932b2",
      ),
    ] {
    let file = @libavutil.av_base64_decode(encoded, 128).unwrap()
    let demux = av_aiff_open(file).unwrap()
    assert_eq(demux.format.codec, codec)
    assert_eq(demux.format.block_align, channels)
    assert_eq(demux.sample_count, count.to_int64())
    assert_eq(demux.packets[0].duration, count)
    if codec == "adpcm_ima_ws" {
      let short_comm = file.to_array()
      short_comm[37] = 1
      let demux = av_aiff_open(Bytes::from_array(short_comm)).unwrap()
      assert_eq(demux.sample_count, count.to_int64())
    }
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, "aiff")
    assert_eq(audio.codec_id, codec)
    assert_eq(audio.channels, channels)
    assert_eq(audio.sample_rate, 22050)
    let wav = audio.to_wav_s16()
    let data = av_wav_open(wav).unwrap()
    assert_eq(data.data_size, (count * channels * 2).to_int64())
    assert_eq(caf_md5(wav[data.data_offset.to_int():].to_owned()), md5)

    let media = MediaFile::open(file)
    let packet = media.next_packet().unwrap()
    let decoder = media.audio_decoder(0)
    let mid = packet.data.length() / (2 * channels) * channels
    let first = decoder
      .decode({ ..packet, data: packet.data[:mid].to_owned(), })
      .unwrap()
    let second = decoder
      .decode({
        ..packet,
        data: packet.data[mid:].to_owned(),
        pts: first.nb_samples.to_int64(),
      })
      .unwrap()
    assert_eq(second.pts, Some(first.nb_samples.to_int64()))
    for c in 0..<channels {
      assert_eq(first.samples[c] + second.samples[c], audio.samples[c])
    }
  }
}

///|
test "AIFF-C DPCM rejects partial stereo sample frames" {
  let decoder = @libavcodec.aiff_dpcm_decoder_new("sdx2_dpcm", 2).unwrap()
  assert_true(
    decoder.decode_packet(b"\x7f") is Err("aiff dpcm: incomplete sample frame"),
  )
  assert_eq(decoder.decode_packet(b"\x03\xfd").unwrap(), [18, -18])
  let decoder = @libavcodec.adpcm_decoder_new("adpcm_ima_ws", 2).unwrap()
  assert_true(
    decoder.decode_block(b"\x7f")
    is Err("adpcm: invalid Westwood IMA packet size"),
  )
}
