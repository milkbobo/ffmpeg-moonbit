///|
/// `§436` scene-cut detection (x264 `--scenecut`, 0..=100, 0 = off):
/// decide at push time whether this picture is the start of a new scene
/// and therefore codes as an IDR, closing the current GOP (a pending B
/// picture first codes as a tail P, the §431 forced-IDR path).
///
/// The proxy pair mirrors x264's inter-vs-intra cost test with two
/// deterministic subsampled sums over the raw luma plane (the same
/// every-other-row/byte grid the CRF controller samples):
///
/// - **inter** — `SAD(previous display frame, this frame)`: what motion
///   compensation from the previous picture would leave behind. On a
///   static scene it is ~0; at a hard cut it is the full frame energy.
/// - **intra** — the spatial gradient `|p[x] - p[x-1]| + |p[x] - p[row]|`
///   over the same grid: what intra prediction (which removes spatial
///   redundancy) would leave behind. Scene-dependent, motion-independent.
///   (Two edges accumulate per sample, so the sum carries an inherent 2x
///   against the single-difference inter SAD — an effective shift the
///   threshold absorbs; both sides are deterministic integers.)
///
/// A picture is a cut when inter saving has collapsed: with libx264's
/// "higher = more aggressive" reading, `scenecut = s` cuts when
///
/// ```text
/// inter * 100 >= intra * (100 - s)
/// ```
///
/// (`s = 40` cuts once the inter residual reaches 60% of the intra
/// residual; `s = 100` cuts on any inter activity). An absolute floor
/// keeps flat-to-flat noise from cutting: the inter sum must also reach
/// one unit per sixteen sampled pixels. The test is integer-only, so
/// every backend takes the same decision, and it is display-causal —
/// the streaming encoder is its only consumer (the batch entries take
/// explicit `pict_types`).
fn h264_enc_scenecut_intra(y : Bytes, height : Int32) -> Int64 {
  let row = y.length() / height
  let mut sum : Int64 = 0L
  // Skip row 0 / column 0 (no left/top neighbour); same grid as the
  // inter SAD (every other row, every other byte).
  for py = 2; py < height; py = py + 2 {
    let base = py * row
    for px = 2; px < row; px = px + 2 {
      let here = y[base + px].to_int()
      let left = y[base + px - 1].to_int()
      let top = y[base + px - row].to_int()
      let d1 = here - left
      let d2 = here - top
      sum = sum + (if d1 > 0 { d1 } else { -d1 }).to_int64()
      sum = sum + (if d2 > 0 { d2 } else { -d2 }).to_int64()
    }
  }
  sum
}

///|
/// The cut decision (see `h264_enc_scenecut_intra`). `inter` is the SAD
/// against the previous display frame, `intra` the spatial gradient,
/// `samples` the number of pixels the two sums cover (for the absolute
/// floor) and `scenecut` the caller's threshold in 0..=100.
fn h264_enc_scenecut_cut(
  inter : Int64,
  intra : Int64,
  samples : Int64,
  scenecut : Int32,
) -> Bool {
  if inter <= 0L || inter * 16L < samples {
    // Absolute floor: one unit of inter SAD per sixteen sampled pixels,
    // so flat-to-flat sensor noise never trips the cut.
    return false
  }
  if intra <= 0L {
    // Zero spatial gradient (flat frame) with real inter change: the
    // previous scene cannot predict this one — a hard cut.
    return true
  }
  inter * 100L >= intra * (100L - scenecut.to_int64())
}
