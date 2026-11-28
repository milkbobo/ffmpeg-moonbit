///|
/// `decode-audio` - the third JSON CLI command (proposal deliverable ②):
///
///   moon run cmd/decode-audio -- <media-file> [--output out.wav]
///                               [--format FORMAT]
///                               [--rate 8000..192000] [--g722-bits 6..8] [--g726-bits 2..5]
///
/// Decodes the first audio stream all the way to float PCM through the
/// unified playback API (every container/codec combination the audio line
/// supports), prints a JSON summary on stdout (codec, rates, decoded
/// lengths and durations). With `--output` it can also encode audio files.
fn main raise {
  let args = @env.args()
  if args.length() < 2 {
    println(
      "usage: decode-audio <media-file> [--output FILE] [--format FORMAT] [--rate N]",
    )
    println("  decodes the first audio stream, prints a JSON summary,")
    println("  optionally writing 16-bit PCM WAV to --output")
    println(
      "  --format adpcm_ima_wav, adpcm_ms or adpcm_yamaha writes mono/stereo ADPCM WAV",
    )
    println("  --format w64_ima_wav, w64_ms or w64_yamaha writes ADPCM Wave64")
    println("  --format dfpwm exports mono 48 kHz DFPWM to --output")
    println(
      "  --format wav_dfpwm or w64_dfpwm writes mono DFPWM in WAV or Wave64",
    )
    println("  --format g722 exports mono 16 kHz G.722 to --output")
    println("  --format g726 or g726le exports mono 8 kHz audio to --output")
    println("  --format wav_g722 or wav_g726 writes mono G.722 or G.726 in WAV")
    println(
      "  --format au_g722 or au_g726le writes mono G.722 or G.726LE in Sun AU",
    )
    println(
      "  --format aifc_g722 or aifc_g726le writes mono G.722 or 5-bit G.726LE in AIFF-C",
    )
    println(
      "  --format aptx or aptxhd exports stereo audio, defaulting to 48 kHz",
    )
    println("  --format roq exports mono or stereo RoQ at 22.05 kHz")
    println("  --format kvag or apm writes mono/stereo game audio")
    println("  --format argo_asf writes mono/stereo Argonaut ASF")
    println("  --format wsaud writes mono/stereo Westwood AUD")
    println("  --format aifc_ima4 writes mono/stereo Apple IMA4 in AIFF-C")
    println("  --format aifc_gsm writes mono GSM in AIFF-C")
    println("  --format mov_gsm writes mono GSM in QuickTime MOV")
    println("  --format aifc_adp4 writes mono/stereo Westwood IMA in AIFF-C")
    println("  --format aifc_alaw or aifc_mulaw writes G.711 in AIFF-C")
    println("  --format smjpeg_pcm writes an audio-only Loki SMJPEG file")
    println("  --format sox or sox_be writes native 32-bit PCM SoX")
    println("  --format mmf writes mono or stereo Yamaha ADPCM in SMAF")
    println("  --format daud writes six-channel 96 kHz D-Cinema audio")
    println("  --format ast writes Nintendo AST with signed 16-bit planar PCM")
    println("  --format rso writes mono unsigned 8-bit Mindstorms audio")
    println("  --format wve writes mono 8 kHz Psion 3 A-law audio")
    println("  --format loas writes mono or stereo AAC-LC in LOAS/LATM")
    println("  --format 8svx or 16sv writes Amiga planar PCM")
    println("  --format avr, avr_s8, avr_u8 or avr_u16 writes AVR PCM")
    println(
      "  --format maud, maud_u8, maud_alaw or maud_mulaw writes Amiga MAUD",
    )
    println("  --format ts_s302m writes 48 kHz SMPTE 302M in MPEG-TS")
    println("  --format ts_bluray_lpcm writes Blu-ray LPCM in HDMV MPEG-TS")
    println("  --format ts_opus writes mono or stereo Opus in MPEG-TS")
    println(
      "  --format ts_aac|ts_latm writes AAC-LC in MPEG-TS with ADTS or LATM",
    )
    println("  --format adts writes a raw AAC-LC ADTS stream")
    println(
      "  --bluray-bits 16|24 sets Blu-ray LPCM output depth (default: 24)",
    )
    println(
      "  --s302m-bits 16|20|24 sets SMPTE 302M output depth (default: 24)",
    )
    println(
      "  --format sphere writes NIST SPHERE with --sphere-codec NAME (default: pcm_s16le)",
    )
    println("  --format voc, voc_u8, voc_alaw or voc_mulaw writes Creative VOC")
    println(
      "  --format ircam writes IRCAM with --ircam-codec NAME (default: pcm_s16le)",
    )
    println("  --format caf_ima4 writes mono/stereo Apple IMA4 in CAF")
    println(
      "  --format caf_ima_wav or caf_ms writes WAV IMA or Microsoft ADPCM in CAF",
    )
    println(
      "  --format caf_f32le, caf_f32be, caf_f64le or caf_f64be writes float CAF",
    )
    println("  --format caf_alaw or caf_mulaw writes G.711 in CAF")
    println("  --format caf_ac3 writes AC-3 in CAF")
    println("  --format ac3|ts_ac3 writes raw AC-3 or AC-3 in MPEG-TS")
    println("  --format caf_aac writes mono or stereo AAC-LC in CAF")
    println("  --format mp4_aac writes mono or stereo AAC-LC in MP4")
    println("  --format mkv_aac writes mono or stereo AAC-LC in Matroska")
    println("  --format caf_gsm or caf_gsm_ms writes mono GSM or WAV49 in CAF")
    println("  --format gsm, wav_gsm_ms or w64_gsm_ms writes mono GSM or WAV49")
    println(
      "  --format caf_mp2 or caf_mp3 writes mono or stereo MPEG audio in CAF",
    )
    println("  --format caf_opus writes mono or stereo Opus in CAF")
    println("  --format ogg_opus writes mono or stereo Ogg Opus")
    println(
      "  --format webm_opus|mkv_opus writes mono or stereo Opus in WebM or Matroska",
    )
    println("  --format ogg_vorbis writes stereo Ogg Vorbis")
    println(
      "  --format caf_flac writes FLAC in CAF with --caf-flac-bits 16, 24 or 32 (default: 24)",
    )
    println(
      "  --format ogg_flac writes Ogg FLAC with --flac-bits 16, 24 or 32 (default: 24)",
    )
    println(
      "  --format wav_flac or w64_flac writes FLAC in WAV or Wave64 with --flac-bits",
    )
    println("  --format mp4_flac writes FLAC in MP4 with --flac-bits")
    println(
      "  --format mp4_alac, caf_alac or mkv_alac writes mono or stereo ALAC with --alac-bits 16, 24 or 32 (default: 24)",
    )
    println("  --format mkv_flac writes FLAC in Matroska with --flac-bits")
    println(
      "  --format w64_f64, w64_alaw or w64_mulaw writes float64 or G.711 Wave64",
    )
    println("  --format adx writes mono/stereo unencrypted CRI ADX")
    println("  --format qoa writes Quite OK Audio")
    println("  --format flv_adpcm writes mono/stereo Flash ADPCM in FLV")
    println("  --format flv_aac writes mono or stereo AAC-LC in FLV")
    println("  --format flv_flac writes FLAC in Enhanced FLV with --flac-bits")
    println(
      "  --format tta exports TTA with --tta-bits 8, 16 or 24 (default: 24)",
    )
    println("  --tta-crc verifies CRCs in native TTA input")
    println(
      "  --format alp exports ALP .tun (22.05 kHz) or .pcm (up to 44.1 kHz)",
    )
    println("  --aptx-rate N supplies the sample rate of a raw aptX input")
    println(
      "  --g722-bits 6..8 sets the width for byte-aligned raw G.722 input (default: 8)",
    )
    println(
      "  --g726-bits 2..5 sets the code width for raw G.726 input and output (default: 4)",
    )
    return
  }
  let mut path = ""
  let mut output = ""
  let mut format = "wav"
  let mut rate : Int32 = 0
  let mut g722_bits = 8
  let mut g726_bits = 4
  let mut aptx_rate = 48000
  let mut tta_bits = 24
  let mut flac_bits = 24
  let mut alac_bits = 24
  let mut ircam_codec = "pcm_s16le"
  let mut sphere_codec = "pcm_s16le"
  let mut s302m_bits = 24
  let mut bluray_bits = 24
  let mut tta_verify_crc = false
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--output" && i + 1 < args.length() {
      output = args[i + 1]
      i = i + 2
    } else if a == "--output" {
      fail("decode-audio: --output requires a value")
    } else if a == "--format" {
      if i + 1 >= args.length() {
        fail("decode-audio: --format requires a value")
      }
      format = args[i + 1]
      i = i + 2
    } else if a == "--rate" && i + 1 < args.length() {
      rate = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --rate expects a number")
      }
      i = i + 2
    } else if a == "--rate" {
      fail("decode-audio: --rate requires a value")
    } else if a == "--tta-crc" {
      tta_verify_crc = true
      i = i + 1
    } else if a == "--ircam-codec" {
      if i + 1 >= args.length() {
        fail("decode-audio: --ircam-codec requires a value")
      }
      ircam_codec = args[i + 1]
      i = i + 2
    } else if a == "--sphere-codec" {
      if i + 1 >= args.length() {
        fail("decode-audio: --sphere-codec requires a value")
      }
      sphere_codec = args[i + 1]
      i = i + 2
    } else if a == "--s302m-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --s302m-bits requires a value")
      }
      s302m_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --s302m-bits expects a number")
      }
      i = i + 2
    } else if a == "--bluray-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --bluray-bits requires a value")
      }
      bluray_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --bluray-bits expects a number")
      }
      i = i + 2
    } else if a == "--caf-flac-bits" || a == "--flac-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: \{a} requires a value")
      }
      flac_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: \{a} expects a number")
      }
      i = i + 2
    } else if a == "--alac-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --alac-bits requires a value")
      }
      alac_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --alac-bits expects a number")
      }
      i = i + 2
    } else if a == "--tta-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --tta-bits requires a value")
      }
      tta_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --tta-bits expects a number")
      }
      i = i + 2
    } else if a == "--aptx-rate" {
      if i + 1 >= args.length() {
        fail("decode-audio: --aptx-rate requires a value")
      }
      aptx_rate = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --aptx-rate expects a number")
      }
      i = i + 2
    } else if a == "--g722-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --g722-bits requires a value")
      }
      g722_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --g722-bits expects a number")
      }
      i = i + 2
    } else if a == "--g726-bits" {
      if i + 1 >= args.length() {
        fail("decode-audio: --g726-bits requires a value")
      }
      g726_bits = @string.parse_int(args[i + 1]) catch {
        _ => fail("decode-audio: --g726-bits expects a number")
      }
      i = i + 2
    } else if path == "" {
      path = a
      i = i + 1
    } else {
      fail("decode-audio: unexpected extra argument \{a}")
    }
  }
  if path == "" {
    fail("decode-audio: no input file")
  }
  let alp_pcm = format == "alp" && output.to_lower().has_suffix(".pcm")
  let raw_rate = match format {
    "wav" => 0
    "tta"
    | "adpcm_ima_wav"
    | "adpcm_ms"
    | "adpcm_yamaha"
    | "kvag"
    | "wsaud"
    | "aifc_ima4"
    | "aifc_gsm"
    | "mov_gsm"
    | "aifc_adp4"
    | "aifc_alaw"
    | "aifc_mulaw"
    | "smjpeg_pcm"
    | "sox"
    | "sox_be"
    | "mmf"
    | "voc"
    | "ast"
    | "rso"
    | "sphere"
    | "loas"
    | "adts"
    | "8svx"
    | "16sv"
    | "avr"
    | "avr_s8"
    | "avr_u8"
    | "avr_u16"
    | "maud"
    | "maud_u8"
    | "maud_alaw"
    | "maud_mulaw"
    | "ts_bluray_lpcm"
    | "ts_opus"
    | "ts_aac"
    | "ts_latm"
    | "voc_u8"
    | "voc_alaw"
    | "voc_mulaw"
    | "ircam"
    | "caf_ima4"
    | "caf_ima_wav"
    | "caf_ac3"
    | "ac3"
    | "ts_ac3"
    | "caf_aac"
    | "mp4_aac"
    | "mkv_aac"
    | "caf_mp2"
    | "caf_mp3"
    | "caf_gsm"
    | "caf_gsm_ms"
    | "gsm"
    | "wav_gsm_ms"
    | "w64_gsm_ms"
    | "caf_flac"
    | "ogg_flac"
    | "mp4_flac"
    | "mp4_alac"
    | "caf_alac"
    | "mkv_alac"
    | "mkv_flac"
    | "wav_flac"
    | "w64_flac"
    | "caf_opus"
    | "ogg_opus"
    | "webm_opus"
    | "mkv_opus"
    | "ogg_vorbis"
    | "caf_ms"
    | "caf_f32le"
    | "caf_f32be"
    | "caf_f64le"
    | "caf_f64be"
    | "caf_alaw"
    | "caf_mulaw"
    | "adx"
    | "wav_dfpwm"
    | "w64_dfpwm"
    | "w64_ima_wav"
    | "w64_ms"
    | "w64_yamaha"
    | "w64_f64"
    | "w64_alaw"
    | "w64_mulaw"
    | "qoa"
    | "flv_adpcm"
    | "flv_aac"
    | "flv_flac"
    | "apm"
    | "argo_asf" => {
      guard output != "" else {
        fail("decode-audio: \{format} requires --output")
      }
      0
    }
    "dfpwm" => 48000
    "g722" | "wav_g722" | "au_g722" | "aifc_g722" => 16000
    "g726" | "g726le" | "wav_g726" | "au_g726le" | "aifc_g726le" => 8000
    "aptx" | "aptxhd" => if rate == 0 { 48000 } else { rate }
    "roq" => 22050
    "daud" => 96000
    "wve" => 8000
    "ts_s302m" => 48000
    "alp" => {
      guard output != "" else { fail("decode-audio: alp requires --output") }
      if alp_pcm {
        0
      } else {
        22050
      }
    }
    _ => fail("decode-audio: unsupported output format \{format}")
  }
  if raw_rate != 0 {
    if output == "" || (rate != 0 && rate != raw_rate) {
      fail(
        "decode-audio: \{format} requires --output and a \{raw_rate} Hz rate",
      )
    }
    rate = raw_rate
  }
  let data = @fs.read_file_to_bytes(path)
  let decoded = @avf.decode_audio_file(
    data,
    filename=path,
    g726_bits~,
    g722_bits~,
    aptx_rate~,
    tta_verify_crc~,
  ) catch {
    e => fail("decode-audio: \{path}: \{e.message()}")
  }
  let audio = if rate != 0 {
    decoded.resample_to(rate) catch {
      e => fail("decode-audio: \{e.message()}")
    }
  } else {
    decoded
  }
  if output != "" {
    let bytes = try {
      match format {
        "dfpwm" => audio.to_dfpwm()
        "wav_dfpwm" | "w64_dfpwm" =>
          audio.to_wav_dfpwm(wave64=format == "w64_dfpwm")
        "w64_f64" => audio.to_w64_samples("pcm_f64le")
        "w64_alaw" => audio.to_w64_samples("pcm_alaw")
        "w64_mulaw" => audio.to_w64_samples("pcm_mulaw")
        "w64_ima_wav" | "w64_ms" | "w64_yamaha" =>
          audio.to_wav_adpcm("adpcm_" + format[4:].to_owned(), wave64=true)
        "g722" => audio.to_g722()
        "wav_g722" => audio.to_wav_g722()
        "wav_g726" => audio.to_wav_g726(g726_bits)
        "au_g722" => audio.to_au_g722()
        "au_g726le" => audio.to_au_g726le(g726_bits)
        "aifc_g722" => audio.to_aifc_g722()
        "aifc_g726le" => audio.to_aifc_g726le()
        "aptx" | "aptxhd" => audio.to_aptx(hd=format == "aptxhd")
        "roq" => audio.to_roq()
        "tta" => audio.to_tta(bits=tta_bits)
        "alp" => audio.to_alp(pcm=alp_pcm)
        "kvag" | "apm" => audio.to_ima_game(apm=format == "apm")
        "argo_asf" => audio.to_argo_asf()
        "wsaud" => audio.to_wsaud()
        "aifc_ima4" => audio.to_aifc_ima4()
        "aifc_gsm" => audio.to_aifc_gsm()
        "mov_gsm" => audio.to_mov_gsm()
        "aifc_adp4" => audio.to_aifc_adp4()
        "aifc_alaw" | "aifc_mulaw" =>
          audio.to_aifc_g711(mulaw=format == "aifc_mulaw")
        "smjpeg_pcm" => audio.to_smjpeg_pcm()
        "sox" | "sox_be" => audio.to_sox(big_endian=format == "sox_be")
        "mmf" => audio.to_mmf()
        "daud" => audio.to_daud()
        "ast" => audio.to_ast()
        "rso" => audio.to_rso()
        "wve" => audio.to_wve()
        "sphere" => audio.to_sphere(codec=sphere_codec)
        "loas" => audio.to_loas()
        "adts" => audio.to_adts()
        "8svx" => audio.to_svx()
        "16sv" => audio.to_svx(bits=16)
        "avr" => audio.to_avr()
        "avr_s8" => audio.to_avr(bits=8)
        "avr_u8" => audio.to_avr(bits=8, signed=false)
        "avr_u16" => audio.to_avr(signed=false)
        "maud" => audio.to_maud()
        "maud_u8" => audio.to_maud(codec="pcm_u8")
        "maud_alaw" => audio.to_maud(codec="pcm_alaw")
        "maud_mulaw" => audio.to_maud(codec="pcm_mulaw")
        "ts_s302m" => audio.to_ts_s302m(bits=s302m_bits)
        "ts_bluray_lpcm" => audio.to_ts_bluray_lpcm(bits=bluray_bits)
        "ts_opus" => audio.to_ts_opus()
        "ts_aac" => audio.to_ts_aac()
        "ts_latm" => audio.to_ts_aac(latm=true)
        "voc" => audio.to_voc()
        "voc_u8" => audio.to_voc(codec="pcm_u8")
        "voc_alaw" => audio.to_voc(codec="pcm_alaw")
        "voc_mulaw" => audio.to_voc(codec="pcm_mulaw")
        "ircam" => audio.to_ircam(codec=ircam_codec)
        "caf_ima4" => audio.to_caf_ima4()
        "caf_ima_wav" => audio.to_caf_wav_adpcm("adpcm_ima_wav")
        "caf_ac3" => audio.to_caf_ac3()
        "ac3" => audio.to_ac3()
        "ts_ac3" => audio.to_ts_ac3()
        "caf_aac" => audio.to_caf_aac()
        "mp4_aac" => audio.to_mp4_aac()
        "mkv_aac" => audio.to_mkv_aac()
        "caf_mp2" => audio.to_caf_mp2()
        "caf_mp3" => audio.to_caf_mp3()
        "caf_gsm" | "caf_gsm_ms" =>
          audio.to_caf_gsm(wav49=format == "caf_gsm_ms")
        "gsm" => audio.to_gsm()
        "wav_gsm_ms" | "w64_gsm_ms" =>
          audio.to_wav_gsm_ms(wave64=format == "w64_gsm_ms")
        "caf_flac" => audio.to_caf_flac(bits=flac_bits)
        "ogg_flac" => audio.to_ogg_flac(bits=flac_bits)
        "mp4_flac" => audio.to_mp4_flac(bits=flac_bits)
        "mp4_alac" => audio.to_mp4_alac(bits=alac_bits)
        "caf_alac" => audio.to_caf_alac(bits=alac_bits)
        "mkv_alac" => audio.to_mkv_alac(bits=alac_bits)
        "mkv_flac" => audio.to_mkv_flac(bits=flac_bits)
        "wav_flac" | "w64_flac" =>
          audio.to_wav_flac(bits=flac_bits, wave64=format == "w64_flac")
        "caf_opus" => audio.to_caf_opus()
        "ogg_opus" => audio.to_ogg_opus()
        "webm_opus" => audio.to_webm_opus()
        "mkv_opus" => audio.to_webm_opus(doctype="matroska")
        "ogg_vorbis" => audio.to_ogg_vorbis()
        "caf_ms" => audio.to_caf_wav_adpcm("adpcm_ms")
        "caf_f32le"
        | "caf_f32be"
        | "caf_f64le"
        | "caf_f64be"
        | "caf_alaw"
        | "caf_mulaw" => audio.to_caf_samples("pcm_" + format[4:].to_owned())
        "adx" => audio.to_adx()
        "qoa" => audio.to_qoa()
        "flv_adpcm" => audio.to_flv_adpcm()
        "flv_aac" => audio.to_flv_aac()
        "flv_flac" => audio.to_flv_flac(bits=flac_bits)
        "adpcm_ima_wav" | "adpcm_ms" | "adpcm_yamaha" =>
          audio.to_wav_adpcm(format)
        "g726" | "g726le" =>
          audio.to_g726(g726_bits, little_endian=format == "g726le")
        _ => audio.to_wav_s16()
      }
    } catch {
      e => fail("decode-audio: \{format} export: \{e.message()}")
    }
    @fs.write_bytes_to_file(output, bytes)
  }
  println(audio.summary_json())
}
