///|
/// WMA Pro packet decoding: the bit reservoir (`save_bits`) and the packet
/// state machine of `decode_packet`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.

// ---------------------------------------------------------------------------
// the bit reservoir
// ---------------------------------------------------------------------------

///|
fn wmapro_bit_at(src : Array[Byte], pos : Int32) -> Int32 {
  if pos >> 3 >= src.length() {
    0
  } else {
    (src[pos >> 3].to_int() >> (7 - (pos & 7))) & 1
  }
}

///|
fn wmapro_set_bit(dst : Array[Byte], pos : Int32, bit : Int32) -> Unit {
  let i = pos >> 3
  let mask = 1 << (7 - (pos & 7))
  dst[i] = if bit != 0 {
    (dst[i].to_int() | mask).to_byte()
  } else {
    (dst[i].to_int() & (-mask - 1)).to_byte()
  }
}

///|
/// `ff_copy_bits`: `len` bits of `src` from the byte boundary at `src_pos`
/// appended to the reservoir at bit position `dst_pos`.
fn wmapro_copy_bits(
  dst : Array[Byte],
  dst_pos : Int32,
  src : Array[Byte],
  src_pos : Int32,
  len : Int32,
) -> Unit {
  for i in 0..<len {
    wmapro_set_bit(dst, dst_pos + i, wmapro_bit_at(src, src_pos + i))
  }
}

///|
/// `save_bits`: move `len` bits of the packet reader into the bit reservoir.
/// `append` adds them to the frame in progress; otherwise the reservoir is
/// reset and the bits start a new frame.
fn WmaProDecoder::save_bits(self : WmaProDecoder, len0 : Int32, append : Bool) -> Unit {
  let mut len = len0

  // when the frame data does not need to be concatenated, the input buffer
  // is reset and additional bits from the previous frame are copied and
  // skipped later so that a fast byte copy is possible
  let buflen = if !append {
    self.frame_offset = self.pgb.index & 7
    self.num_saved_bits = self.frame_offset
    self.pb_pos = 0
    (self.num_saved_bits + len + 7) >> 3
  } else {
    (self.pb_pos + len + 7) >> 3
  }
  if len <= 0 || buflen > wmapro_max_framesize {
    self.last_error = "wmapro: too small input buffer"
    self.packet_loss = true
    return
  }
  self.num_saved_bits += len
  let src = self.pgb.bytes
  if !append {
    wmapro_copy_bits(
      self.frame_data,
      self.pb_pos,
      src,
      (self.pgb.index >> 3) << 3,
      self.num_saved_bits,
    )
    self.pb_pos += self.num_saved_bits
  } else {
    let mut align = 8 - (self.pgb.index & 7)
    if align > len {
      align = len
    }
    let head = self.pgb.read(align)
    for i in 0..<align {
      wmapro_set_bit(
        self.frame_data,
        self.pb_pos + i,
        ((head >> (align - 1 - i)) & 1U).reinterpret_as_int(),
      )
    }
    self.pb_pos += align
    len -= align
    wmapro_copy_bits(
      self.frame_data,
      self.pb_pos,
      src,
      (self.pgb.index >> 3) << 3,
      len,
    )
    self.pb_pos += len
  }
  self.pgb.skip_long(len)

  // `flush_put_bits` on a copy of the writer: the partial byte is padded
  // with zeros
  let flushed = (self.pb_pos + 7) & -8
  for b in self.pb_pos..<flushed {
    wmapro_set_bit(self.frame_data, b, 0)
  }
  self.gb = WmaproBits::new(self.frame_data, self.num_saved_bits)
  self.gb.skip(self.frame_offset)
}

// ---------------------------------------------------------------------------
// packets
// ---------------------------------------------------------------------------

///|
fn wmapro_packet_bytes(data : Bytes) -> Array[Byte] {
  Array::makei(data.length(), i => data[i])
}

///|
/// `remaining_bits` of the packet reader.
fn WmaProDecoder::packet_bits_left(self : WmaProDecoder) -> Int32 {
  self.buf_bit_size - self.pgb.count()
}

///|
/// `decode_packet` with `frame_buf` as the output frame: one decoder call
/// on `data` (empty: end of stream). Returns the bytes consumed, whether
/// the frame is to be output, and its range (`start`, `nb_samples`) after
/// the frame's trim.
///
/// What the C reports by its return value is kept apart the same way: a
/// lost packet comes back consumed without a frame (the C answers
/// `AVERROR_INVALIDDATA`, and its caller drops the rest of the packet),
/// while an unsupported feature is an `Err`.
fn WmaProDecoder::decode_packet_inner(
  self : WmaProDecoder,
  data : Bytes,
) -> Result[(Int32, Bool, Int32, Int32), WmaproErr] {
  let buf_size = data.length()
  let mut got_frame = false
  if buf_size == 0 {
    // Must output remaining samples after stream end.
    self.packet_done = false
    if self.eof_done {
      return Ok((0, false, 0, self.samples_per_frame))
    }

    // clean output buffer and copy last IMDCT samples
    let half = self.samples_per_frame >> 1
    for i in 0..<self.nb_channels {
      let out = self.channel[i].out
      let row = self.frame_buf[i]
      for k in 0..<half {
        row[k] = out[k]
      }
      for k in half..<self.samples_per_frame {
        row[k] = 0.0
      }
    }
    self.eof_done = true
    self.packet_done = true
    got_frame = true
  } else if self.packet_done || self.packet_loss {
    self.packet_done = false

    // sanity check for the buffer length
    if buf_size < self.block_align {
      self.last_error = "wmapro: input packet too small (\{buf_size} < \{self.block_align})"
      self.packet_loss = true
      return Ok((buf_size, false, 0, self.samples_per_frame))
    }
    self.next_packet_start = buf_size - self.block_align
    self.buf_bit_size = self.block_align << 3
    self.pgb = WmaproBits::new(wmapro_packet_bytes(data), self.block_align << 3)

    // parse packet header
    let packet_sequence_number = self.pgb.read(4).reinterpret_as_int()
    self.pgb.skip(2)

    // number of bits that need to be added to the previous frame
    let mut num_bits_prev_frame =
      self.pgb.read(self.log2_frame_size).reinterpret_as_int()

    // check for packet loss
    if !self.packet_loss &&
      ((self.packet_sequence_number + 1) & 0xF) != packet_sequence_number {
      self.last_error = "wmapro: packet loss detected! seq \{self.packet_sequence_number} vs \{packet_sequence_number}"
      self.packet_loss = true
    }
    self.packet_sequence_number = packet_sequence_number
    if num_bits_prev_frame > 0 {
      let remaining_packet_bits = self.buf_bit_size - self.pgb.count()
      if num_bits_prev_frame >= remaining_packet_bits {
        num_bits_prev_frame = remaining_packet_bits
        self.packet_done = true
      }

      // append the previous frame data to the remaining data from the
      // previous packet to create a full frame
      self.save_bits(num_bits_prev_frame, true)

      // decode the cross packet frame if it is valid
      if !self.packet_loss {
        match self.decode_frame(self.frame_buf) {
          Err(e) => return Err(e)
          Ok((got, _)) => got_frame = got
        }
      }
    }
    if self.packet_loss {
      // reset number of saved bits so that the decoder does not start to
      // decode incomplete frames in the len_prefix == 0 case
      self.num_saved_bits = 0
      self.packet_loss = false
    }
  } else {
    if buf_size < self.next_packet_start {
      self.last_error = "wmapro: packet shorter than the pending frame data"
      self.packet_loss = true
      return Ok((buf_size, false, 0, self.samples_per_frame))
    }
    self.buf_bit_size = (buf_size - self.next_packet_start) << 3
    self.pgb = WmaproBits::new(
      wmapro_packet_bytes(data),
      (buf_size - self.next_packet_start) << 3,
    )
    self.pgb.skip(self.packet_offset)
    if self.len_prefix && self.packet_bits_left() > self.log2_frame_size {
      let frame_size = self.pgb.show(self.log2_frame_size).reinterpret_as_int()
      if frame_size != 0 && frame_size <= self.packet_bits_left() {
        self.save_bits(frame_size, false)
        if !self.packet_loss {
          match self.decode_frame(self.frame_buf) {
            Err(e) => return Err(e)
            Ok((got, more)) => {
              got_frame = got
              self.packet_done = !more
            }
          }
        }
      } else {
        self.packet_done = true
      }
    } else if !self.len_prefix && self.num_saved_bits > self.gb.count() {
      // when the frames do not have a length prefix, we don't know the
      // compressed length of the individual frames; however, we know what
      // part of a new packet belongs to the previous frame, therefore we
      // save the incoming packet first, then we append the "previous
      // frame" data from the next packet so that we get a buffer that only
      // contains full frames
      let (got, more) = match self.decode_frame(self.frame_buf) {
        Err(e) => return Err(e)
        Ok(res) => res
      }
      got_frame = got
      self.packet_done = !more
    } else {
      self.packet_done = true
    }
  }
  if self.packet_bits_left() < 0 {
    self.last_error = "wmapro: overread \{-(self.packet_bits_left())}"
    self.packet_loss = true
  }
  if self.packet_done && !self.packet_loss && self.packet_bits_left() > 0 {
    // save the rest of the data so that it can be decoded with the next
    // packet
    self.save_bits(self.packet_bits_left(), false)
  }
  self.packet_offset = self.pgb.count() & 7
  if self.packet_loss {
    return Ok((buf_size, false, 0, self.samples_per_frame))
  }
  // The C returns the reader's position after the tail's `save_bits`, so
  // the leftover bits of an incomplete frame count as consumed.
  let consumed = if buf_size == 0 { 0 } else { self.pgb.count() >> 3 }
  let mut start = 0
  let mut nb_samples = self.samples_per_frame
  if self.trim_start != 0 {
    if self.trim_start < nb_samples {
      start = self.trim_start
      nb_samples -= self.trim_start
    } else {
      got_frame = false
    }
    self.trim_start = 0
  }
  if self.trim_end != 0 {
    if self.trim_end < nb_samples {
      nb_samples -= self.trim_end
    } else {
      got_frame = false
    }
    self.trim_end = 0
  }
  Ok((consumed, got_frame, start, nb_samples))
}

///|
/// Decode one step of a demuxer packet, which holds `block_align` bytes
/// (or less at the end of the file). Returns the bytes consumed and the
/// decoded frame, if any: `None` when the packet does not complete a
/// frame, when the first frame is skipped (its overlap-add has no
/// predecessor), or when a broken packet was dropped (`last_error` says
/// why). Call again with the rest of the packet while it returns a positive
/// count shorter than the input.
pub fn WmaProDecoder::decode_packet(
  self : WmaProDecoder,
  data : Bytes,
) -> Result[(Int32, Array[Array[Double]]?), String] {
  match self.decode_packet_inner(data) {
    Err(Unsupported(msg)) => Err(msg)
    Err(Broken(msg)) => {
      self.last_error = msg
      Ok((data.length(), None))
    }
    Ok((consumed, false, _, _)) => Ok((consumed, None))
    Ok((consumed, true, start, nb)) => {
      let rows = Array::makei(self.nb_channels, ch => {
        self.frame_buf[ch][start:start + nb].to_owned()
      })
      Ok((consumed, Some(rows)))
    }
  }
}

///|
/// The end of stream call (the C's empty packet): the second half of the
/// last overlap-add, zero padded to a frame, once.
pub fn WmaProDecoder::flush(
  self : WmaProDecoder,
) -> Result[Array[Array[Double]]?, String] {
  match self.decode_packet(b"") {
    Ok((_, frame)) => Ok(frame)
    Err(e) => Err(e)
  }
}
