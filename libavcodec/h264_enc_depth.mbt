///|
/// Bit-depth plumbing for the H.264 encoder (`§412`).
///
/// Above 8 bits the spec extends the luma QP range by
/// `QpBdOffsetY = 6 * (bit_depth - 8)` and scales every dequantisation
/// factor by `2^(bit_depth - 8)` (the same `qmul << (qp/6 + 2)` formula,
/// indexed by the larger QP). The encoder therefore keeps its user-facing
/// QP in 8-bit units (`qp=26` means the same relative quantiser at every
/// bit depth — x264's `QP_BD_OFFSET`) and converts only where the quantiser,
/// the dequantisation tables and `get_chroma_qp` consume it.
///
/// Sample buffers stay `Array[Int32]` throughout (they already did for
/// 8-bit); only the input/output byte packing changes: `bit_depth > 8`
/// means planar little-endian 16-bit samples, the `yuv420p10le` layout.

///|
/// User-space QP -> the extended QP the quantiser and the shared dequant
/// tables are indexed by (`qp + QpBdOffsetY`).
fn h264_enc_qp_ext(qp : Int32, bit_depth : Int32) -> Int32 {
  qp + 6 * (bit_depth - 8)
}

///|
/// Largest representable sample value at this bit depth. The loader clips
/// 16-bit input to it, which is a no-op for conformant `yuv420p10le` data
/// and keeps stray code values from leaking into prediction.
fn h264_enc_max_sample(bit_depth : Int32) -> Int32 {
  (1 << bit_depth) - 1
}

///|
/// Encoder bit depths in scope (`§419`): 8 (Baseline/Main/High), 9 and 10
/// (High 10, profile_idc 110) plus 12 and 14 (High 4:4:4 Predictive,
/// profile_idc 244 — the only profile with `bit_depth_luma_minus8` up to 6,
/// even at 4:2:0). 11/13 stay rejected: the reference decoder
/// PATCHWELCOMEs them (h264_ps.mbt's parity check). The encoder remains
/// 4:2:0 only; 4:2:2/4:4:4 chroma is out of scope.
fn h264_enc_bit_depth_ok(bit_depth : Int32) -> Bool {
  bit_depth == 8 ||
  bit_depth == 9 ||
  bit_depth == 10 ||
  bit_depth == 12 ||
  bit_depth == 14
}

///|
/// profile_idc of the parameter sets: 244 (High 4:4:4 Predictive) above 10
/// bits, 122 (High 4:2:2) at 8..10 bits with `chroma_format=2` (`§420`),
/// 110 (High 10) at 9/10, else the caller's 8-bit profile
/// (66 Baseline / 77 Main / 100 High).
fn h264_enc_profile_idc(
  bit_depth : Int32,
  base : Int32,
  chroma~ : Int32 = 1,
) -> Int32 {
  if bit_depth > 10 {
    244
  } else if chroma == 2 {
    122
  } else if bit_depth > 8 {
    110
  } else {
    base
  }
}

///|
/// Decode one planar input plane into the macroblock-aligned `Array[Int32]`
/// the encoders work on. 8-bit inputs are packed u8; above 8 bits they are
/// little-endian 16-bit samples (`yuv420p10le`), matching the decoder's
/// `H264Frame::yuvp` output so tests can diff encoder recon against decode.
fn h264_enc_load_plane(
  src : Bytes,
  w : Int32,
  h : Int32,
  stride : Int32,
  plane_h : Int32,
  bit_depth~ : Int32 = 8,
) -> Array[Int32] {
  let plane : Array[Int32] = Array::make(stride * plane_h, 0)
  let max_sample = h264_enc_max_sample(bit_depth)
  if bit_depth > 8 {
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        let i = 2 * (row * w + col)
        let s = src[i].to_int() | (src[i + 1].to_int() << 8)
        plane[row * stride + col] = if s > max_sample { max_sample } else { s }
      }
    }
  } else {
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        plane[row * stride + col] = src[row * w + col].to_int()
      }
    }
  }
  plane
}

///|
/// Byte length one tightly packed plane of `w * h` samples occupies at this
/// bit depth: the entry points validate their inputs against it.
fn h264_enc_plane_bytes(w : Int32, h : Int32, bit_depth : Int32) -> Int32 {
  let samples = w * h
  if bit_depth > 8 {
    samples * 2
  } else {
    samples
  }
}

///|
/// Pack one plane into `Bytes` in `H264Frame::yuvp` order (8-bit u8,
/// above 8 bits little-endian 16-bit) so blackbox tests can diff the
/// encoder's reconstruction against the decoder's unfiltered output.
fn h264_enc_pack_plane(
  plane : Array[Int32],
  w : Int32,
  h : Int32,
  stride : Int32,
  bit_depth~ : Int32 = 8,
) -> Array[Byte] {
  let out : Array[Byte] = []
  for row = 0; row < h; row = row + 1 {
    for col = 0; col < w; col = col + 1 {
      let s = plane[row * stride + col]
      out.push(s.to_byte())
      if bit_depth > 8 {
        out.push((s >> 8).to_byte())
      }
    }
  }
  out
}
