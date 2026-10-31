///|
/// MoonBit port of the FFmpeg 9.0.2 MPEG-TS demuxer slice:
/// `libavformat/mpegts.c` (`handle_packet`, `mpegts_push_data` PES assembly,
/// `parse_pcr`, PAT/PMT section parsing and `ff_mpegts_stream_type`), with the
/// 188/192/204-byte packet layouts from `mpegts_probe`/`mpegts_read_header`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Scope: one in-memory transport stream, PAT/PMT program discovery, PES
/// assembly (PTS/DTS, unbounded video PES flushed at the next start or EOF,
/// known-length PES emitted as soon as complete), PCR extraction and the
/// ISO/HDMV/registration stream-type mapping. Output packets are PES packets
/// (the demuxer layer); Annex B / ADTS frame splitting belongs to the codec
/// parsers, as in the C.
///
/// Out of scope: multi-packet PSI sections are supported, but section CRCs are
/// not verified; encrypted HLS sample streams, Blu-ray TrueHD+AC3 substream
/// splitting, teletext PCR timestamp fixups, DVB/ATSC metadata, and timestamp
/// wrap unwrapping (33-bit values are reported as-is).

///|
/// `AV_NOPTS_VALUE`. */
pub let ts_nopts : Int64 = -9223372036854775808L

///|
/// One elementary stream discovered in a PMT. */
pub struct TsStream {
  pid : Int32
  program_number : Int32
  stream_type : Int32
  /// FFmpeg codec name ("h264", "hevc", "aac", "mp3", ...); "" if unknown.
  codec : String
  /// "video", "audio", "subtitle" or "data".
  codec_type : String
  /// Four-character registration descriptor when present (e.g. "HEVC").
  registration : String
  /// ISO 639 language from descriptor 0x0A; "" when absent.
  language : String
}

///|
/// One program from the PAT plus its PMT fields. */
pub struct TsProgram {
  program_number : Int32
  pmt_pid : Int32
  mut pcr_pid : Int32
  stream_indices : Array[Int32]
  /// SDT service_descriptor fields; "" / 0 when no SDT was seen.
  mut service_name : String
  mut service_provider : String
  mut service_type : Int32
}

///|
/// One demuxed PES packet. `pos` is the byte offset of the first TS packet of
/// the PES (FFmpeg's `ts_packet_pos`), and `payload` excludes the PES header.
pub struct TsPacket {
  stream_index : Int32
  pid : Int32
  pos : Int64
  pts : Int64
  dts : Int64
  is_keyframe : Bool
  payload : Bytes
}

///|
/// A PCR sample from an adaptation field. `base` is the 33-bit 90 kHz part
/// and `ext` the 9-bit 27 MHz extension. */
pub struct TsPcr {
  pos : Int64
  pid : Int32
  base : Int64
  ext : Int32
}

///|
/// Parsed transport stream. */
pub struct TsDemux {
  /// 188, 192 (M2TS) or 204 (RS).
  packet_size : Int32
  /// Byte offset of the sync byte inside a raw packet (4 for M2TS, else 0).
  sync_offset : Int32
  programs : Array[TsProgram]
  streams : Array[TsStream]
  packets : Array[TsPacket]
  pcrs : Array[TsPcr]
}

///|
fn ts_rb16(data : BytesView, off : Int32) -> Int32 {
  if off < 0 || off + 2 > data.length() {
    0
  } else {
    (data[off].to_int() << 8) | data[off + 1].to_int()
  }
}

///|
fn ts_fourcc(data : BytesView, off : Int32) -> String {
  if off < 0 || off + 4 > data.length() {
    return ""
  }
  let sb = StringBuilder()
  for i in 0..<4 {
    sb.write_char(data[off + i].to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
/// The raw-packet layout detected by `mpegts_probe`: try 188, then 192 (M2TS
/// with a 4-byte prefix), then 204 (RS-coded). */
fn ts_detect_layout(data : BytesView) -> (Int32, Int32)? {
  let n = data.length()
  if n >= 188 && data[0] == b'\x47' {
    if n < 376 || data[188] == b'\x47' {
      let mut ok = true
      if n >= 564 {
        ok = data[376] == b'\x47'
      }
      if ok {
        return Some((188, 0))
      }
    }
  }
  if n >= 192 && data[4] == b'\x47' {
    if n < 384 || data[196] == b'\x47' {
      return Some((192, 4))
    }
  }
  if n >= 204 && data[0] == b'\x47' {
    if n < 408 || data[204] == b'\x47' {
      return Some((204, 0))
    }
  }
  None
}

///|
/// `ff_mpegts_stream_type`: ISO table, then HDMV when the program registration
/// is HDMV/HDPR, then ATSC private types and the registration descriptor.
pub fn ff_mpegts_stream_type(
  stream_type : Int32,
  registration : String,
  program_registration : String,
) -> (String, String) {
  let hdmv = program_registration == "HDMV" || program_registration == "HDPR"
  if hdmv {
    match stream_type {
      0x80 => return ("pcm_bluray", "audio")
      0x81 => return ("ac3", "audio")
      0x82 => return ("dts", "audio")
      0x83 => return ("truehd", "audio")
      0x84 => return ("eac3", "audio")
      0x85 | 0x86 => return ("dts", "audio")
      0x90 => return ("hdmv_pgs_subtitle", "subtitle")
      0x92 => return ("hdmv_text_subtitle", "subtitle")
      0xA1 => return ("eac3", "audio")
      0xA2 => return ("dts", "audio")
      _ => ()
    }
  }
  match stream_type {
    0x01 | 0x02 => ("mpeg2video", "video")
    0x03 | 0x04 => ("mp3", "audio")
    0x0F => ("aac", "audio")
    0x10 => ("mpeg4", "video")
    0x11 => ("aac_latm", "audio")
    0x1B => ("h264", "video")
    0x1C => ("aac", "audio")
    0x20 => ("h264", "video")
    0x21 => ("jpeg2000", "video")
    0x24 => ("hevc", "video")
    0x32 => ("jpegxs", "video")
    0x33 => ("vvc", "video")
    0x36 => ("lcevc", "video")
    0x42 => ("cavs", "video")
    0xCF => ("aac", "audio")
    0xD1 => ("dirac", "video")
    0xD2 => ("avs2", "video")
    0xD4 => ("avs3", "video")
    0xDB => ("h264", "video")
    0xEA => ("vc1", "video")
    0x06 =>
      match registration {
        "AC-3" => ("ac3", "audio")
        "AC-4" => ("ac4", "audio")
        "EAC3" => ("eac3", "audio")
        "DTS1" | "DTS2" | "DTS3" => ("dts", "audio")
        "HEVC" => ("hevc", "video")
        "Opus" => ("opus", "audio")
        "VC-1" => ("vc1", "video")
        "drac" => ("dirac", "video")
        "VVC " => ("vvc", "video")
        "BSSD" => ("s302m", "audio")
        "KLV " => ("smpte_klv", "data")
        "ID3 " => ("timed_id3", "data")
        _ => ("", "data")
      }
    0x81 => ("ac3", "audio")
    0x87 => ("eac3", "audio")
    0x8A => ("dts", "audio")
    _ => ("", "data")
  }
}

///|
/// Descriptor walk that extracts the registration, language and audio format
/// tags. `0x6A`/`0x7A`/`0x7B` are the DVB AC-3/E-AC-3/DTS descriptors,
/// `0x81`/`0x87` the ATSC ones. */
fn ts_parse_descriptors(
  data : BytesView,
  start : Int32,
  end : Int32,
  registration : Ref[String],
  language : Ref[String],
  desc_codec : Ref[String],
  desc_type : Ref[String],
) -> Unit {
  let mut p = start
  while p + 2 <= end {
    let tag = data[p].to_int()
    let len = data[p + 1].to_int()
    let body = p + 2
    if body + len > end {
      break
    }
    match tag {
      0x05 => if len >= 4 { registration.val = ts_fourcc(data, body) }
      0x0A =>
        if len >= 3 {
          let sb = StringBuilder()
          for i in 0..<3 {
            sb.write_char(data[body + i].to_int().unsafe_to_char())
          }
          language.val = sb.to_string()
        }
      0x6A | 0x81 => {
        desc_codec.val = "ac3"
        desc_type.val = "audio"
      }
      0x7A | 0x87 => {
        desc_codec.val = "eac3"
        desc_type.val = "audio"
      }
      0x7B | 0x82 => {
        desc_codec.val = "dts"
        desc_type.val = "audio"
      }
      _ => ()
    }
    p = body + len
  }
}

///|
fn ts_find_program(demux : TsDemux, program_number : Int32) -> Int32? {
  for i, prg in demux.programs {
    if prg.program_number == program_number {
      return Some(i)
    }
  }
  None
}

///|
fn ts_find_stream(demux : TsDemux, pid : Int32) -> Int32? {
  for i, st in demux.streams {
    if st.pid == pid {
      return Some(i)
    }
  }
  None
}

///|
/// Parse a complete PAT section (`table_id == 0x00`). */
fn ts_parse_pat(section : BytesView, demux : TsDemux) -> Unit {
  if section.length() < 12 || section[0].to_int() != 0x00 {
    return
  }
  let sec_len = ((section[1].to_int() & 0x0F) << 8) | section[2].to_int()
  let end = 3 + sec_len - 4
  if end > section.length() {
    return
  }
  let mut p = 8
  while p + 4 <= end {
    let program_number = ts_rb16(section, p)
    let pid = ts_rb16(section, p + 2) & 0x1FFF
    if program_number != 0 && ts_find_program(demux, program_number) is None {
      demux.programs.push({
        program_number,
        pmt_pid: pid,
        pcr_pid: -1,
        stream_indices: [],
        service_name: "",
        service_provider: "",
        service_type: 0,
      })
    }
    p = p + 4
  }
}

///|
/// Apply the SDT (`table_id == 0x42`) service_descriptor to matching programs
/// (`service_id == program_number`). Called after the packet loop so an SDT
/// placed before the PAT still lands.
fn ts_parse_sdt(section : BytesView, demux : TsDemux) -> Unit {
  if section.length() < 12 || section[0].to_int() != 0x42 {
    return
  }
  let sec_len = ((section[1].to_int() & 0x0F) << 8) | section[2].to_int()
  let end = 3 + sec_len - 4
  if end > section.length() || end < 11 {
    return
  }
  let mut p = 11
  while p + 5 <= end {
    let service_id = ts_rb16(section, p)
    let desc_len = ((section[p + 3].to_int() & 0x0F) << 8) |
      section[p + 4].to_int()
    let dstart = p + 5
    let dend = dstart + desc_len
    if dend > end {
      return
    }
    let mut q = dstart
    while q + 2 <= dend {
      let tag = section[q].to_int()
      let len = section[q + 1].to_int()
      let payload_end = q + 2 + len
      if payload_end > dend {
        return
      }
      if tag == 0x48 && len >= 3 {
        let service_type = section[q + 2].to_int()
        let mut r = q + 3
        let provider_len = section[r].to_int()
        r = r + 1
        if r + provider_len > payload_end {
          return
        }
        let provider_bytes : Array[Byte] = []
        for i = 0; i < provider_len; i = i + 1 {
          provider_bytes.push(section[r + i])
        }
        let service_provider = utf8_to_string(provider_bytes)
        r = r + provider_len
        if r >= payload_end {
          return
        }
        let name_len = section[r].to_int()
        r = r + 1
        if r + name_len > payload_end {
          return
        }
        let name_bytes : Array[Byte] = []
        for i = 0; i < name_len; i = i + 1 {
          name_bytes.push(section[r + i])
        }
        let service_name = utf8_to_string(name_bytes)
        match ts_find_program(demux, service_id) {
          Some(index) => {
            demux.programs[index].service_name = service_name
            demux.programs[index].service_provider = service_provider
            demux.programs[index].service_type = service_type
          }
          None => ()
        }
      }
      q = payload_end
    }
    p = dend
  }
}

///|
/// Parse a complete PMT section (`table_id == 0x02`). Repeated PMTs are merged:
/// streams keep their first-seen index, matching the C's stable stream list.
fn ts_parse_pmt(section : BytesView, demux : TsDemux, pmt_pid : Int32) -> Unit {
  if section.length() < 12 || section[0].to_int() != 0x02 {
    return
  }
  let sec_len = ((section[1].to_int() & 0x0F) << 8) | section[2].to_int()
  let end = 3 + sec_len - 4
  if end > section.length() || end < 12 {
    return
  }
  let program_number = ts_rb16(section, 3)
  let pcr_pid = ts_rb16(section, 8) & 0x1FFF
  let program_info_len = ts_rb16(section, 10) & 0x0FFF
  let program_reg = Ref("")
  let dummy_reg = Ref("")
  ignore(dummy_reg)
  let dummy_lang = Ref("")
  let dummy_codec = Ref("")
  let dummy_type = Ref("")
  ts_parse_descriptors(
    section,
    12,
    12 + program_info_len,
    program_reg,
    dummy_lang,
    dummy_codec,
    dummy_type,
  )
  let prg_index = match ts_find_program(demux, program_number) {
    Some(i) => i
    None => {
      demux.programs.push({
        program_number,
        pmt_pid,
        pcr_pid,
        stream_indices: [],
        service_name: "",
        service_provider: "",
        service_type: 0,
      })
      demux.programs.length() - 1
    }
  }
  demux.programs[prg_index].pcr_pid = pcr_pid
  let mut p = 12 + program_info_len
  while p + 5 <= end {
    let stream_type = section[p].to_int()
    let pid = ts_rb16(section, p + 1) & 0x1FFF
    let es_info_len = ts_rb16(section, p + 3) & 0x0FFF
    let dstart = p + 5
    let dend = dstart + es_info_len
    if dend > end {
      break
    }
    let registration = Ref("")
    let language = Ref("")
    let desc_codec = Ref("")
    let desc_type = Ref("")
    ts_parse_descriptors(
      section, dstart, dend, registration, language, desc_codec, desc_type,
    )
    let stream_index = match ts_find_stream(demux, pid) {
      Some(i) => i
      None => {
        let (codec, codec_type) = if desc_codec.val != "" {
          (desc_codec.val, desc_type.val)
        } else {
          ff_mpegts_stream_type(stream_type, registration.val, program_reg.val)
        }
        demux.streams.push({
          pid,
          program_number,
          stream_type,
          codec,
          codec_type,
          registration: registration.val,
          language: language.val,
        })
        let idx = demux.streams.length() - 1
        demux.programs[prg_index].stream_indices.push(idx)
        idx
      }
    }
    ignore(stream_index)
    p = dend
  }
}

///|
/// Per-PID PES assembly state. */
priv struct TsPesState {
  buffer : Array[Byte]
  mut start_pos : Int64
  mut header_parsed : Bool
  mut header_size : Int32
  mut pes_length : Int32
  mut pts : Int64
  mut dts : Int64
  mut active : Bool
}

///|
fn new_pes_state() -> TsPesState {
  {
    buffer: [],
    start_pos: 0L,
    header_parsed: false,
    header_size: 0,
    pes_length: 0,
    pts: ts_nopts,
    dts: ts_nopts,
    active: false,
  }
}

///|
/// `ff_parse_pes_pts`: 33-bit timestamp at `off`. */
fn ts_parse_pts(data : BytesView, off : Int32) -> Int64 {
  ((data[off].to_int64() & 0x0EL) << 29) |
  (ts_rb16(data, off + 1).to_int64() >> 1 << 15) |
  (ts_rb16(data, off + 3).to_int64() >> 1)
}

///|
fn ts_stream_id_is_header_only(id : Int32) -> Bool {
  id == 0xBC ||
  id == 0xBE ||
  id == 0xBF ||
  id == 0xF0 ||
  id == 0xF1 ||
  id == 0xF2 ||
  id == 0xFF
}

///|
fn ts_emit_pes(
  demux : TsDemux,
  state : TsPesState,
  stream_index : Int32,
  pid : Int32,
) -> Unit {
  if state.buffer.length() <= state.header_size {
    return
  }
  let end = if state.pes_length != 0 {
    let total = 6 + state.pes_length
    if total < state.buffer.length() {
      total
    } else {
      state.buffer.length()
    }
  } else {
    state.buffer.length()
  }
  if end <= state.header_size {
    return
  }
  let payload = Bytes::from_array(state.buffer[state.header_size:end])
  demux.packets.push({
    stream_index,
    pid,
    pos: state.start_pos,
    pts: state.pts,
    dts: state.dts,
    is_keyframe: false,
    payload,
  })
}

///|
/// `mpegts_push_data`: append one TS payload to the PID's PES, parse the header
/// once enough bytes are present, and emit complete packets.
fn ts_feed_pes(
  demux : TsDemux,
  states : Map[Int32, TsPesState],
  stream_index : Int32,
  pid : Int32,
  payload : BytesView,
  is_start : Bool,
  packet_pos : Int64,
) -> Unit {
  let state = match states.get(pid) {
    Some(s) => s
    None => {
      let s = new_pes_state()
      states[pid] = s
      s
    }
  }
  if is_start {
    if state.active && state.header_parsed {
      ts_emit_pes(demux, state, stream_index, pid)
    }
    state.buffer.clear()
    state.active = true
    state.header_parsed = false
    state.header_size = 0
    state.pes_length = 0
    state.pts = ts_nopts
    state.dts = ts_nopts
    state.start_pos = packet_pos
  }
  if !state.active {
    return
  }
  for i in 0..<payload.length() {
    state.buffer.push(payload[i])
  }
  if !state.header_parsed {
    if state.buffer.length() < 9 {
      return
    }
    if state.buffer[0] != b'\x00' ||
      state.buffer[1] != b'\x00' ||
      state.buffer[2] != b'\x01' {
      state.active = false
      return
    }
    state.pes_length = ts_rb16(Bytes::from_array(state.buffer), 4)
    let flags = state.buffer[7].to_int()
    let hdr_data_len = state.buffer[8].to_int()
    state.header_size = 9 + hdr_data_len
    if state.buffer.length() < state.header_size {
      return
    }
    let stream_id = state.buffer[3].to_int()
    if stream_id == 0xBE {
      state.active = false
      return
    }
    if ts_stream_id_is_header_only(stream_id) {
      state.header_size = 6
    } else {
      let r = 9
      if (flags & 0xC0) == 0x80 {
        let p = ts_parse_pts(Bytes::from_array(state.buffer), r)
        state.pts = p
        state.dts = p
      } else if (flags & 0xC0) == 0xC0 {
        let buf = Bytes::from_array(state.buffer)
        state.pts = ts_parse_pts(buf, r)
        state.dts = ts_parse_pts(buf, r + 5)
      }
    }
    state.header_parsed = true
  }
  if state.pes_length != 0 {
    let total = 6 + state.pes_length
    if state.buffer.length() >= total {
      ts_emit_pes(demux, state, stream_index, pid)
      state.active = false
    }
  }
}

///|
/// Open an in-memory MPEG-TS / M2TS / RS stream.
pub fn av_mpegts_open(data : Bytes) -> Result[TsDemux, String] {
  let (packet_size, sync_offset) = match ts_detect_layout(data) {
    Some(l) => l
    None => return Err("EINVAL: no MPEG-TS sync")
  }
  let demux : TsDemux = {
    packet_size,
    sync_offset,
    programs: [],
    streams: [],
    packets: [],
    pcrs: [],
  }
  let pes_states : Map[Int32, TsPesState] = Map([])
  let section_buffers : Map[Int32, Array[Byte]] = Map([])
  let sdt_sections : Array[Bytes] = []
  let mut raw_pos = 0
  while raw_pos + packet_size <= data.length() {
    let base = raw_pos + sync_offset
    if base + 188 > data.length() || data[base] != b'\x47' {
      // Resynchronise on the next raw packet; the C scans byte-wise.
      raw_pos = raw_pos + packet_size
      continue
    }
    let packet = data[base:base + 188]
    let pid = ts_rb16(packet, 1) & 0x1FFF
    let is_start = (packet[1].to_int() & 0x40) != 0
    let afc = (packet[3].to_int() >> 4) & 3
    let has_adaptation = (afc & 2) != 0
    let has_payload = (afc & 1) != 0
    let mut p = 4
    if has_adaptation {
      if p >= 188 {
        raw_pos = raw_pos + packet_size
        continue
      }
      let af_len = packet[p].to_int()
      if af_len >= 1 && p + 1 < 188 && (packet[p + 1].to_int() & 0x10) != 0 {
        let flags = packet[p + 1].to_int()
        if af_len >= 7 && (flags & 0x10) != 0 {
          let q = p + 2
          let base27 = (packet[q].to_int64() << 25) |
            (packet[q + 1].to_int64() << 17) |
            (packet[q + 2].to_int64() << 9) |
            (packet[q + 3].to_int64() << 1) |
            ((packet[q + 4].to_int64() >> 7) & 1L)
          let ext = ((packet[q + 4].to_int() & 1) << 8) | packet[q + 5].to_int()
          demux.pcrs.push({ pos: raw_pos.to_int64(), pid, base: base27, ext, })
        }
      }
      p = p + 1 + af_len
    }
    let packet_start = raw_pos.to_int64()
    raw_pos = raw_pos + packet_size
    if !has_payload || p >= 188 {
      continue
    }
    let payload = packet[p:188]
    if pid == 0 || pid == 0x11 {
      // PAT / SDT: PSI section with a pointer field on start packets.
      let buf = match section_buffers.get(pid) {
        Some(b) => b
        None => {
          let b : Array[Byte] = []
          section_buffers[pid] = b
          b
        }
      }
      if is_start {
        buf.clear()
        if payload.length() > 0 {
          let pointer = payload[0].to_int()
          if 1 + pointer <= payload.length() {
            for i in (1 + pointer)..<payload.length() {
              buf.push(payload[i])
            }
          }
        }
      } else {
        for i in 0..<payload.length() {
          buf.push(payload[i])
        }
      }
      if buf.length() >= 3 {
        let sec_len = ((buf[1].to_int() & 0x0F) << 8) | buf[2].to_int()
        if buf.length() >= 3 + sec_len {
          let section = Bytes::from_array(buf[0:3 + sec_len])
          if pid == 0 {
            ts_parse_pat(section, demux)
          } else {
            // Programs may not exist yet (ffmpeg writes the SDT first).
            sdt_sections.push(section)
          }
          buf.clear()
        }
      }
      continue
    }
    let is_pmt = {
      let mut found = false
      for prg in demux.programs {
        if prg.pmt_pid == pid {
          found = true
          break
        }
      }
      found
    }
    if is_pmt {
      let buf = match section_buffers.get(pid) {
        Some(b) => b
        None => {
          let b : Array[Byte] = []
          section_buffers[pid] = b
          b
        }
      }
      if is_start {
        buf.clear()
        if payload.length() > 0 {
          let pointer = payload[0].to_int()
          if 1 + pointer <= payload.length() {
            for i in (1 + pointer)..<payload.length() {
              buf.push(payload[i])
            }
          }
        }
      } else {
        for i in 0..<payload.length() {
          buf.push(payload[i])
        }
      }
      if buf.length() >= 3 {
        let sec_len = ((buf[1].to_int() & 0x0F) << 8) | buf[2].to_int()
        if buf.length() >= 3 + sec_len {
          ts_parse_pmt(Bytes::from_array(buf[0:3 + sec_len]), demux, pid)
          buf.clear()
        }
      }
      continue
    }
    match ts_find_stream(demux, pid) {
      Some(stream_index) =>
        ts_feed_pes(
          demux, pes_states, stream_index, pid, payload, is_start, packet_start,
        )
      None => ()
    }
  }
  // EOF flush, in PID order as the C's `NB_PID_MAX` scan does.
  let pids : Array[Int32] = []
  for pid, state in pes_states {
    if state.active && state.header_parsed {
      pids.push(pid)
    }
  }
  pids.sort()
  for pid in pids {
    let state = pes_states[pid]
    match ts_find_stream(demux, pid) {
      Some(stream_index) => ts_emit_pes(demux, state, stream_index, pid)
      None => ()
    }
  }
  for section in sdt_sections {
    ts_parse_sdt(section, demux)
  }
  Ok(demux)
}
