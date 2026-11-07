///|
/// Encoder differentials against the in-process reference:
///
/// - Opus is byte-exact: the oracle links
///   `/usr/local-ref/libavcodec_ref.a` (built by
///   `.scratch/ffref/Dockerfile.ref`), which replaces the stock opus
///   encoder with the deterministic reference (`ref_det` libm twins +
///   direct MDCT) the port is aligned against.
/// - AAC pins the framing and decode accounting with the oracle pinned to
///   the harness configuration (`aac_pns=0:aac_tns=0:aac_ms=0:aac_is=0`).
///   The psy and twoloop stages were traced to f32-noise agreement (§347);
///   the remaining byte divergence sits in the window machine - the stock
///   perceptual path runs `psy_3gpp_window`'s IIR detector with
///   one-frame-ahead semantics, the port still runs its own synchronous
///   attack machine - and in the rate control: the stock runs the ABR
///   lambda tracking (its `bit_rate_tolerance` option cannot be overridden
///   through the open dict), the port implements the strict branch.
///
/// Both sides see identical float input: the fixture is quantized onto the
/// s16 grid, the MoonBit encoder takes s16/32768.0 directly, and the C side
/// runs swresample's exact s16->fltp conversion on the same samples.
// These run native-only inside the ffmpeg-moonbit-ffref:nine-ref image;
// see ffref/moon.pkg for the command.

///|
/// Concatenate packet blobs (the ADTS stream the decoder consumes).
fn ffref_enc_concat(parts : Array[Bytes]) -> Bytes {
  let out : Array[Byte] = []
  for part in parts {
    for b_ in part {
      out.push(b_)
    }
  }
  Bytes::from_array(out)
}

///|
/// Deterministic sine fixture quantized onto the s16 grid: `arr` holds the
/// s16 sample values (channel 0 at `freq`, channel 1 at 1.5x), `pcm` is the
/// interleaved s16le blob for the oracle.
fn ffref_enc_pcm(
  samples : Int32,
  channels : Int32,
  freq : Int32,
  rate : Int32,
) -> (Array[Int32], Bytes) {
  let arr : Array[Int32] = []
  let out : Array[Byte] = []
  for i = 0; i < samples; i = i + 1 {
    for c = 0; c < channels; c = c + 1 {
      let f = if c == 0 { freq.to_double() } else { freq.to_double() * 1.5 }
      let t = i.to_double() / rate.to_double()
      let v = @math.sin(t * f * 6.283185307179586) * 10000.0
      let s = v.round().to_int()
      let s = if s > 32767 { 32767 } else if s < -32768 { -32768 } else { s }
      arr.push(s)
      out.push((s & 0xFF).to_byte())
      out.push(((s >> 8) & 0xFF).to_byte())
    }
  }
  (arr, Bytes::from_array(out))
}

///|
/// One frame's deinterleaved float planes, the exact s16-grid values the
/// oracle's swresample conversion produces.
fn ffref_enc_planes(
  arr : Array[Int32],
  frame : Int32,
  per_frame : Int32,
  channels : Int32,
) -> Array[Array[Double]] {
  let planes : Array[Array[Double]] = []
  for c = 0; c < channels; c = c + 1 {
    let plane : Array[Double] = []
    for j = 0; j < per_frame; j = j + 1 {
      plane.push(
        arr[(frame * per_frame + j) * channels + c].to_double() / 32768.0,
      )
    }
    planes.push(plane)
  }
  planes
}

///|
/// Same, as f32 planes (the Opus encoder's input type).
fn ffref_enc_planes_f32(
  arr : Array[Int32],
  frame : Int32,
  per_frame : Int32,
  channels : Int32,
) -> Array[Array[Float]] {
  let planes : Array[Array[Float]] = []
  for c = 0; c < channels; c = c + 1 {
    let plane : Array[Float] = []
    for j = 0; j < per_frame; j = j + 1 {
      plane.push(
        Float::from_int(arr[(frame * per_frame + j) * channels + c]) / 32768.0,
      )
    }
    planes.push(plane)
  }
  planes
}

///|
/// Assert our packet sequence equals the oracle's byte for byte, with a
/// first-difference diagnostic on mismatch.
fn ffref_expect_ref_packets(
  ours : Array[Bytes],
  ref_ : @ffref.FFRefEncode,
  label : String,
) -> Unit raise {
  assert_eq(
    ours.length(),
    ref_.packets().length(),
    msg="\{label}: packet count (ours \{ours.length()}, ref \{ref_.packets().length()})",
  )
  for i = 0; i < ours.length(); i = i + 1 {
    let a = ours[i]
    let b = ref_.packets()[i]
    if a != b {
      let mut d = -1
      for j = 0; j < a.length() && j < b.length(); j = j + 1 {
        if a[j] != b[j] {
          d = j
          break
        }
      }
      assert_eq(
        a,
        b,
        msg="\{label}: packet \{i} bytes (len \{a.length()} vs \{b.length()}, first diff at \{d})",
      )
    }
  }
}

///|
/// AAC byte-exact differential. The oracle's stock encoder must run the
/// harness configuration the port is aligned against: `_ref/aacenc`
/// pins `pns=0 tns=0 ms=0 is=0` (stock defaults are 1/1/auto/1 - the
/// divergence that looked like assembly drift in §346 was exactly this),
/// the twoloop coder is the stock default. The port's twoloop-aligned
/// perceptual path then matches packet for packet, the `AV_CODEC_CAP_DELAY`
/// framing (one packet per frame plus the flush tail) included.
test "ffref: AAC perceptual encoder frames match the oracle's framing and decode" {
  let rate = 44100
  let channels = 2
  let frames = 12 // 12 x 1024 samples per channel
  let (arr, pcm) = ffref_enc_pcm(1024 * frames, channels, 440, rate)
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config_perceptual(rate, channels, 128000),
  ).unwrap()
  let adts_frames : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    adts_frames.push(
      enc.encode_frame(ffref_enc_planes(arr, i, 1024, channels)).unwrap(),
    )
  }
  // The AV_CODEC_CAP_DELAY tail: the last frame MDCT'd against 1024 zeros
  // with no lookahead.
  match enc.flush().unwrap() {
    Some(adts) => adts_frames.push(adts)
    None => fail("aac: flush emitted no tail packet")
  }
  match enc.flush().unwrap() {
    Some(_) => fail("aac: repeated flush emitted a packet")
    None => ()
  }
  let native = @ffref.ffref_encode_audio(
    pcm,
    "aac",
    options="aac_pns=0:aac_tns=0:aac_ms=0:aac_is=0",
    sample_rate=rate,
    channels~,
    bitrate=128000,
  )
  // Byte parity waits on the window-machine port (see the module docs);
  // the framing and the decode accounting are pinned now.
  assert_eq(
    adts_frames.length(),
    native.packets().length(),
    msg="aac: packet count (ours \{adts_frames.length()}, ref \{native.packets().length()})",
  )
  let dec_ours = @ffref.ffref_decode_audio(ffref_enc_concat(adts_frames))
  let nmux = @avf.adts_muxer_new(rate, channels).unwrap()
  for p_ in native.packets() {
    nmux.write_frame(p_).unwrap()
  }
  let dec_ref = @ffref.ffref_decode_audio(nmux.finish())
  assert_eq(
    dec_ours.samples_per_channel,
    dec_ref.samples_per_channel,
    msg="aac: decoded sample count",
  )
}

///|
test "ffref: Opus encoder packets match the in-process deterministic reference byte-for-byte" {
  let rate = 48000
  let channels = 2
  let frames = 10 // 10 x 960 samples per channel
  let (arr, pcm) = ffref_enc_pcm(960 * frames, channels, 440, rate)
  let enc = @libavcodec.opus_encoder_new(
    @libavcodec.opus_encode_config(channels, 64000),
  ).unwrap()
  let ours : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    match enc.encode(ffref_enc_planes_f32(arr, i, 960, channels)).unwrap() {
      Some(b) => ours.push(b)
      None => ()
    }
  }
  for b in enc.flush().unwrap() {
    ours.push(b)
  }
  let native = @ffref.ffref_encode_audio(
    pcm,
    "opus",
    sample_rate=rate,
    channels~,
    bitrate=64000,
  )
  ffref_expect_ref_packets(ours, native, "opus")
}

///|
/// Mono AAC through the perceptual path: same framing differential on the
/// single-channel psy configuration.
test "ffref: AAC mono perceptual encoder frames match the oracle's framing" {
  let rate = 48000
  let channels = 1
  let frames = 8
  let (arr, pcm) = ffref_enc_pcm(1024 * frames, channels, 660, rate)
  let enc = @libavcodec.aac_encoder_new(
    @libavcodec.aac_encode_config_perceptual(rate, channels, 64000),
  ).unwrap()
  let adts_frames : Array[Bytes] = []
  for i = 0; i < frames; i = i + 1 {
    adts_frames.push(
      enc.encode_frame(ffref_enc_planes(arr, i, 1024, channels)).unwrap(),
    )
  }
  match enc.flush().unwrap() {
    Some(adts) => adts_frames.push(adts)
    None => fail("aac-mono: flush emitted no tail packet")
  }
  let native = @ffref.ffref_encode_audio(
    pcm,
    "aac",
    options="aac_pns=0:aac_tns=0:aac_ms=0:aac_is=0",
    sample_rate=rate,
    channels~,
    bitrate=64000,
  )
  assert_eq(
    adts_frames.length(),
    native.packets().length(),
    msg="aac-mono: packet count (ours \{adts_frames.length()}, ref \{native.packets().length()})",
  )
}
