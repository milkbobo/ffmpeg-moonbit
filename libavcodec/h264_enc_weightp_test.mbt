// Blackbox tests for §410, the encoder-side explicit weighted prediction
// (`weightp`). A fading scene is the case explicit weights exist for: the
// reference and the source differ by a near-constant gain, so one weight per
// plane removes most of the residual energy the DCT would otherwise spend.

///|
/// A textured scene that fades by `gain/32` per frame, chroma included, so
/// the fitted luma/chroma slopes actually leave the neutral table.
fn h264wp_fade_fixture(
  w : Int32,
  h : Int32,
  n : Int32,
) -> Array[(Bytes, Bytes, Bytes)] {
  let out : Array[(Bytes, Bytes, Bytes)] = []
  let cw = w / 2
  let ch = h / 2
  for k in 0..<n {
    // 32/32, 30/32, 28/32 ... a uniform photometric fade, never reaching 0.
    let gain = 32 - 2 * k
    let y : Array[Byte] = Array::make(w * h, b'\x00')
    let u : Array[Byte] = Array::make(cw * ch, b'\x00')
    let v : Array[Byte] = Array::make(cw * ch, b'\x00')
    for row in 0..<h {
      for col in 0..<w {
        let base = (col * 3 + row * 5 + col * row % 17 * 2) % 170 + 60
        y[row * w + col] = (base * gain / 32).to_byte()
      }
    }
    for row in 0..<ch {
      for col in 0..<cw {
        let ub = 96 + (col * 5 + row * 3) % 48
        let vb = 150 - (col * 3 + row * 5) % 40
        u[row * cw + col] = (ub * gain / 32).to_byte()
        v[row * cw + col] = (vb * gain / 32).to_byte()
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
fn h264wp_md5(data : Bytes) -> String {
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
/// Mean absolute luma error of a decoded frame against the source frame.
fn h264wp_mae(
  f : @libavcodec.H264Frame,
  src : Bytes,
  w : Int32,
  h : Int32,
) -> Int32 {
  let mut sum = 0
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let d = src[row * w + col].to_int() - f.y[row * f.ystride + col]
      sum = sum + (if d < 0 { -d } else { d })
    }
  }
  sum / (w * h)
}

///|
fn h264wp_total_mae(
  dec : Array[@libavcodec.H264Frame],
  frames : Array[(Bytes, Bytes, Bytes)],
  w : Int32,
  h : Int32,
) -> Int32 {
  let mut total = 0
  for i in 1..<dec.length() {
    total = total + h264wp_mae(dec[i], frames[i].0, w, h)
  }
  total
}

///|
/// Explicit weights must actually pay off on a fade: the bitstream shrinks,
/// the P frames get closer to the source, and the encoder reconstruction
/// stays identical to what the decoder rebuilds from the weighted stream —
/// i.e. the `use_weight` gate on both sides agrees bit-for-bit.
test "h264 enc: weightp cuts a fade's residual energy" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 6)
  let rec_on : Array[Bytes] = []
  let on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      weightp=true,
      recon=rec_on,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if on.length() >= off.length() {
    fail(
      "weightp stream \{on.length()} B is not smaller than \{off.length()} B",
    )
  }
  let dec_on = match @libavcodec.h264_decode_annexb_frames(on, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let dec_off = match @libavcodec.h264_decode_annexb_frames(off, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec_on.length() != 6 || dec_off.length() != 6 {
    fail(
      "expected 6 frames each, got \{dec_on.length()} and \{dec_off.length()}",
    )
  }
  // Reconstruction invariant: with weights in play the decoder applies the
  // same table, so the unfiltered rebuild must equal the encoder's recon.
  if rec_on.length() != 5 {
    fail("expected 5 P-frame reconstructions, got \{rec_on.length()}")
  }
  for i, r in rec_on {
    if h264wp_md5(r) != h264wp_md5(dec_on[i + 1].yuvp()) {
      fail("P frame \{i + 1}: encoder recon != weighted decoder recon")
    }
  }
  let mae_on = h264wp_total_mae(dec_on, frames, w, h)
  let mae_off = h264wp_total_mae(dec_off, frames, w, h)
  if mae_on >= mae_off {
    fail("weightp did not reduce luma error: \{mae_on} vs \{mae_off}")
  }
  println(
    "WPBYTES:on=\{on.length()},off=\{off.length()} MAE:on=\{mae_on},off=\{mae_off}",
  )
  // C arbitration: docker ffmpeg 9.0.2 (`nine-x264`) decodes this stream
  // with zero warnings and its `framemd5` matches the filtered output of
  // this decoder exactly — so the `pred_weight_table()` the encoder writes
  // and the weighted MC it applies agree with FFmpeg's own implementation.
  let filtered = match @libavcodec.h264_decode_annexb_frames(on, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let pins = [
    "a89bd6379ca72e67b8593d4546f172f8", "70ad49b3f0d98ddb494fd8c90a94581f", "f3e840210eea8690dc4ab5b427e41906",
    "1a7e01b35ddb423598c496c140958b44", "936394915bdfc14a978b98a002efe77d", "6d8751612c86016c73ccff7189362006",
  ]
  for i, f in filtered {
    inspect(h264wp_md5(f.yuvp()), content=pins[i])
  }
  // Replayable Annex B dump for re-running the external arbitration.
  let mut d = ""
  for i = 0; i < on.length(); i = i + 1 {
    d = d + (on[i].to_int() & 0xFF).to_string() + ","
  }
  println("WPARB:\{d}")
}

///|
/// The new tool must stay opt-in: omitting `weightp` produces the exact same
/// bytes as an explicit `false`, so every pre-existing stream stays stable.
test "h264 enc: weightp is opt-in (default stream unchanged)" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 4)
  let default_stream = match
    @libavcodec.h264_encode_frames(frames, width=w, height=h, qp=28) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let explicit_off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=28,
      weightp=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if h264wp_md5(default_stream) != h264wp_md5(explicit_off) {
    fail("default stream differs from weightp=false")
  }
}

///|
/// A pure gain change on a static scene is the strongest weighted-prediction
/// case: the weighted prediction is exact, so the P frame collapses towards
/// its header and the reconstruction still matches the decoder.
test "h264 enc: weightp reproduces a pure gain change" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 2)
  let rec : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=30,
      b_slices=false,
      weightp=true,
      recon=rec,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 2 {
    fail("expected 2 frames, got \{dec.length()}")
  }
  if rec.length() != 1 {
    fail("expected 1 P-frame reconstruction, got \{rec.length()}")
  }
  if h264wp_md5(rec[0]) != h264wp_md5(dec[1].yuvp()) {
    fail("weighted gain change: encoder recon != decoder recon")
  }
  let mae = h264wp_mae(dec[1], frames[1].0, w, h)
  // The reference here is the lossy I-frame reconstruction, so the fade is
  // reproduced exactly only up to that I-frame error; what must hold is that
  // the weighting beats the unweighted prediction by a wide margin.
  let off = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=30,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec_off = match @libavcodec.h264_decode_annexb_frames(off, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let mae_off = h264wp_mae(dec_off[1], frames[1].0, w, h)
  if mae >= mae_off {
    fail(
      "weighted gain change did not beat the plain prediction: \{mae} vs \{mae_off}",
    )
  }
  println(
    "WPGAIN:\{stream.length()} vs \{off.length()} MAE:\{mae} vs \{mae_off}",
  )
}

///|
/// CABAC shares the same weight table writer and the same `mc_into_rec`
/// injection point; a weighted CABAC stream must decode to the encoder's
/// reconstruction as well.
test "h264 enc: weightp round-trips under CABAC" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 5)
  let rec : Array[Bytes] = []
  let stream = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      weightp=true,
      recon=rec,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let plain = match
    @libavcodec.h264_encode_frames_cabac(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if stream.length() >= plain.length() {
    fail(
      "weighted CABAC stream \{stream.length()} B is not smaller than \{plain.length()} B",
    )
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 5 {
    fail("expected 5 frames, got \{dec.length()}")
  }
  for i, r in rec {
    if h264wp_md5(r) != h264wp_md5(dec[i + 1].yuvp()) {
      fail("CABAC P frame \{i + 1}: encoder recon != decoder recon")
    }
  }
}

///|
/// `weightp` must compose with the default B-slice GOP: a weighted stream
/// with interleaved B pictures still decodes every picture, and the P frames
/// keep their smaller residuals.
test "h264 enc: weightp composes with the B-slice GOP" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 6)
  let on = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      weightp=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let off = match
    @libavcodec.h264_encode_frames(frames, width=w, height=h, qp=26) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let dec = match @libavcodec.h264_decode_annexb_frames(on, true) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec.length() != 6 {
    fail("expected 6 pictures, got \{dec.length()}")
  }
  if on.length() >= off.length() {
    fail(
      "weighted B-GOP \{on.length()} B is not smaller than \{off.length()} B",
    )
  }
  let mae_on = h264wp_total_mae(dec, frames, w, h)
  println("WPB:on=\{on.length()},off=\{off.length()} MAE:on=\{mae_on}")
}

///|
/// The streaming encoder fits the same table from the same reference: a
/// push_frame sequence must be byte-identical to the batch encoder with the
/// same options.
test "h264 enc: streaming weightp matches the batch stream" {
  let w = 96
  let h = 64
  let frames = h264wp_fade_fixture(w, h, 5)
  let enc = match
    @libavcodec.H264StreamEncoder::open(
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      weightp=true,
    ) {
    Ok(e) => e
    Err(e) => fail(e)
  }
  for f in frames {
    match enc.push_frame(f.0, f.1, f.2) {
      Ok(_) => ()
      Err(e) => fail(e)
    }
  }
  let chunks = match enc.finish() {
    Ok(c) => c
    Err(e) => fail(e)
  }
  let mut total = 0
  for c in chunks {
    total = total + c.length()
  }
  let packed : Array[Byte] = Array::make(total, b'\x00')
  let mut pos = 0
  for c in chunks {
    for i in 0..<c.length() {
      packed[pos] = c[i]
      pos = pos + 1
    }
  }
  let streamed : Bytes = Bytes::from_array(packed[:])
  let batch = match
    @libavcodec.h264_encode_frames(
      frames,
      width=w,
      height=h,
      qp=26,
      b_slices=false,
      weightp=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if h264wp_md5(streamed) != h264wp_md5(batch) {
    let mut first = -1
    let n = if streamed.length() < batch.length() {
      streamed.length()
    } else {
      batch.length()
    }
    for i in 0..<n {
      if first < 0 && streamed[i] != batch[i] {
        first = i
      }
    }
    println(
      "WPDIFF:streamed=\{streamed.length()},batch=\{batch.length()},first=\{first}",
    )
    fail("streaming weightp output differs from the batch output")
  }
}
