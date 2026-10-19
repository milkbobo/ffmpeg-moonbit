///|
/// Whitebox tests for the MPEG-4 AudioSpecificConfig parser
/// (`libavcodec/mpeg4audio.mbt`), ported from `libavcodec/mpeg4audio.c`.
///
/// Expected values are derived from ISO/IEC 14496-3 bit layouts (object type,
/// sampling-frequency index, channel configuration) and from the parser's own
/// documented behaviour (implicit SBR sync extension `0x2b7`/`0x548`, PS
/// fixups). The real-FFmpeg cross-check of the whole esds path lives in
/// libavformat's `mp4_real_wbtest.mbt` (a Docker-ffmpeg-generated AAC file).

///| MSB-first bit writer used to assemble test configs. */
priv struct TestBits {
  bits : Array[Int]
}

fn TestBits::new() -> TestBits {
  { bits: [] }
}

fn TestBits::put(self : TestBits, value : UInt, n : Int) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.bits.push(((value >> i) & 1).reinterpret_as_int())
  }
}

fn TestBits::bytes(self : TestBits) -> Bytes {
  let out : Array[Byte] = []
  let mut i = 0
  while i < self.bits.length() {
    let mut v = 0
    for j = 0; j < 8; j = j + 1 {
      v = v * 2
      if i + j < self.bits.length() {
        v = v + self.bits[i + j]
      }
    }
    out.push(v.to_byte())
    i = i + 8
  }
  Bytes::from_array(out[:])
}

test "mpeg4audio: AAC-LC 44100 Hz mono (real values)" {
  let b = TestBits::new()
  b.put(2, 5)
  b.put(4, 4)
  b.put(1, 4)
  b.put(0, 3)
  let buf = b.bytes()
  let cfg = new_mpeg4_audio_config()
  let ret = ff_mpeg4audio_get_config(cfg, buf, true).unwrap()
  assert_eq(cfg.object_type, 2)
  assert_eq(cfg.sampling_index, 4)
  assert_eq(cfg.sample_rate, 44100)
  assert_eq(cfg.chan_config, 1)
  assert_eq(cfg.channels, 1)
  assert_eq(cfg.frame_length, 1024)
  assert_eq(cfg.frame_length_short, false)
  // No SBR: the buffer is exhausted before the sync-extension scan can run
  // (it needs > 15 bits left), so both stay "unknown" (-1), as in C.
  assert_eq(cfg.sbr, -1)
  assert_eq(cfg.ps, -1)
  // The GASpecificConfig starts after the 13-bit header.
  assert_eq(ret, 13)
}

test "mpeg4audio: channel-configuration table" {
  let b = TestBits::new()
  b.put(2, 5)
  b.put(4, 4)
  b.put(7, 4) // 5.2.1 -> 8 channels
  b.put(0, 3)
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), false).unwrap()
  assert_eq(cfg.channels, 8)
  let b2 = TestBits::new()
  b2.put(2, 5)
  b2.put(4, 4)
  b2.put(11, 4) // 3/3.1 -> 7 channels
  b2.put(0, 3)
  let cfg2 = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg2, b2.bytes(), false).unwrap()
  assert_eq(cfg2.channels, 7)
  let b2b = TestBits::new()
  b2b.put(2, 5)
  b2b.put(4, 4)
  b2b.put(12, 4) // 3/2/2.1 -> 8 channels
  b2b.put(0, 3)
  let cfg2b = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg2b, b2b.bytes(), false).unwrap()
  assert_eq(cfg2b.channels, 8)
  // chan_config 15 is rejected.
  let b3 = TestBits::new()
  b3.put(2, 5)
  b3.put(4, 4)
  b3.put(15, 4)
  b3.put(0, 3)
  let cfg3 = new_mpeg4_audio_config()
  assert_eq(ff_mpeg4audio_get_config(cfg3, b3.bytes(), false) is Err(_), true)
}

test "mpeg4audio: explicit 24-bit sampling rate" {
  // The explicit 24-bit rate directly follows the 0xf index, before the
  // channel configuration.
  let b = TestBits::new()
  b.put(2, 5)
  b.put(0x0F, 4)
  b.put(5000, 24)
  b.put(1, 4)
  b.put(0, 3)
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), false).unwrap()
  assert_eq(cfg.sampling_index, 15)
  assert_eq(cfg.sample_rate, 5000)
}

test "mpeg4audio: escape object type (32 + 6-bit extension)" {
  let b = TestBits::new()
  b.put(31, 5) // AOT_ESCAPE
  b.put(13, 6) // -> object type 45
  b.put(4, 4)
  b.put(1, 4)
  b.put(0, 3)
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), false).unwrap()
  assert_eq(cfg.object_type, 45)
}

test "mpeg4audio: implicit SBR sync extension raises the sample rate" {
  // AAC-LC 44100 stereo followed by the 0x2b7 sync, extension object type 5
  // (SBR), SBR flag 1 and an extension sampling index of 3 (88200): the
  // classic HE-AAC v1 signalling.
  let b = TestBits::new()
  b.put(2, 5)
  b.put(4, 4)
  b.put(2, 4)
  b.put(0, 3)
  b.put(0x2B7, 11)
  b.put(5, 5) // extension object type: AOT_SBR
  b.put(1, 1) // sbr present
  b.put(1, 4) // ext index 1 -> 88200
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), true).unwrap()
  assert_eq(cfg.ext_object_type, 5)
  assert_eq(cfg.sbr, 1)
  assert_eq(cfg.ext_sample_rate, 88200)
}

test "mpeg4audio: SBR signalled but flag 0 keeps the base rate" {
  // The aac.mp4 produced by FFmpeg 9.0.2: ext_object_type 5 with sbr flag 0.
  // Bytes 12 08 56 e5 00.
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(
    cfg,
    b"\x12\x08\x56\xe5\x00",
    true,
  ).unwrap()
  assert_eq(cfg.object_type, 2)
  assert_eq(cfg.sample_rate, 44100)
  assert_eq(cfg.channels, 1)
  assert_eq(cfg.ext_object_type, 5)
  assert_eq(cfg.sbr, 0)
  assert_eq(cfg.ext_sample_rate, 0)
  assert_eq(cfg.ps, 0)
}

test "mpeg4audio: AAC-LD frame lengths" {
  let b = TestBits::new()
  b.put(23, 5) // AOT_ER_AAC_LD
  b.put(4, 4)
  b.put(1, 4)
  b.put(1, 1) // frameLengthFlag -> short
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), false).unwrap()
  assert_eq(cfg.frame_length_short, true)
  assert_eq(cfg.frame_length, 480)
}

test "mpeg4audio: implicit header SBR (object type 5)" {
  // object_type 5 (SBR) in the header itself. Bit order: object type, base
  // sampling index, channel configuration, then the extension sampling index
  // and the inner object type.
  let b = TestBits::new()
  b.put(5, 5) // AOT_SBR
  b.put(4, 4) // base rate index 4 -> 44100
  b.put(1, 4) // chan config
  b.put(4, 4) // ext rate index 4 -> 44100
  b.put(2, 5) // inner object type: AAC LC
  b.put(0, 3) // GASpecificConfig flags
  let cfg = new_mpeg4_audio_config()
  let _ = ff_mpeg4audio_get_config(cfg, b.bytes(), false).unwrap()
  assert_eq(cfg.sbr, 1)
  assert_eq(cfg.ext_sample_rate, 44100)
  assert_eq(cfg.object_type, 2)
  assert_eq(cfg.frame_length, 1024)
}
