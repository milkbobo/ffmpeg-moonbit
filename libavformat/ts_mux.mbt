///|
/// Minimal in-memory MPEG-TS writer for one video and one audio elementary
/// stream.  It mirrors the table/PES layout used by FFmpeg 9.0.2
/// `mpegtsenc.c` (PAT, PMT, PES with optional PTS+DTS headers) without the transport
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
  /// Emit the corresponding PMT entry (false for audio-only/video-only TS).
  has_video : Bool
  has_audio : Bool
  /// SDT fields (`mpegtsenc.c` defaults: Service01 / FFmpeg / digital TV).
  service_name : String
  service_provider : String
  service_type : Int32
  transport_stream_id : Int32
  original_network_id : Int32
  /// Emit a NIT (`-mpegts_flags nit`): provider as network name plus a
  /// one-entry service list.
  nit : Bool
  /// ISO 639 language for the audio ES; empty omits the descriptor.
  audio_language : String
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
  /// Include a video entry in the PMT (false for audio-only renditions).
  video~ : Bool = true,
  /// Include an audio entry in the PMT (false for video-only renditions).
  audio~ : Bool = true,
  /// SDT service name; empty uses FFmpeg's "Service01".
  service_name~ : String = "",
  /// SDT service provider; empty uses FFmpeg's "FFmpeg".
  service_provider~ : String = "",
  /// DVB service type (0x01 digital TV, 0x02 digital radio, ...).
  service_type~ : Int32 = 0x01,
  transport_stream_id~ : Int32 = 1,
  original_network_id~ : Int32 = 0xFF01,
  /// Emit a NIT on PID 0x10 (`-mpegts_flags nit`).
  nit~ : Bool = false,
  /// ISO 639 language written as a PMT language descriptor for the audio ES.
  audio_language~ : String = "",
) -> TsMuxer {
  {
    pmt_pid: 0x1000,
    video_pid,
    audio_pid,
    video_stream_type,
    audio_stream_type,
    has_video: video,
    has_audio: audio,
    service_name: if service_name == "" {
      "Service01"
    } else {
      service_name
    },
    service_provider: if service_provider == "" {
      "FFmpeg"
    } else {
      service_provider
    },
    service_type,
    transport_stream_id,
    original_network_id,
    nit,
    audio_language,
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
  let crc = @libavutil.av_crc(table, 0xFFFFFFFFU, Bytes::from_array(section))
  // mpegtsenc stores av_bswap32() of the CRC in the section.
  ((crc & 0xFFU) << 24) |
  (((crc >> 8) & 0xFFU) << 16) |
  (((crc >> 16) & 0xFFU) << 8) |
  (crc >> 24)
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
  ts_mux_u16(section, self.transport_stream_id)
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
/// `service_name`/`service_provider` UTF-8 bytes clamped to the 8-bit
/// descriptor length field.
fn ts_mux_service_bytes(value : String) -> Array[Byte] {
  let bytes = utf8_from_string(value)
  let n = if bytes.length() > 255 { 255 } else { bytes.length() }
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    out.push(bytes[i])
  }
  out
}

///|
/// SDT (table_id 0x42) with one service descriptor (DVB tag 0x48), laid out
/// like `mpegtsenc.c::mpegts_write_sdt`.
fn TsMuxer::sdt(self : TsMuxer) -> Unit {
  let provider = ts_mux_service_bytes(self.service_provider)
  let name = ts_mux_service_bytes(self.service_name)
  let section : Array[Byte] = []
  section.push(b'\x42')
  // 5 header bytes + original_network_id(2) + reserved(1) + service entry
  // (5 + descriptors) + CRC(4).
  ts_mux_u16(section, 0xF000 | (22 + provider.length() + name.length()))
  ts_mux_u16(section, self.transport_stream_id)
  section.push(b'\xC1')
  section.push(b'\x00')
  section.push(b'\x00')
  ts_mux_u16(section, self.original_network_id)
  section.push(b'\xFF')
  ts_mux_u16(section, 1) // service_id == program_number
  section.push(b'\xFC') // EIT schedule/present-following flags clear
  ts_mux_u16(section, 0x8000 | (5 + provider.length() + name.length()))
  section.push(b'\x48') // service_descriptor
  section.push((3 + provider.length() + name.length()).to_byte())
  section.push(self.service_type.to_byte())
  section.push(provider.length().to_byte())
  for b in provider {
    section.push(b)
  }
  section.push(name.length().to_byte())
  for b in name {
    section.push(b)
  }
  let crc = ts_mux_crc(section)
  for i in 0..<4 {
    section.push(((crc >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
  self.section(0x11, section)
}

///|
/// `ISO_639_LANGUAGE_DESCRIPTOR` for a single 3-letter code (audio_type
/// undefined), or empty when the code is not three characters.
fn ts_mux_language_descriptor(language : String) -> Array[Byte] {
  let out : Array[Byte] = []
  if language.length() == 3 {
    out.push(b'\x0A')
    out.push(b'\x04')
    for i in 0..<3 {
      out.push((language[i].to_int() & 0xFF).to_byte())
    }
    out.push(b'\x00')
  }
  out
}

///|
/// Video ES descriptors: mpegtsenc registers HEVC with a 0x05 descriptor
/// when strict compliance is normal (the default).
fn ts_mux_video_descriptors(stream_type : Int32) -> Array[Byte] {
  let out : Array[Byte] = []
  if stream_type == 0x24 {
    out.push(b'\x05')
    out.push(b'\x04')
    out.push(b'H')
    out.push(b'E')
    out.push(b'V')
    out.push(b'C')
  }
  out
}

///|
fn TsMuxer::pmt(self : TsMuxer) -> Unit {
  let section : Array[Byte] = []
  section.push(b'\x02')
  let video_desc : Array[Byte] = if self.has_video {
    ts_mux_video_descriptors(self.video_stream_type)
  } else {
    []
  }
  let audio_desc : Array[Byte] = if self.has_audio {
    ts_mux_language_descriptor(self.audio_language)
  } else {
    []
  }
  let es_len = (if self.has_video { 5 + video_desc.length() } else { 0 }) +
    (if self.has_audio { 5 + audio_desc.length() } else { 0 })
  ts_mux_u16(section, 0xB000 | (9 + es_len + 4))
  ts_mux_u16(section, 1) // program_number
  section.push(b'\xC1')
  section.push(b'\x00')
  section.push(b'\x00')
  // PCR rides on the first configured elementary stream.
  let pcr_pid = if self.has_video { self.video_pid } else { self.audio_pid }
  ts_mux_u16(section, 0xE000 | pcr_pid)
  ts_mux_u16(section, 0xF000) // program_info_length = 0
  if self.has_video {
    section.push(self.video_stream_type.to_byte())
    ts_mux_u16(section, 0xE000 | self.video_pid)
    ts_mux_u16(section, 0xF000 | video_desc.length())
    for b in video_desc {
      section.push(b)
    }
  }
  if self.has_audio {
    section.push(self.audio_stream_type.to_byte())
    ts_mux_u16(section, 0xE000 | self.audio_pid)
    ts_mux_u16(section, 0xF000 | audio_desc.length())
    for b in audio_desc {
      section.push(b)
    }
  }
  let crc = ts_mux_crc(section)
  for i in 0..<4 {
    section.push(((crc >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
  self.section(self.pmt_pid, section)
}

///|
/// NIT (table_id 0x40) on PID 0x10: network_name_descriptor with the
/// provider name plus a service_list_descriptor, as
/// `mpegtsenc.c::mpegts_write_nit` lays it out.
fn TsMuxer::write_nit(self : TsMuxer) -> Unit {
  let network = ts_mux_service_bytes(self.service_provider)
  let section : Array[Byte] = []
  section.push(b'\x40')
  // 5 header bytes + data (network descriptors, loop) + CRC(4).
  ts_mux_u16(section, 0xF000 | (5 + 17 + network.length() + 4))
  ts_mux_u16(section, self.original_network_id) // network_id
  section.push(b'\xC1')
  section.push(b'\x00')
  section.push(b'\x00')
  ts_mux_u16(section, 0xF000 | (2 + network.length()))
  section.push(b'\x40') // network_name_descriptor
  section.push(network.length().to_byte())
  for b in network {
    section.push(b)
  }
  ts_mux_u16(section, 0xF000 | 11)
  ts_mux_u16(section, self.transport_stream_id)
  ts_mux_u16(section, self.original_network_id)
  ts_mux_u16(section, 0xF000 | 5)
  section.push(b'\x41') // service_list_descriptor
  section.push(b'\x03')
  ts_mux_u16(section, 1) // service_id == program_number
  section.push(self.service_type.to_byte())
  let crc = ts_mux_crc(section)
  for i in 0..<4 {
    section.push(((crc >> (24 - 8 * i)) & 0xFFU).to_byte())
  }
  self.section(0x10, section)
}

///|
fn TsMuxer::ensure_tables(self : TsMuxer) -> Unit {
  if !self.wrote_tables {
    self.wrote_tables = true
    self.sdt()
    self.pat()
    self.pmt()
    if self.nit {
      self.write_nit()
    }
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
  dts : Int64?,
) -> Unit {
  let pes : Array[Byte] = [0, 0, 1, stream_id.to_byte()]
  let has_dts = dts is Some(_)
  // flags(2) + header_length(1) + PTS(5) [+ DTS(5)]
  let header_data = if has_dts { 13 } else { 8 }
  let packet_len = if bounded && payload.length() + header_data <= 0xFFFF {
    payload.length() + header_data
  } else {
    0
  }
  ts_mux_u16(pes, packet_len)
  pes.push(b'\x84') // marker '10', PES header data present
  pes.push(if has_dts { b'\xc0' } else { b'\x80' })
  pes.push(if has_dts { 10 } else { 5 })
  ts_mux_pts(pes, pts)
  match dts {
    Some(value) => ts_mux_pts(pes, value)
    None => ()
  }
  for b in payload {
    pes.push(b)
  }
  self.emit(pid, true, pes[:], pcr)
}

///|
/// Write one video access-unit payload (H.264/HEVC Annex B) with a PTS in
/// 90 kHz units. `dts`, when given, is written alongside the PTS (PES header
/// flags 0xC0) and also drives the PCR.
pub fn TsMuxer::write_video(
  self : TsMuxer,
  pts : Int64,
  payload : Bytes,
  dts? : Int64,
) -> Unit {
  self.ensure_tables()
  let pcr = match dts {
    Some(value) => value
    None => pts
  }
  self.pes(self.video_pid, 0xE0, pts, payload, false, pcr, dts)
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
  self.pes(self.audio_pid, 0xC0, pts, framed, true, -1L, None)
}

///|
/// Return the accumulated transport stream.  PAT/PMT are emitted on the first
/// packet write or here when the muxer never received payload.
pub fn TsMuxer::finish(self : TsMuxer) -> Bytes {
  self.ensure_tables()
  Bytes::from_array(self.out)
}
