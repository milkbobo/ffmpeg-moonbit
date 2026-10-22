///|
/// FFmpeg h264idct_template.c stores dctcoef as int16 at 8 bit, int32 above.
fn h264_store_coef(value : Int32, bit_depth? : Int32 = 8) -> Int32 {
  if bit_depth == 8 { h264_i16(value) } else { value }
}

///|
fn h264_store_coefu(value : UInt32, bit_depth? : Int32 = 8) -> Int32 {
  h264_store_coef(value.reinterpret_as_int(), bit_depth~)
}

///|
fn h264_max_qp(ctx : H264DecCtx) -> Int32 { 51 + 6 * (ctx.bit_depth - 8) }
