// Blackbox tests for §438b: the sequence-header OBU writer. Acceptance
// oracle = `av1_parse_sequence_header` in `av1.mbt` (already validated
// against real streams): every written OBU must parse back field for
// field.

///|
fn av1seq_assert(
  config : @libavcodec.Av1SeqEncConfig,
) -> @libavcodec.Av1SequenceParameters raise {
  let obu = match @libavcodec.av1_enc_write_sequence_header_obu(config) {
    Ok(b) => b
    Err(e) => fail(e)
  }
  let seq = match @libavcodec.av1_parse_sequence_header(obu) {
    Ok(s) => s
    Err(e) => fail("parse failed: \{e}")
  }
  if seq.profile != 0 {
    fail("profile \{seq.profile}")
  }
  if seq.width != config.width || seq.height != config.height {
    fail(
      "geometry \{seq.width}x\{seq.height} != \{config.width}x\{config.height}",
    )
  }
  if seq.bitdepth != config.bit_depth {
    fail("bitdepth \{seq.bitdepth} != \{config.bit_depth}")
  }
  if seq.monochrome != config.monochrome {
    fail("monochrome \{seq.monochrome}")
  }
  if seq.level != config.level {
    fail("level \{seq.level} != \{config.level}")
  }
  if seq.reduced_still_picture_header != config.still_picture {
    fail("reduced \{seq.reduced_still_picture_header}")
  }
  // The encoder's fixed capability set.
  if seq.chroma_subsampling_x != true || seq.chroma_subsampling_y != true {
    if !config.monochrome {
      fail("profile 0 must stay 4:2:0")
    }
  }
  if seq.enable_superres || seq.enable_cdef || seq.enable_restoration {
    fail("loop tools must stay off")
  }
  if seq.film_grain_params_present {
    fail("film grain must stay off")
  }
  seq
}

///|
test "av1 seq enc: general 8-bit 420 round trip" {
  let seq = av1seq_assert(
    @libavcodec.Av1SeqEncConfig::default(width=1920, height=1080),
  )
  if seq.reduced_still_picture_header {
    fail("general header must not be still")
  }
  // The chosen screen-content / integer-MV selectors (2/2).
  if seq.seq_force_screen_content_tools != 2 || seq.seq_force_integer_mv != 2 {
    fail(
      "force sc/imv \{seq.seq_force_screen_content_tools}/\{seq.seq_force_integer_mv}",
    )
  }
  if seq.enable_order_hint {
    fail("order hint must stay off for now")
  }
}

///|
test "av1 seq enc: 10-bit and monochrome" {
  let cfg10 : @libavcodec.Av1SeqEncConfig = {
    ..@libavcodec.Av1SeqEncConfig::default(width=640, height=360),
    bit_depth: 10,
  }
  let _ = av1seq_assert(cfg10)
  let cfgm : @libavcodec.Av1SeqEncConfig = {
    ..@libavcodec.Av1SeqEncConfig::default(width=320, height=240),
    monochrome: true,
  }
  let seqm = av1seq_assert(cfgm)
  if !seqm.monochrome {
    fail("monochrome lost")
  }
}

///|
test "av1 seq enc: still-picture reduced header" {
  let cfg : @libavcodec.Av1SeqEncConfig = {
    ..@libavcodec.Av1SeqEncConfig::default(width=800, height=600),
    still_picture: true,
    level: 7,
  }
  let seq = av1seq_assert(cfg)
  if !seq.reduced_still_picture_header {
    fail("reduced flag lost")
  }
}

///|
test "av1 seq enc: geometry bit widths and level tier bit" {
  // 65536 needs 16 width bits; level 9 (max major) exercises the tier
  // bit in the general header.
  let cfg : @libavcodec.Av1SeqEncConfig = {
    ..@libavcodec.Av1SeqEncConfig::default(width=65536, height=64),
    level: 9,
  }
  let seq = av1seq_assert(cfg)
  if seq.frame_width_bits != 16 {
    fail("width bits \{seq.frame_width_bits}")
  }
  if seq.tier != 0 {
    fail("tier \{seq.tier}")
  }
}

///|
test "av1 seq enc: validation errors" {
  for
    bad in [
      { ..@libavcodec.Av1SeqEncConfig::default(width=0, height=64), },
      { ..@libavcodec.Av1SeqEncConfig::default(width=64, height=0), },
      {
        ..@libavcodec.Av1SeqEncConfig::default(width=64, height=64),
        bit_depth: 12,
      },
      {
        ..@libavcodec.Av1SeqEncConfig::default(width=64, height=64),
        level: 32,
      },
    ] {
    match @libavcodec.av1_enc_write_sequence_header_obu(bad) {
      Ok(_) => fail("bad config accepted")
      Err(_) => ()
    }
  }
}
