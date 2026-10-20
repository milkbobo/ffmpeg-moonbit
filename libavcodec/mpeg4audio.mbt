///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/mpeg4audio.c`
/// (`ff_mpeg4audio_get_config_gb` / `avpriv_mpeg4audio_get_config2`), the
/// parser of the MPEG-4 AudioSpecificConfig found inside an `esds` box.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Ported as-is, including the quirky parts: the MP3onMP4 draft check on
/// `show_bits`, the ALS header sniffing that may skip 24 bits twice, the
/// implicit-SBR sync extension scan (`0x2b7`/`0x548`), and the trailing
/// PS-vs-SBR fixups. The return value is `specific_config_bitindex -
/// start_bit_index`, exactly as in the C code.
///
/// Needed by libavformat's `esds` handling (isom.c calls
/// `avpriv_mpeg4audio_get_config2` on the DecoderSpecificInfo of every AAC
/// track), hence this file lives in libavcodec but is consumed by the
/// libavformat package, mirroring FFmpeg's own dependency direction.

// Audio object types from libavcodec/mpeg4audio.h, the ones referenced by
// name below. The frame-length switch keeps the numeric AOT values in its
// patterns (MoonBit patterns cannot use `let` constants).

///|
/// `AOT_NULL`. */
let aot_null : Int32 = 0

///|
/// `AOT_AAC_LC`. */
let aot_aac_lc : Int32 = 2

///|
/// `AOT_SBR`. */
let aot_sbr : Int32 = 5

///|
/// `AOT_ER_BSAC`. */
let aot_er_bsac : Int32 = 22

///|
/// `AOT_PS`. */
let aot_ps : Int32 = 29

///|
/// `AOT_ESCAPE`. */
let aot_escape : Int32 = 31

///|
/// `AOT_ALS`. */
let aot_als : Int32 = 36

///|
/// `ff_mpeg4audio_channels`: channel count for each channel-configuration
/// index (0 means "see the GASpecificConfig / PCE").
let mpeg4audio_channels : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 8, 0, 0, 0, 7, 8, 24, 8,
]

///|
/// `ff_mpeg4audio_sample_rates` from `mpeg4audio_sample_rates.h`: 13 real
/// entries, zero-padded to 16 so an out-of-range index reads 0 like the C.
let mpeg4audio_sample_rates : FixedArray[Int32] = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000,
  7350, 0, 0, 0,
]

///|
/// `MPEG4AudioConfig` from libavcodec/mpeg4audio.h. `sbr`/`ps` use the C
/// convention: 1 present, 0 not present, -1 unknown.
pub struct Mpeg4AudioConfig {
  mut object_type : Int32
  mut sampling_index : Int32
  mut sample_rate : Int32
  mut chan_config : Int32
  mut channels : Int32
  mut ext_object_type : Int32
  mut ext_sampling_index : Int32
  mut ext_sample_rate : Int32
  mut ext_chan_config : Int32
  mut frame_length : Int32
  mut frame_length_short : Bool
  mut sbr : Int32
  mut ps : Int32
}

///|
/// Zero-initialised config, mirroring `MPEG4AudioConfig cfg = {0}`. */
pub fn new_mpeg4_audio_config() -> Mpeg4AudioConfig {
  {
    object_type: 0,
    sampling_index: 0,
    sample_rate: 0,
    chan_config: 0,
    channels: 0,
    ext_object_type: 0,
    ext_sampling_index: 0,
    ext_sample_rate: 0,
    ext_chan_config: 0,
    frame_length: 0,
    frame_length_short: false,
    sbr: 0,
    ps: 0,
  }
}

///|
/// MSB-first bit reader over a byte buffer, matching `GetBitContext` as used
/// by this parser (`get_bits`, `get_bits1`, `show_bits`, `skip_bits`).
/// Reads past the end return 0 bits, like `get_bits` on an exhausted context.
priv struct GetBits {
  buf : Bytes
  mut pos : Int32 // bit position
}

///|
fn GetBits::new(buf : Bytes) -> GetBits {
  { buf, pos: 0, }
}

///|
/// `get_bits_left`: bits remaining before the end of the buffer. */
fn GetBits::bits_left(self : GetBits) -> Int32 {
  self.buf.length() * 8 - self.pos
}

///|
/// `get_bits_count`. */
fn GetBits::count(self : GetBits) -> Int32 {
  self.pos
}

///|
fn GetBits::bit_at(self : GetBits, bitpos : Int32) -> UInt32 {
  if bitpos < 0 || bitpos >= self.buf.length() * 8 {
    return 0
  }
  (self.buf[bitpos / 8].to_uint() >> (7 - bitpos % 8)) & 1
}

///|
/// `get_bits`: `n` bits MSB-first (`n <= 32`). */
fn GetBits::read(self : GetBits, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = (v << 1) | self.bit_at(self.pos + i)
  }
  self.pos = self.pos + n
  v
}

///|
/// `get_bits1`. */
fn GetBits::read1(self : GetBits) -> UInt32 {
  self.read(1)
}

///|
/// `show_bits`: peek `n` bits without consuming them. */
fn GetBits::show(self : GetBits, n : Int32) -> UInt32 {
  let mut v : UInt32 = 0
  for i = 0; i < n; i = i + 1 {
    v = (v << 1) | self.bit_at(self.pos + i)
  }
  v
}

///|
/// `skip_bits`. */
fn GetBits::skip(self : GetBits, n : Int32) -> Unit {
  self.pos = self.pos + n
}

///|
/// `get_object_type`: 5 bits, with the 32+ escape form. */
fn get_object_type(gb : GetBits) -> Int32 {
  let object_type = gb.read(5).reinterpret_as_int()
  if object_type == aot_escape {
    return 32 + gb.read(6).reinterpret_as_int()
  }
  object_type
}

///|
/// `get_sample_rate`: 4-bit index (0x0f selects an explicit 24-bit rate).
/// The index is reported back through `index` even for the explicit form.
fn get_sample_rate(gb : GetBits, index : (Int32) -> Unit) -> Int32 {
  let idx = gb.read(4).reinterpret_as_int()
  index(idx)
  if idx == 0x0F {
    gb.read(24).reinterpret_as_int()
  } else {
    mpeg4audio_sample_rates[idx]
  }
}

///|
/// `parse_config_ALS`: an ALS AudioSpecificConfig carries its own sample rate
/// and channel count, which override the header fields.
fn parse_config_als(gb : GetBits, c : Mpeg4AudioConfig) -> Result[Unit, String] {
  if gb.bits_left() < 112 {
    return Err("EINVAL")
  }
  // MKBETAG('A','L','S','\0')
  if gb.read(32) != 0x414C5300 {
    return Err("EINVAL")
  }
  c.sample_rate = gb.read(32).reinterpret_as_int()
  if c.sample_rate <= 0 {
    return Err("EINVAL")
  }
  gb.skip(32) // number of samples
  c.chan_config = 0
  c.channels = gb.read(16).reinterpret_as_int() + 1
  Ok(())
}

///|
/// `ff_mpeg4audio_get_config_gb` / `avpriv_mpeg4audio_get_config2`: parse an
/// AudioSpecificConfig into `c`. Returns the bit offset of the decoder
/// specific config within the buffer (the C return value) on success.
pub fn ff_mpeg4audio_get_config(
  c : Mpeg4AudioConfig,
  buf : Bytes,
  sync_extension : Bool,
) -> Result[Int32, String] {
  if buf.length() <= 0 {
    return Err("EINVAL")
  }
  let gb = GetBits::new(buf)
  let start_bit_index = gb.count()
  c.object_type = get_object_type(gb)
  c.sample_rate = get_sample_rate(gb, idx => c.sampling_index = idx)
  c.chan_config = gb.read(4).reinterpret_as_int()
  if c.chan_config < mpeg4audio_channels.length() {
    c.channels = mpeg4audio_channels[c.chan_config]
  } else {
    return Err("EINVAL")
  }
  c.sbr = -1
  c.ps = -1
  // `object_type == AOT_SBR`, or `AOT_PS` unless the following bits look like
  // the W6132 Annex YYYY draft MP3onMP4 stream.
  let mp3on4_draft = (gb.show(3) & 0x03) != 0 && (gb.show(9) & 0x3F) == 0
  if c.object_type == aot_sbr || (c.object_type == aot_ps && !mp3on4_draft) {
    if c.object_type == aot_ps {
      c.ps = 1
    }
    c.ext_object_type = aot_sbr
    c.sbr = 1
    c.ext_sample_rate = get_sample_rate(gb, idx => c.ext_sampling_index = idx)
    c.object_type = get_object_type(gb)
    if c.object_type == aot_er_bsac {
      c.ext_chan_config = gb.read(4).reinterpret_as_int()
    }
  } else {
    c.ext_object_type = aot_null
    c.ext_sample_rate = 0
  }
  let specific_config_bitindex = gb.count()
  if c.object_type == aot_als {
    gb.skip(5)
    // MKBETAG('\0','A','L','S') as a 24-bit prefix
    if gb.show(24) != 0x00414C53 {
      gb.skip(24)
    }
    let als_config_bitindex = gb.count()
    match parse_config_als(gb, c) {
      Err(e) => return Err(e)
      Ok(_) => ()
    }
    // ALS is not in the frame-length switch; fall through to the shared tail
    // (implicit SBR/PS scan and fixups) with the ALS-specific bit index.
    return mpeg4audio_finalise(
      c,
      gb,
      sync_extension,
      als_config_bitindex - start_bit_index,
    )
  }
  match c.object_type {
    1
    | 2
    | 3
    | 4
    // AOT_AAC_MAIN / AAC_LC / AAC_SSR / AAC_LTP / ER_AAC_LC
    | 17 => {
      c.frame_length_short = gb.read1() == 1
      c.frame_length = if c.frame_length_short { 960 } else { 1024 }
    }
    23
    // AOT_ER_AAC_LD / AOT_ER_AAC_ELD
    | 39 => {
      c.frame_length_short = gb.read1() == 1
      c.frame_length = if c.frame_length_short { 480 } else { 512 }
    }
    // AOT_USAC
    42 => {
      if gb.read(5) == 0x1F {
        gb.skip(24) // usacSamplingFrequency
      }
      let core_sbr_frame_len_idx = gb.read(3).reinterpret_as_int()
      c.frame_length_short = core_sbr_frame_len_idx == 0 ||
        core_sbr_frame_len_idx == 2
      let sbr_ratio = if core_sbr_frame_len_idx == 2 {
        2
      } else if core_sbr_frame_len_idx == 3 {
        3
      } else {
        0
      }
      let ratio_mult = if sbr_ratio == 2 {
        8
      } else if sbr_ratio == 3 {
        2
      } else {
        1
      }
      let ratio_dec = if sbr_ratio == 2 { 3 } else { 1 }
      let fl = if c.frame_length_short { 768 } else { 1024 }
      c.frame_length = fl * ratio_mult / ratio_dec
    }
    _ => ()
  }
  mpeg4audio_finalise(
    c,
    gb,
    sync_extension,
    specific_config_bitindex - start_bit_index,
  )
}

///|
/// The tail of `ff_mpeg4audio_get_config_gb` shared by the regular path and
/// the ALS branch: implicit SBR/PS sync-extension scan and the PS fixups.
/// (The C has no such helper; both paths just run the same trailing code, so
/// this factoring is behaviour-preserving.)
fn mpeg4audio_finalise(
  c : Mpeg4AudioConfig,
  gb : GetBits,
  sync_extension : Bool,
  ret : Int32,
) -> Result[Int32, String] {
  if c.ext_object_type != aot_sbr && sync_extension {
    while gb.bits_left() > 15 {
      if gb.show(11) == 0x2B7 {
        // sync extension
        gb.skip(11)
        c.ext_object_type = get_object_type(gb)
        if c.ext_object_type == aot_sbr {
          c.sbr = gb.read1().reinterpret_as_int()
          if c.sbr == 1 {
            c.ext_sample_rate = get_sample_rate(gb, idx => {
              c.ext_sampling_index = idx
            })
            if c.ext_sample_rate == c.sample_rate {
              c.sbr = -1
            }
          }
        }
        if gb.bits_left() > 11 && gb.read(11) == 0x548 {
          c.ps = gb.read1().reinterpret_as_int()
        }
        break
      } else {
        gb.skip(1)
      }
    }
  }
  // PS requires SBR (`!c->sbr` is only true for sbr == 0).
  if c.sbr == 0 {
    c.ps = 0
  }
  // Limit implicit PS to the HE-AACv2 profile, and drop PS for any channel
  // count with the low bit cleared (`channels & ~0x01`).
  if (c.ps == -1 && c.object_type != aot_aac_lc) ||
    (c.channels & 0xFFFFFFFE) != 0 {
    c.ps = 0
  }
  Ok(ret)
}
