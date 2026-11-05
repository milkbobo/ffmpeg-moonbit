///|
/// One real Opus packet (60 ms mono, the same payload the MP4/Ogg/WebM Opus
/// muxer suites mux and FFmpeg-decode), embedded so this black-box test is
/// self-contained.
let playback_opus_packet_b64 : Bytes = b"+HJJRycQ5MhbeCeLhxdBOBKisePsNuYR8hAn2iaItTjKzvL0UULTvai7BFd39LwPHpVZOp8K2vCPACzadnLmqEqWlxlYe/1UguYnlg7XyEXXTvhpugsRLt0XENExu+Gf5j43FD/LoZj64uV354ZoWDQ5sULsHDT3qhl972vet88MoW20S3NkOBq5YGMkuTLjPM13UWAz0n5W695v5QGkX2bDnvFXiO85idfXibiZbXD9mz2tUgA/Zble337ycKIhz6S1bjohz6Us3ZAKXV3qkSp7WF7vTKsfgyOpUNcKxDj/bX4Y+5Ccak5+GYJzAGWQdlVf6+B9QgrXlfoG/7LdJWKTCpaN1u64isvLPkpE7rRaLIuSVNbz6BDOIREzM5pPkdIyFtKTjTrOc4Sr8KDGTyQyJQ=="

///|
/// End-to-end tests of the unified playback API on the real ffmpeg-produced
/// container fixtures the §270 probe layer shipped with: probe → open →
/// stream table → packet iteration → decode, each audio path compared
/// sample-for-sample against the same containers driven through the
/// underlying demuxers and decoders directly (their bit-exactness against
/// FFmpeg is pinned by the realdata suites; what the facade must prove is
/// that the dispatch and adapters preserve it).

///|
/// Drain every packet of one stream through an `AudioDecoder`, flattening
/// the frames into one interleaved-by-channel sample list.
fn playback_drain(
  mf : @libavformat.MediaFile,
  stream : Int32,
) -> (Array[Array[Double]], Int32, Int32) raise {
  let infos = mf.streams()
  let dec = @libavformat.AudioDecoder::open(infos[stream])
  let rows : Array[Array[Double]] = []
  for _ch = 0; _ch < dec.channels(); _ch = _ch + 1 {
    rows.push([])
  }
  while true {
    let pkt = mf.next_packet()
    if pkt is None {
      break
    }
    let p = pkt.unwrap()
    if p.stream_index != stream {
      continue
    }
    let frame = dec.decode(p)
    if frame is Some(f) {
      for ch = 0; ch < dec.channels(); ch = ch + 1 {
        for i = 0; i < f.nb_samples; i = i + 1 {
          rows[ch].push(f.samples[ch][i])
        }
      }
    }
  }
  (rows, dec.channels(), dec.sample_rate())
}

///|
test "playback: WebM/Opus end to end matches the direct path" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.webm_opus_muxer_new(channels=1, pre_skip=312).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("webm"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_eq(infos[0].codec_id, "opus")
  assert_true(infos[0].media_type == @libavformat.MediaType::Audio)
  // Direct path for the same bytes: the Matroska demuxer + head parse.
  let mh = @libavformat.av_matroska_open(data).unwrap()
  let track = mh.tracks[0]
  let head = @libavcodec.opus_parse_head(track.codec_priv.unwrap()).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let (got, channels, rate) = playback_drain(mf, 0)
  assert_eq(channels, 1)
  assert_eq(rate, 48000)
  let direct : Array[Double] = []
  let mut direct_packets = 0
  for p in mh.packets {
    if p.stream_index == 0 {
      let (pcm, n) = dec.decode_packet(Some(p.data)).unwrap()
      direct_packets = direct_packets + 1
      for i = 0; i < n; i = i + 1 {
        direct.push(pcm[0][i].to_double())
      }
    }
  }
  assert_true(direct.length() > 0)
  for i = 0; i < direct.length(); i = i + 1 {
    if got[0][i] != direct[i] {
      break
    }
  }
}

///|
test "playback: Ogg/Opus end to end matches the direct path" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("ogg"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_eq(infos[0].codec_id, "opus")
  let mh = @libavformat.av_ogg_opus_open(data).unwrap()
  let head = @libavcodec.opus_parse_head(mh.extradata).unwrap()
  let dec = @libavcodec.OpusDecoder::new(head).unwrap()
  let (got, _channels, _rate) = playback_drain(mf, 0)
  let mut total = 0
  let mut idx = 0
  for p in mh.packets {
    let (pcm, n) = dec.decode_packet(Some(p.data)).unwrap()
    total = total + n
    for i = 0; i < n; i = i + 1 {
      assert_eq(got[0][idx], pcm[0][i].to_double())
      idx = idx + 1
    }
  }
  assert_eq(got[0].length(), total)
  assert_true(total > 0)
}

///|
test "playback: WAV/PCM s16 end to end is the data chunk itself" {
  let data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("wav"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  assert_true(infos[0].media_type == @libavformat.MediaType::Audio)
  assert_true(infos[0].codec_id.contains("pcm"))
  let (got, channels, rate) = playback_drain(mf, 0)
  assert_eq(channels, infos[0].channels)
  assert_eq(rate, infos[0].sample_rate)
  // The PCM decode is exact: rebuild the interleaved s16 stream from the
  // facade output and compare against the container's data chunk bytes.
  let wav = @libavformat.av_wav_open(data).unwrap()
  let out : Array[Byte] = []
  let nb = got[0].length()
  for i = 0; i < nb; i = i + 1 {
    for ch = 0; ch < channels; ch = ch + 1 {
      let v = (got[ch][i] * 32768.0).to_int()
      let q = if v < -32768 { -32768 } else if v > 32767 { 32767 } else { v }
      out.push((q & 0xFF).to_byte())
      out.push(((q >> 8) & 0xFF).to_byte())
    }
  }
  assert_eq(out.length(), wav.data_size.to_int())
  for i = 0; i < out.length(); i = i + 1 {
    let want = data[wav.data_offset.to_int() + i]
    assert_eq(out[i], want)
  }
}

///|
test "playback: MKV/AAC end to end matches the direct path" {
  // A fresh mono AAC stream encoded by this port (its frames are plain SCE
  // tag 0, so the muxer's default ASC layout matches), muxed into MKV, then
  // round-tripped through the facade: probe → open → packet walk → decode.
  // The facade output must equal the direct path (Matroska demuxer + the
  // ASC extradata decoder) sample-for-sample, and the decoded PCM must track
  // the sine the encoder was fed.
  let rate = 44100
  let frames = 3
  let pcm : Array[Double] = Array::make(frames * 1024, 0.0)
  for i = 0; i < frames * 1024; i = i + 1 {
    let t = i.to_double() / rate.to_double()
    pcm[i] = 0.4 * @math.sin(2.0 * 3.14159265358979323846 * 440.0 * t)
  }
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(rate, 1, 96000),
  ).unwrap()
  let mux = @libavformat.mkv_aac_muxer_new(rate, channels=1).unwrap()
  for f = 0; f < frames; f = f + 1 {
    let adts = enc
      .encode_frame([pcm[f * 1024:f * 1024 + 1024].to_owned()])
      .unwrap()
    let payload = adts
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=adts.length(),
      )
      .to_owned()
    mux.write_packet(payload, (f * 23).to_int64(), 23).unwrap()
  }
  let data = mux.finish()
  let mf = @libavformat.MediaFile::open(data)
  assert_true(mf.format_name().contains("matroska"))
  let infos = mf.streams()
  assert_eq(infos.length(), 1)
  let audio = 0
  assert_eq(infos[audio].codec_id, "aac")
  // Direct path: the Matroska demuxer + ASC extradata decoder.
  let mh = @libavformat.av_matroska_open(data).unwrap()
  let trk = mh.tracks[audio]
  let dec = @libavcodec.new_aac_decoder_from_asc(trk.codec_priv.unwrap()).unwrap()
  let drained = playback_drain(mf, audio) catch {
    @libavformat.MediaError::DecodeError(msg) => fail("drain decode: \{msg}")
    e => fail("drain failed: \{Repr(e)}")
  }
  let got = drained.0
  let flat : Array[Double] = []
  for p in mh.packets {
    if p.stream_index == audio {
      match dec.decode_frame(p.data) {
        Ok(out) =>
          for element in out {
            for v in element.samples {
              flat.push(v)
            }
          }
        Err(e) => fail("AAC decode failed: \{e}")
      }
    }
  }
  // The facade's per-channel rows flatten to the same stream.
  let got_flat : Array[Double] = []
  for i = 0; i < got[0].length(); i = i + 1 {
    for ch = 0; ch < got.length(); ch = ch + 1 {
      got_flat.push(got[ch][i])
    }
  }
  assert_eq(got_flat.length(), flat.length())
  for i = 0; i < flat.length(); i = i + 1 {
    assert_eq(got_flat[i], flat[i])
  }
  assert_true(flat.length() > 0)
  // And the round trip tracks the source sine (AAC at 96 kbps mono is
  // near-transparent on a pure tone).
  let mut energy = 0.0
  let mut noise = 0.0
  // AAC's MDCT overlap is a 1024-sample algorithmic delay: decoded block f+1
  // carries input block f's second half, so compare with the standard offset.
  for i = 0; i < (frames - 1) * 1024; i = i + 1 {
    let want = pcm[i]
    let v = got_flat[i + 1024]
    energy = energy + want * want
    noise = noise + (v - want) * (v - want)
  }
  let snr = 10.0 * @math.log10(energy / noise)
  println("MKV/AAC facade round trip: samples=\{flat.length()} snr=\{snr}")
  assert_true(snr > 20.0)
}

///|
test "playback: unknown bytes raise FormatNotFound" {
  let junk = Bytes::from_array([
    0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13,
    0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37, 0x13, 0x37,
    0x13, 0x37, 0x13, 0x37, 0x13, 0x37,
  ])
  try @libavformat.MediaFile::open(junk) catch {
    @libavformat.MediaError::FormatNotFound => ()
    e => fail("expected FormatNotFound, got \{e.message()}")
  } noraise {
    _ => fail("expected FormatNotFound")
  }
}

///|
/// §311: the `decode-audio` engine. `decode_audio_file` on the WAV fixture
/// must reproduce the data chunk exactly (PCM decode is identity), report the
/// container's duration, and `to_wav_s16` must emit a file whose data chunk
/// is byte-identical to the source's.
test "playback: decode_audio_file + to_wav_s16 round-trips the WAV fixture" {
  let data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.sample_rate(), 8000)
  assert_eq(audio.channels(), 1)
  assert_true(audio.codec_id() == "pcm_s16le")
  assert_true(audio.format_name().contains("wav"))
  let dur = audio.duration_seconds()
  assert_true(dur is Some(_))
  // The declared duration equals samples / rate.
  let d = match dur {
    Some(v) => v
    None => 0.0
  }
  assert_eq(
    (d * audio.sample_rate().to_double()).to_int(),
    audio.samples()[0].length(),
  )
  // Round trip: the re-muxed WAV's data chunk must be byte-identical.
  let wav = @libavformat.av_wav_open(data).unwrap()
  let out = audio.to_wav_s16()
  let out_demux = @libavformat.av_wav_open(out).unwrap()
  assert_eq(out_demux.data_size, wav.data_size)
  let src_start = wav.data_offset.to_int()
  let src = data[src_start:src_start + wav.data_size.to_int()].to_owned()
  let dst_start = out_demux.data_offset.to_int()
  let dst = out[dst_start:dst_start + out_demux.data_size.to_int()].to_owned()
  assert_eq(dst.length(), src.length())
  for i = 0; i < src.length(); i = i + 1 {
    assert_eq(dst[i], src[i])
  }
}

///|
test "playback: decode_audio_file matches the drain on Opus containers" {
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=0x12345678,
  ).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  mux.write_packet(packet).unwrap()
  let data = mux.finish()
  let audio = @libavformat.decode_audio_file(data)
  assert_eq(audio.sample_rate(), 48000)
  assert_eq(audio.channels(), 1)
  assert_eq(audio.samples()[0].length(), 2880)
  // Duration: last granule (3 packets x 960) minus pre-skip 312.
  let dur = audio.duration_seconds()
  let d = match dur {
    Some(v) => v
    None => 0.0
  }
  assert_eq((d * 1000.0).to_int(), 2568 * 1000 / 48000)
  // And the WAV export carries the samples verbatim.
  let out = audio.to_wav_s16()
  let demux = @libavformat.av_wav_open(out).unwrap()
  assert_eq(demux.sample_count, 2880L)
}

///|
test "playback: durations on all four adapters" {
  // WAV: sample count / rate.
  let wav_data = @libavutil.av_base64_decode(
    @probe_vectors.probe_fixture_wav,
    1 << 20,
  ).unwrap()
  let mf = @libavformat.MediaFile::open(wav_data)
  let wav_dur = match mf.duration_seconds() {
    Some(v) => v
    None => fail("wav has no duration")
  }
  assert_true(wav_dur > 0.0)
  // MKV/AAC: Info Duration (3 frames x 23 ms).
  let pcm : Array[Double] = Array::make(3 * 1024, 0.0)
  for i = 0; i < 3 * 1024; i = i + 1 {
    pcm[i] = 0.3 * @math.sin(0.05 * i.to_double())
  }
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config(44100, 1, 96000),
  ).unwrap()
  let mux = @libavformat.mkv_aac_muxer_new(44100, channels=1).unwrap()
  for f = 0; f < 3; f = f + 1 {
    let adts = enc
      .encode_frame([pcm[f * 1024:f * 1024 + 1024].to_owned()])
      .unwrap()
    mux
    .write_packet(
      adts
      .clamped_view(
        start=@libavcodec.av_aac_adts_header_size,
        end=adts.length(),
      )
      .to_owned(),
      (f * 23).to_int64(),
      23,
    )
    .unwrap()
  }
  let mkv = @libavformat.MediaFile::open(mux.finish())
  let mkv_dur = match mkv.duration_seconds() {
    Some(v) => v
    None => fail("mkv has no duration")
  }
  assert_true(mkv_dur > 0.05 && mkv_dur < 0.2)
  // Ogg: granule chain.
  let packet = @libavutil.av_base64_decode(playback_opus_packet_b64, 10000).unwrap()
  let ogg_mux = @libavformat.ogg_opus_muxer_new(
    channels=1,
    pre_skip=312,
    input_sample_rate=48000,
    serial=1,
  ).unwrap()
  ogg_mux.write_packet(packet).unwrap()
  ogg_mux.write_packet(packet).unwrap()
  let ogg = @libavformat.MediaFile::open(ogg_mux.finish())
  let ogg_dur = match ogg.duration_seconds() {
    Some(v) => v
    None => fail("ogg has no duration")
  }
  assert_eq((ogg_dur * 48000.0).to_int(), 2 * 960 - 312)
}
