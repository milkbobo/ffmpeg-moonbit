///|
/// One slice within a shared progressive picture (FFmpeg h264_slice.c).
/// LGPL-2.1-or-later. Each slice owns its entropy/QP/MV prediction state.
fn h264_decode_picture_slice(
  ctx : H264DecCtx,
  nal : H2645Nal,
  gb : BitReader,
  sh : H264SliceHeader,
  references : H264SliceRefs,
  slice_num : Int32,
) -> Result[Unit, String] {
  ctx.failed_mb = -1
  let refs = references.list0
  for (identity, buffer) in references.reference_buffers {
    ctx.reference_buffers[identity] = buffer
  }
  ctx.ref_list1 = references.list1
  ctx.ref_count1 = sh.num_ref_idx_l1_active
  ctx.colocated = references.colocated
  ctx.colocated_mbaff = references.colocated_mbaff
  ctx.colocated_field_picture = references.colocated_field_picture
  ctx.poc = references.poc
  ctx.poc_top = references.poc_top
  ctx.poc_bottom = references.poc_bottom
  ctx.long_pocs = references.long_pocs
  ctx.direct_spatial = sh.direct_spatial_mv_pred
  ctx.active_list = 0
  ctx.slice_num = slice_num
  ctx.si_slice = sh.slice_type_nos == 4
  ctx.slice_type_nos = match sh.slice_type_nos {
    3 => 0
    4 => 2
    value => value
  }
  ctx.qscale = sh.qscale
  ctx.last_qscale_diff = 0
  ctx.mb_skip_run = -1
  // `mb_field_decoding_flag = picture_structure != PICT_FRAME`.
  ctx.mb_field = ctx.field_picture
  ctx.prev_mb_skipped = false
  ctx.next_mb_skipped = false
  ctx.ref_count0 = sh.num_ref_idx_l0_active
  ctx.ref_list0 = refs.copy()
  ctx.pwt = sh.pwt
  ctx.ref_list1 = h264_fill_mbaff_refs(ctx.ref_list1, ctx.mb_aff)
  if ctx.slice_type_nos == 0 && refs.is_empty() {
    return Err("no reference picture for a P slice")
  }
  while ctx.ref_list0.length() < ctx.ref_count0 && !refs.is_empty() {
    ctx.ref_list0.push(refs[0])
  }
  ctx.ref_list0 = h264_fill_mbaff_refs(ctx.ref_list0, ctx.mb_aff)
  let cabac : CabacContext? = if ctx.pps.cabac != 0 {
    gb.align()
    match ff_init_cabac_decoder(nal.data, gb.count() / 8) {
      Ok(value) => Some(value)
      Err(error) => return Err(error)
    }
  } else {
    None
  }
  let states = ff_h264_init_cabac_states(
    sh.qscale,
    ctx.bit_depth,
    ctx.slice_type_nos,
    sh.cabac_init_flag,
  )
  // `first_mb_in_slice` counts MB pairs in MBAFF frame pictures.
  let mut terminated = false
  if ctx.mb_aff {
    let pairs_per_row = ctx.mb_width
    let total_pairs = ctx.mb_height / 2 * pairs_per_row
    let start_pair = sh.first_mb_in_slice
    let mut pair = start_pair
    while pair < total_pairs {
      let pair_y = pair / pairs_per_row * 2
      let mb_x = pair % pairs_per_row
      if mb_x == 0 && pair_y >= 2 {
        // `predict_field_decoding_flag`: left (previous row end) or top
        // (bottom MB of the previous pair row, same column).
        let left = ctx.infos[pair_y * pairs_per_row - 1]
        let above = ctx.infos[(pair_y - 1) * pairs_per_row]
        ctx.mb_field = if left.slice_num == slice_num && left.mb_type_bits != 0 {
          left.field_mb
        } else if above.slice_num == slice_num && above.mb_type_bits != 0 {
          above.field_mb
        } else {
          false
        }
      }
      for parity = 0; parity < 2; parity = parity + 1 {
        let index = (pair_y + parity) * pairs_per_row + mb_x
        let info = ctx.infos[index]
        if info.mb_type_bits != 0 {
          return Err("overlapping H.264 slices")
        }
        info.slice_num = slice_num
        info.deblock_idc = sh.disable_deblocking_filter_idc
        info.alpha_offset = 52 + sh.slice_alpha_c0_offset
        info.beta_offset = 52 + sh.slice_beta_offset
        let mb_y = pair_y + parity
        let result = match cabac {
          Some(coder) =>
            h264_decode_mb_cabac(coder, states, ctx, index, mb_x, mb_y)
          None => h264_decode_mb(gb, ctx, index, mb_x, mb_y)
        }
        match result {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        for block in 0..<16 {
          let ref_index = info.ref_idx[block]
          info.ref_identity[block] = h264_deblock_ref_id(
            ctx,
            ref_index,
            info.field_mb,
          )
          let ref1 = info.ref_idx1[block]
          info.ref_identity1[block] = h264_deblock_ref_id(
            ctx,
            ref1,
            info.field_mb,
            list=1,
          )
        }
      }
      pair += 1
      if cabac is Some(coder) && coder.get_cabac_terminate() != 0 {
        terminated = true
        break
      }
    }
    if pair == start_pair {
      return Err("empty H.264 slice")
    }
  } else if ctx.field_picture {
    // A field picture's `first_mb_in_slice` counts field MBs (field raster
    // order); the frame-row coordinate adds the field parity.
    let field_rows = ctx.mb_height / 2
    let start = sh.first_mb_in_slice
    let start_row = start / ctx.mb_width
    let start_x = start % ctx.mb_width
    let parity = if ctx.bottom_field { 1 } else { 0 }
    let mut row = start_row
    let mut count = 0
    let mut stop = false
    while row < field_rows && !stop {
      let first_x = if row == start_row { start_x } else { 0 }
      let mut x = first_x
      while x < ctx.mb_width {
        if cabac is None && gb.bits_left() <= 0 && ctx.mb_skip_run <= 0 {
          stop = true
          break
        }
        let mb_y = row * 2 + parity
        let index = mb_y * ctx.mb_width + x
        let info = ctx.infos[index]
        if info.mb_type_bits != 0 {
          return Err("overlapping H.264 slices")
        }
        info.slice_num = slice_num
        info.deblock_idc = sh.disable_deblocking_filter_idc
        info.alpha_offset = 52 + sh.slice_alpha_c0_offset
        info.beta_offset = 52 + sh.slice_beta_offset
        let result = match cabac {
          Some(coder) =>
            h264_decode_mb_cabac(coder, states, ctx, index, x, mb_y)
          None => h264_decode_mb(gb, ctx, index, x, mb_y)
        }
        match result {
          Ok(_) => ()
          Err(error) => return Err(error)
        }
        for block in 0..<16 {
          let ref_index = info.ref_idx[block]
          info.ref_identity[block] = h264_deblock_ref_id(
            ctx,
            ref_index,
            info.field_mb,
          )
          let ref1 = info.ref_idx1[block]
          info.ref_identity1[block] = h264_deblock_ref_id(
            ctx,
            ref1,
            info.field_mb,
            list=1,
          )
        }
        count = count + 1
        x = x + 1
        if cabac is Some(coder) && coder.get_cabac_terminate() != 0 {
          terminated = true
          stop = true
          break
        }
      }
      row = row + 1
    }
    if count == 0 {
      return Err("empty H.264 slice")
    }
  } else {
    let mb_count = ctx.mb_width * ctx.mb_height
    let start = sh.first_mb_in_slice
    let mut index = start
    while index < mb_count {
      if cabac is None && gb.bits_left() <= 0 && ctx.mb_skip_run <= 0 {
        break
      }
      let info = ctx.infos[index]
      if info.mb_type_bits != 0 {
        return Err("overlapping H.264 slices")
      }
      ctx.failed_mb = index
      info.slice_num = slice_num
      info.deblock_idc = sh.disable_deblocking_filter_idc
      info.alpha_offset = 52 + sh.slice_alpha_c0_offset
      info.beta_offset = 52 + sh.slice_beta_offset
      let result = match cabac {
        Some(coder) =>
          h264_decode_mb_cabac(
            coder,
            states,
            ctx,
            index,
            index % ctx.mb_width,
            index / ctx.mb_width,
          )
        None =>
          h264_decode_mb(
            gb,
            ctx,
            index,
            index % ctx.mb_width,
            index / ctx.mb_width,
          )
      }
      match result {
        Ok(_) => ()
        Err(error) => return Err(error)
      }
      let eos = match cabac {
        Some(coder) => {
          let ended = coder.get_cabac_terminate() != 0
          if coder.pos > (nal.size_bits + 7) / 8 + 4 {
            return Err("H.264 CABAC bytestream overread")
          }
          ended
        }
        None => false
      }
      for block in 0..<16 {
        let ref_index = info.ref_idx[block]
        info.ref_identity[block] = h264_deblock_ref_id(
          ctx,
          ref_index,
          info.field_mb,
        )
        let ref1 = info.ref_idx1[block]
        info.ref_identity1[block] = h264_deblock_ref_id(
          ctx,
          ref1,
          info.field_mb,
          list=1,
        )
      }
      index += 1
      ctx.failed_mb = -1
      if eos {
        terminated = true
        break
      }
    }
    if index == start {
      return Err("empty H.264 slice")
    }
  }
  if cabac is Some(_) && !terminated {
    return Err(
      "missing H.264 end_of_slice_flag: frame=\{sh.frame_num} slice=\{slice_num} first=\{sh.first_mb_in_slice}",
    )
  }
  if cabac is None && (gb.bits_left() < 0 || ctx.mb_skip_run > 0) {
    return Err("H.264 slice exceeds picture")
  }
  Ok(())
}
