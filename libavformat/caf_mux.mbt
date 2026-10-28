///|
/// Minimal CAF writers following FFmpeg 9.0.2 `libavformat/cafenc.c`:
/// ALAC (VBR packet table) and big-endian LPCM (constant packets).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

///|
fn caf_mux_u16be(dst : Array[Byte], v : Int32) -> Unit {
  dst.push(((v >> 8) & 0xFF).to_byte())
  dst.push((v & 0xFF).to_byte())
}

///|
fn caf_mux_u32be(dst : Array[Byte], v : UInt32) -> Unit {
  dst.push(((v >> 24) & 0xFFU).to_byte())
  dst.push(((v >> 16) & 0xFFU).to_byte())
  dst.push(((v >> 8) & 0xFFU).to_byte())
  dst.push((v & 0xFFU).to_byte())
}

///|
fn caf_mux_u64be(dst : Array[Byte], v : UInt64) -> Unit {
  caf_mux_u32be(dst, (v >> 32).to_int().reinterpret_as_uint())
  caf_mux_u32be(dst, (v & 0xFFFFFFFFUL).to_int().reinterpret_as_uint())
}

///|
fn caf_mux_double(dst : Array[Byte], v : Double) -> Unit {
  caf_mux_u64be(dst, v.reinterpret_as_uint64())
}

///|
fn caf_mux_tag(dst : Array[Byte], tag : String) -> Unit {
  for c in tag {
    dst.push(c.to_int().to_byte())
  }
}

///|
fn caf_mux_chunk(dst : Array[Byte], id : String, payload : Array[Byte]) -> Unit {
  caf_mux_tag(dst, id)
  caf_mux_u64be(dst, payload.length().reinterpret_as_uint().to_uint64())
  dst.append(payload)
}

///|
/// `ff_mp4_write_descr_len`-style size encoding for the ALAC packet table.
fn caf_mux_descr_len(dst : Array[Byte], v : Int32) -> Unit {
  if v < 0x80 {
    dst.push(v.to_byte())
    return
  }
  if v < 0x4000 {
    dst.push(((v >> 7) | 0x80).to_byte())
    dst.push((v & 0x7F).to_byte())
    return
  }
  if v < 0x200000 {
    dst.push(((v >> 14) | 0x80).to_byte())
    dst.push((((v >> 7) & 0x7F) | 0x80).to_byte())
    dst.push((v & 0x7F).to_byte())
    return
  }
  dst.push(((v >> 21) | 0x80).to_byte())
  dst.push((((v >> 14) & 0x7F) | 0x80).to_byte())
  dst.push((((v >> 7) & 0x7F) | 0x80).to_byte())
  dst.push((v & 0x7F).to_byte())
}

///|
/// ALAC in CAF: `frma`+`alac` magic cookie, VBR `pakt` packet table.
pub struct CafAlacMuxer {
  cookie : Bytes
  sample_rate : Int32
  channels : Int32
  packets : Array[Bytes]
  durations : Array[Int32]
}

///|
pub fn caf_alac_muxer_new(cookie : Bytes) -> Result[CafAlacMuxer, String] {
  if cookie.length() < 36 ||
    cookie[4] != b'a' ||
    cookie[5] != b'l' ||
    cookie[6] != b'a' ||
    cookie[7] != b'c' {
    return Err("EINVAL: invalid ALAC magic cookie")
  }
  let sample_rate = caf_u32be(cookie, 32).reinterpret_as_int()
  let channels = cookie[21].to_int()
  if sample_rate <= 0 || channels < 1 || channels > 8 {
    return Err("EINVAL: invalid ALAC CAF parameters")
  }
  Ok({ cookie, sample_rate, channels, packets: [], durations: [], })
}

///|
pub fn CafAlacMuxer::write_packet(
  self : CafAlacMuxer,
  packet : Bytes,
  duration~ : Int32 = 4096,
) -> Result[Unit, String] {
  if packet.length() == 0 || duration <= 0 {
    return Err("EINVAL: invalid ALAC packet")
  }
  self.packets.push(packet)
  self.durations.push(duration)
  Ok(())
}

///|
pub fn CafAlacMuxer::finish(self : CafAlacMuxer) -> Bytes {
  let desc : Array[Byte] = []
  caf_mux_double(desc, self.sample_rate.to_double())
  caf_mux_tag(desc, "alac")
  caf_mux_u32be(desc, 0U) // format flags
  caf_mux_u32be(desc, 0U) // bytes per packet (variable)
  caf_mux_u32be(desc, 4096U) // frames per packet
  caf_mux_u32be(desc, self.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, 0U) // bits per channel (from the cookie)
  let kuki : Array[Byte] = []
  caf_mux_u32be(kuki, 12U)
  caf_mux_tag(kuki, "frma")
  caf_mux_tag(kuki, "alac")
  for b in self.cookie {
    kuki.push(b)
  }
  let payload : Array[Byte] = []
  for packet in self.packets {
    for b in packet {
      payload.push(b)
    }
  }
  let data : Array[Byte] = []
  caf_mux_u32be(data, 0U) // edit count
  data.append(payload)
  let mut valid = 0L
  let pakt : Array[Byte] = []
  caf_mux_u64be(pakt, self.packets.length().reinterpret_as_uint().to_uint64())
  for d in self.durations {
    valid = valid + d.to_int64()
  }
  caf_mux_u64be(pakt, valid.reinterpret_as_uint64())
  caf_mux_u32be(pakt, 0U) // priming frames
  let padded = 4096L * self.packets.length().to_int64()
  let remainder = if padded > valid { padded - valid } else { 0L }
  caf_mux_u32be(pakt, remainder.to_int().reinterpret_as_uint())
  for packet in self.packets {
    caf_mux_descr_len(pakt, packet.length())
  }
  let out : Array[Byte] = []
  caf_mux_tag(out, "caff")
  caf_mux_u16be(out, 1)
  caf_mux_u16be(out, 0)
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "kuki", kuki)
  caf_mux_chunk(out, "data", data)
  caf_mux_chunk(out, "pakt", pakt)
  Bytes::from_array(out)
}

///|
/// Big-endian LPCM in CAF.
pub struct CafLpcmMuxer {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  big_endian : Bool
  data : Array[Byte]
}

///|
pub fn caf_lpcm_muxer_new(
  sample_rate : Int32,
  channels : Int32,
  bits~ : Int32 = 16,
  big_endian~ : Bool = false,
) -> Result[CafLpcmMuxer, String] {
  if sample_rate <= 0 || channels < 1 || channels > 32 {
    return Err("EINVAL: invalid CAF LPCM parameters")
  }
  if bits != 8 && bits != 16 && bits != 24 && bits != 32 {
    return Err("EINVAL: CAF LPCM supports 8/16/24/32-bit samples")
  }
  Ok({ sample_rate, channels, bits, big_endian, data: [], })
}

///|
pub fn CafLpcmMuxer::write_samples(
  self : CafLpcmMuxer,
  samples : ArrayView[Int32],
) -> Unit {
  let bytes = self.bits / 8
  for sample in samples {
    let v = sample.reinterpret_as_uint()
    for i = 0; i < bytes; i = i + 1 {
      let shift = if self.big_endian { 8 * (bytes - 1 - i) } else { 8 * i }
      self.data.push(((v >> shift) & 0xFFU).to_byte())
    }
  }
}

///|
pub fn CafLpcmMuxer::finish(self : CafLpcmMuxer) -> Bytes {
  let block_align = self.channels * (self.bits / 8)
  let desc : Array[Byte] = []
  caf_mux_double(desc, self.sample_rate.to_double())
  caf_mux_tag(desc, "lpcm")
  caf_mux_u32be(desc, if self.big_endian { 0U } else { 2U }) // CAF flag 2 = little-endian
  caf_mux_u32be(desc, block_align.reinterpret_as_uint())
  caf_mux_u32be(desc, 1U) // frames per packet
  caf_mux_u32be(desc, self.channels.reinterpret_as_uint())
  caf_mux_u32be(desc, self.bits.reinterpret_as_uint())
  let data : Array[Byte] = []
  caf_mux_u32be(data, 0U) // edit count
  data.append(self.data)
  let out : Array[Byte] = []
  caf_mux_tag(out, "caff")
  caf_mux_u16be(out, 1)
  caf_mux_u16be(out, 0)
  caf_mux_chunk(out, "desc", desc)
  caf_mux_chunk(out, "data", data)
  Bytes::from_array(out)
}
