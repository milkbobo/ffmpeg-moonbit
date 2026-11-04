/// MoonBit port of FFmpeg 9.0.2 `opus/enc.c` (`ff_opus_encoder`): the CELT-only
/// native Opus encoder orchestration — input queueing, packet decisions,
/// `celt_encode_frame`, the TOC/frame assembler and the `OpusHead` extradata.
///
/// The public API takes interleaved int16 samples (as `Int32`, like the other
/// encoders in this package) and converts them to the encoder's float
/// planar domain with `sample / 32768.0f`, the same conversion the reference
/// harness applies. The default configuration matches the C defaults:
/// 48 kHz, `frame_size = 960` (20 ms), CELT-only, full band.

///|
/// Encoder configuration.
pub struct OpusEncodeConfig {
  channels : Int
  bit_rate : Int
}

///|
pub fn opus_encode_config(channels : Int, bit_rate : Int) -> OpusEncodeConfig {
  { channels, bit_rate }
}

///|
/// The native Opus encoder (`OpusEncContext`).
pub struct OpusEncoder {
  channels : Int
  frame_size : Int
  bit_rate : Int
  sample_rate : Int
  frames : Array[OpusEncCeltFrame]
  rc : OpusRangeEncoder
  last_quantized_energy : Array[Array[Float]]
  psy : OpusEncPsy
  bufqueue : Array[OpusEncPcmFrame]
  mut packet_frames : Int
  mut packet_framesize : Int
  eof : Int
  initial_padding : Int
  /// `ff_af_queue` accounting: remaining starts at initial_padding (120)
  /// and each add appends the frame's samples; the FIRST add also appends
  /// the padding to the frame's duration (the drained packet count depends
  /// on this), and removals cap at what the frame queue holds.
  mut afq_remaining : Int
  mut afq_queued : Int
  mut afq_first : Int
}

///|
/// `opus_encode_init`: validate and set up the encoder state.
pub fn opus_encoder_new(config : OpusEncodeConfig) -> Result[OpusEncoder, String] {
  let channels = config.channels
  if channels != 1 && channels != 2 {
    return Err("Opus encoder supports 1 or 2 channels")
  }
  let bit_rate = if config.bit_rate <= 0 {
    // default: coupled streams * 96000 + (channels - 2*coupled) * 48000
    if channels == 1 {
      48000
    } else {
      96000
    }
  } else if config.bit_rate < 6000 {
    6000
  } else if config.bit_rate > 255000 * channels {
    255000 * channels
  } else {
    config.bit_rate
  }
  let frame : Array[OpusEncCeltFrame] = []
  frame.push(OpusEncCeltFrame::new(channels, true))
  let enc : OpusEncoder = {
    channels,
    frame_size: 960,
    bit_rate,
    sample_rate: 48000,
    frames: frame,
    rc: OpusRangeEncoder::new(),
    last_quantized_energy: [Array::make(21, 0.0), Array::make(21, 0.0)],
    psy: OpusEncPsy::new(channels),
    bufqueue: [],
    packet_frames: 1,
    packet_framesize: 3,
    eof: 0,
    initial_padding: 120,
    afq_remaining: 120,
    afq_queued: 0,
    afq_first: 1,
  }
  // spawn the empty overlap frame
  enc.bufqueue.push(OpusEncoder::empty_frame(960, channels))
  enc.psy.bit_rate_f = Float::from_int(bit_rate)
  Ok(enc)
}

///|
fn OpusEncoder::empty_frame(samples : Int, channels : Int) -> OpusEncPcmFrame {
  let data : Array[Array[Float]] = []
  for _c in 0..<channels {
    data.push(Array::make(samples, 0.0))
  }
  { nb_samples: samples, data }
}

///|
/// `opus_write_extradata`: the 19-byte `OpusHead`.
pub fn OpusEncoder::extradata(self : OpusEncoder) -> Bytes {
  let out : Array[Byte] = []
  let magic = "OpusHead"
  for i in 0..<8 {
    out.push(magic[i].to_int().to_byte())
  }
  out.push(b'\x01')
  out.push(self.channels.to_byte())
  let pre = self.initial_padding
  out.push((pre & 0xFF).to_byte())
  out.push(((pre >> 8) & 0xFF).to_byte())
  let rate = self.sample_rate
  for shift in [0, 8, 16, 24] {
    out.push(((rate >> shift) & 0xFF).to_byte())
  }
  out.push(b'\x00')
  out.push(b'\x00')
  // channel mapping family (default layout)
  out.push(b'\x00')
  Bytes::from_array(out)
}

///|
/// `celt_frame_setup_input`: pop one frame for the overlap and stage the
/// packet's samples per channel (frame_size 960: one entry).
fn OpusEncoder::frame_setup_input(self : OpusEncoder, f : OpusEncCeltFrame) -> Unit {
  let cur = self.bufqueue[0]
  let n = cur.nb_samples.min(opus_enc_overlap)
  for ch in 0..<f.channels {
    let b = f.block[ch]
    if n < opus_enc_overlap {
      for i in 0..<(opus_enc_overlap - n) {
        b.overlap[i] = 0.0
      }
    }
    for i in 0..<n {
      b.overlap[opus_enc_overlap - n + i] = cur.data[ch][cur.nb_samples - n + i]
    }
  }
  let _overlap_removed = self.bufqueue.remove(0)
  let subframes = 960 / self.frame_size
  for sf in 0..<subframes {
    let entry : OpusEncPcmFrame = if sf != subframes - 1 {
      let e = self.bufqueue[0]
      let _removed = self.bufqueue.remove(0)
      e
    } else {
      self.bufqueue[0]
    }
    for ch in 0..<f.channels {
      let b = f.block[ch]
      let len = self.frame_size.min(entry.nb_samples)
      for i in 0..<len {
        b.samples[sf * self.frame_size + i] = entry.data[ch][i]
      }
      for i in len..<self.frame_size {
        b.samples[sf * self.frame_size + i] = 0.0
      }
    }
  }
}

///|
/// `opus_gen_toc` for the CELT-only encoder. Returns (toc_byte,
/// fsize_needed); the config table entry for CELT 20 ms fullband is 32.
fn OpusEncoder::gen_toc(self : OpusEncoder) -> (Int, Bool) {
  // toc_cfg[framesize][CELT][FB]: 17,18,19,20 for 2.5/5/10/20 ms at FB
  let celt_cfg : Array[Int] = [29, 30, 31, 32]
  let cfg = if self.packet_framesize < celt_cfg.length() {
    celt_cfg[self.packet_framesize]
  } else {
    0
  }
  if cfg == 0 {
    return (0, false)
  }
  let mut tmp = 0
  let mut fsize_needed = false
  if self.packet_frames == 2 {
    if self.frames[0].framebits == self.frames[1].framebits {
      tmp = 0x1
    } else {
      tmp = 0x2
      fsize_needed = true
    }
  } else if self.packet_frames > 2 {
    tmp = 0x3
    // extended TOC: only reachable via the silent-flush path
  }
  tmp = tmp | ((if self.channels > 1 { 1 } else { 0 }) << 2)
  tmp = tmp | ((cfg - 1) << 3)
  (tmp, fsize_needed)
}

///|
/// `write_opuslacing`.
fn opus_enc_write_lacing(dst : Array[Byte], off : Int, v : Int) -> Int {
  let first = (v - ((v - 255 + 3) & 0xFFFFFFFC)).min(v)
  dst[off] = first.to_byte()
  dst[off + 1] = ((v - first) >> 2).to_byte()
  if v >= 252 {
    2
  } else {
    1
  }
}

///|
/// `opus_packet_assembler`.
fn OpusEncoder::packet_assembler(self : OpusEncoder, out : Array[Byte]) -> Int {
  let (toc, fsize_needed) = self.gen_toc()
  let mut offset = 0
  if toc == 0 {
    abort("opus enc: unencodable toc")
  }
  out[offset] = toc.to_byte()
  offset += 1
  let mut fsize_needed2 = fsize_needed
  if self.packet_frames > 2 {
    // extended toc byte
    let mut any_diff = false
    for i in 0..<(self.packet_frames - 1) {
      if self.frames[i].framebits != self.frames[i + 1].framebits {
        any_diff = true
      }
    }
    let extended = (if any_diff { 1 } else { 0 }) << 7
    out[offset] = (extended | self.packet_frames).to_byte()
    offset += 1
    fsize_needed2 = any_diff
  }
  if fsize_needed2 {
    for i in 0..<(self.packet_frames - 1) {
      offset += opus_enc_write_lacing(out, offset, self.frames[i].framebits >> 3)
    }
  }
  for i in 0..<self.packet_frames {
    let size = self.frames[i].framebits >> 3
    self.rc.end_frame(i, out, offset, size)
    offset += size
  }
  offset
}

///|
/// Encode one packet; `planes[ch][i]` is the FLTP float input (1.0 = full
/// scale) with `frame_size` samples per channel. Returns the Opus packet
/// bytes (TOC + range-coded frame data, exactly what goes into an Ogg
/// Opus packet) or an error.
pub fn OpusEncoder::encode(
  self : OpusEncoder,
  planes : Array[Array[Float]],
) -> Result[Option[Bytes], String] {
  if planes.length() < self.channels || planes[0].length() < self.frame_size {
    return Err("Opus encoder needs \{self.frame_size} samples per channel")
  }
  let data : Array[Array[Float]] = []
  for ch in 0..<self.channels {
    let plane : Array[Float] = Array::make(self.frame_size, 0.0)
    for i in 0..<self.frame_size {
      plane[i] = planes[ch][i]
    }
    data.push(plane)
  }
  self.bufqueue.push({ nb_samples: self.frame_size, data })
  // ff_af_queue_add: first frame's duration absorbs the initial padding
  let pad = if self.afq_first != 0 { 120 } else { 0 }
  self.afq_first = 0
  let add = self.frame_size + pad
  self.afq_queued += add
  self.afq_remaining += self.frame_size
  // psychoacoustic packet decision: None while the lookahead buffers
  if self.psy.process(self.bufqueue, self.channels) {
    return Ok(None)
  }
  let packet = match self.encode_decision() {
    Ok(b) => b
    Err(msg) => return Err(msg)
  }
  Ok(Some(packet))
}

///|
/// The body of C's `opus_encode_frame` after the psy decision succeeds.
fn OpusEncoder::encode_decision(
  self : OpusEncoder,
) -> Result[Bytes, String] {
  self.packet_frames = self.psy.p_frames
  self.packet_framesize = self.psy.p_framesize
  // pad with empty frames if the queue is short (flush path)
  let used = self.packet_frames * (self.frame_size / self.frame_size)
  let pad_empty = used - self.bufqueue.length() + 1
  for _i in 0..<pad_empty {
    self.bufqueue.push(OpusEncoder::empty_frame(self.frame_size, self.channels))
  }
  let mut alloc_size = 0
  for i in 0..<self.packet_frames {
    self.celt_encode_frame(self.rc, self.frames[i], i)
    alloc_size += self.frames[i].framebits >> 3
  }
  alloc_size += 2 + self.packet_frames * 2
  let out : Array[Byte] = Array::make(alloc_size + 8, b'\x00')
  let written = self.packet_assembler(out)
  self.psy_postencode_update()
  let request = self.packet_frames * self.frame_size
  let removed = request.min(self.afq_queued)
  self.afq_queued -= removed
  self.afq_remaining -= removed
  let bytes : Array[Byte] = []
  for i in 0..<written {
    bytes.push(out[i])
  }
  Ok(Bytes::from_array(bytes))
}

///|
/// Flush the encoder (EOF): mark the psy end-of-stream and drain the
/// remaining buffered steps as packets, mirroring C's NULL-frame callbacks.
/// The final packets pad with silence and may be 1-byte TOC-only silent
/// frames, exactly like the reference.
pub fn OpusEncoder::flush(self : OpusEncoder) -> Result[Array[Bytes], String] {
  self.psy.eof = 1
  let out : Array[Bytes] = []
  while self.afq_remaining > 0 {
    if self.psy.process(self.bufqueue, self.channels) {
      break
    }
    let packet = match self.encode_decision() {
      Ok(b) => b
      Err(msg) => return Err(msg)
    }
    out.push(packet)
  }
  Ok(out)
}

///|
/// `celt_encode_frame` (enc.c).
fn OpusEncoder::celt_encode_frame(
  self : OpusEncoder,
  rc : OpusRangeEncoder,
  f : OpusEncCeltFrame,
  index : Int,
) -> Unit {
  rc.init()
  self.psy_celt_frame_init(f, index)
  self.frame_setup_input(f)
  if f.silence != 0 {
    if f.framebits >= 16 {
      rc.encode_log(1, 15)
    }
    for ch in 0..<self.channels {
      for i in 0..<21 {
        self.last_quantized_energy[ch][i] = 0.0
      }
    }
    f.framebits = 0
    return
  }
  self.apply_preemph(f)
  if f.pfilter != 0 {
    rc.encode_log(0, 15)
    self.quant_pfilter(rc, f)
  }
  opus_enc_frame_mdct(f)
  while self.psy_celt_frame_process(f, index) {
    opus_enc_frame_mdct(f)
  }
  rc.init()
  // Silence
  rc.encode_log(0, 15)
  // Pitch filter
  if f.start_band == 0 && rc.tell() + 16 <= f.framebits {
    self.quant_pfilter(rc, f)
  }
  // Transient flag
  if f.size != 0 && rc.tell() + 3 <= f.framebits {
    rc.encode_log(f.transient, 3)
  }
  // Main encoding
  opus_enc_celt_quant_coarse(f, rc, self.last_quantized_energy)
  opus_enc_celt_tf(f, rc)
  self.celt_bitalloc(f, rc)
  opus_enc_celt_quant_fine(f, rc)
  self.celt_quant_bands(f, rc)
  // Anticollapse bit
  if f.anticollapse_needed != 0 {
    rc.put_raw(f.anticollapse.reinterpret_as_uint(), 1)
  }
  // Final per-band energy adjustments from leftover bits
  opus_enc_celt_quant_final(f, rc)
  for ch in 0..<f.channels {
    let block = f.block[ch]
    for i in 0..<21 {
      self.last_quantized_energy[ch][i] = block.energy[i] + block.error_energy[i]
    }
  }
}

///|
/// `ff_opus_psy_signal_eof`: mark end of stream; subsequent `encode` calls
/// drain the remaining buffered audio.
pub fn OpusEncoder::signal_eof(self : OpusEncoder) -> Unit {
  self.psy.eof = 1
}
