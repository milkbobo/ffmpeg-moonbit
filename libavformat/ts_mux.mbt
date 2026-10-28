///|
/// Minimal in-memory MPEG-TS writer for one video and one audio elementary
/// stream.  It mirrors the table/PES layout used by FFmpeg 9.0.2
/// `mpegtsenc.c` (PAT, PMT, PES with PTS-only headers) without the transport
/// buffering and PCR scheduling.  The PMT stream types default to H.264
/// (0x1B) + AAC ADTS (0x0F) and can be overridden per constructor call
/// (HEVC 0x24, MP3 0x03/0x04, ... as written by FFmpeg `mpegtsenc.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2004 Alex Beregszaszi.
/// This port keeps the same license.

///|
pub struct TsMuxer {
  pmt_pid : Int32
  video_pid : Int32
  audio_pid : Int32
  video_stream_type : Int32
  audio_stream_type : Int32
  mut wrote_tables : Bool
  /// Non-zero enables automatic ADTS framing of AAC access units.
  mut adts_rate : Int32
  mut adts_channels : Int32
  mut adts_object_type : Int32
  /// Continuity counters indexed by PID (13-bit PID space).
  cc : FixedArray[Int32]
  out : Array[Byte]
}

///|
pub fn ts_muxer_new(
  video_pid~ : Int32 = 0x100,
  audio_pid~ : Int32 = 0x101,
  /// PMT stream type of the video ES (0x1B H.264, 0x24 HEVC, ...).
  video_stream_type~ : Int32 = 0x1B,
  /// PMT stream type of the audio ES (0x0F AAC ADTS, 0x03 MP3, ...).
  audio_stream_type~ : Int32 = 0x0F,
) -> TsMuxer {
  {
    pmt_pid: 0x1000,
    video_pid,
    audio_pid,
    video_stream_type,
    audio_stream_type,
    wrote_tables: false,
    adts_rate: 0,
    adts_channels: 0,
    adts_object_type: 2,
    cc: FixedArray::make(8192, 0),
    out: [],
  }
}

///|
fn ts_mux_u16(dst : Array[Byte], v : Int32) -> Unit {
  dst.push(((v >> 8) & 0xFF).to_byte())
  dst.push((v & 0xFF).to_byte())
}

///|
fn ts_mux_crc(section : Array[Byte]) -> UInt32 {
  let table = @libavutil.av_crc_init(false, 32, 0x04C11DB7U).unwrap()
  @libavutil.av_crc(table, 0xFFFFFFFFU, Bytes::from_array(section))
}

///|
fn TsMuxer::next_cc(self : TsMuxer, pid : Int32) -> Int32 {
  let v = self.cc[pid]
  self.cc[pid] = (v + 1) & 0xF
  v
}

///|
/// One 188-byte packet carrying a PES/PSI payload (last packet is padded with
/// an adaptation field).  `pcr < 0` means no PCR in this packet.
fn TsMuxer::emit(
  self : TsMuxer,
  pid : Int32,
  pusi : Bool,
  payload : ArrayView[Byte],
  pcr : Int64,
) -> Unit {
  let mut pos = 0
  while pos < payload.length() {
    let with_pcr = pcr >= 0L && pos == 0
    let max_n = if with_pcr { 176 } else { 184 }
    let n = if payload.length() - pos < max_n {
      payload.length() - pos
    } else {
      max_n
    }
    let cc = self.next_cc(pid)
    self.out.push(b'\x47')
    self.out.push(
      (if pusi && pos == 0 { 0x40 } else { 0 }).to_byte() |
      ((pid >> 8) & 0x1F).to_byte(),
    )
    self.out.push((pid & 0xFF).to_byte())
    if n == 184 {
      self.out.push((0x10 | cc).to_byte())
    } else {
      self.out.push((0x30 | cc).to_byte())
      let adapt_len = 183 - n
      self.out.push(adapt_len.to_byte())
      if with_pcr {
        self.out.push(b'\x10') // PCR_flag
        self.out.push(((pcr >> 25) & 0xFFL).to_int().to_byte())
        self.out.push(((pcr >> 17) & 0xFFL).to_int().to_byte())
        self.out.push(((pcr >> 9) & 0xFFL).to_int().to_byte())
        self.out.push(((pcr >> 1) & 0xFFL).to_int().to_byte())
        self.out.push((((pcr & 1L) << 7) | 0x7EL).to_int().to_byte())
        self.out.push(b'\x00')
        for _ in 7..<adapt_len {
          self.out.push(b'\xFF')
        }
      } else if adapt_len > 0 {
        self.out.push(b'\x00')
        for _ in 1..<adapt_len {
          self.out.push(b'\xFF')
        }
      }
    }
    for i in 0..<n {
      self.out.push(payload[pos + i])
    }
    pos = pos + n
  }
}

///|
fn TsMuxer::section(self : TsMuxer, pid : Int32, section : Array[Byte]) -> Unit {
  let payload : Array[Byte] = [0]
  payload.append(section)
  while payload.length() < 184 {
    payload.push(b'\xFF')
  }
  self.emit(pid, true, payload[:184], -1L)
}

///|
fn TsMuxer::pat(self : TsMuxer) -> Unit {
  let section : Array[Byte] = []
  section.push(b'\x00')
  ts_mux_u16(section, 0xB000 | 13)
  ts_mux_u16(section, 1) // transport_stream_id
  section.push(b'\xC1') // version 0, current_next=1
  section.push(b'\x00')
  section.push(b'\x00')
  ts_mux_u16(section, 1) // program_number
  ts_mux_u16(section, 0xE000 | self.pmt_pid)
  let crc = ts_mux_crc(section)
  for i in 0..<4 {
    section.push(((crc >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
  self.section(0, section)
}

///|
fn TsMuxer::pmt(self : TsMuxer) -> Unit {
  let section : Array[Byte] = []
  section.push(b'\x02')
  ts_mux_u16(section, 0xB000 | (9 + 5 * 2 + 4))
  ts_mux_u16(section, 1) // program_number
  section.push(b'\xC1')
  section.push(b'\x00')
  section.push(b'\x00')
  ts_mux_u16(section, 0xE000 | self.video_pid) // PCR_PID
  ts_mux_u16(section, 0xF000) // program_info_length = 0
  section.push(self.video_stream_type.to_byte())
  ts_mux_u16(section, 0xE000 | self.video_pid)
  ts_mux_u16(section, 0xF000)
  section.push(self.audio_stream_type.to_byte())
  ts_mux_u16(section, 0xE000 | self.audio_pid)
  ts_mux_u16(section, 0xF000)
  let crc = ts_mux_crc(section)
  for i in 0..<4 {
    section.push(((crc >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
  self.section(self.pmt_pid, section)
}

///|
fn TsMuxer::ensure_tables(self : TsMuxer) -> Unit {
  if !self.wrote_tables {
    self.wrote_tables = true
    self.pat()
    self.pmt()
  }
}

///|
fn ts_mux_pts(dst : Array[Byte], pts : Int64) -> Unit {
  dst.push((0x20 | (((pts >> 30) & 0x07L).to_int() << 1) | 1).to_byte())
  dst.push(((pts >> 22) & 0xFFL).to_int().to_byte())
  dst.push((((pts >> 14) & 0xFEL).to_int() | 1).to_byte())
  dst.push(((pts >> 7) & 0xFFL).to_int().to_byte())
  dst.push((((pts << 1) & 0xFEL).to_int() | 1).to_byte())
}

///|
fn TsMuxer::pes(
  self : TsMuxer,
  pid : Int32,
  stream_id : Int32,
  pts : Int64,
  payload : Bytes,
  bounded : Bool,
  pcr : Int64,
) -> Unit {
  let pes : Array[Byte] = [0, 0, 1, stream_id.to_byte()]
  let header_data = 8 // flags(2) + header_length(1) + PTS(5)
  let packet_len = if bounded && payload.length() + header_data <= 0xFFFF {
    payload.length() + header_data
  } else {
    0
  }
  ts_mux_u16(pes, packet_len)
  pes.push(b'\x84') // marker '10', PES header data present
  pes.push(b'\x80') // PTS only
  pes.push(5)
  ts_mux_pts(pes, pts)
  for b in payload {
    pes.push(b)
  }
  self.emit(pid, true, pes[:], pcr)
}

///|
/// Write one video access-unit payload (H.264/HEVC Annex B) with a PTS in
/// 90 kHz units.
pub fn TsMuxer::write_video(
  self : TsMuxer,
  pts : Int64,
  payload : Bytes,
) -> Unit {
  self.ensure_tables()
  self.pes(self.video_pid, 0xE0, pts, payload, false, pts)
}

///|
/// Write one audio payload (AAC ADTS or MP3 frame) with a PTS in 90 kHz units.

///|
/// Wrap AAC access units in ADTS headers (required for stream type 0x0F to
/// be playable outside this port's demuxer). Frames that would exceed the
/// 13-bit ADTS length are written raw, as before.
pub fn TsMuxer::enable_adts(
  self : TsMuxer,
  sample_rate : Int32,
  channels : Int32,
  object_type~ : Int32 = 2,
) -> Result[Unit, String] {
  if self.audio_stream_type != 0x0F {
    return Err("EINVAL: ADTS wrapping needs AAC stream type 0x0F")
  }
  match
    @libavcodec.aac_adts_header_write(sample_rate, channels, object_type, 8) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  self.adts_rate = sample_rate
  self.adts_channels = channels
  self.adts_object_type = object_type
  Ok(())
}

///|
/// The muxer is minimal and infallible; the raw access unit is written for
/// frames ADTS cannot express.
pub fn TsMuxer::write_audio(
  self : TsMuxer,
  pts : Int64,
  payload : Bytes,
) -> Unit {
  self.ensure_tables()
  let framed : Bytes = if self.adts_rate > 0 {
    match
      @libavcodec.aac_adts_header_write(
        self.adts_rate,
        self.adts_channels,
        self.adts_object_type,
        payload.length() + @libavcodec.av_aac_adts_header_size,
      ) {
      Ok(header) => {
        let out : Array[Byte] = []
        for b in header {
          out.push(b)
        }
        for b in payload {
          out.push(b)
        }
        Bytes::from_array(out)
      }
      Err(_) => payload
    }
  } else {
    payload
  }
  self.pes(self.audio_pid, 0xC0, pts, framed, true, -1L)
}

///|
/// Return the accumulated transport stream.  PAT/PMT are emitted on the first
/// packet write or here when the muxer never received payload.
pub fn TsMuxer::finish(self : TsMuxer) -> Bytes {
  self.ensure_tables()
  Bytes::from_array(self.out)
}
