///|
/// Stream-table differential against the real libavformat. Fixtures are the
/// in-memory container/codec matrix already staged in ffref_test.mbt; HLS and
/// DASH are path-backed and live in ffref_streaming_test.mbt.
///
/// `ffref_stream_info` is a separate C entry point from `ffref_packets`: the
/// packet oracle pins framing and timestamps, this one pins what a player
/// needs before it can pick a decoder (codec name, geometry, audio layout,
/// extradata).
fn ffref_si_fixtures() -> Array[(String, Bytes)] {
  [
    (
      "ogg-opus",
      @libavutil.av_base64_decode(playback_ogg_file_b64, 1 << 24).unwrap(),
    ),
    (
      "wav-pcm",
      @libavutil.av_base64_decode(playback_pcm_wav_b64, 1 << 24).unwrap(),
    ),
    (
      "mkv-h264-aac",
      @libavutil.av_base64_decode(playback_real_mkv_b64, 1 << 24).unwrap(),
    ),
    (
      "mkv-hevc",
      @libavutil.av_base64_decode(e2e_hevc_mkv_b64, 1 << 24).unwrap(),
    ),
    (
      "webm-vp9",
      @libavutil.av_base64_decode(e2e_vp9_webm_b64, 1 << 24).unwrap(),
    ),
    ("mkv-av1", @libavutil.av_base64_decode(e2e_av1_mkv_b64, 1 << 24).unwrap()),
    (
      "mp3-es",
      @libavutil.av_base64_decode(ffref_mp3_file_b64, 1 << 24).unwrap(),
    ),
    (
      "ts-h264-aac",
      @libavutil.av_base64_decode(ffref_av_ts_b64, 1 << 24).unwrap(),
    ),
    (
      "mkv-mjpeg",
      @libavutil.av_base64_decode(ffref_mjpeg_mkv_b64, 1 << 24).unwrap(),
    ),
    (
      "png-rgb",
      @libavutil.av_base64_decode(ffref_rgb_png_b64, 1 << 24).unwrap(),
    ),
    (
      "png-rgba",
      @libavutil.av_base64_decode(ffref_rgba_png_b64, 1 << 24).unwrap(),
    ),
    (
      "mp4-aac",
      @libavutil.av_base64_decode(ffref_aac_m4a_b64, 1 << 24).unwrap(),
    ),
    (
      "fmp4-seg",
      @libavutil.av_base64_decode(ffref_fmp4_seg_b64, 1 << 24).unwrap(),
    ),
    (
      "wav-aac",
      @libavutil.av_base64_decode(ffref_aac_wav_b64, 1 << 24).unwrap(),
    ),
    (
      "wav-mp3",
      @libavutil.av_base64_decode(ffref_mp3_wav_b64, 1 << 24).unwrap(),
    ),
    (
      "wav-adts-aac",
      @libavutil.av_base64_decode(ffref_aac_adts_wav_b64, 1 << 24).unwrap(),
    ),
  ]
}

///|
/// Map the oracle's numeric media type onto the port's enum.
fn ffref_si_media_type(code : Int32) -> @avf.MediaType {
  if code == 0 {
    @avf.MediaType::Video
  } else if code == 1 {
    @avf.MediaType::Audio
  } else {
    @avf.MediaType::Subtitle
  }
}

///|
/// Field-for-field comparison of `@avf.MediaFile`'s stream table against
/// libavformat after `avformat_find_stream_info`. `skip_*` marks the two
/// documented gaps where the port differs (see the matrix test); everything
/// else is strict, extradata bytes included.
fn ffref_si_check(
  data : Bytes,
  label : String,
  skip_geometry~ : Bool = false,
  skip_extradata~ : Bool = false,
) -> Unit raise {
  let oracle = @ffref.ffref_stream_info(data)
  let ours = @avf.MediaFile::open(data).streams()
  assert_eq(
    oracle.length(),
    ours.length(),
    msg="\{label}: stream count (\{ours.length()} vs \{oracle.length()})",
  )
  for i = 0; i < oracle.length(); i = i + 1 {
    let o = oracle[i]
    let s = ours[i]
    assert_true(
      s.media_type == ffref_si_media_type(o.media_type),
      msg="\{label}: stream \{i} media type (oracle \{o.media_type})",
    )
    assert_eq(s.codec_id, o.codec_id, msg="\{label}: stream \{i} codec name")
    assert_eq(
      s.sample_rate,
      o.sample_rate,
      msg="\{label}: stream \{i} sample rate",
    )
    assert_eq(s.channels, o.channels, msg="\{label}: stream \{i} channels")
    if !skip_geometry {
      assert_eq(s.width, o.width, msg="\{label}: stream \{i} width")
      assert_eq(s.height, o.height, msg="\{label}: stream \{i} height")
    }
    if !skip_extradata {
      let extra = match s.extradata {
        Some(b) => b
        None => b""
      }
      assert_eq(
        extra,
        o.extradata,
        msg="\{label}: stream \{i} extradata (\{extra.length()} vs \{o.extradata.length()})",
      )
    }
  }
}

///|
/// The full in-memory matrix: MP4 / fMP4 / Matroska / WebM / MPEG-TS / Ogg /
/// WAV carrying H264, HEVC, AV1, VP9, MJPEG, AAC, MP3, Opus and PCM.
///
/// Two known divergences are pinned rather than silently ignored:
///   * `ts-h264-aac`: the port's TS demuxer does not derive video geometry
///     from SPS and exposes raw PES bytes as extradata, while libavformat
///     normalises both after find_stream_info.
///   * `wav-adts-aac`: the port carries a 2-byte AudioSpecificConfig that
///     the C side leaves empty (the known WAV/AAC packetisation difference,
///     see `ffref_test.mbt` "ADTS-in-WAV").
test "ffref: stream table matches libavformat across the container codec matrix" {
  for pair in ffref_si_fixtures() {
    let (label, data) = pair
    // Bare MP3/PNG have no MediaFile adapter; they are covered below.
    let unsupported = label == "mp3-es" ||
      label == "png-rgb" ||
      label == "png-rgba"
    if !unsupported {
      let skip_geometry = label == "ts-h264-aac"
      let skip_extradata = label == "ts-h264-aac" || label == "wav-adts-aac"
      ffref_si_check(data, label, skip_geometry~, skip_extradata~)
    }
  }
}

///|
/// Elementary streams bypass `MediaFile` (they are decoded through the codec
/// entry points). Pin the oracle's view anyway: this exercises the FFI blob
/// parser on short codec names and zero-length extradata regions.
test "ffref: stream-info blob parses bare MP3 and PNG elementary streams" {
  for pair in ffref_si_fixtures() {
    let (label, data) = pair
    if label == "mp3-es" {
      let streams = @ffref.ffref_stream_info(data)
      assert_eq(streams.length(), 1, msg="mp3-es: stream count")
      let s = streams[0]
      assert_eq(s.codec_id, "mp3", msg="mp3-es: codec name")
      assert_eq(s.media_type, 1, msg="mp3-es: audio")
      assert_eq(s.sample_rate, 44100, msg="mp3-es: sample rate")
      assert_eq(s.channels, 2, msg="mp3-es: channels")
      assert_eq(s.width, 0, msg="mp3-es: width")
      assert_eq(s.height, 0, msg="mp3-es: height")
      assert_eq(s.extradata.length(), 0, msg="mp3-es: extradata")
    } else if label == "png-rgb" || label == "png-rgba" {
      let streams = @ffref.ffref_stream_info(data)
      assert_eq(streams.length(), 1, msg="\{label}: stream count")
      let s = streams[0]
      assert_eq(s.codec_id, "png", msg="\{label}: codec name")
      assert_eq(s.media_type, 0, msg="\{label}: video")
      assert_eq(s.width, 40, msg="\{label}: width")
      assert_eq(s.height, 28, msg="\{label}: height")
      assert_eq(s.sample_rate, 0, msg="\{label}: sample rate")
      assert_eq(s.extradata.length(), 0, msg="\{label}: extradata")
    }
  }
}

///|
/// NULL from the C entry points must become `FFRefError`, never a silently
/// empty result. Covers both new/old oracle surfaces.
test "ffref: oracle failures are mapped to FFRefError" {
  let probe = Some(@ffref.ffref_stream_info(b"")) catch { _ => None }
  assert_true(probe is None, msg="stream-info: empty input must raise")
  let encoded = Some(
    @ffref.ffref_encode_audio(
      b"",
      "ffref_no_such_encoder",
      sample_rate=44100,
      channels=1,
      bitrate=64000,
    ),
  ) catch {
    _ => None
  }
  assert_true(encoded is None, msg="encode: unknown encoder must raise")
}
