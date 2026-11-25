///|
/// `AV_RL16`.
fn wmapro_rl16(data : Bytes, off : Int32) -> Int32 {
  data[off].to_int() | (data[off + 1].to_int() << 8)
}

///|
/// `AV_RL32`.
fn wmapro_rl32(data : Bytes, off : Int32) -> UInt32 {
  data[off].to_int().reinterpret_as_uint() |
  (data[off + 1].to_int().reinterpret_as_uint() << 8) |
  (data[off + 2].to_int().reinterpret_as_uint() << 16) |
  (data[off + 3].to_int().reinterpret_as_uint() << 24)
}

///|
/// `av_popcount`.
fn wmapro_popcount(v : UInt32) -> Int32 {
  let mut n = 0
  let mut x = v
  while x != 0U {
    n += (x & 1U).reinterpret_as_int()
    x = x >> 1
  }
  n
}

///|
/// `ff_wma_get_frame_len_bits(sample_rate, 3, decode_flags)`.
fn wmapro_frame_len_bits(sample_rate : Int32, decode_flags : Int32) -> Int32 {
  let mut bits = if sample_rate <= 16000 {
    9
  } else if sample_rate <= 22050 {
    10
  } else if sample_rate <= 48000 {
    11
  } else if sample_rate <= 96000 {
    12
  } else {
    13
  }
  let tmp = decode_flags & 0x6
  if tmp == 0x2 {
    bits += 1
  } else if tmp == 0x4 {
    bits -= 1
  } else if tmp == 0x6 {
    bits -= 2
  }
  bits
}

///|
/// Open the WMA Pro decoder (`decode_init` for `AV_CODEC_ID_WMAPRO`).
///
/// `extradata` is what the container hands over as the WAVEFORMATEX
/// extension (`cbSize` bytes, at least 18): the valid bits per sample at
/// offset 0, the channel mask at 2 and the decode flags at 14. `channels`
/// is the container's channel count, used when the mask is zero. A packet
/// holds `block_align` bytes.
pub fn wmapro_decoder_new(
  extradata : Bytes,
  sample_rate : Int32,
  channels : Int32,
  block_align : Int32,
) -> Result[WmaProDecoder, String] {
  if block_align <= 0 {
    return Err("wmapro: block_align is not set")
  }
  if extradata.length() < 18 {
    return Err("wmapro: unknown extradata size (18 bytes needed)")
  }
  if sample_rate <= 0 {
    return Err("wmapro: invalid sample rate \{sample_rate}")
  }
  let decode_flags = wmapro_rl16(extradata, 14)
  let channel_mask = wmapro_rl32(extradata, 2)
  let bits_per_sample = wmapro_rl16(extradata, 0)
  let nb_channels = if channel_mask != 0U {
    wmapro_popcount(channel_mask)
  } else {
    channels
  }
  if bits_per_sample > 32 || bits_per_sample < 1 {
    return Err("wmapro: bits per sample is \{bits_per_sample}")
  }
  let log2_frame_size = wma_log2(block_align) + 4
  if log2_frame_size > 25 {
    return Err("wmapro: large block align")
  }
  let len_prefix = (decode_flags & 0x40) != 0
  let bits = wmapro_frame_len_bits(sample_rate, decode_flags)
  if bits > wmapro_block_max_bits {
    return Err("wmapro: 14-bit block sizes are not supported")
  }
  let samples_per_frame = 1 << bits

  // subframe info
  let log2_max_num_subframes = (decode_flags >> 3) & 0x7
  let max_num_subframes = 1 << log2_max_num_subframes
  let max_subframe_len_bit = max_num_subframes == 16 || max_num_subframes == 4
  let subframe_len_bits = wma_log2(log2_max_num_subframes) + 1
  let num_possible_block_sizes = log2_max_num_subframes + 1
  let min_samples_per_subframe = samples_per_frame / max_num_subframes
  let dynamic_range_compression = (decode_flags & 0x80) != 0
  if max_num_subframes > wmapro_max_subframes {
    return Err("wmapro: invalid number of subframes \{max_num_subframes}")
  }
  if min_samples_per_subframe < wmapro_block_min_size() {
    return Err(
      "wmapro: min_samples_per_subframe of \{min_samples_per_subframe} too small",
    )
  }
  if nb_channels <= 0 {
    return Err("wmapro: invalid number of channels \{nb_channels}")
  } else if nb_channels > wmapro_max_channels || nb_channels > channels {
    return Err("wmapro: more than \{wmapro_max_channels} channels are not supported")
  }

  let channel : Array[WmaproChannel] = Array::makei(
    wmapro_max_channels,
    _ => WmaproChannel::new(),
  )

  // extract lfe channel position
  let mut lfe_channel = -1
  if (channel_mask & 8U) != 0U {
    let mut mask : UInt32 = 1U
    while mask < 16U {
      if (channel_mask & mask) != 0U {
        lfe_channel += 1
      }
      mask = mask << 1
    }
  }

  // number of scale factor bands and their offsets for every possible
  // block size
  let sfb_offsets : Array[FixedArray[Int32]] = Array::makei(
    wmapro_block_sizes,
    _ => FixedArray::makei(wmapro_max_bands, _ => 0),
  )
  let num_sfb = FixedArray::makei(wmapro_block_sizes, _ => 0)
  for i in 0..<num_possible_block_sizes {
    let subframe_len = samples_per_frame >> i
    let mut band = 1
    sfb_offsets[i][0] = 0
    let mut x = 0
    while x < wmapro_max_bands - 1 && sfb_offsets[i][band - 1] < subframe_len {
      let offset = ((subframe_len * 2 * wmapro_critical_freq[x]) / sample_rate + 2) &
        -4
      if offset > sfb_offsets[i][band - 1] {
        sfb_offsets[i][band] = offset
        band += 1
      }
      if offset >= subframe_len {
        break
      }
      x += 1
    }
    sfb_offsets[i][band - 1] = subframe_len
    num_sfb[i] = band - 1
    if num_sfb[i] <= 0 {
      return Err("wmapro: num_sfb invalid")
    }
  }

  // Scale factors can be shared between blocks of different size, as
  // every block size has its own scale factor band layout; `sf_offsets`
  // maps the band of one layout onto the other.
  let sf_offsets : Array[Array[FixedArray[Int32]]] = Array::makei(
    wmapro_block_sizes,
    _ => Array::makei(wmapro_block_sizes, _ => FixedArray::makei(wmapro_max_bands, _ => 0)),
  )
  for i in 0..<num_possible_block_sizes {
    for b in 0..<num_sfb[i] {
      let offset = ((sfb_offsets[i][b] + sfb_offsets[i][b + 1] - 1) << i) >> 1
      for x in 0..<num_possible_block_sizes {
        let mut v = 0
        while (sfb_offsets[x][v + 1] << x) < offset {
          v += 1
          if v + 1 >= wmapro_max_bands {
            return Err("wmapro: scale factor band table overflow")
          }
        }
        sf_offsets[i][x][b] = v
      }
    }
  }

  // MDCT scale per block size (`av_tx_init`'s `scale`): a power of two,
  // so the C's float holds it exactly.
  let tx_scale = FixedArray::makei(wmapro_block_sizes, i => {
    let shift = wmapro_block_min_bits + i - 1 + bits_per_sample - 1
    1.0 / (1L << shift).to_double()
  })
  let pi = 3.14159265358979323846

  // cosine table for the IMDCT: one period of pi / (4 * samples_per_frame)
  let imdct_cos = Array::make(8 * samples_per_frame, 0.0)
  let step = pi / (4.0 * samples_per_frame.to_double())
  for k in 0..<(8 * samples_per_frame) {
    imdct_cos[k] = @math.cos(k.to_double() * step)
  }

  // subwoofer cutoff values
  let subwoofer_cutoffs = FixedArray::makei(wmapro_block_sizes, _ => 0)
  for i in 0..<num_possible_block_sizes {
    let block_size = samples_per_frame >> i
    let cutoff = (440L * block_size.to_int64() +
      3L * (sample_rate >> 1).to_int64() -
      1L) /
      sample_rate.to_int64()
    let cut = cutoff.to_int()
    subwoofer_cutoffs[i] = if cut < 4 {
      4
    } else if cut > block_size {
      block_size
    } else {
      cut
    }
  }

  for i in 0..<nb_channels {
    channel[i].prev_block_len = samples_per_frame
  }

  let frame_data = Array::make(wmapro_max_framesize + 64, b'\x00')
  Ok({
    frame_data,
    pb_pos: 0,
    tx_scale,
    tmp: Array::make(wmapro_block_max_size, 0.0),
    frame_buf: Array::makei(
      wmapro_max_channels,
      _ => Array::make(samples_per_frame, 0.0),
    ),
    windows: wmapro_sine_windows(),
    imdct_cos,
    imdct_mask: 8 * samples_per_frame - 1,
    sample_rate,
    block_align,
    decode_flags,
    len_prefix,
    dynamic_range_compression,
    bits_per_sample,
    samples_per_frame,
    trim_start: 0,
    trim_end: 0,
    log2_frame_size,
    lfe_channel,
    max_num_subframes,
    subframe_len_bits,
    max_subframe_len_bit,
    min_samples_per_subframe,
    num_sfb,
    sfb_offsets,
    sf_offsets,
    subwoofer_cutoffs,
    pgb: WmaproBits::new([], 0),
    next_packet_start: 0,
    packet_offset: 0,
    packet_sequence_number: 0,
    num_saved_bits: 0,
    frame_offset: 0,
    packet_loss: true,
    packet_done: false,
    eof_done: false,
    gb: WmaproBits::new(frame_data, 0),
    buf_bit_size: 0,
    skip_frame: true,
    parsed_all_subframes: false,
    subframe_len: 0,
    nb_channels,
    channels_for_cur_subframe: 0,
    channel_indexes_for_cur_subframe: FixedArray::makei(
      wmapro_max_channels,
      _ => 0,
    ),
    num_bands: 0,
    transmit_num_vec_coeffs: false,
    table_idx: 0,
    esc_len: 0,
    num_chgroups: 0,
    chgroup: Array::makei(wmapro_max_channels, _ => WmaproChannelGrp::new()),
    channel,
    sf_vlc: wmapro_vlc_new(wmapro_scale_syms, wmapro_scale_lens, -60),
    sf_rl_vlc: wmapro_vlc_new(wmapro_scale_rl_syms, wmapro_scale_rl_lens, 0),
    coef_vlc: [
      wmapro_vlc_new(wmapro_coef0_syms, wmapro_coef0_lens, 0),
      wmapro_vlc_new(wmapro_coef1_syms, wmapro_coef1_lens, 0),
    ],
    vec4_vlc: wmapro_vlc_new(wmapro_vec4_syms, wmapro_vec4_lens, -1),
    vec2_vlc: wmapro_vlc_new(wmapro_vec2_syms, wmapro_vec2_lens, -1),
    vec1_vlc: wmapro_vlc_new(wmapro_vec1_syms, wmapro_vec1_lens, 0),
    sin64: Array::makei(33, i => @math.sin(i.to_double() * pi / 64.0)),
    last_error: "",
  })
}

///|
/// The decoder's channel count (the extradata's channel mask decides).
pub fn WmaProDecoder::channels(self : WmaProDecoder) -> Int32 {
  self.nb_channels
}

///|
/// Samples per decoded frame (`samples_per_frame`).
pub fn WmaProDecoder::samples_per_frame(self : WmaProDecoder) -> Int32 {
  self.samples_per_frame
}

///|
/// `block_align`: the packet size the bitstream is cut into.
pub fn WmaProDecoder::block_align(self : WmaProDecoder) -> Int32 {
  self.block_align
}

///|
/// The reason of the most recent dropped frame or packet ("" when none).
/// The C logs these and carries on; so does `decode_packet`.
pub fn WmaProDecoder::last_error(self : WmaProDecoder) -> String {
  self.last_error
}
