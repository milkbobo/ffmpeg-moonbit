/// MoonBit port of FFmpeg 9.0.2 `libavcodec/mlpdec.c` (with `mlp.c`,
/// `mlp_parse.c` and `mlpdsp.c` folded in): the MLP (Meridian Lossless
/// Packing) and Dolby TrueHD decoder.
///
/// Scope: major-sync parsing (16-bit checksum), access-unit framing with up
/// to four substreams, restart headers, decoding parameters, the three
/// residual Huffman codebooks, FIR/IIR prediction, primitive matrices with
/// LSB bypass and 0x31eb noise injection, and the `ch_assign` /
/// `output_shift` packing stage producing interleaved S32 (24-bit streams)
/// or S16 output.
///
/// Original FFmpeg code is LGPL-2.1-or-later, Copyright (c) 2007-2008 Ian
/// Caulfield. This port keeps the same license.
///
/// Deviations, none observable in the decoded PCM: the checks upstream only
/// logs (restart-header checksum, per-substream parity/CRC-63 checksum, the
/// lossless-check byte) are not computed; the `downmix` AVOption and the
/// matrix-encoding side data are metadata-only and omitted. Channel masks
/// stay below bit 20, so layout masks use `Int32` instead of C's `uint64_t`.

///|
/// `MAX_CHANNELS`. */
let mlp_max_channels : Int32 = 8

///|
/// `MAX_SUBSTREAMS`. */
let mlp_max_substreams : Int32 = 4

///|
/// `MAX_MATRICES` (TrueHD limit; MLP uses 6). */
let mlp_max_matrices : Int32 = 8

///|
/// `MAX_MATRIX_CHANNEL_MLP` / `MAX_MATRIX_CHANNEL_TRUEHD`. */
let mlp_max_matrix_channel_mlp : Int32 = 5

///|
let mlp_max_matrix_channel_truehd : Int32 = 7

///|
/// `MAX_BLOCKSIZE` / `MAX_BLOCKSIZE_POW2` (rate factor 4). */
let mlp_max_blocksize : Int32 = 160

///|
let mlp_max_blocksize_pow2 : Int32 = 256

///|
/// `MAX_FIR_ORDER` / `MAX_IIR_ORDER`. */
let mlp_max_fir_order : Int32 = 8

///|
let mlp_max_iir_order : Int32 = 4

///|
/// `PARAM_*` decoding-parameter presence flags. */
let mlp_param_blocksize : Int32 = 128

///|
let mlp_param_matrix : Int32 = 64

///|
let mlp_param_outshift : Int32 = 32

///|
let mlp_param_quantstep : Int32 = 16

///|
let mlp_param_fir : Int32 = 8

///|
let mlp_param_iir : Int32 = 4

///|
let mlp_param_huffoffset : Int32 = 2

///|
let mlp_param_presence : Int32 = 1

///|
/// `ff_mlp_huffman_tables`: three codebooks of 18 `{ code, length }` codes
/// (the VLC symbol is the table index, i.e. the residual MSB value). */
let mlp_huffman_tables : Array[Array[(UInt32, Int32)]] = [
  // Huffman table 0, -7 - +10
  [
    (0x01U, 9),
    (0x01U, 8),
    (0x01U, 7),
    (0x01U, 6),
    (0x01U, 5),
    (0x01U, 4),
    (0x01U, 3),
    (0x04U, 3),
    (0x05U, 3),
    (0x06U, 3),
    (0x07U, 3),
    (0x03U, 3),
    (0x05U, 4),
    (0x09U, 5),
    (0x11U, 6),
    (0x21U, 7),
    (0x41U, 8),
    (0x81U, 9),
  ],
  // Huffman table 1, -7 - +8
  [
    (0x01U, 9),
    (0x01U, 8),
    (0x01U, 7),
    (0x01U, 6),
    (0x01U, 5),
    (0x01U, 4),
    (0x01U, 3),
    (0x02U, 2),
    (0x03U, 2),
    (0x03U, 3),
    (0x05U, 4),
    (0x09U, 5),
    (0x11U, 6),
    (0x21U, 7),
    (0x41U, 8),
    (0x81U, 9),
  ],
  // Huffman table 2, -7 - +7
  [
    (0x01U, 9),
    (0x01U, 8),
    (0x01U, 7),
    (0x01U, 6),
    (0x01U, 5),
    (0x01U, 4),
    (0x01U, 3),
    (0x01U, 1),
    (0x03U, 3),
    (0x05U, 4),
    (0x09U, 5),
    (0x11U, 6),
    (0x21U, 7),
    (0x41U, 8),
    (0x81U, 9),
  ],
]

///|
/// `mlp_quants`: bit depth per 4-bit quant field (0 = reserved). */
let mlp_parse_quants : Array[Int32] = [
  16, 20, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
]

///|
/// `mlp_layout`: MLP channel-layout mask per 5-bit arrangement, in the
/// AV_CH bit numbering of libavutil/channel_layout.h (FL=1, FR=2, FC=4,
/// LFE=8, BL=0x10, BR=0x20, BC=0x100). */
let mlp_parse_layouts : Array[Int32] = [
  0x4, 0x3, 0x103, 0x33, 0xB, 0x10B, 0x3B, 0x7, 0x107, 0x37, 0xF, 0x10F,
  0x3F, 0x107, 0x37, 0xF, 0x10F, 0x3F, 0x3B, 0x37, 0x3F, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0,
]

///|
/// `thd_chancount`: channel pairs/groups of the TrueHD 13-bit channel map. */
let mlp_thd_chancount : Array[Int32] = [
  2, 1, 1, 2, 2, 2, 2, 1, 1, 2, 2, 1, 1,
]

///|
/// `thd_layout`: layout mask per channel-map group. */
let mlp_thd_layout : Array[Int32] = [
  0x3, // LR
  0x4, // C
  0x8, // LFE
  0x600, // LRs
  0x5000, // LRvh
  0xC0, // LRc
  0x30, // LRrs
  0x100, // Cs
  0x800, // Ts
  0x60000, // LRsd
  0x18000, // LRw
  0x2000, // Cvh
  0x80000, // LFE2
]

///|
/// `thd_channel_order`: the AV_CH bit position of each entry of the decoder
/// channel order (FL, FR, C, LFE, LRs, LRvh, LRc, LRrs, Cs, Ts, LRsd, LRw,
/// Cvh, LFE2 interleaved as in `mlpdec.c`). */
let mlp_thd_order_bits : Array[Int32] = [
  0, 1, 2, 3, 9, 10, 12, 14, 6, 7, 4, 5, 8, 11, 17, 18, 15, 16, 13, 19,
]

///|
/// `AV_CH_LAYOUT_STEREO` etc. used by the substream mask logic. */
let mlp_layout_stereo : Int32 = 0x3

///|
let mlp_layout_mono : Int32 = 0x4

///|
let mlp_layout_quad_lfe : Int32 = 0x3B

///|
let mlp_layout_5p0_back : Int32 = 0x37

///|
let mlp_layout_5p1_back : Int32 = 0x3F

///|
/// `noise_table`: TrueHD 0x31eb noise generation table (int8 values). */
let mlp_noise_table : Array[Int32] = [
  30, 51, 22, 54, 3, 7, -4, 38, 14, 55, 46, 81, 22, 58, -3, 2, 52, 31, -7,
  51, 15, 44, 74, 30, 85, -17, 10, 33, 18, 80, 28, 62, 10, 32, 23, 69, 72,
  26, 35, 17, 73, 60, 8, 56, 2, 6, -2, -5, 51, 4, 11, 50, 66, 76, 21, 44, 33,
  47, 1, 26, 64, 48, 57, 40, 38, 16, -10, -28, 92, 22, -18, 29, -10, 5, -13,
  49, 19, 24, 70, 34, 61, 48, 30, 14, -6, 25, 58, 33, 42, 60, 67, 17, 54, 17,
  22, 30, 67, 44, -9, 50, -11, 43, 40, 32, 59, 82, 13, 49, -14, 55, 60, 36,
  48, 49, 31, 47, 15, 12, 4, 65, 1, 23, 29, 39, 45, -2, 84, 69, 0, 72, 37,
  57, 27, 41, -15, -16, 35, 31, 14, 61, 24, 0, 27, 24, 16, 41, 55, 34, 53, 9,
  56, 12, 25, 29, 53, 5, 20, -20, -8, 20, 13, 28, -3, 78, 38, 16, 11, 62, 46,
  29, 21, 24, 46, 65, 43, -23, 89, 18, 74, 21, 38, -12, 19, 12, -19, 8, 15,
  33, 4, 57, 9, -8, 36, 35, 26, 28, 7, 83, 63, 79, 75, 11, 3, 87, 37, 47, 34,
  40, 39, 19, 20, 42, 27, 34, 39, 77, 13, 42, 59, 64, 45, -1, 32, 37, 45, -5,
  53, -6, 7, 36, 50, 23, 6, 32, 9, -21, 18, 71, 27, 52, -25, 31, 35, 42, -1,
  68, 63, 52, 26, 43, 66, 37, 41, 25, 40, 70,
]

///|
fn mlp_rl16(b : Bytes, i : Int32) -> UInt32 {
  b[i].to_uint() | (b[i + 1].to_uint() << 8)
}

///|
fn mlp_rb32(b : Bytes, i : Int32) -> UInt32 {
  (b[i].to_uint() << 24) |
  (b[i + 1].to_uint() << 16) |
  (b[i + 2].to_uint() << 8) |
  b[i + 3].to_uint()
}

///|
/// `ff_mlp_calculate_parity`: XOR of all bytes. */
fn mlp_parity(b : Bytes) -> Int32 {
  let mut acc : Int32 = 0
  for i = 0; i < b.length(); i = i + 1 {
    acc = acc ^ b[i].to_uint().reinterpret_as_int()
  }
  acc
}

///|
/// `ff_mlp_checksum8` (CRC-63 based, init `0x3c`). */
fn mlp_checksum8(
  crc_63 : FixedArray[UInt32],
  buf : Bytes,
  size : Int32,
) -> Int32 {
  let crc = @libavutil.av_crc(crc_63, 0x3CU, buf[0:size - 1].to_owned())
  crc.reinterpret_as_int() ^ buf[size - 1].to_uint().reinterpret_as_int()
}

///|
/// `ff_mlp_checksum16` (CRC-2D based, little-endian tail). */
fn mlp_checksum16(
  crc_2d : FixedArray[UInt32],
  buf : Bytes,
  size : Int32,
) -> UInt32 {
  let crc = @libavutil.av_crc(crc_2d, 0U, buf[0:size - 2].to_owned())
  crc ^ mlp_rl16(buf, size - 2)
}

///|
/// `popcount` over a layout mask. */
fn mlp_popcount(mask : Int32) -> Int32 {
  let mut n = 0
  let mut m = mask
  while m != 0 {
    m = m & (m - 1)
    n += 1
  }
  n
}

///|
/// `thd_channel_layout_extract_channel`: the `index`-th set bit of `mask` in
/// the decoder channel order, or -1 when out of range. */
fn mlp_thd_extract_channel(mask : Int32, index : Int32) -> Int32 {
  if mlp_popcount(mask) <= index {
    return -1
  }
  let mut idx = index
  for k = 0; k < mlp_thd_order_bits.length(); k = k + 1 {
    let bit = mlp_thd_order_bits[k]
    if (mask & (1 << bit)) != 0 {
      if idx == 0 {
        return bit
      }
      idx -= 1
    }
  }
  -1
}

///|
/// `av_channel_layout_index_from_channel` for a native mask layout: the
/// number of layout channels with a smaller bit position. */
fn mlp_layout_index(mask : Int32, bitpos : Int32) -> Int32 {
  let mut cnt = 0
  for b = 0; b < bitpos; b = b + 1 {
    if (mask & (1 << b)) != 0 {
      cnt += 1
    }
  }
  cnt
}

///|
/// `mlp_samplerate` from the 4-bit rate field. */
fn mlp_samplerate(bits : Int32) -> Int32 {
  if bits == 0xF {
    return 0
  }
  (if (bits & 8) != 0 { 44100 } else { 48000 }) << (bits & 7)
}

///|
/// `truehd_channels`: channel count of a 13-bit TrueHD channel map. */
fn mlp_truehd_channels(chanmap : Int32) -> Int32 {
  let mut channels = 0
  for i = 0; i < 13; i = i + 1 {
    channels += mlp_thd_chancount[i] * ((chanmap >> i) & 1)
  }
  channels
}

///|
/// `truehd_layout`: layout mask of a 13-bit TrueHD channel map. */
fn mlp_truehd_layout(chanmap : Int32) -> Int32 {
  let mut layout = 0
  for i = 0; i < 13; i = i + 1 {
    if ((chanmap >> i) & 1) != 0 {
      layout = layout | mlp_thd_layout[i]
    }
  }
  layout
}

///|
/// `get_sbits`: `n` bits MSB-first, sign-extended. */
fn mlp_sbits(gb : BitReader, n : Int32) -> Int32 {
  let v = gb.read(n).reinterpret_as_int()
  if n > 0 && (v & (1 << (n - 1))) != 0 {
    v - (1 << n)
  } else {
    v
  }
}

///|
/// `get_vlc2` on one residual codebook: match the peeked bits against the 18
/// prefix codes and consume the winning code's length. Returns -1 when no
/// code matches (upstream's invalid-VLC error). */
fn mlp_huff_decode(gb : BitReader, book : Array[(UInt32, Int32)]) -> Int32 {
  let peek = gb.show(9)
  // The codebooks hold 18 / 16 / 15 codes; upstream zero-pads to 18.
  for i = 0; i < book.length(); i = i + 1 {
    let (code, len) = book[i]
    if (peek >> (9 - len)) == code {
      gb.skip(len)
      return i
    }
  }
  -1
}

///|
/// One prediction filter (`FilterParams`); `state` holds the most recent
/// outputs, newest first. */
pub struct MlpFilterParams {
  mut order : Int32
  mut shift : Int32
  state : FixedArray[Int32]
}

///|
fn mlp_filter_new() -> MlpFilterParams {
  { order: 0, shift: 0, state: FixedArray::make(mlp_max_fir_order, 0) }
}

///|
/// `ChannelParams` of one coded channel; `coeff` is `[FIR × 8][IIR × 8]`. */
pub struct MlpChannelParams {
  fir : MlpFilterParams
  iir : MlpFilterParams
  coeff : FixedArray[Int32]
  mut huff_offset : Int32
  mut sign_huff_offset : Int32
  mut codebook : Int32
  mut huff_lsbs : Int32
}

///|
fn mlp_channel_new() -> MlpChannelParams {
  {
    fir: mlp_filter_new(),
    iir: mlp_filter_new(),
    coeff: FixedArray::make(2 * mlp_max_fir_order, 0),
    huff_offset: 0,
    sign_huff_offset: 0,
    codebook: 0,
    huff_lsbs: 0,
  }
}

///|
/// `SubStream` decoding state. */
pub struct MlpSubStream {
  mut restart_seen : Bool
  mut end_of_stream : Bool
  mut noise_type : Int32 // 1 when the restart sync word is 0x31eb
  mut min_channel : Int32
  mut max_channel : Int32
  mut coded_channels : Int32
  mut max_matrix_channel : Int32
  ch_assign : FixedArray[Int32]
  mut mask : Int32
  channel_params : Array[MlpChannelParams]
  mut noise_shift : Int32
  mut noisegen_seed : UInt32
  mut data_check_present : Bool
  mut param_presence_flags : Int32
  mut num_primitive_matrices : Int32
  matrix_out_ch : FixedArray[Int32]
  lsb_bypass : FixedArray[Int32]
  matrix_coeff : FixedArray[Int32] // [matrix × 8][channel]
  matrix_noise_shift : FixedArray[Int32]
  quant_step_size : FixedArray[Int32]
  mut blocksize : Int32
  mut blockpos : Int32
  output_shift : FixedArray[Int32]
  mut lossless_check_data : Int32
}

///|
fn mlp_substream_new() -> MlpSubStream {
  let params : Array[MlpChannelParams] = []
  for i = 0; i < mlp_max_channels; i = i + 1 {
    params.push(mlp_channel_new())
  }
  {
    restart_seen: false,
    end_of_stream: false,
    noise_type: 0,
    min_channel: 0,
    max_channel: 0,
    coded_channels: 0,
    max_matrix_channel: 0,
    ch_assign: FixedArray::make(mlp_max_channels, 0),
    mask: 0,
    channel_params: params,
    noise_shift: 0,
    noisegen_seed: 0U,
    data_check_present: false,
    param_presence_flags: 0xFF,
    num_primitive_matrices: 0,
    matrix_out_ch: FixedArray::make(mlp_max_matrices, 0),
    lsb_bypass: FixedArray::make(mlp_max_matrices, 0),
    matrix_coeff: FixedArray::make(mlp_max_matrices * mlp_max_channels, 0),
    matrix_noise_shift: FixedArray::make(mlp_max_matrices, 0),
    quant_step_size: FixedArray::make(mlp_max_channels, 0),
    blocksize: 0,
    blockpos: 0,
    output_shift: FixedArray::make(mlp_max_channels, 0),
    lossless_check_data: -1,
  }
}

///|
/// One decoded access unit: interleaved samples plus the stream parameters
/// in effect. 24/20-bit streams hold their samples left-justified in the
/// `Int32`s (FFmpeg's `AV_SAMPLE_FMT_S32`); 16-bit streams hold S16 values. */
pub struct MlpAudio {
  sample_rate : Int32
  channels : Int32
  bits : Int32
  samples : Array[Int32]
}

///|
/// Interleaved PCM bytes matching FFmpeg's output format: S16LE for 16-bit
/// streams, left-justified S32LE for 20/24-bit streams. */
pub fn MlpAudio::pcm_bytes(self : MlpAudio) -> Bytes {
  let out : Array[Byte] = []
  let wide = self.bits > 16
  for v in self.samples {
    out.push((v & 0xFF).to_byte())
    out.push(((v >> 8) & 0xFF).to_byte())
    if wide {
      out.push(((v >> 16) & 0xFF).to_byte())
      out.push(((v >> 24) & 0xFF).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
/// The MLP / TrueHD decoder. Construct with `MlpDecoder::new(truehd = ...)`
/// — the two codec ids differ in substream limits, `ch_assign` remapping and
/// a few validations. */
pub struct MlpDecoder {
  truehd : Bool
  crc_63 : FixedArray[UInt32]
  crc_2d : FixedArray[UInt32]
  mut major_sync_header_size : Int32
  mut params_valid : Bool
  mut num_substreams : Int32
  mut extended_substream_info : Int32
  mut substream_info : Int32
  mut max_decoded_substream : Int32
  mut needs_reordering : Bool
  mut access_unit_size : Int32
  mut access_unit_size_pow2 : Int32
  mut sample_rate : Int32
  mut bits : Int32
  mut channels : Int32
  substream : Array[MlpSubStream]
  mut cur_substr : Int32 // the substream whose parameters are being read
  mut matrix_changed : Int32
  filter_changed : FixedArray[Int32] // [channel × 2][filter]
  noise_buffer : FixedArray[Int32]
  bypassed_lsbs : FixedArray[Int32] // [sample × 8][matrix]
  sample_buffer : FixedArray[Int32] // [sample × 8][channel]
}

///|
pub fn MlpDecoder::new(truehd : Bool) -> MlpDecoder {
  let crc_63 = match @libavutil.av_crc_init(false, 8, 0x63U) {
    Ok(t) => t
    Err(e) => abort("mlp: crc_63 init: \{e}")
  }
  let crc_2d = match @libavutil.av_crc_init(false, 16, 0x2DU) {
    Ok(t) => t
    Err(e) => abort("mlp: crc_2d init: \{e}")
  }
  let subs : Array[MlpSubStream] = []
  for i = 0; i < mlp_max_substreams; i = i + 1 {
    subs.push(mlp_substream_new())
  }
  {
    truehd,
    crc_63,
    crc_2d,
    major_sync_header_size: 0,
    params_valid: false,
    num_substreams: 0,
    extended_substream_info: 0,
    substream_info: 0,
    max_decoded_substream: 0,
    needs_reordering: false,
    access_unit_size: 0,
    access_unit_size_pow2: 0,
    sample_rate: 0,
    bits: 0,
    channels: 0,
    substream: subs,
    cur_substr: 0,
    matrix_changed: 0,
    filter_changed: FixedArray::make(mlp_max_channels * 2, 0),
    noise_buffer: FixedArray::make(mlp_max_blocksize_pow2, 0),
    bypassed_lsbs: FixedArray::make(
      mlp_max_blocksize * mlp_max_channels,
      0,
    ),
    sample_buffer: FixedArray::make(
      mlp_max_blocksize * mlp_max_channels,
      0,
    ),
  }
}

///|
/// Set the per-substream output layout masks after a major sync, mirroring
/// the MLP/TrueHD branches of `read_major_sync`. */
fn MlpDecoder::assign_masks(
  self : MlpDecoder,
  num_substreams : Int32,
  layout_mlp : Int32,
  channels_thd1 : Int32,
  channels_thd2 : Int32,
  layout_thd1 : Int32,
  layout_thd2 : Int32,
) -> Unit {
  if !self.truehd {
    let substr : Int32 = if num_substreams > 1 { 1 } else { 0 }
    if num_substreams > 1 {
      self.substream[0].mask = mlp_layout_stereo
    }
    self.substream[substr].mask = layout_mlp
  } else {
    self.substream[1].mask = layout_thd1
    if channels_thd1 == 2 && channels_thd2 == 2 {
      self.substream[0].mask = mlp_layout_stereo
    }
    if num_substreams > 1 {
      self.substream[0].mask = mlp_layout_stereo
    }
    if num_substreams == 1 && channels_thd1 == 1 && channels_thd2 == 1 {
      self.substream[0].mask = mlp_layout_mono
    }
    if num_substreams > 2 {
      self.substream[2].mask = if layout_thd2 != 0 {
        layout_thd2
      } else {
        layout_thd1
      }
    }
    if num_substreams == 2 {
      self.substream[1].mask = layout_thd2
    }
  }
}

///|
/// `mlp_get_major_sync_size`: 28 bytes plus the optional extension words. */
fn mlp_major_sync_size(buf : Bytes, bufsize : Int32) -> Int32 {
  if bufsize < 28 {
    return -1
  }
  let mut size = 28
  if mlp_rb32(buf, 0) == 0xF8726FBAU {
    if (buf[25].to_uint().reinterpret_as_int() & 1) != 0 {
      let extensions = buf[26].to_uint().reinterpret_as_int() >> 4
      size += 2 + extensions * 2
    }
  }
  size
}

///|
/// `ff_mlp_read_major_sync` + the `read_major_sync` validations and state
/// updates. `payload` is the access unit from byte 4 on; `gb` reads it. */
fn MlpDecoder::read_major_sync(
  self : MlpDecoder,
  payload : Bytes,
  gb : BitReader,
) -> Result[Unit, String] {
  let size_bits = payload.length() * 8
  let header_size = mlp_major_sync_size(payload, payload.length())
  if header_size < 0 || size_bits < header_size * 8 {
    return Err("mlp: packet too short, unable to read major sync")
  }
  if mlp_checksum16(self.crc_2d, payload, header_size - 2) != mlp_rl16(
      payload,
      header_size - 2,
    ) {
    return Err("mlp: major sync info header checksum error")
  }
  if gb.read(24) != 0xF8726FU {
    return Err("mlp: bad sync words")
  }
  let stream_type = gb.read(8).reinterpret_as_int()
  if !self.truehd && stream_type != 0xBB {
    return Err("mlp: unexpected stream type \{stream_type} in MLP")
  }
  if self.truehd && stream_type != 0xBA {
    return Err("mlp: unexpected stream type \{stream_type} in !MLP")
  }
  let parsed : (
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
    Int32,
  ) = if stream_type == 0xBB {
    let g1 = mlp_parse_quants[gb.read(4).reinterpret_as_int()]
    let g2 = mlp_parse_quants[gb.read(4).reinterpret_as_int()]
    let rb = gb.read(4).reinterpret_as_int()
    let g2r = mlp_samplerate(gb.read(4).reinterpret_as_int())
    gb.skip(11)
    let arr = gb.read(5).reinterpret_as_int()
    (g1, g2, rb, g2r, arr, 0, 0, 0, 0)
  } else {
    let rb = gb.read(4).reinterpret_as_int()
    gb.skip(4)
    // channel modifiers — metadata only
    gb.skip(2)
    gb.skip(2)
    let arrangement1 = gb.read(5).reinterpret_as_int()
    let ch1 = mlp_truehd_channels(arrangement1)
    let l1 = mlp_truehd_layout(arrangement1)
    gb.skip(2)
    let arrangement2 = gb.read(13).reinterpret_as_int()
    let ch2 = mlp_truehd_channels(arrangement2)
    let l2 = mlp_truehd_layout(arrangement2)
    (24, 0, rb, 0, 0, ch1, ch2, l1, l2)
  }
  let (
    group1_bits,
    group2_bits,
    ratebits,
    group2_samplerate,
    channel_arrangement_mlp,
    channels_thd1,
    channels_thd2,
    layout_thd1,
    layout_thd2,
  ) = parsed
  let group1_samplerate = mlp_samplerate(ratebits)
  let access_unit_size = 40 << (ratebits & 7)
  let access_unit_size_pow2 = 64 << (ratebits & 7)
  gb.skip(48) // timestamp
  gb.skip(1) // is_vbr
  gb.skip(15) // peak bitrate
  let num_substreams = gb.read(4).reinterpret_as_int()
  gb.skip(2)
  self.extended_substream_info = gb.read(2).reinterpret_as_int()
  self.substream_info = gb.read(8).reinterpret_as_int()
  gb.skip((header_size - 18) * 8)
  // Validations from mlpdec.c read_major_sync
  if group1_bits == 0 {
    return Err("mlp: invalid/unknown bits per sample")
  }
  if group2_bits > group1_bits {
    return Err("mlp: channel group 2 cannot have more bits than group 1")
  }
  if group2_samplerate != 0 && group2_samplerate != group1_samplerate {
    return Err("mlp: channel groups with differing sample rates")
  }
  if group1_samplerate == 0 {
    return Err("mlp: invalid/unknown sampling rate")
  }
  if group1_samplerate > 192000 {
    return Err("mlp: sampling rate too high")
  }
  if access_unit_size > mlp_max_blocksize {
    return Err("mlp: block size too large")
  }
  if access_unit_size_pow2 > mlp_max_blocksize_pow2 {
    return Err("mlp: block size pow2 too large")
  }
  if num_substreams == 0 {
    return Err("mlp: zero substreams")
  }
  if !self.truehd && num_substreams > 2 {
    return Err("mlp: MLP only supports up to 2 substreams")
  }
  if num_substreams > mlp_max_substreams {
    return Err("mlp: too many substreams (\{num_substreams})")
  }
  self.major_sync_header_size = header_size
  self.access_unit_size = access_unit_size
  self.access_unit_size_pow2 = access_unit_size_pow2
  self.num_substreams = num_substreams
  self.max_decoded_substream = if num_substreams - 1 < 2 {
    num_substreams - 1
  } else {
    2
  }
  self.sample_rate = group1_samplerate
  self.bits = group1_bits
  self.params_valid = true
  for i = 0; i < mlp_max_substreams; i = i + 1 {
    self.substream[i].restart_seen = false
  }
  self.assign_masks(
    num_substreams,
    mlp_parse_layouts[channel_arrangement_mlp],
    channels_thd1,
    channels_thd2,
    layout_thd1,
    layout_thd2,
  )
  self.needs_reordering = channel_arrangement_mlp >= 18 &&
    channel_arrangement_mlp <= 20
  Ok(())
}

///|
/// `read_restart_header`. The restart checksum in the C only logs, so it is
/// not computed (its byte is still consumed). */
fn MlpDecoder::read_restart_header(
  self : MlpDecoder,
  gb : BitReader,
  substr : Int32,
) -> Result[Unit, String] {
  let s = self.substream[substr]
  let sync_word = gb.read(13).reinterpret_as_int()
  if sync_word != (0x31EA >> 1) {
    return Err("mlp: restart header sync incorrect")
  }
  let noise_type = gb.read1().reinterpret_as_int()
  if !self.truehd && noise_type != 0 {
    return Err("mlp: MLP must have 0x31ea sync word")
  }
  gb.skip(16) // output timestamp
  let min_channel = gb.read(4).reinterpret_as_int()
  let max_channel = gb.read(4).reinterpret_as_int()
  let max_matrix_channel = gb.read(4).reinterpret_as_int()
  let std_max = if self.truehd {
    mlp_max_matrix_channel_truehd
  } else {
    mlp_max_matrix_channel_mlp
  }
  if max_matrix_channel > std_max {
    return Err("mlp: max matrix channel too large")
  }
  if max_matrix_channel > mlp_max_matrix_channel_mlp && noise_type == 0 {
    return Err("mlp: unsupported channel count")
  }
  if max_channel + 1 > mlp_max_channels || max_channel + 1 < min_channel {
    return Err("mlp: invalid channel range")
  }
  s.min_channel = min_channel
  s.max_channel = max_channel
  s.coded_channels = ((1 << (max_channel - min_channel + 1)) - 1) << min_channel
  s.max_matrix_channel = max_matrix_channel
  s.noise_type = noise_type
  s.noise_shift = gb.read(4).reinterpret_as_int()
  s.noisegen_seed = gb.read(23)
  gb.skip(19)
  s.data_check_present = gb.read1() != 0
  let _lossless_check = gb.read(8) // compared by a log-only check upstream
  gb.skip(16)
  for i = 0; i < mlp_max_channels; i = i + 1 {
    s.ch_assign[i] = 0
  }
  for ch = 0; ch <= max_matrix_channel; ch = ch + 1 {
    let mut assign = gb.read(6).reinterpret_as_int()
    if self.truehd {
      let chan_bit = mlp_thd_extract_channel(s.mask, assign)
      assign = if chan_bit < 0 {
        -1
      } else {
        mlp_layout_index(s.mask, chan_bit)
      }
    }
    if assign < 0 || assign > max_matrix_channel {
      return Err("mlp: invalid output channel assignment")
    }
    s.ch_assign[assign] = ch
  }
  // The restart-header checksum mismatch only logs upstream.
  ignore(gb.read(8))
  // Default decoding parameters.
  s.param_presence_flags = 0xFF
  s.num_primitive_matrices = 0
  s.blocksize = 8
  s.lossless_check_data = 0
  for i = 0; i < mlp_max_channels; i = i + 1 {
    s.output_shift[i] = 0
    s.quant_step_size[i] = 0
  }
  for ch = min_channel; ch <= max_channel; ch = ch + 1 {
    let cp = s.channel_params[ch]
    cp.fir.order = 0
    cp.iir.order = 0
    cp.fir.shift = 0
    cp.iir.shift = 0
    cp.huff_offset = 0
    cp.sign_huff_offset = -(1 << 23)
    cp.codebook = 0
    cp.huff_lsbs = 24
  }
  if substr == self.max_decoded_substream {
    self.channels = mlp_popcount(s.mask)
    if !self.truehd && self.needs_reordering {
      if s.mask == mlp_layout_quad_lfe || s.mask == mlp_layout_5p0_back {
        let i0 = s.ch_assign[4]
        s.ch_assign[4] = s.ch_assign[3]
        s.ch_assign[3] = s.ch_assign[2]
        s.ch_assign[2] = i0
      } else if s.mask == mlp_layout_5p1_back {
        let t2 = s.ch_assign[2]
        s.ch_assign[2] = s.ch_assign[4]
        s.ch_assign[4] = t2
        let t3 = s.ch_assign[3]
        s.ch_assign[3] = s.ch_assign[5]
        s.ch_assign[5] = t3
      }
    }
  }
  Ok(())
}

///|
/// `read_filter_params`. `filter` 0 = FIR, 1 = IIR. */
fn MlpDecoder::read_filter_params(
  self : MlpDecoder,
  gb : BitReader,
  channel : Int32,
  filter : Int32,
) -> Result[Unit, String] {
  let s = self.substream[self.cur_substr]
  let cp = s.channel_params[channel]
  let fp = if filter == 0 { cp.fir } else { cp.iir }
  let max_order = if filter != 0 {
    mlp_max_iir_order
  } else {
    mlp_max_fir_order
  }
  let changed = self.filter_changed[channel * 2 + filter]
  self.filter_changed[channel * 2 + filter] = changed + 1
  if changed > 1 {
    return Err("mlp: filters may change only once per access unit")
  }
  let order = gb.read(4).reinterpret_as_int()
  if order > max_order {
    return Err("mlp: filter order too high")
  }
  fp.order = order
  if order > 0 {
    fp.shift = gb.read(4).reinterpret_as_int()
    let coeff_bits = gb.read(5).reinterpret_as_int()
    let coeff_shift = gb.read(3).reinterpret_as_int()
    if coeff_bits < 1 || coeff_bits > 16 {
      return Err("mlp: filter coeff_bits out of range")
    }
    if coeff_bits + coeff_shift > 16 {
      return Err("mlp: coeff_bits + coeff_shift too high")
    }
    for i = 0; i < order; i = i + 1 {
      cp.coeff[filter * mlp_max_fir_order + i] = mlp_sbits(
        gb,
        coeff_bits,
      ) * (1 << coeff_shift)
    }
    if gb.read1() != 0 {
      if filter == 0 {
        return Err("mlp: FIR filter has state data specified")
      }
      let state_bits = gb.read(4).reinterpret_as_int()
      let state_shift = gb.read(4).reinterpret_as_int()
      for i = 0; i < order; i = i + 1 {
        fp.state[i] = if state_bits != 0 {
          mlp_sbits(gb, state_bits) * (1 << state_shift)
        } else {
          0
        }
      }
    }
  }
  Ok(())
}

///|
/// `read_matrix_params`. */
fn MlpDecoder::read_matrix_params(
  self : MlpDecoder,
  gb : BitReader,
) -> Result[Unit, String] {
  let s = self.substream[self.cur_substr]
  let max_primitive_matrices = if self.truehd {
    mlp_max_matrices
  } else {
    6
  }
  let changed = self.matrix_changed
  self.matrix_changed = changed + 1
  if changed > 1 {
    return Err("mlp: matrices may change only once per access unit")
  }
  s.num_primitive_matrices = gb.read(4).reinterpret_as_int()
  if s.num_primitive_matrices > max_primitive_matrices {
    s.num_primitive_matrices = 0
    for i = 0; i < mlp_max_matrices; i = i + 1 {
      s.matrix_out_ch[i] = 0
    }
    return Err("mlp: too many primitive matrices")
  }
  for mat = 0; mat < s.num_primitive_matrices; mat = mat + 1 {
    s.matrix_out_ch[mat] = gb.read(4).reinterpret_as_int()
    let frac_bits = gb.read(4).reinterpret_as_int()
    s.lsb_bypass[mat] = gb.read1().reinterpret_as_int()
    if s.matrix_out_ch[mat] > s.max_matrix_channel {
      s.num_primitive_matrices = 0
      for i = 0; i < mlp_max_matrices; i = i + 1 {
        s.matrix_out_ch[i] = 0
      }
      return Err("mlp: invalid matrix output channel")
    }
    if frac_bits > 14 {
      s.num_primitive_matrices = 0
      for i = 0; i < mlp_max_matrices; i = i + 1 {
        s.matrix_out_ch[i] = 0
      }
      return Err("mlp: too many fractional bits")
    }
    let mut max_chan = s.max_matrix_channel
    if s.noise_type == 0 {
      max_chan += 2
    }
    for ch = 0; ch <= max_chan; ch = ch + 1 {
      let mut coeff_val = 0
      if gb.read1() != 0 {
        coeff_val = mlp_sbits(gb, frac_bits + 2)
      }
      s.matrix_coeff[mat * mlp_max_channels + ch] = coeff_val * (1 << (14 - frac_bits))
    }
    if s.noise_type != 0 {
      s.matrix_noise_shift[mat] = gb.read(4).reinterpret_as_int()
    } else {
      s.matrix_noise_shift[mat] = 0
    }
  }
  Ok(())
}

///|
/// `read_channel_params`. */
fn MlpDecoder::read_channel_params(
  self : MlpDecoder,
  gb : BitReader,
  ch : Int32,
) -> Result[Unit, String] {
  let s = self.substream[self.cur_substr]
  let cp = s.channel_params[ch]
  let fir = cp.fir
  let iir = cp.iir
  if (s.param_presence_flags & mlp_param_fir) != 0 {
    if gb.read1() != 0 {
      match self.read_filter_params(gb, ch, 0) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  if (s.param_presence_flags & mlp_param_iir) != 0 {
    if gb.read1() != 0 {
      match self.read_filter_params(gb, ch, 1) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  if fir.order + iir.order > 8 {
    return Err("mlp: total filter orders too high")
  }
  if fir.order > 0 && iir.order > 0 && fir.shift != iir.shift {
    return Err("mlp: FIR and IIR filters must use the same precision")
  }
  if fir.order == 0 && iir.order > 0 {
    fir.shift = iir.shift
  }
  if (s.param_presence_flags & mlp_param_huffoffset) != 0 {
    if gb.read1() != 0 {
      cp.huff_offset = mlp_sbits(gb, 15)
    }
  }
  cp.codebook = gb.read(2).reinterpret_as_int()
  cp.huff_lsbs = gb.read(5).reinterpret_as_int()
  if cp.codebook > 0 && cp.huff_lsbs > 24 {
    cp.huff_lsbs = 0
    return Err("mlp: invalid huff_lsbs")
  }
  Ok(())
}

///|
/// `calculate_sign_huff`. */
fn MlpDecoder::calculate_sign_huff(
  self : MlpDecoder,
  substr : Int32,
  ch : Int32,
) -> Int32 {
  let s = self.substream[substr]
  let cp = s.channel_params[ch]
  let lsb_bits = cp.huff_lsbs - s.quant_step_size[ch]
  let sign_shift = lsb_bits + (if cp.codebook > 0 {
    2 - cp.codebook
  } else {
    -1
  })
  let mut sign_huff_offset = cp.huff_offset
  if cp.codebook > 0 {
    sign_huff_offset -= 7 << lsb_bits
  }
  if sign_shift >= 0 {
    sign_huff_offset -= 1 << sign_shift
  }
  sign_huff_offset
}

///|
/// `read_decoding_params`, including the always-run `sign_huff_offset`
/// recomputation of the `fail:` label. */
fn MlpDecoder::read_decoding_params(
  self : MlpDecoder,
  gb : BitReader,
  substr : Int32,
) -> Result[Unit, String] {
  let s = self.substream[substr]
  let mut ret : Result[Unit, String] = Ok(())
  let mut recompute_sho = 0
  if (s.param_presence_flags & mlp_param_presence) != 0 {
    if gb.read1() != 0 {
      s.param_presence_flags = gb.read(8).reinterpret_as_int()
    }
  }
  if (s.param_presence_flags & mlp_param_blocksize) != 0 {
    if gb.read1() != 0 {
      s.blocksize = gb.read(9).reinterpret_as_int()
      if s.blocksize < 8 || s.blocksize > self.access_unit_size {
        s.blocksize = 0
        return Err("mlp: invalid blocksize")
      }
    }
  }
  if (s.param_presence_flags & mlp_param_matrix) != 0 {
    if gb.read1() != 0 {
      match self.read_matrix_params(gb) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  if (s.param_presence_flags & mlp_param_outshift) != 0 {
    if gb.read1() != 0 {
      for ch = 0; ch <= s.max_matrix_channel; ch = ch + 1 {
        let mut shift = mlp_sbits(gb, 4)
        if shift < 0 {
          shift = 0
        }
        s.output_shift[ch] = shift
      }
    }
  }
  if (s.param_presence_flags & mlp_param_quantstep) != 0 {
    if gb.read1() != 0 {
      for ch = 0; ch <= s.max_channel; ch = ch + 1 {
        s.quant_step_size[ch] = gb.read(4).reinterpret_as_int()
        recompute_sho = recompute_sho | (1 << ch)
      }
    }
  }
  for ch = s.min_channel; ch <= s.max_channel; ch = ch + 1 {
    if gb.read1() != 0 {
      recompute_sho = recompute_sho | (1 << ch)
      match self.read_channel_params(gb, ch) {
        Ok(_) => ()
        Err(e) => {
          ret = Err(e)
          break
        }
      }
    }
  }
  // fail:
  for ch = 0; ch <= s.max_channel; ch = ch + 1 {
    if (recompute_sho & (1 << ch)) != 0 {
      let cp = s.channel_params[ch]
      if cp.codebook > 0 && cp.huff_lsbs < s.quant_step_size[ch] {
        let had_err = match ret {
          Ok(_) => false
          Err(_) => true
        }
        if !had_err {
          ret = Err("mlp: quant_step_size larger than huff_lsbs")
        }
        s.quant_step_size[ch] = 0
      }
      cp.sign_huff_offset = self.calculate_sign_huff(substr, ch)
    }
  }
  ret
}

///|
/// `read_huff_channels`: the bypassed matrix LSBs then the per-channel
/// entropy-coded residual. */
fn MlpDecoder::read_huff_channels(
  self : MlpDecoder,
  gb : BitReader,
  substr : Int32,
  pos : Int32,
) -> Result[Unit, String] {
  let s = self.substream[substr]
  for mat = 0; mat < s.num_primitive_matrices; mat = mat + 1 {
    if s.lsb_bypass[mat] != 0 {
      self.bypassed_lsbs[(pos + s.blockpos) * mlp_max_channels + mat] = gb
        .read1()
        .reinterpret_as_int()
    }
  }
  for channel = s.min_channel; channel <= s.max_channel; channel = channel + 1 {
    let cp = s.channel_params[channel]
    let quant_step_size = s.quant_step_size[channel]
    let lsb_bits = cp.huff_lsbs - quant_step_size
    let mut result = 0
    if cp.codebook > 0 {
      result = mlp_huff_decode(gb, mlp_huffman_tables[cp.codebook - 1])
      if result < 0 {
        return Err("mlp: invalid huffman code")
      }
    }
    if lsb_bits > 0 {
      result = (result << lsb_bits) + gb.read(lsb_bits).reinterpret_as_int()
    }
    result += cp.sign_huff_offset
    result = result * (1 << quant_step_size)
    self.sample_buffer[(pos + s.blockpos) * mlp_max_channels + channel] = result
  }
  Ok(())
}

///|
/// `mlp_filter_channel`: run the FIR/IIR prediction over the block just
/// read, updating the sample buffer in place. The C's sliding window over
/// `state_buffer` is modelled as newest-first recent-output arrays seeded
/// from the saved filter state. */
fn MlpDecoder::filter_channel(
  self : MlpDecoder,
  substr : Int32,
  channel : Int32,
) -> Unit {
  let s = self.substream[substr]
  let cp = s.channel_params[channel]
  let fir_order = cp.fir.order
  let iir_order = cp.iir.order
  let filter_shift = cp.fir.shift
  let mask = -(1 << s.quant_step_size[channel])
  let fir_recent : FixedArray[Int32] = FixedArray::make(
    mlp_max_fir_order,
    0,
  )
  for i = 0; i < mlp_max_fir_order; i = i + 1 {
    fir_recent[i] = cp.fir.state[i]
  }
  let iir_recent : FixedArray[Int32] = FixedArray::make(
    mlp_max_iir_order,
    0,
  )
  for i = 0; i < mlp_max_iir_order; i = i + 1 {
    iir_recent[i] = cp.iir.state[i]
  }
  for i = 0; i < s.blocksize; i = i + 1 {
    let idx = (s.blockpos + i) * mlp_max_channels + channel
    let residual = self.sample_buffer[idx]
    let mut accum : Int64 = 0
    for k = 0; k < fir_order; k = k + 1 {
      accum += fir_recent[k].to_int64() * cp.coeff[k].to_int64()
    }
    for k = 0; k < iir_order; k = k + 1 {
      accum += iir_recent[k].to_int64() * cp.coeff[mlp_max_fir_order + k].to_int64()
    }
    accum = accum >> filter_shift
    let result = ((accum + residual.to_int64()) & mask.to_int64()).to_int()
    let iir_val = (result.to_int64() - accum).to_int()
    // push the new outputs to the front of the recent windows
    for k = mlp_max_fir_order - 1; k > 0; k = k - 1 {
      fir_recent[k] = fir_recent[k - 1]
    }
    fir_recent[0] = result
    for k = mlp_max_iir_order - 1; k > 0; k = k - 1 {
      iir_recent[k] = iir_recent[k - 1]
    }
    iir_recent[0] = iir_val
    self.sample_buffer[idx] = result
  }
  for i = 0; i < mlp_max_fir_order; i = i + 1 {
    cp.fir.state[i] = fir_recent[i]
  }
  for i = 0; i < mlp_max_iir_order; i = i + 1 {
    cp.iir.state[i] = iir_recent[i]
  }
}

///|
/// `read_block_data`. The data-check length comparison only logs upstream. */
fn MlpDecoder::read_block_data(
  self : MlpDecoder,
  gb : BitReader,
  substr : Int32,
) -> Result[Unit, String] {
  let s = self.substream[substr]
  if s.data_check_present {
    ignore(gb.read(16)) // expected stream position
  }
  if s.blockpos + s.blocksize > self.access_unit_size {
    return Err("mlp: too many audio samples in frame")
  }
  for i = 0; i < s.blocksize * mlp_max_channels; i = i + 1 {
    self.bypassed_lsbs[s.blockpos * mlp_max_channels + i] = 0
  }
  for i = 0; i < s.blocksize; i = i + 1 {
    match self.read_huff_channels(gb, substr, i) {
      Ok(_) => ()
      Err(e) => return Err(e)
    }
  }
  for ch = s.min_channel; ch <= s.max_channel; ch = ch + 1 {
    self.filter_channel(substr, ch)
  }
  s.blockpos += s.blocksize
  if s.data_check_present {
    gb.skip(8)
  }
  Ok(())
}

///|
/// `generate_2_noise_channels` (0x31ea substreams). */
fn MlpDecoder::generate_2_noise_channels(
  self : MlpDecoder,
  substr : Int32,
) -> Unit {
  let s = self.substream[substr]
  let mut seed = s.noisegen_seed
  let maxchan = s.max_matrix_channel
  for i = 0; i < s.blockpos; i = i + 1 {
    let seed_shr7 = (seed >> 7) & 0xFFFFU
    let b0 = ((seed >> 15) & 0xFFU).reinterpret_as_int()
    let b1 = (seed_shr7 & 0xFFU).reinterpret_as_int()
    let s0 = if (b0 & 0x80) != 0 { b0 - 0x100 } else { b0 }
    let s1 = if (b1 & 0x80) != 0 { b1 - 0x100 } else { b1 }
    self.sample_buffer[i * mlp_max_channels + maxchan + 1] = s0 << s.noise_shift
    self.sample_buffer[i * mlp_max_channels + maxchan + 2] = s1 << s.noise_shift
    seed = (seed << 16) ^ seed_shr7 ^ (seed_shr7 << 5)
  }
  s.noisegen_seed = seed
}

///|
/// `fill_noise_buffer` (0x31eb substreams). */
fn MlpDecoder::fill_noise_buffer(self : MlpDecoder, substr : Int32) -> Unit {
  let s = self.substream[substr]
  let mut seed = s.noisegen_seed
  for i = 0; i < self.access_unit_size_pow2; i = i + 1 {
    let seed_shr15 = (seed >> 15) & 0xFFU
    self.noise_buffer[i] = mlp_noise_table[seed_shr15.reinterpret_as_int()]
    seed = (seed << 8) ^ seed_shr15 ^ (seed_shr15 << 5)
  }
  s.noisegen_seed = seed
}

///|
/// `output_data`: noise fill, primitive matrices (`ff_mlp_rematrix_channel`)
/// and the packing stage (`ff_mlp_pack_output`). */
fn MlpDecoder::output_data(
  self : MlpDecoder,
  substr : Int32,
) -> Result[MlpAudio, String] {
  let s = self.substream[substr]
  if self.channels != s.max_matrix_channel + 1 {
    return Err("mlp: channel count mismatch")
  }
  if s.blockpos == 0 {
    return Err("mlp: no samples to output")
  }
  let is32 = self.bits > 16
  let mut maxchan = s.max_matrix_channel
  if s.noise_type == 0 {
    self.generate_2_noise_channels(substr)
    maxchan += 2
  } else {
    self.fill_noise_buffer(substr)
  }
  for mat = 0; mat < s.num_primitive_matrices; mat = mat + 1 {
    let dest_ch = s.matrix_out_ch[mat]
    let mut index = s.num_primitive_matrices - mat
    let index2 = 2 * index + 1
    let mask = -(1 << s.quant_step_size[dest_ch])
    let coeff_base = mat * mlp_max_channels
    for i = 0; i < s.blockpos; i = i + 1 {
      let base = i * mlp_max_channels
      let mut accum : Int64 = 0
      for src = 0; src <= maxchan; src = src + 1 {
        accum += self.sample_buffer[base + src].to_int64() * s.matrix_coeff[coeff_base + src].to_int64()
      }
      if s.matrix_noise_shift[mat] != 0 {
        index = index & (self.access_unit_size_pow2 - 1)
        accum += self.noise_buffer[index].to_int64() * (1 << (s.matrix_noise_shift[mat] + 7)).to_int64()
        index += index2
      }
      self.sample_buffer[base + dest_ch] = (((accum >> 14) & mask.to_int64()) + self.bypassed_lsbs[base + mat].to_int64()).to_int()
    }
  }
  let samples : Array[Int32] = []
  let mut lossless_check_data = s.lossless_check_data
  for i = 0; i < s.blockpos; i = i + 1 {
    for out_ch = 0; out_ch <= s.max_matrix_channel; out_ch = out_ch + 1 {
      let mat_ch = s.ch_assign[out_ch]
      let sample64 = self.sample_buffer[i * mlp_max_channels + mat_ch].to_int64() * (1 << s.output_shift[mat_ch]).to_int64()
      let sample = sample64.to_int()
      lossless_check_data = lossless_check_data ^ ((sample64 & 0xFFFFFF) << mat_ch).to_int()
      if is32 {
        samples.push((sample64 * 256).to_int())
      } else {
        samples.push(sample >> 8)
      }
    }
  }
  s.lossless_check_data = lossless_check_data
  Ok({
    sample_rate: self.sample_rate,
    channels: self.channels,
    bits: self.bits,
    samples,
  })
}

///|
/// Size in bytes of the access unit beginning at this header.
pub fn mlp_access_unit_size(data : BytesView) -> Int32 {
  if data.length() < 2 {
    return 0
  }
  (((data[0].to_int() & 0xF) << 8) | data[1].to_int()) << 1
}

///|
/// Decode one access unit. `Ok(None)` means the packet was consumed without
/// output (e.g. before the first major sync). */
pub fn MlpDecoder::decode_packet(
  self : MlpDecoder,
  data : Bytes,
) -> Result[Option[MlpAudio], String] {
  if data.length() < 4 {
    return Err("mlp: packet too small")
  }
  let length = mlp_access_unit_size(data[:])
  if length < 4 || length > data.length() {
    return Err("mlp: invalid access unit length")
  }
  let payload = data[4:length].to_owned()
  let gb = BitReader::with_size(payload, (length - 4) * 8)
  let mut header_size = 4
  let mut is_major_sync_unit = false
  if gb.show(31) == 0x7C3937DDU {
    match self.read_major_sync(payload, gb) {
      Ok(_) => ()
      Err(e) => {
        self.params_valid = false
        return Err(e)
      }
    }
    is_major_sync_unit = true
    header_size += self.major_sync_header_size
  }
  if !self.params_valid {
    return Ok(None)
  }
  // Substream directory.
  let mut substr_header_size = 0
  let substream_parity_present : FixedArray[Bool] = FixedArray::make(
    mlp_max_substreams,
    false,
  )
  let substream_data_len : FixedArray[Int32] = FixedArray::make(
    mlp_max_substreams,
    0,
  )
  let mut substream_start = 0
  for substr = 0; substr < self.num_substreams; substr = substr + 1 {
    let extraword_present = gb.read1() != 0
    let nonrestart_substr = gb.read1() != 0
    let checkdata_present = gb.read1() != 0
    gb.skip(1)
    let mut end = (gb.read(12) << 1).reinterpret_as_int()
    substr_header_size += 2
    if extraword_present {
      if !self.truehd {
        self.params_valid = false
        return Err("mlp: there must be no extraword for MLP")
      }
      gb.skip(16)
      substr_header_size += 2
    }
    if length < header_size + substr_header_size {
      self.params_valid = false
      return Err("mlp: insufficient data for headers")
    }
    if nonrestart_substr == is_major_sync_unit {
      self.params_valid = false
      return Err("mlp: invalid nonrestart_substr")
    }
    if end + header_size + substr_header_size > length {
      end = length - header_size - substr_header_size
    }
    if end < substream_start {
      self.params_valid = false
      return Err("mlp: substream end offset before start")
    }
    if substr > self.max_decoded_substream {
      continue
    }
    substream_parity_present[substr] = checkdata_present
    substream_data_len[substr] = end - substream_start
    substream_start = end
  }
  let parity = mlp_parity(data[0:4].to_owned()) ^ mlp_parity(data[header_size : header_size + substr_header_size].to_owned())
  if (((parity >> 4) ^ parity) & 0xF) != 0xF {
    self.params_valid = false
    return Err("mlp: parity check failed")
  }
  // Substream data.
  let mut off = header_size + substr_header_size
  for substr = 0; substr <= self.max_decoded_substream; substr = substr + 1 {
    let s = self.substream[substr]
    let sub_len = substream_data_len[substr]
    let sub = data[off : off + sub_len].to_owned()
    let sgb = BitReader::with_size(sub, sub_len * 8)
    self.matrix_changed = 0
    for i = 0; i < mlp_max_channels * 2; i = i + 1 {
      self.filter_changed[i] = 0
    }
    self.cur_substr = substr
    s.blockpos = 0
    // The block loop; `completed` is false when a parameter error jumped to
    // `next_substr`, skipping the tail checks below.
    let completed = {
      let mut finished = false
      let mut skipped = false
      while !finished && !skipped {
        if sgb.read1() != 0 {
          if sgb.read1() != 0 {
            match self.read_restart_header(sgb, substr) {
              Ok(_) => s.restart_seen = true
              Err(_e) => skipped = true
            }
          }
          if !skipped {
            if !s.restart_seen {
              skipped = true
            } else {
              match self.read_decoding_params(sgb, substr) {
                Ok(_) => ()
                Err(_e) => skipped = true
              }
            }
          }
        }
        if !skipped {
          if !s.restart_seen {
            skipped = true
          } else if ((self.channels == 6 && ((self.substream_info >> 2) & 0x3) != 0x3) ||
              (self.channels == 8 &&
              ((self.substream_info >> 4) & 0x7) != 0x7 &&
              ((self.substream_info >> 4) & 0x7) != 0x6 &&
              ((self.substream_info >> 4) & 0x7) != 0x3)) &&
            substr > 0 &&
            substr < self.max_decoded_substream &&
            s.min_channel <= self.substream[substr - 1].max_channel {
            skipped = true
          } else if substr != self.max_decoded_substream &&
            (s.coded_channels & self.substream[self.max_decoded_substream].coded_channels) != 0 {
            skipped = true
          } else {
            match self.read_block_data(sgb, substr) {
              Ok(_) => ()
              Err(e) => return Err(e)
            }
            if sgb.count() >= sub_len * 8 {
              return Err("mlp: substream \{substr} length mismatch")
            }
            if sgb.read1() != 0 {
              finished = true
            }
          }
        }
      }
      !skipped
    }
    if completed {
      sgb.skip((-sgb.count()) & 15)
      if sub_len * 8 - sgb.count() >= 32 {
        if sgb.read(16) != 0xD234U {
          return Err("mlp: missing end of stream marker")
        }
        let shorten_by = sgb.read(16).reinterpret_as_int()
        if self.truehd && (shorten_by & 0x2000) != 0 {
          let drop = shorten_by & 0x1FFF
          s.blockpos -= if drop < s.blockpos { drop } else { s.blockpos }
        } else if !self.truehd && shorten_by != 0xD234 {
          return Err("mlp: bad MLP end of stream")
        }
        s.end_of_stream = true
      }
      if substream_parity_present[substr] {
        if sub_len * 8 - sgb.count() != 16 {
          return Err("mlp: substream \{substr} length mismatch")
        }
        // Parity/checksum mismatches only log upstream.
        let body = sub[0:sub_len - 2].to_owned()
        let _parity = mlp_parity(body)
        let _checksum = mlp_checksum8(self.crc_63, body, sub_len - 2)
        ignore(sgb.read(8))
        ignore(sgb.read(8))
      }
      if sub_len * 8 != sgb.count() {
        return Err("mlp: substream \{substr} length mismatch")
      }
    }
    off += sub_len
  }
  let out = match self.output_data(self.max_decoded_substream) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  for substr = 0; substr <= self.max_decoded_substream; substr = substr + 1 {
    let s = self.substream[substr]
    if s.end_of_stream {
      s.lossless_check_data = -1
      s.end_of_stream = false
      self.params_valid = false
    }
  }
  Ok(Some(out))
}

///|
/// Decode a concatenation of access units, appending every frame's samples. */
pub fn MlpDecoder::decode_stream(
  self : MlpDecoder,
  data : Bytes,
) -> Result[MlpAudio, String] {
  let out : Array[Int32] = []
  let mut sample_rate = 0
  let mut channels = 0
  let mut bits = 0
  let mut pos = 0
  while pos < data.length() {
    let length = mlp_access_unit_size(data[pos:])
    if length < 4 || pos + length > data.length() {
      return Err("mlp: invalid access unit length at \{pos}")
    }
    match self.decode_packet(data[pos : pos + length].to_owned()) {
      Ok(Some(au)) => {
        sample_rate = au.sample_rate
        channels = au.channels
        bits = au.bits
        for v in au.samples {
          out.push(v)
        }
      }
      Ok(None) => ()
      Err(e) => return Err(e)
    }
    pos += length
  }
  if sample_rate == 0 {
    return Err("mlp: no output frames")
  }
  Ok({ sample_rate, channels, bits, samples: out })
}

///|
/// Decode a complete raw MLP elementary stream. */
pub fn ff_mlp_decode_stream(data : Bytes) -> Result[MlpAudio, String] {
  MlpDecoder::new(false).decode_stream(data)
}

///|
/// Decode a complete raw TrueHD elementary stream. */
pub fn ff_truehd_decode_stream(data : Bytes) -> Result[MlpAudio, String] {
  MlpDecoder::new(true).decode_stream(data)
}
