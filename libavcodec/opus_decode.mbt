///|
/// MoonBit port of the FFmpeg 9.0.2 Opus packet decoder orchestration,
/// `libavcodec/opus/dec.c`. Copyright (c) 2012 Andrew D'Addesio,
/// 2013-2014 Mozilla Corporation. LGPL-2.1-or-later.
///
/// Drives the SILK and CELT layers per logical stream: SILK-only frames are
/// resampled to 48 kHz (`silk_resample_delay` pre-roll, `delayed_samples`
/// flush semantics), hybrid frames add the resampled LP layer to CELT with a
/// `celt_delay` FIFO, SILK frames may carry a CELT redundancy frame that is
/// cross-faded over the 120-sample window, and multistream packets keep
/// streams aligned through per-stream sync FIFOs. Decoding errors conceal to
/// silence for the frame duration, matching the default (non-EXPLODE) C
/// behavior. The output-gain path uses `pow(10, x)`; FFmpeg's `ff_exp10` may
/// differ by a ulp, so gain-free streams are the validated configuration.

///|
let opus_celt_band_end : Array[Int32] = [13, 17, 17, 19, 21]

///|
let opus_silk_frame_duration_ms : Array[Int32] = [
  10, 20, 40, 60, 10, 20, 40, 60, 10, 20, 40, 60, 10, 20, 10, 20,
]

///|
/// Number of leading silence samples fed to the resampler, indexed by the
/// packet bandwidth (0..4).
let opus_silk_resample_delay : Array[Int32] = [4, 8, 11, 11, 11]

///|
/// `get_silk_samplerate`: 8/12/16 kHz by config group. Hybrid frames also
/// land at 16 kHz — the SILK layer always covers up to 8 kHz.
fn opus_silk_samplerate(config : Int32) -> Int32 {
  if config < 4 {
    8000
  } else if config < 8 {
    12000
  } else {
    16000
  }
}

///|
/// Numeric bandwidth 0..4 from the TOC config, as `opus/parse.c` derives it
/// (the MoonBit `OpusPacket` keeps the string form).
fn opus_bandwidth_index(config : Int32) -> Int32 {
  if config < 12 {
    config >> 2
  } else if config < 16 {
    3 + (if config >= 14 { 1 } else { 0 })
  } else {
    let bandwidth = (config - 16) >> 2
    if bandwidth != 0 {
      bandwidth + 1
    } else {
      0
    }
  }
}

///|
/// `opus_fade`: `out = in2 * window + in1 * (1 - window)` with the C's
/// promotion order — the second product and the sum are computed in double.
fn opus_fade(
  out : Array[Float],
  out_pos : Int32,
  in1 : Array[Float],
  in1_pos : Int32,
  in2 : Array[Float],
  in2_pos : Int32,
  window : FixedArray[Float],
  window_pos : Int32,
  len : Int32,
) -> Unit {
  for i in 0..<len {
    let first = in2[in2_pos + i] * window[window_pos + i]
    let second = Float::from_double(
      in1[in1_pos + i].to_double() * (1.0 - window[window_pos + i].to_double()),
    )
    out[out_pos + i] = Float::from_double(
      first.to_double() + second.to_double(),
    )
  }
}

///|
/// Per-channel float FIFO standing in for `AVAudioFifo` (fltp). Values and
/// counts match; storage layout does not.
priv struct OpusFifo {
  chans : Array[Array[Float]]
  mut start : Int32
  mut count : Int32
}

///|
fn OpusFifo::new(channels : Int32) -> OpusFifo {
  let chans : Array[Array[Float]] = []
  for _ in 0..<channels {
    chans.push([])
  }
  { chans, start: 0, count: 0, }
}

///|
fn OpusFifo::size(self : OpusFifo) -> Int32 {
  self.count
}

///|
fn OpusFifo::reset(self : OpusFifo) -> Unit {
  self.start = 0
  self.count = 0
}

///|
/// Append `n` samples starting at `src_pos` of each channel array.
fn OpusFifo::write(
  self : OpusFifo,
  src : Array[Array[Float]],
  src_pos : Int32,
  n : Int32,
) -> Unit {
  for c in 0..<self.chans.length() {
    let buf = self.chans[c]
    let from = src[c]
    for i in 0..<n {
      buf.push(from[src_pos + i])
    }
  }
  self.count += n
  if self.start > 8192 {
    for c in 0..<self.chans.length() {
      self.chans[c] = self.chans[c][self.start:].to_owned()
    }
    self.start = 0
  }
}

///|
/// Take up to `n` samples into channel arrays at `dst_pos`; returns false if
/// fewer than `n` are queued (state unchanged).
fn OpusFifo::read(
  self : OpusFifo,
  dst : Array[Array[Float]],
  dst_pos : Int32,
  n : Int32,
) -> Bool {
  if self.count < n {
    return false
  }
  for c in 0..<self.chans.length() {
    let buf = self.chans[c]
    let to = dst[c]
    for i in 0..<n {
      to[dst_pos + i] = buf[self.start + i]
    }
  }
  self.start += n
  self.count -= n
  true
}

///|
/// One logical Opus stream's decoder state (`OpusStreamContext`).
priv struct OpusStream {
  output_channels : Int32
  silk : OpusSilkDecoder
  celt : OpusCeltDecoder
  swr : OpusResampler
  mut silk_samplerate : Int32
  mut delayed_samples : Int32
  celt_delay : OpusFifo
  sync_buffer : OpusFifo
  silk_buf : Array[Array[Float]]
  celt_buf : Array[Array[Float]]
  dummy_buf : Array[Array[Float]]
  mut redundancy_pcm : Array[Array[Float]]
  mut redundancy_idx : Int32
  mut current_packet : OpusPacket?
  // Output view for the current packet; `chans[c]` is the mapped output
  // channel's storage (or the dummy buffer), `pos` the write cursor.
  mut out_buf : AudioBuf
  mut decoded_samples : Int32
}

///|
fn OpusStream::new(
  output_channels : Int32,
  apply_phase_inv : Bool,
) -> OpusStream {
  let silk_buf : Array[Array[Float]] = []
  let celt_buf : Array[Array[Float]] = []
  let dummy : Array[Array[Float]] = []
  for _ in 0..<output_channels {
    silk_buf.push(Array::make(960, 0.0))
    celt_buf.push(Array::make(960, 0.0))
    dummy.push([])
  }
  {
    output_channels,
    silk: OpusSilkDecoder::new(output_channels),
    celt: match OpusCeltDecoder::new(output_channels, apply_phase_inv~) {
      Ok(decoder) => decoder
      Err(_) => abort("opus: CELT decoder init failed")
    },
    swr: OpusResampler::new(output_channels, 48000),
    silk_samplerate: 0,
    delayed_samples: 0,
    celt_delay: OpusFifo::new(output_channels),
    sync_buffer: OpusFifo::new(output_channels),
    silk_buf,
    celt_buf,
    dummy_buf: dummy,
    redundancy_pcm: [],
    redundancy_idx: 0,
    current_packet: None,
    out_buf: AudioBuf::{ chans: dummy, pos: 0, },
    decoded_samples: 0,
  }
}

///|
/// Bind the packet output views: mapped stream channels point into the packet
/// output arrays, unmapped ones at the stream dummy (grown to `capacity`).
fn OpusStream::bind_out(
  self : OpusStream,
  outputs : Array[Array[Float]],
  mapped : Array[Int32?],
  capacity : Int32,
) -> Unit {
  let chans : Array[Array[Float]] = []
  for ch in 0..<self.output_channels {
    match mapped[ch] {
      Some(index) => chans.push(outputs[index])
      None => {
        if self.dummy_buf[ch].length() < capacity {
          self.dummy_buf[ch] = Array::make(capacity, 0.0)
        }
        chans.push(self.dummy_buf[ch])
      }
    }
  }
  self.out_buf = AudioBuf::{ chans, pos: 0, }
}

///|
/// `opus_init_resample`: open the resampler at the SILK rate and feed the
/// bandwidth-dependent initial silence.
fn OpusStream::init_resample(
  self : OpusStream,
  bandwidth : Int32,
) -> Result[Unit, String] {
  self.swr.open(self.silk_samplerate)
  let silence : Array[Array[Float]] = []
  for _ in 0..<self.output_channels {
    silence.push(Array::make(16, 0.0))
  }
  let dummy_out = AudioBuf::{ chans: self.dummy_buf, pos: 0, }
  let _ = self.swr.convert(
    dummy_out,
    0,
    Some(AudioBuf::{ chans: silence, pos: 0, }),
    opus_silk_resample_delay[bandwidth],
  )
  Ok(())
}

///|
/// `opus_flush_resample`: pull the remaining `nb_samples` from the resampler,
/// mix any queued CELT delay samples, and fade out pending redundancy.
fn OpusStream::flush_resample(
  self : OpusStream,
  nb_samples : Int32,
  window : FixedArray[Float],
) -> Result[Unit, String] {
  let celt_size = self.celt_delay.size()
  let pos_before = self.out_buf.pos
  let produced = self.swr.convert(self.out_buf, nb_samples, None, 0)
  guard produced == nb_samples else {
    return Err("opus: wrong number of flushed samples")
  }
  self.out_buf.pos += nb_samples
  if celt_size > 0 {
    guard celt_size == nb_samples else {
      return Err("opus: wrong number of CELT delay samples")
    }
    let _ = self.celt_delay.read(self.celt_buf, 0, nb_samples)
    for ch in 0..<self.output_channels {
      let dst = self.out_buf.chans[ch]
      let src = self.celt_buf[ch]
      for i in 0..<nb_samples {
        dst[pos_before + i] += src[i]
      }
    }
  }
  if self.redundancy_idx > 0 {
    for ch in 0..<self.output_channels {
      opus_fade(
        self.out_buf.chans[ch],
        pos_before,
        self.out_buf.chans[ch],
        pos_before,
        self.redundancy_pcm[ch],
        120 + self.redundancy_idx,
        window,
        self.redundancy_idx,
        120 - self.redundancy_idx,
      )
    }
    self.redundancy_idx = 0
  }
  Ok(())
}

///|
/// `opus_decode_redundancy`: decode the 10 ms CELT redundancy frame from the
/// packet tail; the returned channel-major PCM replaces `redundancy_pcm`.
fn OpusStream::decode_redundancy(
  self : OpusStream,
  packet_data : Bytes,
  frame_offset : Int32,
  size : Int32,
  bandwidth : Int32,
) -> Result[Unit, String] {
  let rc = match
    opus_rc_init(packet_data[frame_offset:frame_offset + size].to_owned()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match
    self.celt.decode_frame_rc(rc, size, 240, 0, opus_celt_band_end[bandwidth]) {
    Ok(pcm) => {
      self.redundancy_pcm = pcm
      Ok(())
    }
    Err(error) => Err(error)
  }
}

///|
/// `opus_decode_frame`: one Opus frame (SILK/hybrid/CELT dispatch, redundancy
/// handling, resampler feeding). Returns the number of samples produced.
fn OpusStream::decode_frame(
  self : OpusStream,
  packet_data : Bytes,
  frame_offset : Int32,
  size : Int32,
  window : FixedArray[Float],
) -> Result[Int32, String] {
  let packet = match self.current_packet {
    Some(value) => value
    None => return Err("opus: no packet header")
  }
  let frame_bytes = packet_data[frame_offset:frame_offset + size].to_owned()
  let mut samples = packet.frame_duration
  let mut delayed_samples = self.delayed_samples
  let mut size = size
  let rc = match opus_rc_init(frame_bytes) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let bandwidth = opus_bandwidth_index(packet.config)
  // Decode the silk frame.
  if packet.mode == "silk" || packet.mode == "hybrid" {
    if !self.swr.is_opened() {
      match self.init_resample(bandwidth) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
    }
    let silk_samples = match
      self.silk.decode_superframe(
        rc,
        self.silk_buf,
        if bandwidth < 2 {
          bandwidth
        } else {
          2
        },
        packet.stereo.to_int() + 1,
        opus_silk_frame_duration_ms[packet.config],
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    // cur_out stays at the frame start for the whole frame; the caller
    // advances it once after the frame completes (as in dec.c).
    samples = self.swr.convert(
      self.out_buf,
      packet.frame_duration,
      Some(AudioBuf::{ chans: self.silk_buf, pos: 0, }),
      silk_samples,
    )
    self.delayed_samples += packet.frame_duration - samples
    delayed_samples = self.delayed_samples
  } else {
    self.silk.flush()
  }
  // Decode redundancy information.
  let consumed = rc.tell()
  let mut redundancy = 0
  if packet.mode == "hybrid" && consumed + 37 <= size * 8 {
    match rc.decode_log(12) {
      Ok(value) => redundancy = value
      Err(error) => return Err(error)
    }
  } else if packet.mode == "silk" && consumed + 17 <= size * 8 {
    redundancy = 1
  }
  let mut redundancy_pos = 0
  let mut redundancy_size = 0
  if redundancy != 0 {
    match rc.decode_log(1) {
      Ok(value) => redundancy_pos = value
      Err(error) => return Err(error)
    }
    if packet.mode == "hybrid" {
      match rc.decode_uint(256U) {
        Ok(value) => redundancy_size = value.reinterpret_as_int() + 2
        Err(error) => return Err(error)
      }
    } else {
      redundancy_size = size - (consumed + 7) / 8
    }
    size -= redundancy_size
    if size < 0 {
      return Err("opus: invalid redundancy frame size")
    }
    if redundancy_pos != 0 {
      match
        self.decode_redundancy(
          packet_data,
          frame_offset + size,
          redundancy_size,
          bandwidth,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      self.celt.reset()
    }
  }
  // Decode the CELT frame.
  if packet.mode == "celt" || packet.mode == "hybrid" {
    let hybrid = packet.mode == "hybrid"
    let mut celt_output_samples = samples
    let delay_samples = self.celt_delay.size()
    let mut out_tmp_pos = self.out_buf.pos
    if delay_samples > 0 {
      if hybrid {
        let _ = self.celt_delay.read(self.celt_buf, 0, delay_samples)
        for ch in 0..<self.output_channels {
          let dst = self.out_buf.chans[ch]
          let src = self.celt_buf[ch]
          for i in 0..<delay_samples {
            dst[out_tmp_pos + i] += src[i]
          }
        }
        out_tmp_pos += delay_samples
        celt_output_samples -= delay_samples
      } else {
        self.celt_delay.reset()
      }
    }
    let start_band = if hybrid { 17 } else { 0 }
    let pcm = match
      self.celt.decode_frame_rc(
        rc,
        size,
        packet.frame_duration,
        start_band,
        opus_celt_band_end[bandwidth],
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if hybrid {
      let dbg = StringBuilder()
      dbg.write_string("CELT \{packet.frame_duration}")
      for i in 0..<packet.frame_duration {
        for c in 0..<self.output_channels {
          dbg.write_string(" \{pcm[c][i].reinterpret_as_uint()}")
        }
      }
      println(dbg)
    }
    if hybrid {
      for ch in 0..<self.output_channels {
        let dst = self.out_buf.chans[ch]
        let src = pcm[ch]
        for i in 0..<celt_output_samples {
          dst[out_tmp_pos + i] += src[i]
        }
      }
      let celt_delay_samples = packet.frame_duration - celt_output_samples
      self.celt_delay.write(pcm, celt_output_samples, celt_delay_samples)
    } else {
      for ch in 0..<self.output_channels {
        let dst = self.out_buf.chans[ch]
        let src = pcm[ch]
        for i in 0..<packet.frame_duration {
          dst[self.out_buf.pos + i] = src[i]
        }
      }
    }
  } else {
    self.celt.reset()
  }
  if self.redundancy_idx > 0 {
    for ch in 0..<self.output_channels {
      let out = self.out_buf.chans[ch]
      let out_pos = self.out_buf.pos
      opus_fade(
        out,
        out_pos,
        out,
        out_pos,
        self.redundancy_pcm[ch],
        120 + self.redundancy_idx,
        window,
        self.redundancy_idx,
        120 - self.redundancy_idx,
      )
    }
    self.redundancy_idx = 0
  }
  if redundancy != 0 {
    if redundancy_pos == 0 {
      self.celt.reset()
      match
        self.decode_redundancy(
          packet_data,
          frame_offset + size,
          redundancy_size,
          bandwidth,
        ) {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      for ch in 0..<self.output_channels {
        let out = self.out_buf.chans[ch]
        let fade_pos = self.out_buf.pos + samples - 120 + delayed_samples
        opus_fade(
          out,
          fade_pos,
          out,
          fade_pos,
          self.redundancy_pcm[ch],
          120,
          window,
          0,
          120 - delayed_samples,
        )
        if delayed_samples > 0 {
          self.redundancy_idx = 120 - delayed_samples
        }
      }
    } else {
      for ch in 0..<self.output_channels {
        let out = self.out_buf.chans[ch]
        let out_pos = self.out_buf.pos
        for i in 0..<120 {
          out[out_pos + delayed_samples + i] = self.redundancy_pcm[ch][i]
        }
        opus_fade(
          out,
          out_pos + 120 + delayed_samples,
          self.redundancy_pcm[ch],
          120,
          out,
          out_pos + 120 + delayed_samples,
          window,
          0,
          120,
        )
      }
    }
  }
  Ok(samples)
}

///|
/// `opus_decode_subpacket`: flush bookkeeping, then decode every frame of the
/// stream's packet. Returns total output samples for this stream.
fn OpusStream::decode_subpacket(
  self : OpusStream,
  packet_data : Bytes?,
  window : FixedArray[Float],
) -> Result[Int32, String] {
  let mut output_samples = 0
  let mut flush_needed = false
  if self.swr.is_opened() {
    if packet_data is Some(_) {
      flush_needed = self.current_packet_mode() == "celt" ||
        self.swr.in_rate() != self.silk_samplerate
    } else {
      flush_needed = self.delayed_samples > 0
    }
  }
  if packet_data is None && !flush_needed {
    return Ok(0)
  }
  if flush_needed {
    match self.flush_resample(self.delayed_samples, window) {
      Ok(_) => ()
      Err(error) => return Err(error)
    }
    self.swr.close()
    output_samples += self.delayed_samples
    self.delayed_samples = 0
    if packet_data is None {
      return Ok(output_samples)
    }
  }
  let packet = match self.current_packet {
    Some(value) => value
    None => return Err("opus: no packet header")
  }
  let data = match packet_data {
    Some(value) => value
    None => return Err("opus: no packet data")
  }
  for i in 0..<packet.frame_count {
    let size = packet.frame_sizes[i]
    let samples = match
      self.decode_frame(data, packet.frame_offsets[i], size, window) {
      Ok(value) => value
      Err(_) => {
        // Concealment: silence for the frame duration.
        for ch in 0..<self.output_channels {
          let out = self.out_buf.chans[ch]
          let pos = self.out_buf.pos
          for j in 0..<packet.frame_duration {
            out[pos + j] = 0.0
          }
        }
        packet.frame_duration
      }
    }
    output_samples += samples
    self.out_buf.pos += samples
  }
  Ok(output_samples)
}

///|
fn OpusStream::current_packet_mode(self : OpusStream) -> String {
  match self.current_packet {
    Some(packet) => packet.mode
    None => ""
  }
}

///|
/// The multistream Opus decoder (`OpusContext`), built from a parsed
/// OpusHead. Output is channel-major float PCM at 48 kHz in FFmpeg's channel
/// order (the head's output_map).
pub struct OpusDecoder {
  priv head : OpusHead
  priv streams : Array[OpusStream]
  priv gain : Float
}

///|
/// Create a decoder for the given OpusHead extradata. One stream decoder per
/// logical stream; stereo streams come first, as in the C.
pub fn OpusDecoder::new(
  head : OpusHead,
  apply_phase_inv~ : Bool = true,
) -> Result[OpusDecoder, String] {
  let streams : Array[OpusStream] = []
  for i in 0..<head.stream_count {
    let output_channels = if i < head.coupled_count { 2 } else { 1 }
    streams.push(OpusStream::new(output_channels, apply_phase_inv))
  }
  let gain : Float = if head.output_gain != 0 {
    Float::from_double(
      @math.pow(10.0, head.output_gain.to_double() / (20.0 * 256.0)),
    )
  } else {
    1.0
  }
  Ok({ head, streams, gain, })
}

///|
/// `opus_decode_flush`: forget all history (after a seek).
pub fn OpusDecoder::flush(self : OpusDecoder) -> Unit {
  for stream in self.streams {
    stream.delayed_samples = 0
    stream.celt_delay.reset()
    stream.sync_buffer.reset()
    stream.swr.close()
    stream.silk.flush()
    stream.celt.reset()
    stream.redundancy_idx = 0
  }
}

///|
/// Decode one container packet (all logical streams), or drain the decoder
/// with `data = None` after the last packet. Returns channel-major float PCM
/// in FFmpeg output channel order with `samples` valid samples per channel;
/// empty result when nothing is decodable.
pub fn OpusDecoder::decode_packet(
  self : OpusDecoder,
  data : Bytes?,
) -> Result[(Array[Array[Float]], Int32), String] {
  let channels = self.head.channels
  let window = opus_celt_window2
  let mut coded_samples = 0
  let mut delayed_samples = 0
  let spans : Array[OpusStreamPacket] = match data {
    Some(buf) =>
      match self.head.parse_packet(buf) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    None => []
  }
  if data is Some(_) {
    coded_samples = spans[0].packet.frame_count * spans[0].packet.frame_duration
    self.streams[0].silk_samplerate = opus_silk_samplerate(
      spans[0].packet.config,
    )
    for i in 0..<self.streams.length() {
      self.streams[i].current_packet = Some(spans[i].packet)
      if i > 0 {
        self.streams[i].silk_samplerate = opus_silk_samplerate(
          spans[i].packet.config,
        )
      }
    }
  }
  for stream in self.streams {
    let pending = stream.delayed_samples + stream.sync_buffer.size()
    if pending > delayed_samples {
      delayed_samples = pending
    }
  }
  let nb_samples = coded_samples + delayed_samples
  if nb_samples == 0 {
    return Ok(([], 0))
  }
  let aligned = (nb_samples + 7) >> 3 << 3
  let outputs : Array[Array[Float]] = []
  for _ in 0..<channels {
    outputs.push(Array::make(aligned, 0.0))
  }
  // Per-stream: which output channel (if any) feeds stream channel ch.
  let stream_maps : Array[Array[Int32?]] = []
  for _ in 0..<self.streams.length() {
    stream_maps.push([None, None])
  }
  for i in 0..<channels {
    let map = self.head.output_map[i]
    if map.copy_from is Some(_) || map.silence {
      continue
    }
    stream_maps[map.stream_index][map.channel_index] = Some(i)
  }
  for i in 0..<self.streams.length() {
    self.streams[i].bind_out(outputs, stream_maps[i], aligned)
  }
  // Read the data from the sync buffers.
  for stream in self.streams {
    let sync_size = stream.sync_buffer.size()
    if sync_size > 0 {
      let _ = stream.sync_buffer.read(
        stream.out_buf.chans,
        stream.out_buf.pos,
        sync_size,
      )
      stream.out_buf.pos += sync_size
    }
  }
  // Decode each stream's sub-packet.
  let mut decoded_samples = 2147483647
  for i in 0..<self.streams.length() {
    let stream = self.streams[i]
    let span_data : Bytes? = match data {
      Some(buf) => Some(buf[spans[i].offset:].to_owned())
      None => None
    }
    let produced = match stream.decode_subpacket(span_data, window) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    stream.decoded_samples = produced
    if produced < decoded_samples {
      decoded_samples = produced
    }
  }
  // Buffer the extra samples for stream synchronization.
  for stream in self.streams {
    let extra = stream.decoded_samples - decoded_samples
    if extra > 0 {
      let bufs : Array[Array[Float]] = []
      for ch in 0..<stream.output_channels {
        let buf = stream.out_buf.chans[ch]
        // C falls back to the first output channel for unmapped channels;
        // the values are never observable, only the counts matter.
        bufs.push(buf)
      }
      stream.sync_buffer.write(bufs, decoded_samples, extra)
    }
  }
  // Copied and silent channels, then the output gain.
  for i in 0..<channels {
    let map = self.head.output_map[i]
    match map.copy_from {
      Some(source) =>
        for j in 0..<nb_samples {
          outputs[i][j] = outputs[source][j]
        }
      None =>
        if map.silence {
          for j in 0..<nb_samples {
            outputs[i][j] = 0.0
          }
        }
    }
    if self.head.output_gain != 0 && decoded_samples > 0 {
      let limit = (decoded_samples + 7) >> 3 << 3
      for j in 0..<limit {
        outputs[i][j] *= self.gain
      }
    }
  }
  Ok((outputs, decoded_samples))
}
