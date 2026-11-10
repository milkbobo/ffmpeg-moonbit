// Round-trip validation of the libx264 binding: the encoder's output is
// decoded by BOTH the real FFmpeg H.264 decoder (C oracle via
// `x264_decode_annexb`) and the pure MoonBit decoder of this repository,
// and the two must agree pixel-for-pixel - the same standard the decoder
// itself was accepted against. Determinism (two opens, byte-identical
// streams) pins the thread_count=1 + BITEXACT configuration the binding
// runs.

///|
fn x264_put_sample(
  plane : Array[Byte],
  idx : Int32,
  s : Int32,
  bps : Int32,
) -> Unit {
  plane[idx * bps] = (s & 0xFF).to_byte()
  if bps == 2 {
    plane[idx * bps + 1] = ((s >> 8) & 0xFF).to_byte()
  }
}

///|
/// Deterministic YUV 4:2:0 fixture: moving gradient + checkerboard + a
/// roaming 16x16 box (luma) and drifting chroma, `bps` bytes per sample LE.
fn x264_fixture(
  n : Int32,
  w : Int32,
  h : Int32,
  bps : Int32,
) -> Array[(Int64, Bytes, Bytes, Bytes)] {
  let cw = w / 2
  let ch = h / 2
  let frames : Array[(Int64, Bytes, Bytes, Bytes)] = []
  for f in 0..<n {
    let y : Array[Byte] = Array::make(w * h * bps, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch * bps, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch * bps, b'\x00')
    let bx = f * 4 % (w - 16)
    let by = f * 6 % (h - 16)
    for row in 0..<h {
      for col in 0..<w {
        let mut s = (col * 2 + row * 3 + f * 7) & 0xFF
        if (((col >> 2) + (row >> 2) + f) & 1) == 1 {
          s = (s + 48) & 0xFF
        }
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        let border = col == bx || col == bx + 15 || row == by || row == by + 15
        if inbox && border {
          s = 40
        } else if inbox {
          s = 220
        }
        x264_put_sample(y, row * w + col, s, bps)
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        x264_put_sample(u, row * cw + col, ((col + f) & 0x3F) + 96, bps)
        x264_put_sample(v, row * cw + col, ((row + f * 2) & 0x3F) + 96, bps)
      }
    }
    frames.push(
      (
        f.to_int64(),
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  frames
}

///|
/// Encode the fixture once; returns `(extradata, packets)`.
fn x264_run(
  frames : Array[(Int64, Bytes, Bytes, Bytes)],
  options : Array[(String, String)],
  pix : X264PixelFormat,
  global_header : Bool,
  bit_rate : Int32,
) -> (Bytes?, Array[X264Packet]) raise X264Error {
  let enc = X264Encoder::open(
    width=96,
    height=64,
    pix_fmt=pix,
    time_base=(1, 25),
    framerate=(25, 1),
    bit_rate~,
    global_header~,
    options~,
  )
  let extra = if global_header { Some(enc.extradata()) } else { None }
  let packets = enc.encode_all(frames)
  enc.close()
  (extra, packets)
}

///|
fn x264_bytes_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn x264_concat(packets : Array[X264Packet]) -> Bytes {
  let out : Array[Byte] = []
  for p in packets {
    for i in 0..<p.data.length() {
      out.push(p.data[i])
    }
  }
  Bytes::from_array(out[:])
}

///|
/// Diff a whole encoded stream both ways: decode with the pure MoonBit
/// decoder (presentation order) and with the in-stub C oracle, then compare
/// every frame's packed planes byte-for-byte. `bps` is bytes per sample.
fn x264_cross_decode(
  stream : Bytes,
  want_frames : Int32,
  bps : Int32,
) -> Unit raise {
  let c = match x264_decode_annexb(stream) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  let n = c.n_frames
  let width = c.width
  let height = c.height
  let frames = match
    @libavcodec.h264_decode_annexb_display_frames(stream, false) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if n != frames.length() {
    fail("frame count: C \{n} vs pure \{frames.length()}")
  }
  if n != want_frames {
    fail("expected \{want_frames} frames, decoded \{n}")
  }
  if c.bytes_per_sample() != bps {
    fail("bps: C \{c.bytes_per_sample()} vs test \{bps}")
  }
  let plane_y = width * height * bps
  let plane_c = width / 2 * (height / 2) * bps
  for i = 0; i < n; i = i + 1 {
    let f = frames[i]
    if f.width != width || f.height != height {
      fail(
        "frame \{i}: geometry \{f.width}x\{f.height} vs C \{width}x\{height}",
      )
    }
    let got = f.yuvp()
    if !x264_bytes_eq(got[0:plane_y].to_owned(), c.frame_y(i)) {
      fail("frame \{i}: luma planes differ (kind=\{c.kind})")
    }
    if !x264_bytes_eq(got[plane_y:plane_y + plane_c].to_owned(), c.frame_u(i)) {
      fail("frame \{i}: Cb planes differ")
    }
    if !x264_bytes_eq(
        got[plane_y + plane_c:plane_y + 2 * plane_c].to_owned(),
        c.frame_v(i),
      ) {
      fail("frame \{i}: Cr planes differ")
    }
  }
}

///|
test "x264 supports the canonical formats" {
  assert_true(x264_supports("libx264", Yuv420p))
  // The nine-x264 image pins Ubuntu noble's multi-bit-depth x264 build.
  assert_true(x264_supports("libx264", Yuv420p10le))
  assert_false(x264_supports("no-such-encoder", Yuv420p))
}

///|
test "x264 encode is deterministic (ultrafast/baseline, no B pictures)" {
  let frames = x264_fixture(33, 96, 64, 1)
  let options : Array[(String, String)] = [
    ("preset", "ultrafast"),
    ("profile", "baseline"),
    ("g", "25"),
  ]
  let (extra1, pk1) = x264_run(frames, options, Yuv420p, false, 0)
  let (extra2, pk2) = x264_run(frames, options, Yuv420p, false, 0)
  assert_true(extra1 is None)
  assert_true(extra2 is None)
  if pk1.length() != 33 || pk2.length() != 33 {
    fail("expected 33 packets, got \{pk1.length()} / \{pk2.length()}")
  }
  for i in 0..<pk1.length() {
    if !x264_bytes_eq(pk1[i].data, pk2[i].data) {
      fail("packet \{i} differs between two identical runs")
    }
    assert_eq(pk1[i].pts, pk2[i].pts)
    assert_eq(pk1[i].dts, pk2[i].dts)
    assert_eq(pk1[i].keyframe, pk2[i].keyframe)
  }
  assert_true(pk1[0].keyframe)
}

///|
test "x264 ultrafast/baseline annexb round-trip matches both decoders" {
  let frames = x264_fixture(33, 96, 64, 1)
  let (_, pk) = x264_run(
    frames,
    [("preset", "ultrafast"), ("profile", "baseline"), ("g", "25")],
    Yuv420p,
    false,
    0,
  )
  // No global header: packets are complete Annex B access units
  // (SPS/PPS in-band at every IDR); plain concatenation is a valid stream.
  x264_cross_decode(x264_concat(pk), 33, 1)
}

///|
test "x264 medium preset round-trip (CABAC, High profile, B pictures)" {
  let frames = x264_fixture(33, 96, 64, 1)
  let (_, pk) = x264_run(
    frames,
    [("preset", "medium"), ("crf", "23"), ("g", "25"), ("bf", "3")],
    Yuv420p,
    false,
    0,
  )
  if pk.length() != 33 {
    fail("expected 33 packets (one per picture), got \{pk.length()}")
  }
  x264_cross_decode(x264_concat(pk), 33, 1)
}

///|
/// Split an Annex B byte stream into its NAL payloads (start codes dropped,
/// trailing zero bytes of 4-byte codes stripped).
fn x264_split_annexb(data : Bytes) -> Array[Bytes] {
  let nals : Array[Bytes] = []
  let len = data.length()
  let mut i = 0
  let mut start = -1
  while i < len {
    if i + 2 < len &&
      data[i] == b'\x00' &&
      data[i + 1] == b'\x00' &&
      data[i + 2] == b'\x01' {
      if start >= 0 {
        let mut end = i
        // trailing zeros before a start code belong to the code
        while end > start && data[end - 1] == b'\x00' {
          end = end - 1
        }
        nals.push(data[start:end].to_owned())
      }
      start = i + 3
      i = start
    } else {
      i = i + 1
    }
  }
  if start >= 0 && start < len {
    nals.push(data[start:len].to_owned())
  }
  nals
}

///|
/// Build an avcC record from Annex B SPS/PPS NALs - exactly what movenc
/// does when muxing libx264 output (FFmpeg's wrapper hands the muxer an
/// Annex B parameter-set blob as extradata).
fn x264_build_avcc(nals : Array[Bytes]) -> Bytes raise {
  let mut sps : Bytes? = None
  let mut pps : Bytes? = None
  for nal in nals {
    // nal header: forbidden_zero(1) nal_ref_idc(2) nal_unit_type(5)
    match nal[0].to_int() & 0x1F {
      7 => sps = Some(nal)
      8 => pps = Some(nal)
      _ => ()
    }
  }
  let sps = match sps {
    Some(v) => v
    None => fail("no SPS NAL in extradata")
  }
  let pps = match pps {
    Some(v) => v
    None => fail("no PPS NAL in extradata")
  }
  let out : Array[Byte] = [
    b'\x01', // configurationVersion
    sps[1], // profile_idc
    sps[2], // constraint flags + reserved
    sps[3], // level_idc
    b'\xFF', // lengthSizeMinusOne = 3 -> 4-byte lengths
    b'\xE1', // 1 SPS
    (sps.length() >> 8).to_byte(),
    sps.length().to_byte(),
  ]
  for i in 0..<sps.length() {
    out.push(sps[i])
  }
  out.push(b'\x01') // 1 PPS
  out.push((pps.length() >> 8).to_byte())
  out.push(pps.length().to_byte())
  for i in 0..<pps.length() {
    out.push(pps[i])
  }
  Bytes::from_array(out[:])
}

///|
/// One Annex B access unit -> one MP4-style sample: every NAL prefixed with
/// its u32be length.
fn x264_au_to_lenprefixed(au : Bytes) -> Bytes {
  let out : Array[Byte] = []
  for nal in x264_split_annexb(au) {
    let len = nal.length()
    out.push((len >> 24).to_byte())
    out.push(((len >> 16) & 0xFF).to_byte())
    out.push(((len >> 8) & 0xFF).to_byte())
    out.push((len & 0xFF).to_byte())
    for i in 0..<len {
      out.push(nal[i])
    }
  }
  Bytes::from_array(out[:])
}

///|
test "x264 global header -> avcC path (movenc-style) round-trip" {
  let frames = x264_fixture(33, 96, 64, 1)
  // global_header: the wrapper moves SPS/PPS out of the bitstream into
  // extradata (an Annex B parameter-set blob) and stops repeating headers.
  let (extra, pk) = x264_run(
    frames,
    [("preset", "medium"), ("g", "25")],
    Yuv420p,
    true,
    0,
  )
  let annexb_ps = match extra {
    Some(b) => b
    None => fail("no extradata with global_header")
  }
  // Build the avcC the way an MP4 muxer would, then decode the pure MP4
  // path: avcC extradata + length-prefixed samples.
  let avcc = x264_build_avcc(x264_split_annexb(annexb_ps))
  if avcc[0] != b'\x01' {
    fail("built record is not avcC")
  }
  let ps = @libavcodec.new_h264_param_sets()
  let info = match @libavcodec.ff_h264_decode_extradata(avcc, ps) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  assert_eq(info.nal_length_size, 4)
  let sps = match ps.sps_list[0] {
    Some(v) => v
    None => fail("no SPS decoded from extradata")
  }
  // medium preset: 8x8 transform + CABAC -> High profile, 4:2:0, 8-bit.
  assert_eq(sps.profile_idc, 100)
  assert_eq(sps.chroma_format_idc, 1)
  assert_eq(sps.bit_depth_luma, 8)
  let samples : Array[Bytes] = []
  for p in pk {
    samples.push(x264_au_to_lenprefixed(p.data))
  }
  let frames_avc = match
    @libavcodec.h264_decode_avc_display_frames(avcc, samples, false) {
    Ok(v) => v
    Err(e) => fail(e)
  }
  if frames_avc.length() != 33 {
    fail("avc path: expected 33 frames, got \{frames_avc.length()}")
  }
  // The same bitstream as Annex B (extradata in front of the packets) via
  // the C oracle must produce identical pixels.
  let stream_parts : Array[X264Packet] = [
    { data: annexb_ps, pts: None, dts: None, keyframe: false, },
  ]
  for p in pk {
    stream_parts.push(p)
  }
  let stream = x264_concat(stream_parts)
  let c = match x264_decode_annexb(stream) {
    Ok(v) => v
    Err(e) => fail("C oracle decode of the repacked stream: \{e}")
  }
  if c.n_frames != frames_avc.length() {
    fail(
      "repacked stream frame count: C \{c.n_frames} vs pure \{frames_avc.length()}",
    )
  }
  for i = 0; i < c.n_frames; i = i + 1 {
    let packed = frames_avc[i].yuvp()
    if !x264_bytes_eq(packed[0:96 * 64].to_owned(), c.frame_y(i)) ||
      !x264_bytes_eq(packed[96 * 64:96 * 64 + 48 * 32].to_owned(), c.frame_u(i)) ||
      !x264_bytes_eq(packed[96 * 64 + 48 * 32:].to_owned(), c.frame_v(i)) {
      fail("frame \{i}: avc path and C repack decode differ")
    }
  }
}

///|
test "x264 10-bit round-trip (High 10)" {
  let frames = x264_fixture(33, 96, 64, 2)
  let (_, pk) = x264_run(
    frames,
    [("preset", "medium"), ("crf", "20"), ("profile", "high10"), ("g", "25")],
    Yuv420p10le,
    false,
    0,
  )
  // C blob kind 1 = yuv420p10le; every sample is 2 bytes LE.
  x264_cross_decode(x264_concat(pk), 33, 2)
}

///|
test "x264 oracle: pure-MoonBit CABAC encoder stream decodes identically in C" {
  // The repository's own CABAC encoder (Main profile I+P): its Annex B
  // stream must satisfy the dual-decode standard - FFmpeg's C decoder and
  // the pure MoonBit decoder agree pixel-for-pixel.
  let frames8 = x264_fixture(6, 96, 64, 1)
  let planes : Array[(Bytes, Bytes, Bytes)] = []
  for f in frames8 {
    let (_, y, u, v) = f
    planes.push((y, u, v))
  }
  let stream = match
    @libavcodec.h264_encode_frames_cabac(planes, width=96, height=64, qp=24) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 6, 1)
}

///|
/// Deterministic scene cut for the pure-MoonBit encoder's Intra16x16-in-P
/// path: a gradient I picture followed by two flat white pictures (the
/// whole frame with `split_col=0`, only the right half otherwise).
fn x264_cut_fixture(split_col : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<3 {
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(w / 2 * (h / 2), b'\x00')
    let v : Array[Byte] = Array::make(w / 2 * (h / 2), b'\x00')
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let flat = f > 0 && col >= split_col
        let s = if flat { 240 } else { (col * 2 + row * 3) & 0xFF }
        y[row * w + col] = s.to_byte()
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        let flat = f > 0 && col * 2 >= split_col
        u[row * (w / 2) + col] = (if flat {
          128
        } else {
          96 + ((col + row) & 0x3F)
        }).to_byte()
        v[row * (w / 2) + col] = (if flat {
          128
        } else {
          96 + ((col * 2 + row) & 0x3F)
        }).to_byte()
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
/// The intra16x16-in-P macroblock syntax (mb_type 5..30, DC/AC CAVLC
/// splitting) must satisfy the same dual-decode standard as the x264 and
/// CABAC encoder streams: FFmpeg's C decoder and this repository's decoder
/// agree on every pixel of every frame.
test "x264 oracle: pure-MoonBit P-slice Intra16x16 stream decodes identically in C" {
  let frames = x264_cut_fixture(0)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}

///|
/// A partial cut puts intra and inter macroblocks in the same P slice; the
/// nC mirror across that boundary is the subtle part of §383, so it gets
/// its own C-oracle regression.
test "x264 oracle: mixed intra/inter P slice decodes identically in C" {
  let frames = x264_cut_fixture(48)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}

///|
/// Shape validation is the safe wrapper's job (moonbit-c-binding phase 3).
/// Empty and start-code-only buffers must fail before the extern is called,
/// never as an opaque NULL blob from C.
test "x264 oracle: short streams are rejected by the safe wrapper" {
  match x264_decode_annexb(b"") {
    Ok(_) => fail("empty stream unexpectedly decoded")
    Err(_) => ()
  }
  match x264_decode_annexb(b"\x00\x00\x00\x01") {
    Ok(_) => fail("start-code-only stream unexpectedly decoded")
    Err(_) => ()
  }
}

///|
/// §384: the CABAC P-slice intra16x16 branch (ctx_base 17, intra_slice 0)
/// must satisfy the same dual-decode standard - FFmpeg's C decoder and the
/// pure MoonBit decoder agree on every pixel of every frame.
test "x264 oracle: CABAC P-slice Intra16x16 stream decodes identically in C" {
  let frames = x264_cut_fixture(0)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}

///|
/// The mixed CABAC slice puts intra and inter macroblocks behind the same
/// arithmetic engine, so the C oracle also covers the context transition.
test "x264 oracle: CABAC mixed intra/inter P slice decodes identically in C" {
  let frames = x264_cut_fixture(48)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      intra_in_p=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}

///|
/// Textured ramps + a roaming box: content the 8x8 transform's compaction
/// wins on, so the I frame codes genuine I8x8 macroblocks and the P frames
/// carry inter 8x8 residuals.
fn x264_dct8_fixture() -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<3 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let bx = f * 4 % (w - 16)
    let by = f * 6 % (h - 16)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = ((col + row) * 2) & 0xFF
        if (col / 8 + row / 8 + f) % 2 == 1 {
          s = (s + 24) & 0xFF
        }
        if col >= bx && col < bx + 16 && row >= by && row < by + 16 {
          s = (s + 90) & 0xFF
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((96 + ((col + f) & 0x1F)).to_byte())
        v.push((160 - ((row + 2 * f) & 0x1F)).to_byte())
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
/// The High-profile transform_8x8 stream (SPS profile 100, PPS
/// transform_8x8_mode_flag, I-frame I8x8 macroblocks and inter 8x8
/// residuals) must satisfy the dual-decode standard: FFmpeg's C decoder
/// and the pure MoonBit decoder agree pixel-for-pixel.
test "x264 oracle: pure-MoonBit 8x8DCT CABAC stream decodes identically in C" {
  let frames = x264_dct8_fixture()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=24,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}

///|
/// The CAVLC High-profile 8x8DCT stream (four interleaved sub-lists per
/// quadrant, transform_size_8x8_flag, leader nz sums) through the same
/// dual-decode standard: FFmpeg's C decoder and the pure MoonBit decoder
/// agree pixel-for-pixel.
test "x264 oracle: pure-MoonBit 8x8DCT CAVLC stream decodes identically in C" {
  let frames = x264_dct8_fixture()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      dct8x8=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  x264_cross_decode(stream, 3, 1)
}
