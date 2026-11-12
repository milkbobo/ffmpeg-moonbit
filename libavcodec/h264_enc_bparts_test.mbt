// Blackbox tests for the sub-partitioned B kinds (`§395`, the `b_parts`
// opt-in): 16x8/8x16 two-partition kinds and B_8x8 with per-group
// sub-macroblock decisions, both entropy coders and the streaming
// encoder. The gates: the reconstruction invariant against this
// repository's decoder (display order by POC), the sub-partition branch
// statistics, byte equality with the streaming encoder, determinism, and
// external docker-ffmpeg arbitration with pinned framemd5 values.

///|
/// A fixture that forces sub-partitioning: two 16x16 boxes on
/// independently moving halves (the top slides right, the bottom slides
/// left) over a gradient, so no 16x16 motion or spatial direct
/// reconstructs the whole macroblock and the encoder has to split.
fn h264bp_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    let tx = f * 8 % (w - 24)
    let bx = (frames_n - 1 - f) * 8 % (w - 24)
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let mut s = (col * 3 + row * 2 + f * 5) & 0xFF
        let top_box = row >= 8 && row < 24 && col >= tx && col < tx + 16
        let bot_box = row >= h - 24 && row < h - 8 && col >= bx && col < bx + 16
        if top_box && (col == tx || col == tx + 15 || row == 8 || row == 23) {
          s = 30
        } else if top_box {
          s = 235
        } else if bot_box &&
          (col == bx || col == bx + 15 || row == h - 24 || row == h - 9) {
          s = 220
        } else if bot_box {
          s = 50
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col * 2 + row + f) & 0x3F) + 96).to_byte())
        v.push((((row * 2 + col + f * 3) & 0x3F) + 96).to_byte())
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
/// Reconstruct-pixel equality between the decoder's unfiltered output
/// (coding order, offset by the IDR) and the encoder's per-picture
/// recons, for the frames from `first` on.
fn h264bp_check_recon(
  dec : Array[@libavcodec.H264Frame],
  recon : Array[Bytes],
  w : Int32,
  h : Int32,
  first : Int32,
) -> Unit raise {
  for i in first..<dec.length() {
    let r = dec[i]
    let src = recon[i - 1]
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        if src[row * w + col] != r.y[row * r.ystride + col].to_byte() {
          fail(
            "frame \{i} recon mismatch at \{row},\{col}: \{src[row * w + col]} vs \{r.y[row * r.ystride + col]}",
          )
        }
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        if src[w * h + row * (w / 2) + col] !=
          r.u[row * r.cstride + col].to_byte() {
          fail("frame \{i} u recon mismatch at \{row},\{col}")
        }
        if src[w * h + w / 2 * (h / 2) + row * (w / 2) + col] !=
          r.v[row * r.cstride + col].to_byte() {
          fail("frame \{i} v recon mismatch at \{row},\{col}")
        }
      }
    }
  }
}

///|
/// A four-quadrant fixture: every quadrant slides at its own speed and
/// direction over a noisy gradient, so 8x8 groups regularly pick
/// different lists or sub shapes from their neighbours.
fn h264bp_quad_fixture(
  w : Int32,
  h : Int32,
  frames_n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let half_w = w / 2
  let half_h = h / 2
  for f in 0..<frames_n {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let qx = if col < half_w { 0 } else { 1 }
        let qy = if row < half_h { 0 } else { 1 }
        let speed = (qx + qy * 2 + 1) * 3
        let dir = if (qx + qy) % 2 == 0 { 1 } else { -1 }
        let mut s = ((col * 7 + row * 13 + f * 11) & 0x1F) * 4 + 40
        let bx = (f * speed * dir % (half_w - 16) + half_w - 16) % (half_w - 16) +
          qx * half_w
        let by = f * speed % (half_h - 16) + qy * half_h
        let inbox = col >= bx && col < bx + 16 && row >= by && row < by + 16
        if inbox && (col == bx || col == bx + 15 || row == by || row == by + 15) {
          s = 24
        } else if inbox {
          s = 230
        }
        y.push(s.to_byte())
      }
    }
    for row = 0; row < h / 2; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col * 3 + row * 5 + f * 7) & 0x3F) + 80).to_byte())
        v.push((((row * 3 + col * 5 + f * 2) & 0x3F) + 80).to_byte())
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
test "h264 enc bparts: round trip equals encoder reconstruction (cavlc)" {
  let frames = h264bp_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if recon.length() != 5 {
    fail("expected 5 recons, got \{recon.length()}")
  }
  if stats.b_mbs <= 0 {
    fail("no B macroblocks coded: the B path was not exercised")
  }
  if stats.bpart_mbs <= 0 {
    fail("no sub-partitioned B macroblocks: the b_parts path was not exercised")
  }
  // A four-quadrant fixture (each quadrant slides differently) pushes the
  // per-group B_8x8 decision harder: finer sub shapes must survive.
  let quad = h264bp_quad_fixture(96, 64, 6)
  let qstats = @libavcodec.H264EncStats::new()
  match
    @libavcodec.h264_encode_frames(
      quad,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
      stats=qstats,
    ) {
    Ok(_) => ()
    Err(e) => fail(e)
  }
  println(
    "ARBBPARTSSTATS b=\{stats.b_mbs} part=\{stats.bpart_mbs} b8x8=\{stats.b8x8_mbs} direct=\{stats.bdirect_mbs} bi=\{stats.bi_mbs} l1=\{stats.bl1_mbs} quad_part=\{qstats.bpart_mbs} quad_8x8=\{qstats.b8x8_mbs}",
  )
  if stats.b8x8_mbs <= 0 {
    fail("no B_8x8 macroblocks: the kind-22 path was not exercised")
  }
  if qstats.bpart_mbs <= 0 {
    fail("no sub-partitioned B macroblocks on the four-quadrant fixture")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bp_check_recon(dec, recon, 96, 64, 1)
  // Filtered decode must stay well-formed too.
  match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) =>
      if f.length() != 6 {
        fail("filtered decode: expected 6 frames, got \{f.length()}")
      }
    Err(e) => fail(e)
  }
}

///|
test "h264 enc bparts: round trip equals encoder reconstruction (cabac)" {
  let frames = h264bp_fixture(96, 64, 6)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.bpart_mbs <= 0 {
    fail("no sub-partitioned B macroblocks under CABAC")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames, got \{dec.length()}")
  }
  h264bp_check_recon(dec, recon, 96, 64, 1)
}

///|
test "h264 enc bparts: round trip equals encoder reconstruction (cabac rd)" {
  let frames = h264bp_fixture(96, 64, 4)
  let recon : Array[Bytes] = []
  let stats = @libavcodec.H264EncStats::new()
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
      cabac_rd=true,
      recon~,
      stats~,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stats.bpart_mbs <= 0 {
    fail("no sub-partitioned B macroblocks under CABAC RD")
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 4 {
    fail("expected 4 frames, got \{dec.length()}")
  }
  h264bp_check_recon(dec, recon, 96, 64, 1)
}

///|
test "h264 enc bparts: streaming encoder is byte-identical to the batch" {
  let frames = h264bp_fixture(96, 64, 6)
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=96,
      height=64,
      qp=24,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  let streamed : Array[Bytes] = []
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
    for au in enc.drain() {
      streamed.push(au)
    }
  }
  match enc.finish() {
    Ok(au) =>
      for part in au {
        streamed.push(part)
      }
    Err(e) => fail(e)
  }
  let mut total = 0
  for part in streamed {
    total = total + part.length()
  }
  let joined : Array[Byte] = []
  for part in streamed {
    for i in 0..<part.length() {
      joined.push(part[i])
    }
  }
  let joined_bytes = Bytes::from_array(joined[:])
  if total != batch.length() {
    fail("streamed \{total} bytes vs batch \{batch.length()} bytes")
  }
  for i in 0..<batch.length() {
    if joined_bytes[i] != batch[i] {
      fail("stream/batch byte mismatch at \{i}")
    }
  }
}

///|
test "h264 enc bparts: deterministic and opt-in gated" {
  let frames = h264bp_fixture(64, 64, 4)
  let a = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let b = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if a.length() != b.length() {
    fail("determinism: length mismatch")
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("determinism: byte mismatch at \{i}")
    }
  }
  // b_parts without b_slices must be rejected by the stream opener.
  match @libavcodec.H264StreamEncoder::open(width=64, height=64, b_parts=true) {
    Ok(_) => fail("b_parts without b_slices must fail")
    Err(_) => ()
  }
}

///|
/// Display-order packed-YUV MD5s (the framemd5 arbitration order).
fn h264bp_display_md5s(frames : Array[@libavcodec.H264Frame]) -> Array[String] {
  let out : Array[String] = []
  for k in 0..<frames.length() {
    let want = k * 2
    let mut found = false
    for f in frames {
      if f.poc == want {
        out.push(h264b_md5(f.yuvp()))
        found = true
        break
      }
    }
    if !found {
      abort("no frame with poc \{want}")
    }
  }
  out
}

///|
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// sub-partitioned I/P/B stream decodes in the reference implementation
/// with zero warnings, in DISPLAY order (POC reordering), and every
/// deblocked frame matches this repository's decoder byte-for-byte. The
/// pinned framemd5 MD5s were obtained via the ARBBPARTS dump route.
test "h264 enc bparts: ffmpeg-arbitrated six frames (96x64, QP 22)" {
  let frames = h264bp_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i in 0..<stream.length() {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBPARTS:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames")
  }
  let md5s = h264bp_display_md5s(dec)
  for md5 in md5s {
    println("ARBBPARTSMD5:\{md5}")
  }
  let pins = [
    "56fd577a3d9ed7d5999bc5bb41b80944", "9ed533c4993031ca42de1277ff096382", "0b03dc10f8c9b188f8de948b1c8856af",
    "3871b10bae426e0acdda6cf6ca97dc56", "fcb39c4437fd5461386d41f94287749a", "5f4a4c5d55e6755cc10477a611a83325",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}

///|
/// External arbitration of the CABAC sub-partitioned stream (the CABAC
/// mb_type / sub-macroblock-type bin trees differ from the CAVLC route).
test "h264 enc bparts: ffmpeg-arbitrated CABAC six frames (96x64, QP 22)" {
  let frames = h264bp_fixture(96, 64, 6)
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=96,
      height=64,
      qp=22,
      b_slices=true,
      b_parts=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = ""
  for i in 0..<stream.length() {
    dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBPARTSCABAC:\{dump}")
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 frames")
  }
  let md5s = h264bp_display_md5s(dec)
  for md5 in md5s {
    println("ARBBPARTSCABACMD5:\{md5}")
  }
  let pins = [
    "8eebc020e8938ba2aa6ba05a9180ef8e", "2a857d7097c0a7ba22f05622c187fdc9", "1d4e094d37d48049a9abc380599eb059",
    "e3380164b347781c542f7e9db70ebff8", "9112a5482ffbd5026d720139b5ed3d1a", "05da06e97e430a3ab4b78a6212f9e123",
  ]
  for i in 0..<6 {
    inspect(md5s[i], content=pins[i])
  }
}
