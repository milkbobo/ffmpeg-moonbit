// Copyright © 2018-2021, VideoLAN and dav1d authors
// Copyright © 2018, Two Orioles, LLC
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
//    this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

///|
/// Segment-id syntax from dav1d 1.5.1 src/decode.c (BSD-2-Clause).
/// The previous map is retained only when primary-reference coded grids
/// match; its stride is then the current frame's b4_stride.
pub(all) struct Av1SegmentContext {
  msac : Av1Msac
  cdf : Av1CdfCtx
  enabled : Bool
  update_map : Bool
  temporal : Bool
  preskip : Bool
  last_active : Int32
  current : FixedArray[Byte]
  previous : FixedArray[Byte]?
  stride : Int32
}

///|
/// `get_prev_frame_segid`: minimum segment id over the visible block,
/// including every row. No previous map predicts segment zero.
fn Av1SegmentContext::previous_id(
  self : Av1SegmentContext,
  bx : Int32,
  by : Int32,
  w4 : Int32,
  h4 : Int32,
) -> Int32 raise Av1DecError {
  guard self.previous is Some(map) else { return 0 }
  let mut id = 8
  for y in 0..<h4 {
    for x in 0..<w4 {
      id = av1_imin(id, map[(by + y) * self.stride + bx + x].to_int())
    }
    if id == 0 {
      break
    }
  }
  guard id < 8 else {
    raise Av1DecError::Unsupported("av1: invalid previous segment map")
  }
  id
}

///|
/// Read the segment id at its prescribed position (before skip for an
/// unchanged map or preskip features, otherwise after skip). Returns the
/// id and the temporal-prediction bit to publish into both edge contexts.
pub fn Av1SegmentContext::read_id(
  self : Av1SegmentContext,
  bx : Int32,
  by : Int32,
  w4 : Int32,
  h4 : Int32,
  have_top : Bool,
  have_left : Bool,
  prediction_ctx : Int32,
  skip : Bool,
) -> (Int32, Int32) raise Av1DecError {
  if !self.enabled {
    return (0, 0)
  }
  if !self.update_map {
    return (self.previous_id(bx, by, w4, h4), 0)
  }
  let skip_spatial = !self.preskip && skip
  let pred = if !skip_spatial && self.temporal {
    self.msac
    .decode_bool_adapt(self.cdf.seg_pred, prediction_ctx * 2)
    .reinterpret_as_int()
  } else {
    0
  }
  if pred != 0 {
    return (self.previous_id(bx, by, w4, h4), pred)
  }
  let (spatial, ctx) = av1_get_cur_frame_segid(
    self.current,
    self.stride,
    by,
    bx,
    have_top,
    have_left,
  )
  if skip_spatial {
    return (if spatial < 8 { spatial } else { 0 }, 0)
  }
  let diff = self.msac.decode_symbol_adapt(self.cdf.seg_id, ctx * 8, 7)
  let id = av1_neg_deinterleave(diff, spatial, self.last_active + 1)
  // C assigns neg_deinterleave's result to unsigned b->seg_id before
  // clipping. Negative results therefore also become segment zero.
  (if id < 0 || id > self.last_active || id >= 8 { 0 } else { id }, 0)
}
