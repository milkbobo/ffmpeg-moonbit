///|
/// The `DATA` chunk walk of FFmpeg 9.0.2 `libavformat/rmdec.c`: `rm_sync`,
/// `ff_rm_parse_packet`, `ff_rm_retrieve_cache`,
/// `rm_assemble_video_frame` and `rm_read_packet`, plus the timestamp
/// bookkeeping of the generic `compute_pkt_fields`. Original FFmpeg code is
/// LGPL-2.1-or-later; this port keeps the same license. See `realmedia.mbt`
/// for the module notes.

///|
/// Hand one packet to the caller the way `av_read_frame` does after
/// `compute_pkt_fields`: a missing timestamp is filled in from the stream's
/// running `cur_dts`, the first real timestamp of a stream rebases the
/// packets that were emitted before it (`update_initial_timestamps`), and
/// audio packets are keyframes (`ff_is_intra_only`).
fn RealMediaState::emit(
  self : RealMediaState,
  si : Int32,
  data : Bytes,
  pts : Int64,
  key : Bool,
  pos : Int64,
) -> Unit {
  let st = self.streams[si]
  let audio = st.kind is RealMediaKindAudio
  let duration = realmedia_packet_duration_ms(st, data.length())
  let has_pts = pts != av_nopts_value
  // Without a timestamp and without a derivable duration the C leaves the
  // packet at AV_NOPTS_VALUE.
  let filled = !has_pts && duration > 0L
  let mut relative = false
  let out = if has_pts {
    if st.ts_relative {
      let shift = pts - st.cur_dts
      for p in st.relative_packets {
        let q = self.packets[p]
        self.packets[p] = {
          stream_index: q.stream_index,
          data: q.data,
          pts: q.pts + shift,
          keyframe: q.keyframe,
          pos: q.pos,
        }
      }
      st.ts_relative = false
    }
    pts
  } else if filled {
    // presentation is not delayed: PTS and DTS are the same
    relative = st.ts_relative
    st.cur_dts
  } else {
    av_nopts_value
  }
  if has_pts || filled {
    // sti->cur_dts = av_add_stable(time_base, pkt->pts, duration, 1)
    st.cur_dts = out + duration
  }
  if relative {
    st.relative_packets.push(self.packets.length())
  }
  self.packets.push({
    stream_index: si,
    data,
    pts: out,
    keyframe: audio || key,
    pos,
  })
}

///|
/// `rm_sync`: locate the next packet header. Returns `(len, timestamp,
/// flags, stream index, pos)`; `len` is -1 at end of file.
fn RealMediaState::sync(
  self : RealMediaState,
) -> Result[(Int64, Int64, Int32, Int32, Int64), String] {
  let io = self.io
  let mut state = 0xFFFFFFFFU
  while !io.eof {
    let mut len = 0L
    let mut timestamp = av_nopts_value
    let mut flags = 0
    let mut num = 0
    let mut mlti_id = 0
    // Negative while a packet header is being decoded; otherwise the number
    // of bytes of an unusable record that still have to be skipped.
    let mut skip_len = -1L
    // The C reports avio_tell() - 3 here; only keyframe index entries use it.
    let pos = io.pos.to_int64() - 3L
    if self.remaining_len > 0 {
      num = self.current_stream
      len = self.remaining_len.to_int64()
    } else {
      state = (state << 8) + io.r8().reinterpret_as_uint()
      if state == realmedia_tag_be("INDX") {
        let mut size = io.rb32()
        let ver = io.rb16()
        if ver != 0 && ver != 2 {
          return Err("realmedia: invalid index version")
        }
        let n_pkts = io.rb32()
        let expected = if ver == 0 {
          20L + n_pkts * 14L
        } else {
          24L + n_pkts * 18L
        }
        if size == 20L && expected <= 2147483647L {
          // some files don't add index entries to chunk size...
          size = expected
        }
        // A wrong size is only warned about in the C; a huge one is a
        // negative int there and skipped as "len < 14".
        if size > 2147483647L || size < 14L {
          continue
        }
        skip_len = size - 14L // we already read part of the index header
      }
      // (A DATA tag in the middle of a chunk is only warned about in the C.)
      if skip_len < 0L {
        if state > 0xFFFFU || state <= 12U {
          continue
        }
        len = (state - 12U).reinterpret_as_int().to_int64()
        state = 0xFFFFFFFFU
        num = io.rb16()
        timestamp = io.rb32()
        let mlti = ((io.r8() >> 1) - 1).max(0)
        mlti_id = mlti << 16
        flags = io.r8()
      }
    }
    let mut found = -1
    if skip_len < 0L {
      for i = 0; i < self.streams.length(); i = i + 1 {
        if mlti_id + num == self.streams[i].stream_number {
          found = i
          break
        }
      }
      if found < 0 {
        skip_len = len
      }
    }
    if skip_len >= 0L {
      // skip packet if unknown number
      io.skip(skip_len)
      self.remaining_len = 0
      continue
    }
    return Ok((len, timestamp, flags, found, pos))
  }
  Ok((-1L, av_nopts_value, 0, -1, -1L))
}

///|
/// `ff_rm_retrieve_cache`: the next packet of the audio group being drained.
fn RealMediaState::retrieve_cache(
  self : RealMediaState,
) -> Result[Unit, String] {
  let io = self.io
  let si = self.audio_stream_num
  let st = self.streams[si]
  let deint = st.deint_id
  let (data, start) = if deint == realmedia_deint_vbrf ||
    deint == realmedia_deint_vbrs {
    let length = st.sub_packet_lengths[st.sub_packet_cnt - self.audio_pkt_cnt]
    let (bytes, at) = io.take(length.to_int64())
    if bytes.length() == 0 {
      // av_get_packet returns the read error (end of file) for an empty read
      return Err("")
    }
    (bytes, at)
  } else {
    let block_align = st.block_align
    let offset = block_align *
      (st.sub_packet_h * st.audio_framesize / block_align - self.audio_pkt_cnt)
    let out : Array[Byte] = Array::make(block_align, b'\x00')
    for i = 0; i < block_align; i = i + 1 {
      out[i] = st.audio_buf[offset + i]
    }
    (Bytes::from_array(out), -1)
  }
  self.audio_pkt_cnt -= 1
  let pts = st.audiotimestamp
  let key = pts != av_nopts_value
  if key {
    st.audiotimestamp = av_nopts_value
  }
  self.emit(si, data, pts, key, start.to_int64())
  Ok(())
}

///|
/// `rm_assemble_video_frame`. Returns 0 when a frame was emitted, 1 when a
/// slice was buffered (or the slice does not fit and is dropped, as in the
/// C) and `Err` for the errors the C reports upwards. `seq` receives the
/// sequence number of a slice header (`*pseq`).
fn RealMediaState::assemble_video(
  self : RealMediaState,
  si : Int32,
  len_in : Int64,
  seq : Ref[Int32],
  flags : Int32,
  timestamp : Int64,
) -> Result[Int32, String] {
  let io = self.io
  let vst = self.streams[si]
  let hdr = io.r8()
  let mut len = len_in - 1L
  let kind = hdr >> 6
  let mut seq_no = 0
  let mut len2 = 0
  let mut pos = 0
  let mut pic_num = 0
  if kind != 3 { // not frame as a part of packet
    seq_no = io.r8()
    len -= 1L
  }
  if kind != 1 { // not whole frame
    // get_num, twice
    let mut n = io.rb16() & 0x7FFF
    len -= 2L
    if n >= 0x4000 {
      len2 = n - 0x4000
    } else {
      let n1 = io.rb16()
      len -= 2L
      len2 = (n << 16) | n1
    }
    n = io.rb16() & 0x7FFF
    len -= 2L
    if n >= 0x4000 {
      pos = n - 0x4000
    } else {
      let n1 = io.rb16()
      len -= 2L
      pos = (n << 16) | n1
    }
    pic_num = io.r8()
    len -= 1L
  }
  if len < 0L {
    // "Insufficient data": the C's -1, read on
    return Ok(-1)
  }
  self.remaining_len = len.to_int()
  let key = (flags & 2) != 0
  if (kind & 1) != 0 { // frame, not slice
    let mut take = len
    let mut pts = timestamp
    if kind == 3 { // frame as a part of packet
      take = len2.to_int64()
      pts = pos.to_int64()
    }
    if self.remaining_len.to_int64() < take {
      // "Insufficient remaining len": the C's -1, read on
      return Ok(-1)
    }
    self.remaining_len -= take.to_int()
    let bytes = match io.read_exact(take) {
      Ok(b) => b
      Err(e) => return Err(e)
    }
    // 9-byte slice table header: no slices, one entry
    let frame = Array::makei(take.to_int() + 9, i => {
      if i < 9 {
        b'\x00'
      } else {
        bytes[i - 9]
      }
    })
    realmedia_wl32(frame, 1, 1)
    realmedia_wl32(frame, 5, 0)
    self.emit(si, Bytes::from_array(frame), pts, key, -1L)
    return Ok(0)
  }

  // now we have to deal with single slice
  seq.val = seq_no
  if (seq_no & 0x7F) == 1 || vst.curpic_num != pic_num {
    // ffio_limit caps the frame size at what is left of the file
    let limit = if io.remaining() == 0L { 1L } else { io.remaining() }
    if len2.to_int64() > limit {
      return Err("realmedia: impossibly sized packet")
    }
    vst.slices = ((hdr & 0x3F) << 1) + 1
    vst.videobufsize = len2 + 8 * vst.slices + 1
    vst.video_buf = Some(Array::make(vst.videobufsize, b'\x00'))
    vst.videobufpos = 8 * vst.slices + 1
    vst.cur_slice = 0
    vst.curpic_num = pic_num
    vst.pktpos = io.pos.to_int64()
  }
  let mut take = len
  if kind == 2 {
    take = len.min(pos.to_int64())
  }
  vst.cur_slice += 1
  if vst.cur_slice > vst.slices {
    // cur slice too large
    return Ok(1)
  }
  let buf = match vst.video_buf {
    Some(b) => b
    None => return Err("realmedia: video buffer lost")
  }
  realmedia_wl32(buf, 8 * vst.cur_slice - 7, 1)
  realmedia_wl32(
    buf,
    8 * vst.cur_slice - 3,
    vst.videobufpos - 8 * vst.slices - 1,
  )
  if vst.videobufpos.to_int64() + take > vst.videobufsize.to_int64() {
    // outside videobufsize
    return Ok(1)
  }
  io.read_full(buf, vst.videobufpos, take.to_int())
  vst.videobufpos += take.to_int()
  self.remaining_len -= take.to_int()

  if kind == 2 || vst.videobufpos == vst.videobufsize {
    // Slice count, the table entries of the slices received, then the
    // payload moved up over the unused table entries.
    buf[0] = (vst.cur_slice - 1).to_byte()
    let payload = vst.videobufpos - 1 - 8 * vst.slices
    let out : Array[Byte] = Array::make(
      1 + 8 * vst.cur_slice + payload,
      b'\x00',
    )
    for i = 0; i < 1 + 8 * vst.cur_slice; i = i + 1 {
      out[i] = buf[i]
    }
    for i = 0; i < payload; i = i + 1 {
      out[1 + 8 * vst.cur_slice + i] = buf[1 + 8 * vst.slices + i]
    }
    vst.video_buf = None
    vst.slices = 0
    self.emit(si, Bytes::from_array(out), timestamp, key, vst.pktpos)
    return Ok(0)
  }
  Ok(1)
}

///|
/// `ff_rm_parse_packet`: consume one record of `len` payload bytes. Returns
/// the number of audio packets now queued, 0 when a packet was emitted and
/// -1 when the record was only part of one (the caller reads on).
fn RealMediaState::parse_packet(
  self : RealMediaState,
  si : Int32,
  len : Int64,
  seq : Ref[Int32],
  flags : Int32,
  timestamp : Int64,
) -> Result[Int32, String] {
  let io = self.io
  let st = self.streams[si]
  if st.kind is RealMediaKindVideo {
    self.current_stream = st.stream_number
    return match self.assemble_video(si, len, seq, flags, timestamp) {
      Ok(0) => Ok(0)
      Ok(_) => Ok(-1)
      Err(e) => Err(e)
    }
  }
  if st.kind is RealMediaKindAudio {
    let deint = st.deint_id
    if deint == realmedia_deint_genr ||
      deint == realmedia_deint_int4 ||
      deint == realmedia_deint_sipr {
      let sps = st.sub_packet_size
      let cfs = st.coded_framesize
      let h = st.sub_packet_h
      let w = st.audio_framesize
      if (flags & 2) != 0 {
        st.sub_packet_cnt = 0
      }
      let y = st.sub_packet_cnt
      if y == 0 {
        st.audiotimestamp = timestamp
      }
      let buf = st.audio_buf
      if deint == realmedia_deint_int4 {
        for x = 0; x < h / 2; x = x + 1 {
          io.read_full(buf, x * 2 * w + y * cfs, cfs)
        }
      } else if deint == realmedia_deint_genr {
        let half = (h + 1) / 2
        for x = 0; x < w / sps; x = x + 1 {
          io.read_full(buf, sps * (h * x + half * (y & 1) + (y >> 1)), sps)
        }
      } else {
        io.read_full(buf, y * w, w)
      }
      st.sub_packet_cnt += 1
      if st.sub_packet_cnt < h {
        return Ok(-1)
      }
      if deint == realmedia_deint_sipr {
        realmedia_reorder_sipr(buf, h, w)
      }
      st.sub_packet_cnt = 0
      self.audio_stream_num = si
      if st.block_align <= 0 {
        return Err("realmedia: invalid block alignment")
      }
      self.audio_pkt_cnt = h * w / st.block_align
    } else if deint == realmedia_deint_vbrf || deint == realmedia_deint_vbrs {
      // Variable bitrate AAC: a count, then the sub-packet lengths; the
      // payload follows and is read by ff_rm_retrieve_cache.
      self.audio_stream_num = si
      let count = (io.rb16() & 0xF0) >> 4
      st.sub_packet_cnt = count
      if count != 0 {
        for x = 0; x < count; x = x + 1 {
          st.sub_packet_lengths[x] = io.rb16()
        }
        self.audio_pkt_cnt = count
        st.audiotimestamp = timestamp
      } else {
        return Ok(-1)
      }
    } else {
      let (bytes, start) = io.take(len)
      let data = if st.codec == "ac3" {
        // rm_ac3_swap_bytes
        let swapped : Array[Byte] = Array::makei(bytes.length(), i => bytes[i])
        let mut j = 0
        while j + 1 < bytes.length() {
          let t = swapped[j]
          swapped[j] = swapped[j + 1]
          swapped[j + 1] = t
          j += 2
        }
        Bytes::from_array(swapped)
      } else {
        bytes
      }
      self.emit(si, data, timestamp, (flags & 2) != 0, start.to_int64())
      return Ok(0)
    }
  }
  Ok(self.audio_pkt_cnt)
}

///|
/// `rm_read_packet` until end of file: fills `packets` (and the index
/// entries of the keyframes). Returns "" when the file was read to its end,
/// otherwise the error the C would report.
fn RealMediaState::read_packets(self : RealMediaState) -> String {
  let io = self.io
  let mut old_seq = 1
  while true {
    if self.audio_pkt_cnt > 0 {
      // If there are queued audio packet return them first
      match self.retrieve_cache() {
        Ok(_) => ()
        Err(e) => return e
      }
    } else {
      let mut si = -1
      let mut len = 0L
      let mut timestamp = av_nopts_value
      let mut flags = 0
      let mut pos = -1L
      let seq : Ref[Int32] = Ref(1)
      if self.old_format {
        si = 0
        let st = self.streams[0]
        len = if st.audio_framesize == 0 {
          realmedia_raw_packet_size.to_int64()
        } else {
          st.coded_framesize.to_int64() * st.sub_packet_h.to_int64() / 2L
        }
        if len > 2147483647L {
          return "realmedia: invalid packet length"
        }
        flags = if old_seq == 1 { 2 } else { 0 }
        old_seq += 1
        pos = io.pos.to_int64()
      } else {
        let (l, ts, fl, i, p) = match self.sync() {
          Ok(v) => v
          Err(e) => return e
        }
        len = l
        timestamp = ts
        flags = fl
        pos = p
        if len > 0L {
          si = i
        }
      }
      if io.eof {
        return ""
      }
      if len <= 0L {
        return "realmedia: invalid data"
      }
      let res = match self.parse_packet(si, len, seq, flags, timestamp) {
        Ok(v) => v
        Err(e) => return e
      }
      if (flags & 2) != 0 &&
        (seq.val & 0x7F) == 1 &&
        timestamp != av_nopts_value {
        self.index.push({ stream_index: si, timestamp, pos, })
      }
      if res != 0 {
        continue
      }
    }
  }
  abort("unreachable: the packet loop only leaves through return")
}
