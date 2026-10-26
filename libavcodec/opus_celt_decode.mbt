///|
/// Stateful 48 kHz CELT-only synthesis, one instance per logical Opus stream.
/// Frame input excludes the Opus TOC. Channel count remains fixed per instance.
/// SILK/hybrid, packet loss concealment and container pre-skip are caller layers.
pub struct OpusCeltDecoder {
  priv channels : Int32
  priv apply_phase_inv : Bool
  priv mut history : OpusCeltHistory
  priv mut synthesis : Array[CeltSynthesisChannel]
  priv coefficients_log : Array[OpusCeltCoefficients]
}

///|
/// Create a mono/stereo CELT decoder with empty overlap and energy history.
pub fn OpusCeltDecoder::new(
  channels : Int32,
  apply_phase_inv~ : Bool = true,
) -> Result[OpusCeltDecoder, String] {
  guard channels == 1 || channels == 2 else {
    return Err("opus: invalid CELT output channels")
  }
  Ok({
    channels,
    apply_phase_inv,
    history: OpusCeltHistory::new(),
    synthesis: [
      for _ in 0..<channels => CeltSynthesisChannel::new()
    ],
    coefficients_log: [],
  })
}

///|
/// Reset spectral, overlap, pitch-filter and deemphasis history after a seek.
pub fn OpusCeltDecoder::reset(self : OpusCeltDecoder) -> Unit {
  self.history = OpusCeltHistory::new()
  self.synthesis = [ for _ in 0..<self.channels => CeltSynthesisChannel::new() ]
  self.coefficients_log.clear()
}

///|
/// Decode one CELT frame into channel-major floating PCM at 48 kHz.
/// Supported frame sizes: 120, 240, 480 and 960 samples; end band: 13/17/19/21.
/// Failed frames do not change decoder history. No gain or clipping is applied.
///
/// ```mbt check
/// test {
///   let decoder = @libavcodec.OpusCeltDecoder::new(1).unwrap()
///   let pcm = decoder.decode_frame(b"\xff\xfe", 120, 13).unwrap()
///   assert_eq(pcm, [Array::make(120, 0.0)])
/// }
/// ```
pub fn OpusCeltDecoder::decode_frame(
  self : OpusCeltDecoder,
  data : Bytes,
  frame_size : Int32,
  end_band : Int32,
) -> Result[Array[Array[Float]], String] {
  guard end_band == 13 || end_band == 17 || end_band == 19 || end_band == 21 else {
    return Err("opus: invalid CELT bandwidth")
  }
  let rc = match opus_rc_init(data) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  self.decode_frame_rc(rc, data.length(), frame_size, 0, end_band)
}

///|
/// Decode one CELT frame from a caller-owned range decoder, ported for the
/// SILK/hybrid paths of `opus/dec.c`: the arithmetic window may already hold
/// consumed SILK symbols, and `raw_end` re-points the backwards raw-bit reader
/// at `rc.data[0..raw_end]` (the frame minus any redundancy tail). Start band
/// is 0 for CELT/redundancy frames and 17 for hybrid frames.
pub fn OpusCeltDecoder::decode_frame_rc(
  self : OpusCeltDecoder,
  rc : OpusRangeDecoder,
  raw_end : Int32,
  frame_size : Int32,
  start_band : Int32,
  end_band : Int32,
) -> Result[Array[Array[Float]], String] {
  guard end_band == 13 || end_band == 17 || end_band == 19 || end_band == 21 else {
    return Err("opus: invalid CELT bandwidth")
  }
  rc.reinit_raw(raw_end)
  let frame = match
    rc.decode_celt_coefficients(
      self.history,
      self.channels,
      frame_size,
      start_band,
      end_band,
      apply_phase_inv=self.apply_phase_inv,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let states = self.synthesis.map(fn(channel) { channel.copy() })
  let pcm = [
    for channel in 0..<self.channels => {
      opus_celt_synthesize(states[channel], frame, channel)
    }
  ]
  self.history = frame.history
  self.synthesis = states
  self.coefficients_log.push(frame)
  Ok(pcm)
}
