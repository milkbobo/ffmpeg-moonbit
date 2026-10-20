///|
/// White-box tests for the AAC ADTS and MPEG audio frame headers.
///
/// The real vectors come from `linuxserver/ffmpeg:9.0.2` output:
/// `aac.aac` (AAC-LC 44100 mono, first frame `ff f1 50 40 1b 1f fc`) and
/// `mp3.mp3` (LAME MPEG-1 Layer III 128 kbps 44100 mono; the first audio
/// frame at offset 461 starts with `ff fb 90 c0`). Expected frame sizes match
/// the `ffprobe -show_packets` sizes 216 (AAC) and 417/418 (MP3).
/// The MPEG-2 LSF and free-format cases are constructed from the header
/// layout in ISO/IEC 11172-3 / 13818-3 and decoded by arithmetic.
test "audio_headers: real ADTS AAC-LC 44.1 kHz mono header" {
  let hdr = ff_adts_header_parse_buf(b"\xFF\xF1\x50\x40\x1B\x1F\xFC").unwrap()
  assert_eq(hdr.object_type, 2) // AAC-LC
  assert_eq(hdr.sampling_index, 4)
  assert_eq(hdr.sample_rate, 44100)
  assert_eq(hdr.chan_config, 1)
  assert_eq(hdr.crc_absent, 1)
  assert_eq(hdr.num_aac_frames, 1)
  assert_eq(hdr.samples, 1024)
  assert_eq(hdr.frame_length, 216) // ffprobe packet size
  assert_eq(hdr.bit_rate, 74418) // 216*8*44100/1024
}

///|
test "audio_headers: ADTS rejections" {
  match ff_adts_header_parse_buf(b"\x00\x00\x00\x00\x00\x00\x00") {
    Err(e) => assert_eq(e, "AAC_SYNC")
    Ok(_) => assert_true(false)
  }
  // sample_frequency_index 15 is invalid
  match ff_adts_header_parse_buf(b"\xFF\xF1\x7C\x00\x00\x00\x00") {
    Err(e) => assert_eq(e, "AAC_SAMPLE_RATE")
    Ok(_) => assert_true(false)
  }
  // frame length below the 7-byte header
  match ff_adts_header_parse_buf(b"\xFF\xF1\x50\x40\x00\x00\x1F") {
    Err(e) => assert_eq(e, "AAC_FRAME_SIZE")
    Ok(_) => assert_true(false)
  }
  assert_true(ff_adts_header_parse_buf(b"\xFF\xF1\x50") is Err(_))
}

///|
test "audio_headers: real MPEG-1 Layer III 128 kbps 44.1 kHz mono" {
  let header = 0xFFFB90C0U
  assert_true(ff_mpa_check_header(header))
  let h = avpriv_mpegaudio_decode_header(header).unwrap()
  assert_eq(h.layer, 3)
  assert_eq(h.lsf, 0)
  assert_eq(h.sample_rate, 44100)
  assert_eq(h.sample_rate_index, 0)
  assert_eq(h.bit_rate, 128000)
  assert_eq(h.frame_size, 417) // ffprobe first audio frame size
  assert_eq(h.nb_channels, 1)
  assert_eq(h.mode, 3) // mono
  assert_eq(h.error_protection, 0)
  assert_true(!h.free_format)
  let info = ff_mpa_decode_header(header).unwrap()
  assert_eq(info.codec, "mp3")
  assert_eq(info.samples_per_frame, 1152)
  assert_eq(info.channels, 1)
}

///|
test "audio_headers: MPEG-2 LSF Layer III and free format" {
  // MPEG-2, Layer III, 64 kbps, 22050 Hz: 144000*64/(22050<<1) = 208.
  let h = avpriv_mpegaudio_decode_header(0xFFF38000U).unwrap()
  assert_eq(h.lsf, 1)
  assert_eq(h.layer, 3)
  assert_eq(h.sample_rate, 22050)
  assert_eq(h.sample_rate_index, 3) // 0 + 3*(lsf + mpeg25)
  assert_eq(h.bit_rate, 64000)
  assert_eq(h.frame_size, 208)
  assert_eq(ff_mpa_decode_header(0xFFF38000U).unwrap().samples_per_frame, 576)

  // Bitrate index 0 signals free format: C returns 1, frame_size stays 0.
  let f = avpriv_mpegaudio_decode_header(0xFFFB00C0U).unwrap()
  assert_true(f.free_format)
  assert_eq(f.frame_size, 0)
  assert_eq(f.bit_rate, 0)
}

///|
test "audio_headers: header check rejects invalid layers/rates" {
  assert_true(!ff_mpa_check_header(0xFFE00000U)) // layer 0
  assert_true(!ff_mpa_check_header(0xFFFFF000U)) // bitrate index 15
  assert_true(!ff_mpa_check_header(0xFFFB0C00U)) // sample rate index 3
  assert_true(!ff_mpa_check_header(0xFF000000U)) // sync missing
  // version 01 (reserved)
  assert_true(!ff_mpa_check_header(0xFFEB90C0U))
  assert_true(avpriv_mpegaudio_decode_header(0xFFE00000U) is Err(_))
}
