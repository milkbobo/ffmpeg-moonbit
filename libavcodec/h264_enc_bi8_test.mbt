// Blackbox tests for the High-profile 8x8 transform inside B slices
// (`§400`, the `b_slices + dct8x8` combination): the B sequence's P
// pictures honour the PPS `transform_8x8_mode` flag and the B pictures
// may code Intra 8x8 macroblocks. The gates: the reconstruction invariant
// against this repository's decoder, the Intra 8x8 statistics, byte
// equality with the streaming encoder, determinism, and external
// docker-ffmpeg arbitration with pinned framemd5 values.

///|
/// One b_slices + dct8x8 sequence: reconstruction invariant (unfiltered,
/// coding order), the Intra 8x8 statistic and a clean filtered decode.
fn h264bi8_check(
  frames : Array[(Bytes, Bytes, Bytes)],
  cabac : Bool,
  cabac_rd : Bool,
) -> Bytes raise {
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = if cabac {
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=20,
      b_slices=true,
      dct8x8=true,
      cabac_rd~,
      recon~,
      stats~,
    )
  } else {
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=20,
      b_slices=true,
      dct8x8=true,
      recon~,
      stats~,
    )
  }
  let stream = match stream {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i8p_mbs <= 0 {
    fail("no Intra 8x8 macroblocks inside the B slices")
  }
  if stats.b_mbs <= 0 {
    fail("no B macroblocks coded")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bi_check_recon(dec, recon, 96, 64, 1)
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) =>
      if f.length() != 6 {
        fail("filtered decode: expected 6 frames, got \{f.length()}")
      }
    Err(e) => fail(e)
  }
  stream
}

///|
test "h264 enc bi8: b_slices + dct8x8 codes Intra8x8 in B (cavlc)" {
  ignore(h264bi8_check(h264bi8_fixture(96, 64, 6), false, false))
}

///|
test "h264 enc bi8: b_slices + dct8x8 codes Intra8x8 in B (cabac)" {
  ignore(h264bi8_check(h264bi8_fixture(96, 64, 6), true, false))
}

///|
test "h264 enc bi8: b_slices + dct8x8 codes Intra8x8 in B (cabac rd)" {
  ignore(h264bi8_check(h264bi8_fixture(96, 64, 6), true, true))
}

///|
/// The streaming encoder must produce the batch's bytes exactly, for both
/// entropies and with the CABAC RD pricing on.
fn h264bi8_stream_check(cabac : Bool, cabac_rd : Bool) -> Unit raise {
  let frames = h264bi8_fixture(96, 64, 6)
  let batch = if cabac {
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=20,
      b_slices=true,
      dct8x8=true,
      cabac_rd~,
    )
  } else {
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=20,
      b_slices=true,
      dct8x8=true,
    )
  }
  let batch = match batch {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=20,
      cabac~,
      cabac_rd~,
      b_slices=true,
      dct8x8=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let joined : Array[Byte] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      for i in 0..<au.length() {
        joined.push(au[i])
      }
    }
  }
  match enc.finish() {
    Ok(tail) =>
      for au in tail {
        for i in 0..<au.length() {
          joined.push(au[i])
        }
      }
    Err(e) => fail(e)
  }
  let streamed = Bytes::from_array(joined[:])
  if streamed.length() != batch.length() {
    fail("streamed \{streamed.length()} bytes vs batch \{batch.length()}")
  }
  for i in 0..<batch.length() {
    if streamed[i] != batch[i] {
      fail("stream/batch byte mismatch at \{i}")
    }
  }
}

///|
test "h264 enc bi8: streaming encoder is byte-identical to the batch" {
  h264bi8_stream_check(false, false)
  h264bi8_stream_check(true, false)
  h264bi8_stream_check(true, true)
}

///|
/// Two runs of the same sequence must agree byte for byte, and the
/// combination stays opt-in: without `dct8x8` no Intra 8x8 B macroblock
/// is coded and the stream is the Main-profile one.
test "h264 enc bi8: deterministic and opt-in" {
  let frames = h264bi8_fixture(96, 64, 6)
  for cabac in [false, true] {
    let a = h264bi8_check(frames, cabac, false)
    let b = h264bi8_check(frames, cabac, false)
    if a.length() != b.length() {
      fail("nondeterministic length")
    }
    for i in 0..<a.length() {
      if a[i] != b[i] {
        fail("nondeterministic byte at \{i}")
      }
    }
    let stats = @libavcodec.H264EncStats::new()
    let off = if cabac {
      @libavcodec.h264_encode_frames_cabac(
        frames,
        width=96,
        height=64,
        qp=20,
        b_slices=true,
        stats~,
      )
    } else {
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        qp=20,
        b_slices=true,
        stats~,
      )
    }
    let off = match off {
      Ok(s) => s
      Err(e) => fail(e)
    }
    if stats.i8p_mbs != 0 || stats.i8_mbs != 0 {
      fail("dct8x8 off must not code any 8x8 transform")
    }
    if off.length() == a.length() {
      fail("dct8x8 must change the stream")
    }
  }
}

///|
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): all
/// three b_slices + dct8x8 modes decode with zero warnings, in DISPLAY
/// order (POC reordering), every deblocked frame matching this
/// repository's decoder byte-for-byte. Dump routes ARBBI8V / ARBBI8C /
/// ARBBI8R; the pins below were taken from those routes.
test "h264 enc bi8: ffmpeg-arbitrated six frames (96x64, QP 20)" {
  let frames = h264bi8_fixture(96, 64, 6)
  let pins = [
    [
      "208469698064f1d80620d092ca2bb19e", "79d1758ac80f13a40bbda47f6a9571ae", "0037af1eef93c8f33a64cf9bd15478d4",
      "f10b82f6dfca4c0a5f3372b7c4bbbb01", "d82f604a03383dde0bf77b2ee8220fb4", "7ab794a1d54c2550c8cd475f667f19b9",
    ],
    [
      "208469698064f1d80620d092ca2bb19e", "79d1758ac80f13a40bbda47f6a9571ae", "0037af1eef93c8f33a64cf9bd15478d4",
      "f10b82f6dfca4c0a5f3372b7c4bbbb01", "d82f604a03383dde0bf77b2ee8220fb4", "7a14afeeb3a2cd3c6b9b980bac1d7df5",
    ],
    [
      "208469698064f1d80620d092ca2bb19e", "79d1758ac80f13a40bbda47f6a9571ae", "0037af1eef93c8f33a64cf9bd15478d4",
      "f10b82f6dfca4c0a5f3372b7c4bbbb01", "d82f604a03383dde0bf77b2ee8220fb4", "bb7ca4d48ab389648a36cdfb7a0c32db",
    ],
  ]
  let routes = ["ARBBI8V", "ARBBI8C", "ARBBI8R"]
  for mode in 0..<3 {
    let stream = h264bi8_check(frames, mode > 0, mode == 2)
    let mut dump = ""
    for i in 0..<stream.length() {
      dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
    }
    println("\{routes[mode]}:\{dump}")
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    let md5s = h264bi_display_md5s(dec)
    for i in 0..<6 {
      println("\{routes[mode]}MD5:\{md5s[i]}")
      inspect(md5s[i], content=pins[mode][i])
    }
  }
}
