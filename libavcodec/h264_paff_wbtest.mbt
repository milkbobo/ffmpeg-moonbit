///|
/// Field bookkeeping expectations follow FFmpeg 9.0.2 h264_slice.c /
/// h264_refs.c. Real field-pair headers come from JM 19.0 PAFF vectors.
/// Copyright (c) 2003 Michael Niedermayer. LGPL-2.1-or-later.
fn h264_paff_first_pair() -> (H264Decoder, H264SliceHeader, H264Sps) raise {
  let data = @libavutil.av_base64_decode(jm_paff_p_cavlc_b64, 1000000).unwrap()
  let dec = new_h264_decoder()
  let mut header : H264SliceHeader? = None
  let mut fields = 0
  for nal in ff_h2645_packet_split(data, 4, H264, false).unwrap().nals {
    let output = dec.decode_nals([nal], true).unwrap()
    if nal.nal_type == 1 || nal.nal_type == 5 {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      header = Some(
        ff_h264_decode_slice_header(gb, nal.nal_type, nal.ref_idc, dec.ps).unwrap(),
      )
      fields += 1
      if fields == 1 {
        assert_true(output is None)
        assert_eq(dec.refs[0].reference, 1)
        assert_eq(dec.refs[0].pic.field_poc_bottom, 2147483647)
        assert_true(dec.pending_field is Some(_))
      } else {
        assert_true(output is Some(_))
        // The second IDR field is a non-IDR P slice with a different ref_idc.
        assert_eq(nal.nal_type, 1)
        assert_eq(nal.ref_idc, 2)
        break
      }
    }
  }
  let sh = header.unwrap()
  (dec, sh, dec.ps.sps_list[sh.sps_id].unwrap())
}

///|
test "h264 PAFF: complementary fields share identity and isolate slices" {
  let (dec, _, _) = h264_paff_first_pair()
  assert_eq(dec.refs.length(), 1)
  assert_eq(dec.refs[0].reference, 3)
  assert_true(dec.pending_field is None)
  let entry = dec.refs[0]
  assert_eq(
    entry.pic.poc,
    entry.pic.field_poc_top.min(entry.pic.field_poc_bottom),
  )
  assert_true(entry.pic.field_poc_bottom != 2147483647)
  for x in 0..<11 {
    assert_true(entry.infos[x].slice_num < entry.infos[11 + x].slice_num)
    assert_true(entry.infos[x].field_mb && entry.infos[11 + x].field_mb)
  }
}

///|
test "h264 PAFF: real vectors exercise temporal direct and multiple slices" {
  for data in [jm_paff_b_temporal_cavlc_b64, jm_paff_b_temporal_cabac_b64] {
    let headers = h264_b_headers(
      @libavutil.av_base64_decode(data, 1000000).unwrap(),
    )
    let b = headers.filter(fn(entry) { entry.0.slice_type_nos == 1 })
    assert_true(!b.is_empty())
    for (header, _) in b {
      assert_eq(header.field_pic_flag, 1)
      assert_false(header.direct_spatial_mv_pred)
    }
  }
  let headers = h264_b_headers(
    @libavutil.av_base64_decode(jm_paff_b_slices_b64, 1000000).unwrap(),
  )
  assert_true(headers.any(fn(entry) { entry.0.first_mb_in_slice > 0 }))
  let frames = h264_decode_annexb_frames(
    @libavutil.av_base64_decode(jm_paff_b_slices_b64, 1000000).unwrap(),
    true,
  ).unwrap()
  for frame in frames {
    let mut top_max = -1
    let mut bottom_min = 2147483647
    for i, info in frame.infos {
      if ((i / 11) & 1) == 0 {
        top_max = top_max.max(info.slice_num)
      } else {
        bottom_min = bottom_min.min(info.slice_num)
      }
    }
    assert_true(top_max < bottom_min)
  }
}

///|
test "h264 PAFF: field defaults, long references and B list1 field swap" {
  let (dec, sh, sps) = h264_paff_first_pair()
  let entry = dec.refs[0]
  let partial = {
    ..entry,
    frame_num: 1,
    pic: { ..entry.pic, identity: 20, },
    reference: 2,
  }
  let views = h264_def_list([entry, partial], 1)
  assert_eq(views.map(fn(view) { (view.0.identity, view.0.parity) }), [
    (entry.pic.identity, 1),
    (entry.pic.identity, 2),
    (20, 2),
  ])
  assert_eq(views[0].0.ystride, 2 * entry.pic.ystride)
  assert_eq(views[1].0.base_y, entry.pic.ystride)
  let refs = dec
    .b_references(
      {
        ..sh,
        slice_type_nos: 1,
        num_ref_idx_l0_active: 2,
        num_ref_idx_l1_active: 2,
        ref_mod_l0_ops: [],
        ref_mod_l0_vals: [],
      },
      sps,
      10,
      10,
      11,
      [],
      true,
      1,
    )
    .unwrap()
  assert_eq(refs.list0.map(fn(pic) { pic.parity }), [1, 2])
  assert_eq(refs.list1.map(fn(pic) { pic.parity }), [2, 1])
  // A B slice may have only long references; these must not also appear in
  // the short default list.
  dec.refs[0] = { ..entry, long_index: 0, }
  let refs = dec
    .b_references(
      {
        ..sh,
        slice_type_nos: 1,
        num_ref_idx_l0_active: 2,
        num_ref_idx_l1_active: 2,
        ref_mod_l0_ops: [],
        ref_mod_l0_vals: [],
      },
      sps,
      10,
      10,
      11,
      [entry.pic.identity],
      true,
      1,
    )
    .unwrap()
  assert_eq(refs.list0.map(fn(pic) { pic.parity }), [1, 2])
  assert_eq(refs.list1.map(fn(pic) { pic.parity }), [2, 1])
}

///|
test "h264 PAFF: MMCO short difference removes just the selected field" {
  let (dec, sh, sps) = h264_paff_first_pair()
  let old = { ..dec.refs[0], frame_num: 1, }
  dec.refs[0] = old
  let current = { ..old.pic, identity: 30, }
  // CurrPicNum=5, difference_minus1=2 => PicNum=2 => frame 1 bottom.
  dec
  .mark_reference(
    current,
    old.infos,
    { ..sh, frame_num: 2, adaptive_ref_marking: true, mmco: [(1, 2, 0)], },
    sps,
    false,
    true,
    1,
    false,
  )
  .unwrap()
  assert_eq(dec.refs.length(), 2)
  assert_eq(dec.refs[1].reference, 1)
  assert_eq(dec.refs[1].frame_num, 1)
  // MMCO 2 uses a long picture number directly: bottom current structure
  // selects the opposite (top) field when the low bit is zero.
  dec.refs.clear()
  dec.refs.push({ ..old, long_index: 9, })
  dec
  .mark_reference(
    current,
    old.infos,
    { ..sh, frame_num: 2, adaptive_ref_marking: true, mmco: [(2, 18, 0)], },
    sps,
    false,
    true,
    2,
    false,
  )
  .unwrap()
  assert_eq(dec.refs[1].reference, 2)
  assert_eq(dec.refs[1].long_index, 9)
}

///|
test "h264 PAFF: explicit MMCO overflow drops oldest short then lowest long" {
  let (dec, sh, sps) = h264_paff_first_pair()
  let old = dec.refs[0]
  let current = { ..old.pic, identity: 30, }
  let header = { ..sh, frame_num: 2, adaptive_ref_marking: true, mmco: [], }
  let small = { ..sps, ref_frame_count: 2, }
  dec.refs.push({
    ..old,
    frame_num: 1,
    pic: { ..old.pic, identity: 20, },
    reference: 2,
  })
  dec
  .mark_reference(current, old.infos, header, small, false, true, 1, false)
  .unwrap()
  assert_eq(dec.refs.map(fn(entry) { entry.pic.identity }), [
    30,
    old.pic.identity,
  ])
  dec.refs.clear()
  dec.refs.push({ ..old, long_index: 5, })
  dec.refs.push({ ..old, long_index: 2, pic: { ..old.pic, identity: 20, }, })
  dec
  .mark_reference(
    current,
    old.infos,
    { ..header, mmco: [(6, 0, 7)], },
    small,
    false,
    true,
    1,
    false,
  )
  .unwrap()
  assert_eq(dec.refs.map(fn(entry) { entry.long_index }), [7, 5])
}
