///|
/// RealMedia header parsing: `rm_read_header`, `rm_read_header_old`,
/// `rm_read_audio_stream_info`, `ff_rm_read_mdpr_codecdata`, `rm_read_multi`
/// and `rm_read_index` of FFmpeg 9.0.2 `libavformat/rmdec.c`, plus the
/// `av_realmedia_open` entry point. Original FFmpeg code is LGPL-2.1-or-later;
/// this port keeps the same license. See `realmedia.mbt` for the module notes.

///|
fn RealMediaState::new(data : Bytes) -> RealMediaState {
  {
    io: RealMediaIo::new(data),
    streams: [],
    packets: [],
    index: [],
    metadata: [],
    old_format: false,
    remaining_len: 0,
    current_stream: 0,
    audio_stream_num: 0,
    audio_pkt_cnt: 0,
  }
}

///|
/// `avformat_new_stream` + `ff_rm_alloc_rmstream`: append a stream with the
/// given `MDPR` stream number and return its index.
fn RealMediaState::new_stream(self : RealMediaState, number : Int32) -> Int32 {
  let index = self.streams.length()
  self.streams.push({
    kind: RealMediaKindUnknown,
    stream_number: number,
    codec: "",
    codec_tag: 0,
    bit_rate: 0L,
    sample_rate: 0,
    channels: 0,
    width: 0,
    height: 0,
    block_align: 0,
    extradata: b"",
    title: "",
    mime_type: "",
    start_time: 0L,
    duration: 0L,
    frame_rate_num: 0,
    frame_rate_den: 0,
    deint_id: 0,
    sub_packet_h: 0,
    sub_packet_size: 0,
    coded_framesize: 0,
    audio_framesize: 0,
    audio_buf: [],
    video_buf: None,
    videobufsize: 0,
    videobufpos: 0,
    curpic_num: -1,
    cur_slice: 0,
    slices: 0,
    pktpos: 0L,
    audiotimestamp: av_nopts_value,
    sub_packet_cnt: 0,
    sub_packet_lengths: FixedArray::make(16, 0),
    cur_dts: 0L,
    ts_relative: true,
    relative_packets: [],
  })
  index
}

///|
/// `av_dict_set` with flags 0: replace a tag of the same key, else append.
fn RealMediaState::set_metadata(
  self : RealMediaState,
  key : String,
  value : String,
) -> Unit {
  for i = 0; i < self.metadata.length(); i = i + 1 {
    if self.metadata[i].0 == key {
      self.metadata[i] = (key, value)
      return
    }
  }
  self.metadata.push((key, value))
}

///|
/// `rm_read_metadata`: title, author, copyright and comment, each a
/// two-byte length when `wide` (the `CONT` chunk) or a one-byte length.
fn RealMediaState::read_metadata(self : RealMediaState, wide : Bool) -> Unit {
  for key in ["title", "author", "copyright", "comment"] {
    let len = if wide {
      self.io.rb16().to_int64()
    } else {
      self.io.r8().to_int64()
    }
    if len > 0L {
      let value = self.io.str(len)
      self.set_metadata(key, value)
    }
  }
}

///|
/// `get_str8(pb, buf, sizeof(buf))` into the first four bytes of a buffer
/// that already holds a string: the bytes read replace the prefix, the NUL
/// that ends the string is stored too and the rest keeps its previous value
/// (as with the C's `char buf[256]`).
fn RealMediaIo::str8_into(
  self : RealMediaIo,
  scratch : FixedArray[Int32],
) -> Unit {
  let len = self.r8()
  for i = 0; i < len; i = i + 1 {
    let b = self.r8()
    if i < 4 {
      scratch[i] = b
    }
    if b == 0 {
      self.skip(len.to_int64() - i.to_int64() - 1L)
      break
    }
  }
}

///|
/// `AV_RL32` of the scratch buffer of `str8_into`.
fn realmedia_scratch_le32(scratch : FixedArray[Int32]) -> Int32 {
  let b0 = scratch[0].reinterpret_as_uint()
  let b1 = scratch[1].reinterpret_as_uint()
  let b2 = scratch[2].reinterpret_as_uint()
  let b3 = scratch[3].reinterpret_as_uint()
  let word = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  word.reinterpret_as_int()
}

///|
/// `rm_read_audio_stream_info`: the `.ra.` header of versions 3, 4 and 5.
/// `read_all` is set by the old `.ra` file format, whose header ends with
/// the file tags.
fn RealMediaState::read_audio_stream_info(
  self : RealMediaState,
  si : Int32,
  read_all : Bool,
) -> Result[Unit, String] {
  let io = self.io
  let st = self.streams[si]
  let version = io.rb16()
  if version == 3 {
    let header_size = io.rb16()
    let startpos = io.pos
    io.skip(8L)
    let bytes_per_minute = io.rb16().to_int64()
    io.skip(4L)
    self.read_metadata(false)
    if startpos.to_int64() + header_size.to_int64() >= io.pos.to_int64() + 2L {
      // fourcc (should always be "lpcJ"): one byte, then the string
      io.skip(1L)
      let _ = io.str8()
    }
    // Skip extra header crap (this should never happen)
    if startpos.to_int64() + header_size.to_int64() > io.pos.to_int64() {
      io.skip(startpos.to_int64() + header_size.to_int64() - io.pos.to_int64())
    }
    if bytes_per_minute > 0L {
      st.bit_rate = 8L * bytes_per_minute / 60L
    }
    st.sample_rate = 8000
    st.channels = 1
    st.kind = RealMediaKindAudio
    st.codec = "ra_144"
    st.deint_id = realmedia_deint_int0
    return Ok(())
  }

  // old version (4)
  io.skip(2L) // unused
  io.skip(4L) // ".ra4"
  io.skip(4L) // data size
  io.skip(2L) // version2
  io.skip(4L) // header size
  let flavor = io.rb16()
  let coded_framesize = io.rb32()
  if coded_framesize > 2147483647L {
    return Err("realmedia: invalid coded frame size")
  }
  st.coded_framesize = coded_framesize.to_int()
  io.skip(4L)
  let bytes_per_minute = io.rb32()
  if version == 4 && bytes_per_minute > 0L {
    st.bit_rate = 8L * bytes_per_minute / 60L
  }
  io.skip(4L)
  let sub_packet_h = io.rb16()
  let block_align = io.rb16()
  let sub_packet_size = io.rb16()
  io.skip(2L)
  if version == 5 {
    io.skip(6L)
  }
  st.sample_rate = io.rb16()
  io.skip(4L)
  st.channels = io.rb16()

  // The codec FourCC (and, before version 5, the interleaver FourCC) comes
  // as a length-prefixed string in version 4 and as four raw bytes in
  // version 5.
  let mut codec_tag = 0
  if version == 5 {
    st.deint_id = io.rl32()
    match io.read_exact(4L) {
      Ok(b) => codec_tag = realmedia_le32(b, 0)
      Err(e) => return Err(e)
    }
  } else {
    let scratch : FixedArray[Int32] = FixedArray::make(4, 0)
    io.str8_into(scratch)
    st.deint_id = realmedia_scratch_le32(scratch)
    io.str8_into(scratch)
    codec_tag = realmedia_scratch_le32(scratch)
  }
  st.kind = RealMediaKindAudio
  st.codec_tag = codec_tag
  st.codec = realmedia_codec_name(codec_tag)
  st.sub_packet_h = sub_packet_h
  st.sub_packet_size = sub_packet_size
  st.block_align = block_align

  if st.codec == "ra_288" {
    st.extradata = b""
    st.audio_framesize = block_align
    st.block_align = st.coded_framesize
  } else if st.codec == "cook" || st.codec == "atrac3" || st.codec == "sipr" {
    let codecdata_length = if read_all {
      0L
    } else {
      io.skip(2L)
      io.skip(1L)
      if version == 5 {
        io.skip(1L)
      }
      let length = io.rb32()
      if length > 2147483647L - 64L {
        return Err("realmedia: codecdata_length too large")
      }
      length
    }
    st.audio_framesize = block_align
    if st.codec == "sipr" {
      if flavor > 3 {
        return Err("realmedia: bad SIPR flavor \{flavor}")
      }
      st.block_align = realmedia_sipr_subpk_size[flavor]
    } else {
      if sub_packet_size <= 0 {
        return Err("realmedia: sub_packet_size is invalid")
      }
      st.block_align = sub_packet_size
    }
    match io.extradata(codecdata_length) {
      Ok(extra) => st.extradata = extra
      Err(e) => return Err(e)
    }
  } else if st.codec == "aac" {
    io.skip(2L)
    io.skip(1L)
    if version == 5 {
      io.skip(1L)
    }
    let codecdata_length = io.rb32()
    if codecdata_length > 2147483647L - 64L {
      return Err("realmedia: codecdata_length too large")
    }
    if codecdata_length >= 1L {
      io.skip(1L)
      match io.extradata(codecdata_length - 1L) {
        Ok(extra) => st.extradata = extra
        Err(e) => return Err(e)
      }
    }
  }

  // Interleaver checks
  let deint = st.deint_id
  if deint == realmedia_deint_int4 {
    let h = sub_packet_h.to_int64()
    let cfs = st.coded_framesize.to_int64()
    let w = st.audio_framesize.to_int64()
    let parity = if (sub_packet_h & 1) != 0 { 1L } else { 0L }
    if st.coded_framesize > st.audio_framesize ||
      sub_packet_h <= 1 ||
      cfs * h > (2L + parity) * w {
      return Err("realmedia: invalid Int4 interleaver parameters")
    }
    if cfs * h != 2L * w {
      return Err("realmedia: mismatching interleaver parameters")
    }
  } else if deint == realmedia_deint_genr {
    if sub_packet_size <= 0 || sub_packet_size > st.audio_framesize {
      return Err("realmedia: invalid genr interleaver parameters")
    }
    if st.audio_framesize % sub_packet_size != 0 {
      return Err("realmedia: genr interleaver sizes do not divide")
    }
  } else if deint != realmedia_deint_sipr &&
    deint != realmedia_deint_int0 &&
    deint != realmedia_deint_vbrs &&
    deint != realmedia_deint_vbrf {
    return Err("realmedia: unknown interleaver")
  }
  if deint == realmedia_deint_int4 ||
    deint == realmedia_deint_genr ||
    deint == realmedia_deint_sipr {
    let total = st.audio_framesize.to_int64() * sub_packet_h.to_int64()
    if st.block_align <= 0 ||
      total > 2147483647L ||
      total < st.block_align.to_int64() {
      return Err("realmedia: invalid interleaved buffer size")
    }
    st.audio_buf = Array::make(total.to_int(), b'\x00')
  }

  if read_all {
    io.skip(3L)
    self.read_metadata(false)
  }
  Ok(())
}

///|
/// `av_reduce(&st->avg_frame_rate.den, &st->avg_frame_rate.num, 0x10000, fps,
/// (1 << 30) - 1)` as `rmdec.c` calls it: the reduced fraction
/// `fps field / 0x10000` as (numerator, denominator). The approximation
/// branch of `av_reduce` (a numerator above `2^30 - 1`) is not modelled; such
/// a frame rate is reported as unknown.
fn realmedia_reduce_frame_rate(fps : Int64) -> (Int32, Int32) {
  let mut a = fps
  let mut b = 65536L
  while b != 0L {
    let t = a % b
    a = b
    b = t
  }
  if a <= 0L || fps / a > 1073741823L {
    (0, 0)
  } else {
    ((fps / a).to_int(), (65536L / a).to_int())
  }
}

///|
/// `ff_rm_read_mdpr_codecdata`. `mime` is "" when the header carries no MIME
/// type.
fn RealMediaState::read_mdpr_codecdata(
  self : RealMediaState,
  si : Int32,
  codec_data_size : Int64,
  mime : String,
) -> Result[Unit, String] {
  if codec_data_size > 2147483647L {
    return Err("realmedia: codec data size too large")
  }
  if codec_data_size == 0L {
    return Ok(())
  }
  let io = self.io
  let codec_pos = io.pos
  let v = io.rb32_tag()
  let mut error = ""
  if v == realmedia_tag_ra {
    match self.read_audio_stream_info(si, false) {
      Ok(_) => ()
      Err(e) => error = e
    }
  } else if v == realmedia_tag_be("LSD:") {
    // RealAudio Lossless: the whole codec data is the extradata, which
    // starts with the FourCC.
    io.seek(codec_pos.to_int64())
    match io.extradata(codec_data_size) {
      Ok(extra) => {
        let st = self.streams[si]
        st.extradata = extra
        st.kind = RealMediaKindAudio
        st.codec_tag = if extra.length() >= 4 {
          realmedia_le32(extra, 0)
        } else {
          0
        }
        st.codec = realmedia_codec_name(st.codec_tag)
      }
      Err(e) => error = e
    }
  } else if mime == "logical-fileinfo" {
    // Not a media stream: the chunk only carries file properties.
    let _ = self.streams.pop()
    if io.rb16() != 0 {
      // Unsupported version
    } else {
      let stream_count = io.rb16()
      io.skip(6L * stream_count.to_int64())
      let rule_count = io.rb16()
      io.skip(2L * rule_count.to_int64())
      let property_count = io.rb16()
      let mut bail = false
      for _i = 0; _i < property_count && !bail; _i = _i + 1 {
        io.skip(4L)
        if io.rb16() != 0 {
          // Unsupported Name value property version
          bail = true
        } else {
          let name = io.str8()
          let property_type = io.rb32()
          let value_len = io.rb16().to_int64()
          if property_type == 2L {
            self.set_metadata(name, io.str(value_len))
          } else {
            io.skip(value_len)
          }
        }
      }
    }
  } else {
    let is_video = io.rl32() == realmedia_tag("VIDO")
    let st = self.streams[si]
    if is_video {
      st.codec_tag = io.rl32()
      st.codec = realmedia_codec_name(st.codec_tag)
    }
    if is_video && st.codec != "" {
      st.width = io.rb16()
      st.height = io.rb16()
      io.skip(2L) // looks like bits per sample
      io.skip(4L) // always zero?
      st.kind = RealMediaKindVideo
      let fps = io.rb32()
      let used = io.pos.to_int64() - codec_pos.to_int64()
      match io.extradata(codec_data_size - used) {
        Ok(extra) => st.extradata = extra
        Err(e) => error = e
      }
      if fps > 0L {
        let (num, den) = realmedia_reduce_frame_rate(fps)
        st.frame_rate_num = num
        st.frame_rate_den = den
      }
    }
  }
  if error != "" {
    return Err(error)
  }

  // skip codec info
  let used = io.pos.to_int64() - codec_pos.to_int64()
  if codec_data_size >= used {
    io.skip(codec_data_size - used)
  }
  Ok(())
}

///|
/// `rm_read_multi`: the `MLTI` chunk of a SureStream file, which holds the
/// codec data of `number_of_mdpr` streams. The first is the stream the
/// `MDPR` belongs to; the others are added with their stream number shifted
/// by `index << 16`. The caller seeks back to the end of the chunk.
fn RealMediaState::read_multi(
  self : RealMediaState,
  si : Int32,
) -> Result[Unit, String] {
  let io = self.io
  let number_of_streams = io.rb16()
  for _i = 0; _i < number_of_streams; _i = _i + 1 {
    io.skip(2L)
  }
  let number_of_mdpr = io.rb16()
  let base = self.streams[si]
  for i = 1; i <= number_of_mdpr; i = i + 1 {
    let target = if i == 1 {
      si
    } else {
      let added = self.new_stream(base.stream_number + ((i - 1) << 16))
      let st2 = self.streams[added]
      st2.bit_rate = base.bit_rate
      st2.start_time = base.start_time
      st2.duration = base.duration
      added
    }
    let size2 = io.rb32()
    match self.read_mdpr_codecdata(target, size2, "") {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    // The C keeps the additional streams as data streams unless their codec
    // data says otherwise; this port only keeps media streams.
    if i > 1 && self.streams[target].kind is RealMediaKindUnknown {
      let _ = self.streams.pop()
    }
  }
  Ok(())
}

///|
/// The `MDPR` case of `rm_read_header`.
fn RealMediaState::read_mdpr(
  self : RealMediaState,
  file_duration : Ref[Int64],
) -> Result[Unit, String] {
  let io = self.io
  let number = io.rb16()
  let si = self.new_stream(number)
  let st = self.streams[si]
  io.skip(4L) // max bit rate
  st.bit_rate = io.rb32()
  io.skip(8L) // max packet size, avg packet size
  st.start_time = io.rb32()
  io.skip(4L) // preroll
  st.duration = io.rb32()
  if st.duration > 0L {
    file_duration.val = av_nopts_value
  }
  st.title = io.str8()
  st.mime_type = io.str8()
  let size = io.rb32()
  let codec_pos = io.pos
  let v = io.rb32_tag()
  if v == realmedia_tag_be("MLTI") {
    match self.read_multi(si) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
    io.seek(codec_pos.to_int64() + size)
  } else {
    io.seek(codec_pos.to_int64())
    match self.read_mdpr_codecdata(si, size, st.mime_type) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  Ok(())
}

///|
/// `rm_read_index`: the `INDX` chunks. The caller seeks to the first one;
/// entries are stored as they are read.
fn RealMediaState::read_index(self : RealMediaState) -> Unit {
  let io = self.io
  let mut next_off = 0L
  let mut first = true
  while first || next_off != 0L {
    first = false
    if io.rl32() != realmedia_tag("INDX") {
      return
    }
    let size = io.rb32()
    if size < 20L {
      return
    }
    let ver = io.rb16()
    if ver != 0 && ver != 2 {
      return
    }
    let n_pkts = io.rb32()
    let str_id = io.rb16()
    next_off = io.rb32()
    if ver == 2 {
      io.skip(4L)
    }
    let mut si = -1
    for i = 0; i < self.streams.length(); i = i + 1 {
      if self.streams[i].stream_number == str_id {
        si = i
        break
      }
    }
    // An unknown stream or an entry count beyond the file skips the chunk.
    if si >= 0 && io.remaining() / 14L >= n_pkts {
      for _n = 0L; _n < n_pkts; _n = _n + 1L {
        if io.eof {
          return
        }
        io.skip(2L)
        let pts = io.rb32()
        let pos = if ver == 0 { io.rb32() } else { io.rb64() }
        io.skip(4L) // packet no.
        self.index.push({ stream_index: si, timestamp: pts, pos, })
      }
    }
    if next_off != 0L && io.pos.to_int64() < next_off {
      io.seek(next_off)
    }
  }
}

///|
/// `av_get_audio_frame_duration` for the audio codecs of
/// `ff_rm_codec_tags`: samples in a packet of `size` bytes, 0 when the codec
/// does not tell.
fn realmedia_frame_samples(st : RealMediaStream, size : Int32) -> Int32 {
  let extra = st.extradata
  match st.codec {
    "ra_144" => 160 * (size / 20)
    "ra_288" => 160
    "ac3" => 1536
    "aac" => 1024
    "atrac3" =>
      if st.block_align > 0 && size / st.block_align > 0 {
        1024 * (size / st.block_align)
      } else {
        1024
      }
    "sipr" =>
      match st.block_align {
        20 => 160
        19 => 144
        29 => 288
        37 => 480
        _ => 0
      }
    "cook" =>
      // the decoder's frame size (`avctx->frame_size` in the C)
      match @libavcodec.cook_samples_per_channel(extra, st.channels) {
        Ok(n) => n
        Err(_) => 0
      }
    _ => 0
  }
}

///|
/// The duration `compute_pkt_fields` derives for a packet of `size` bytes:
/// `av_rescale_rnd(1, samples * 1000, sample_rate, AV_ROUND_DOWN)` for
/// audio, the frame period for video.
fn realmedia_packet_duration_ms(st : RealMediaStream, size : Int32) -> Int64 {
  let (units, per) = if st.kind is RealMediaKindVideo {
    if st.frame_rate_num > 0 {
      (st.frame_rate_den.to_int64(), st.frame_rate_num.to_int64())
    } else {
      (0L, 1L)
    }
  } else {
    let samples = realmedia_frame_samples(st, size)
    if samples > 0 && st.sample_rate > 0 {
      (samples.to_int64(), st.sample_rate.to_int64())
    } else {
      (0L, 1L)
    }
  }
  units * 1000L / per
}

///|
/// Parse a RealMedia / RealAudio file: the header chunks, the index and the
/// whole `DATA` chunk. The stream table, the packets in file order and the
/// metadata come back in one `RealMediaDemux`.
pub fn av_realmedia_open(data : Bytes) -> Result[RealMediaDemux, String] {
  let st = RealMediaState::new(data)
  let io = st.io
  let file_duration : Ref[Int64] = Ref(av_nopts_value)
  let mut nb_packets = 0L
  let is_old = data.length() >= 4 &&
    data[0] == b'.' &&
    data[1] == b'r' &&
    data[2] == b'a' &&
    data[3] == b'\xfd'
  if is_old {
    // very old .ra format: one audio header, then the raw packets
    st.old_format = true
    io.skip(4L)
    let si = st.new_stream(0)
    match st.read_audio_stream_info(si, true) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  } else {
    let is_rmf = data.length() >= 4 &&
      data[0] == b'.' &&
      data[1] == b'R' &&
      data[2] == b'M' &&
      (data[3] == b'F' || data[3] == b'P')
    if !is_rmf {
      return Err("realmedia: not a RealMedia file")
    }
    io.skip(4L)
    let tag_size = io.rb32()
    if tag_size > 2147483647L {
      return Err("realmedia: invalid file header size")
    }
    io.skip(tag_size - 8L)
    let mut data_off = 0L
    let mut indx_off = 0L
    let mut flags = 0
    let mut ver = 0
    let mut saw_data = false
    while !io.eof {
      let tag = io.rl32()
      let size = io.rb32()
      ver = io.rb16()
      let is_data = tag == realmedia_tag("DATA")
      if (size < 10L && !is_data) || (ver != 0 && ver != 2) {
        return Err("realmedia: invalid chunk header")
      }
      if tag == realmedia_tag("PROP") {
        io.skip(20L) // max / avg bit rate, max / avg packet size, nb packets
        file_duration.val = io.rb32() // duration
        io.skip(4L) // preroll
        indx_off = if ver == 0 { io.rb32() } else { io.rb64() }
        data_off = io.rb32()
        io.skip(2L) // nb streams
        flags = io.rb16()
      } else if tag == realmedia_tag("CONT") {
        st.read_metadata(true)
      } else if tag == realmedia_tag("MDPR") {
        match st.read_mdpr(file_duration) {
          Ok(_) => ()
          Err(e) => return Err(e)
        }
      } else if is_data {
        saw_data = true
        break
      } else {
        // unknown tag: skip it
        io.skip(size - 10L)
      }
    }
    if !saw_data {
      return Err("realmedia: no DATA chunk")
    }

    let count = io.rb32() // number of packets
    nb_packets = if count == 0L && (flags & 4) != 0 {
      3600L * 25L
    } else {
      count
    }
    let header = if ver == 0 { 18L } else { 30L }
    if ver == 2 {
      io.skip(12L)
    }
    io.skip(4L) // next data header
    if data_off == 0L {
      data_off = io.pos.to_int64() - header
    }
    if indx_off != 0L {
      io.seek(indx_off)
      st.read_index()
      io.seek(data_off + header)
    }
  }

  // Streams that stayed unrecognised are not part of the result.
  let kept : Array[RealMediaStream] = []
  for stream in st.streams {
    if stream.kind is RealMediaKindUnknown {
      // FFmpeg keeps such streams as data streams; this port drops them.
    } else {
      kept.push(stream)
    }
  }
  st.streams = kept
  let read_error = st.read_packets()
  let tracks : Array[RealMediaTrack] = []
  for stream in st.streams {
    tracks.push({
      stream_number: stream.stream_number,
      media_type: if stream.kind is RealMediaKindVideo {
        MediaType::Video
      } else {
        MediaType::Audio
      },
      codec: stream.codec,
      codec_tag: stream.codec_tag,
      bit_rate: stream.bit_rate,
      sample_rate: stream.sample_rate,
      channels: stream.channels,
      width: stream.width,
      height: stream.height,
      block_align: stream.block_align,
      extradata: stream.extradata,
      title: stream.title,
      mime_type: stream.mime_type,
      start_time: stream.start_time,
      duration: stream.duration,
      frame_rate_num: stream.frame_rate_num,
      frame_rate_den: stream.frame_rate_den,
      deint_id: stream.deint_id,
      sub_packet_h: stream.sub_packet_h,
      sub_packet_size: stream.sub_packet_size,
      coded_framesize: stream.coded_framesize,
      audio_framesize: stream.audio_framesize,
    })
  }
  Ok({
    tracks,
    packets: st.packets,
    index: st.index,
    metadata: st.metadata,
    duration: file_duration.val,
    nb_packets,
    old_format: st.old_format,
    read_error,
  })
}
