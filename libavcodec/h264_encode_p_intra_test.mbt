// Blackbox tests for Intra16x16 macroblocks inside a CAVLC P slice.
//
// The intra-in-P fallback is opt-in (`intra_in_p=true`): the default chain
// keeps the inter-only baseline byte-for-byte. These tests pin the new
// syntax path against this repository's decoder, the encoder's own
// reconstruction, and docker ffmpeg's framemd5.

///|
/// Deterministic scene cut: a gradient I picture followed by two pictures
/// whose luma/chroma are flat to the right of `split_col`. Inter prediction
/// from the gradient reference cannot represent the new content, so the
/// RD decision picks the Intra16x16 fallback. `split_col=0` cuts the whole
/// picture; a mid-picture column produces a genuine intra/inter mix.
fn h264_i16_cut_fixture(
  w : Int32,
  h : Int32,
  split_col : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<3 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let flat = f > 0 && col >= split_col
        let s = if flat { 240 } else { (col * 2 + row * 3) & 0xFF }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let flat = f > 0 && col * 2 >= split_col
        u.push((if flat { 128 } else { 96 + ((col + row) & 0x3F) }).to_byte())
        v.push(
          (if flat { 128 } else { 96 + ((col * 2 + row) & 0x3F) }).to_byte(),
        )
      }
    }
    out.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  out
}

///|
fn h264_i16_md5(data : Bytes) -> String {
  let digest = FixedArray::make(16, b'\x00')
  @libavutil.av_md5_sum(digest, data, data.length())
  let hex = "0123456789abcdef"
  let text = StringBuilder()
  for byte in digest {
    text.write_char(hex.get_char((byte.to_int() >> 4) & 15).unwrap())
    text.write_char(hex.get_char(byte.to_int() & 15).unwrap())
  }
  text.to_string()
}

///|
/// Flat source content must survive the intra round trip exactly, and the
/// encoder's reconstruction must equal the decoder's unfiltered pixels for
/// every P frame (the reconstruction invariant). The ARB dump is kept so
/// the external ffmpeg arbitration can be replayed.
test "h264 enc: P-slice Intra16x16 scene cut round-trips" {
  let frames = h264_i16_cut_fixture(96, 64, 0)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  // 6x4 macroblocks: frame 1 is entirely intra, frame 2 is all P_Skip.
  if stats.i16_mbs != 24 {
    fail("expected 24 intra16x16 MBs, got \{stats.i16_mbs}")
  }
  if stats.coded_mbs != 24 {
    fail("expected 24 coded MBs, got \{stats.coded_mbs}")
  }
  let plain = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stream.length() >= plain.length() / 2 {
    fail(
      "intra stream \{stream.length()} B is not at least 2x smaller than inter \{plain.length()} B",
    )
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  if recon.length() != 2 {
    fail("expected 2 P-frame reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264_i16_md5(r) != h264_i16_md5(dec[i + 1].yuvp()) {
      fail("P frame \{i + 1}: encoder reconstruction != decoder reconstruction")
    }
  }
  let (y, _, _) = frames[1]
  let f = dec[1]
  let mut sum = 0
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let d = y[row * 96 + col].to_int() - f.y[row * f.ystride + col]
      sum = sum + (if d < 0 { -d } else { d })
    }
  }
  if sum / (96 * 64) > 1 {
    fail("flat scene-cut luma mean abs error \{sum / (96 * 64)} too high")
  }
  let filtered = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  // Pinned against docker ffmpeg 9.0.2 (`nine-x264`) framemd5: zero
  // warnings, every frame byte-identical to this decoder's filtered output.
  let pins = [
    "57c00c8ae52173ab0283e20006e5a6ec", "80fe0f660ef17d69b35e6a335553d209", "80fe0f660ef17d69b35e6a335553d209",
  ]
  for i, f in filtered {
    inspect(h264_i16_md5(f.yuvp()), content=pins[i])
  }
  // Replayable Annex B dump for the external arbitration (see test header).
  let mut d = ""
  for i = 0; i < stream.length(); i = i + 1 {
    d = d + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("I16ARB:\{d}")
}

///|
/// The new RD candidate must stay opt-in: without `intra_in_p` the stream
/// is identical to an explicit `false` and no intra MB is emitted.
test "h264 enc: intra_in_p is opt-in (inter baseline unchanged)" {
  let frames = h264_i16_cut_fixture(96, 64, 0)
  let stats = @libavcodec.H264EncStats::new()
  let default_stream = match
    @libavcodec.h264_encode_frames(frames, width=96, height=64, qp=24, stats~) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs != 0 {
    fail("default chain emitted \{stats.i16_mbs} intra16x16 MBs")
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if default_stream.length() != off.length() {
    fail("default stream length differs from intra_in_p=false")
  }
  for i = 0; i < off.length(); i = i + 1 {
    if default_stream[i] != off[i] {
      fail("default stream byte \{i} differs from intra_in_p=false")
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(default_stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("baseline stream failed to decode")
  }
}

///|
/// A partial cut mixes intra and inter macroblocks inside one P slice. This
/// is the case that exercises the nC mirror across an intra/inter boundary
/// (an I16x16 MB with cbp&15 == 0 writes no luma counts at all).
test "h264 enc: partial scene cut mixes intra16x16 and inter MBs" {
  let frames = h264_i16_cut_fixture(96, 64, 48)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs == 0 {
    fail("partial cut did not select any Intra16x16 MB")
  }
  if stats.i16_mbs >= stats.coded_mbs {
    fail("partial cut selected intra for every coded MB")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  for i, r in recon {
    if h264_i16_md5(r) != h264_i16_md5(dec[i + 1].yuvp()) {
      fail("mixed P frame \{i + 1}: encoder reconstruction != decoder")
    }
  }
}

///|
/// CABAC P-slice Intra16x16 (§384): the same scene cut, now emitted with
/// the ctx_base=17 / intra_slice=0 mb_type bins. Pinned against docker
/// ffmpeg 9.0.2 framemd5 (zero warnings, every frame byte-identical).
test "h264 enc: CABAC P-slice Intra16x16 scene cut round-trips" {
  let frames = h264_i16_cut_fixture(96, 64, 0)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs != 24 {
    fail("expected 24 CABAC Intra16x16 MBs, got \{stats.i16_mbs}")
  }
  if stats.coded_mbs != 24 {
    fail("expected 24 coded MBs, got \{stats.coded_mbs}")
  }
  let plain = match
    @libavcodec.h264_encode_frames_cabac(frames, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stream.length() >= plain.length() {
    fail(
      "CABAC intra stream \{stream.length()} B is not smaller than inter-only \{plain.length()} B",
    )
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  if recon.length() != 2 {
    fail("expected 2 P-frame reconstructions, got \{recon.length()}")
  }
  for i, r in recon {
    if h264_i16_md5(r) != h264_i16_md5(dec[i + 1].yuvp()) {
      fail("CABAC P frame \{i + 1}: encoder reconstruction != decoder")
    }
  }
  let (y, _, _) = frames[1]
  let f = dec[1]
  let mut sum = 0
  for row = 0; row < 64; row = row + 1 {
    for col = 0; col < 96; col = col + 1 {
      let d = y[row * 96 + col].to_int() - f.y[row * f.ystride + col]
      sum = sum + (if d < 0 { -d } else { d })
    }
  }
  if sum / (96 * 64) > 1 {
    fail("CABAC flat scene-cut luma mean abs error \{sum / (96 * 64)} too high")
  }
  let filtered = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins = [
    "50e3b8d58ddfb7d2d3fc3c3f54a8f2a1", "80fe0f660ef17d69b35e6a335553d209", "80fe0f660ef17d69b35e6a335553d209",
  ]
  for i, f in filtered {
    inspect(h264_i16_md5(f.yuvp()), content=pins[i])
  }
  // Replayable Annex B dump for the external arbitration.
  let mut d = ""
  for i = 0; i < stream.length(); i = i + 1 {
    d = d + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("CABARB:\{d}")
}

///|
/// The CABAC RD candidate must stay opt-in: without `intra_in_p` the stream
/// is identical to an explicit `false` and no intra MB is emitted.
test "h264 enc: CABAC intra_in_p is opt-in (baseline unchanged)" {
  let frames = h264_i16_cut_fixture(96, 64, 0)
  let stats = @libavcodec.H264EncStats::new()
  let default_stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs != 0 {
    fail("default CABAC chain emitted \{stats.i16_mbs} Intra16x16 MBs")
  }
  let off = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if default_stream.length() != off.length() {
    fail("default CABAC stream length differs from intra_in_p=false")
  }
  for i = 0; i < off.length(); i = i + 1 {
    if default_stream[i] != off[i] {
      fail("default CABAC stream byte \{i} differs from intra_in_p=false")
    }
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(default_stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("baseline CABAC stream failed to decode")
  }
}

///|
/// A partial cut mixes intra and inter macroblocks inside one CABAC P
/// slice: the intra/inter boundary is where the CABAC cbf/skip contexts
/// and the nz mirror see a different neighbour type.
test "h264 enc: CABAC partial cut mixes intra16x16 and inter MBs" {
  let frames = h264_i16_cut_fixture(96, 64, 48)
  let stats = @libavcodec.H264EncStats::new()
  let recon : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
      stats~,
      recon~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.i16_mbs == 0 {
    fail("CABAC partial cut did not select any Intra16x16 MB")
  }
  if stats.i16_mbs >= stats.coded_mbs {
    fail("CABAC partial cut selected intra for every coded MB")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 3 {
    fail("expected 3 frames, got \{dec.length()}")
  }
  for i, r in recon {
    if h264_i16_md5(r) != h264_i16_md5(dec[i + 1].yuvp()) {
      fail("mixed CABAC P frame \{i + 1}: encoder reconstruction != decoder")
    }
  }
}
