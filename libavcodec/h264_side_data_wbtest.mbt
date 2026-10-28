///|
/// Side-data export and NAL boundary semantics tests
/// (`h264_side_data.mbt`, `h264_dpb.mbt: decode_nals`), against the
/// trace_headers-transcribed values of `h264_sei_realdata_wbtest.mbt`'s
/// synthetic stream and the JM PAFF vector of `h264_paff_realdata_wbtest.mbt`.

///|
/// Build a type-6 SEI NAL (RBSP, header byte included) from messages.
fn sd_sei_nal(msgs : Array[(Int32, Bytes)]) -> H2645Nal {
  let out : Array[Byte] = [0x06]
  for k = 0; k < msgs.length(); k = k + 1 {
    let (ty, payload) = msgs[k]
    out.push(ty.to_byte())
    let mut size = payload.length()
    while size >= 255 {
      out.push(b'\xFF')
      size = size - 255
    }
    out.push(size.to_byte())
    for i = 0; i < payload.length(); i = i + 1 {
      out.push(payload[i])
    }
  }
  let data = Bytes::from_array(out[:])
  {
    data,
    size_bits: data.length() * 8,
    raw_size: data.length(),
    skipped_bytes_pos: [],
    nal_type: 6,
    ref_idc: 0,
    temporal_id: 0,
    nuh_layer_id: 0,
  }
}

///|
/// GA94 closed-caption container carrying `cc` (a multiple of 3 bytes).
fn sd_ga94(cc : Bytes) -> Bytes {
  let out : Array[Byte] = [
    0xB5,
    0x00,
    0x31,
    0x47,
    0x41,
    0x39,
    0x34,
    0x03,
    (0x40 | (cc.length() / 3)).to_byte(),
    0x00,
  ]
  for i = 0; i < cc.length(); i = i + 1 {
    out.push(cc[i])
  }
  out.push(b'\xFF')
  Bytes::from_array(out[:])
}

///|
/// DTG1 active format description with `active_format_flag` set.
fn sd_afd(v : Int32) -> Bytes {
  b"\xB5\x00\x31\x44\x54\x47\x31\x40" + Bytes::make(1, v.to_byte())
}

///|
/// V-Nova LCEVC payload bytes.
fn sd_lcevc(b : Bytes) -> Bytes {
  b"\xB4\x01\x50\x00" + b
}

///|
/// Recovery point SEI message payload: ue(cnt) + 4 flag bits.
fn sd_recovery(cnt : Int32) -> Bytes {
  let bits : Array[Int32] = []
  // ue(cnt): (nbits(x) - 1) zeros then x, with x = cnt + 1
  let x = cnt + 1
  let mut nbits = 0
  let mut v = x
  while v > 0 {
    nbits = nbits + 1
    v = v >> 1
  }
  for _i = 0; _i < nbits - 1; _i = _i + 1 {
    bits.push(0)
  }
  for i = nbits - 1; i >= 0; i = i - 1 {
    bits.push((x >> i) & 1)
  }
  // exact_match_flag, broken_link_flag, changing_slice_group_idc[2]
  bits.push(0)
  bits.push(0)
  bits.push(0)
  bits.push(0)
  while bits.length() % 8 != 0 {
    bits.push(0)
  }
  let out : Array[Byte] = []
  for i = 0; i < bits.length(); i = i + 8 {
    let mut b = 0
    for j = 0; j < 8; j = j + 1 {
      if bits[i + j] != 0 {
        b = b | (1 << (7 - j))
      }
    }
    out.push(b.to_byte())
  }
  Bytes::from_array(out[:])
}

///|
test "h264: synthetic SEI stream exports frame side data" {
  let data = @libavutil.av_base64_decode(sei_synthetic_b64, 8192).unwrap()
  let frames = h264_decode_annexb_frames(data, true).unwrap()
  assert_eq(frames.length(), 1)
  let frame = frames[0]
  assert_eq(frame.sei_recovery_frame_cnt, 3)
  // ff_h2645_sei_to_frame order: stereo3d, (matrix), (a53), unregistered,
  // ambient, mastering, content light, (afd), (lcevc), film grain, (aom).
  assert_eq(frame.side_data.length(), 7)
  match frame.side_data[0] {
    Stereo3d(s) => {
      assert_eq(s.stereo_type, av_stereo3d_side_by_side)
      assert_eq(s.flags, 0)
      assert_eq(s.view, av_stereo3d_view_packed)
    }
    _ => fail("expected Stereo3d")
  }
  match frame.side_data[1] {
    SeiUnregistered(buf) => assert_eq(buf, sei_synthetic_user_data_0())
    _ => fail("expected SeiUnregistered")
  }
  match frame.side_data[2] {
    SeiUnregistered(buf) => assert_eq(buf, sei_synthetic_user_data_1())
    _ => fail("expected SeiUnregistered")
  }
  match frame.side_data[3] {
    AmbientViewingEnvironment(env) => {
      assert_eq(env.ambient_illuminance.num, 78125)
      assert_eq(env.ambient_illuminance.den, 10000)
      assert_eq(env.ambient_light_x.num, 15635)
      assert_eq(env.ambient_light_x.den, 50000)
      assert_eq(env.ambient_light_y.num, 16450)
    }
    _ => fail("expected AmbientViewingEnvironment")
  }
  match frame.side_data[4] {
    MasteringDisplay(m) => {
      // g,b,r ordering converted to r,g,b
      assert_eq(m.display_primaries[0][0].num, 34000)
      assert_eq(m.display_primaries[0][1].num, 16000)
      assert_eq(m.display_primaries[1][0].num, 13250)
      assert_eq(m.display_primaries[1][1].num, 34500)
      assert_eq(m.display_primaries[2][0].num, 7500)
      assert_eq(m.display_primaries[2][1].num, 3000)
      assert_eq(m.white_point[0].num, 15635)
      assert_eq(m.white_point[1].num, 16450)
      assert_eq(m.display_primaries[0][0].den, 50000)
      assert_eq(m.has_primaries, 1)
      assert_eq(m.max_luminance.num, 10000000)
      assert_eq(m.max_luminance.den, 10000)
      assert_eq(m.min_luminance.num, 1)
      assert_eq(m.has_luminance, 1)
    }
    _ => fail("expected MasteringDisplay")
  }
  match frame.side_data[5] {
    ContentLight(c) => {
      assert_eq(c.max_cll, 1000)
      assert_eq(c.max_fall, 400)
    }
    _ => fail("expected ContentLight")
  }
  match frame.side_data[6] {
    FilmGrainH274(fgp) => {
      assert_eq(fgp.width, 64)
      assert_eq(fgp.height, 48)
      assert_eq(fgp.subsampling_x, 0)
      assert_eq(fgp.subsampling_y, 0)
      assert_eq(fgp.seed, 0U)
      // separate_colour_description_present_flag = 1 in this stream
      assert_eq(fgp.bit_depth_luma, 9)
      assert_eq(fgp.bit_depth_chroma, 10)
      assert_eq(fgp.color_range, 2)
      assert_eq(fgp.color_primaries, 9)
      assert_eq(fgp.color_trc, 16)
      assert_eq(fgp.color_space, 0)
      assert_eq(fgp.model_id, 1)
      assert_eq(fgp.log2_scale_factor, 2)
      assert_eq(fgp.component_model_present[0], 1)
      assert_eq(fgp.component_model_present[1], 0)
      assert_eq(fgp.component_model_present[2], 1)
      assert_eq(fgp.comp_model_value[2][0][0], -511)
    }
    _ => fail("expected FilmGrainH274")
  }
}

///|
test "h264: SEI applies to the picture of its access unit only" {
  let data = @libavutil.av_base64_decode(sei_hrd_b64, 8192).unwrap()
  let pkt = ff_h2645_packet_split(data, 4, H264, false).unwrap()
  let sei_nals : Array[H2645Nal] = []
  let slices : Array[H2645Nal] = []
  for nal in pkt.nals {
    if nal.nal_type == 6 {
      sei_nals.push(nal)
    } else if nal.nal_type == 1 || nal.nal_type == 5 {
      slices.push(nal)
    }
  }
  assert_true(sei_nals.length() >= 2)
  assert_eq(slices.length(), 2)
  // AU1 = [SPS PPS SEI x3 IDR], AU2 = [SPS PPS SEI x2 IDR] (keyint=1);
  // the unregistered user data is the last SEI NAL of each AU.
  let ps_nals : Array[H2645Nal] = []
  for nal in pkt.nals {
    if nal.nal_type == h264_nal_sps || nal.nal_type == h264_nal_pps {
      ps_nals.push(nal)
    }
  }
  let au1_sei : Array[H2645Nal] = []
  let au2_sei : Array[H2645Nal] = []
  for i = 0; i < 3; i = i + 1 {
    au1_sei.push(sei_nals[i])
  }
  for i = 3; i < 5; i = i + 1 {
    au2_sei.push(sei_nals[i])
  }
  // Prefix SEI in the same AU as the slice exports with that picture.
  let dec = new_h264_decoder()
  let au1 : Array[H2645Nal] = ps_nals.copy()
  for nal in au1_sei {
    au1.push(nal)
  }
  au1.push(slices[0])
  let out1 = dec.decode_nals(au1, true).unwrap()
  assert_true(out1 is Some(_))
  let unreg1 = out1.unwrap().side_data.filter(fn(sd) {
    sd is SeiUnregistered(_)
  })
  assert_eq(unreg1.length(), 1)
  // The x264 user data begins with the 16-byte UUID then "x264 - core 165".
  let buf = match unreg1[0] {
    SeiUnregistered(b) => b
    _ => fail("unreachable")
  }
  let mut text = ""
  for i = 16; i < buf.length(); i = i + 1 {
    text = text + buf[i].to_char().to_string()
  }
  assert_true(text.contains("x264 - core 165 - H.264/MPEG-4"))
  // x264 writes exactly one user-data SEI per stream (AU1's); AU2's SEI
  // NALs carry only HRD messages, and AU1's buffer was drained by the
  // export, so AU2's picture gets no side data at all.
  let au2 : Array[H2645Nal] = au2_sei.copy()
  au2.push(slices[1])
  let out2 = dec.decode_nals(au2, true).unwrap()
  assert_eq(out2.unwrap().side_data.length(), 0)
  // An SEI-only AU followed by a slice AU: the per-AU reset at the second
  // AU's start drops the messages (decode_nal_units' ff_h264_sei_uninit).
  let dec2 = new_h264_decoder()
  let ps_sei : Array[H2645Nal] = ps_nals.copy()
  for nal in au1_sei {
    ps_sei.push(nal)
  }
  assert_true(dec2.decode_nals(ps_sei, true).unwrap() is None)
  let out3 = dec2.decode_nals([slices[0]], true).unwrap()
  assert_eq(out3.unwrap().side_data.length(), 0)
  // A recovery point SEI of an AU is stamped on its picture; a picture
  // without one keeps -1 (`h264_frame_start`).
  let dec3 = new_h264_decoder()
  let recovery = sd_sei_nal([(6, sd_recovery(0))])
  let au_r : Array[H2645Nal] = ps_nals.copy()
  au_r.push(recovery)
  for nal in au1_sei {
    au_r.push(nal)
  }
  au_r.push(slices[0])
  let out4 = dec3.decode_nals(au_r, true).unwrap()
  assert_eq(out4.unwrap().sei_recovery_frame_cnt, 0)
  let au2b : Array[H2645Nal] = au2_sei.copy()
  au2b.push(slices[1])
  let out5 = dec3.decode_nals(au2b, true).unwrap()
  assert_eq(out5.unwrap().sei_recovery_frame_cnt, -1)
  assert_true(dec3.has_recovery_point)
}

///|
test "h264: PAFF field pair SEI boundaries" {
  let data = @libavutil.av_base64_decode(jm_paff_p_cavlc_b64(), 1000000).unwrap()
  let pkt = ff_h2645_packet_split(data, 4, H264, false).unwrap()
  let sei_field1 = sd_sei_nal([
    (4, sd_ga94(b"\x11\x22\x33")),
    (6, sd_recovery(0)),
    (4, sd_afd(0xB)),
    (4, sd_lcevc(b"\xAA\x01")),
  ])
  let sei_field2 = sd_sei_nal([
    (4, sd_ga94(b"\xAA\xBB\xCC")),
    (4, sd_afd(0x9)),
    (4, sd_lcevc(b"\xBB\x02")),
  ])
  let dec = new_h264_decoder()
  let frames : Array[H264Frame] = []
  let mut slices_seen = 0
  for nal in pkt.nals {
    if nal.nal_type == 1 || nal.nal_type == 5 {
      slices_seen = slices_seen + 1
      let group : Array[H2645Nal] = if slices_seen == 1 {
        [sei_field1, nal]
      } else if slices_seen == 2 {
        [sei_field2, nal]
      } else {
        [nal]
      }
      match dec.decode_nals(group, true).unwrap() {
        Some(frame) => frames.push(frame)
        None => ()
      }
    } else {
      ignore(dec.decode_nals([nal], true))
    }
  }
  // The first field stays pending: its messages parsed but not exported;
  // the pair (frames[0]) is the picture the assertions below target.
  assert_true(frames.length() >= 1)
  let frame = frames[0]
  // Captions of both fields merge; the second field's AFD replaces the
  // first's; both LCEVC payloads survive (alloc_picture at the first
  // field's picture start, sei_to_frame at the second's).
  let a53 = frame.side_data.filter(fn(sd) { sd is A53Cc(_) })
  assert_eq(a53.length(), 1)
  match a53[0] {
    A53Cc(buf) => assert_eq(buf, b"\x11\x22\x33\xAA\xBB\xCC")
    _ => fail("unreachable")
  }
  let afd = frame.side_data.filter(fn(sd) { sd is Afd(_) })
  assert_eq(afd.length(), 1)
  match afd[0] {
    Afd(v) => assert_eq(v, 0x9)
    _ => fail("unreachable")
  }
  let lcevc = frame.side_data.filter(fn(sd) { sd is Lcevc(_) })
  assert_eq(lcevc.length(), 2)
  // The first field's payload was attached at its picture start
  // (alloc_picture), so it precedes the export entries.
  match lcevc[0] {
    Lcevc(buf) => assert_eq(buf, b"\xAA\x01")
    _ => fail("unreachable")
  }
  match lcevc[1] {
    Lcevc(buf) => assert_eq(buf, b"\xBB\x02")
    _ => fail("unreachable")
  }
  // The pair keeps the first field's recovery point (h264_frame_start only
  // runs for frame pictures and first fields).
  assert_eq(frame.sei_recovery_frame_cnt, 0)
  // Export consumed the merged caption buffer.
  assert_true(dec.sei.itut_t35.a53_cc is None)
  assert_true(dec.sei.itut_t35.lcevc is None)
}
