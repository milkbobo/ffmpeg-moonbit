///|
/// Tests for the Opus packet, AV1 OBU/sequence-header and VP9 frame-header
/// slices. The packets come from the small real WebM files embedded in
/// `webm_codec_parameters_wbtest.mbt` (same white-box test package), so the
/// expected values are ffprobe's: Opus 48 kHz / 20 ms packets, VP9 64x48
/// keyframe, AV1 Main 64x48 yuv420p.

///|
test "opus: real WebM packets are 20 ms" {
  let bytes = @libavutil.av_base64_decode(webm_opus_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  assert_true(mkv.packets.length() >= 3)
  let p = @libavcodec.opus_parse_packet(mkv.packets[0].data).unwrap()
  assert_eq(p.frame_duration, 960)
  assert_eq(p.frame_count, 1)
  assert_eq(p.total_samples, 960)
  assert_eq(p.code, 0)
  assert_true(!p.stereo)
  assert_eq(p.mode, "hybrid")
  assert_eq(p.frame_sizes.length(), 1)
  assert_eq(p.frame_sizes[0], mkv.packets[0].data.length() - 1)
}

///|
test "opus: packet codes 0..3 and lacing" {
  let payload = Bytes::make(10, b'\x00')
  let code0 = @libavcodec.opus_parse_packet(b"\x80").unwrap()
  assert_eq(code0.frame_count, 1)
  assert_eq(code0.frame_duration, 120)
  assert_eq(code0.frame_sizes[0], 0)
  let pkt : Array[Byte] = [b'\x81']
  pkt.append(payload.to_array())
  let code1 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt[:])).unwrap()
  assert_eq(code1.frame_count, 2)
  assert_eq(code1.frame_sizes, [5, 5])
  let pkt2 : Array[Byte] = [b'\x82', b'\x03']
  pkt2.append(payload.to_array())
  let code2 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt2[:])).unwrap()
  assert_eq(code2.frame_count, 2)
  assert_eq(code2.frame_sizes, [3, 7])
  // Code 3 CBR: two equal frames.
  let pkt3 : Array[Byte] = [b'\x83', b'\x02']
  pkt3.append(payload.to_array())
  let code3 = @libavcodec.opus_parse_packet(Bytes::from_array(pkt3[:])).unwrap()
  assert_eq(code3.frame_count, 2)
  assert_eq(code3.frame_sizes, [5, 5])
  // Code 3 VBR: count byte 0x82, first frame length 3, rest 10.
  let pkt4 : Array[Byte] = [b'\x83', b'\x82', b'\x03']
  pkt4.append(payload.to_array())
  let code3v = @libavcodec.opus_parse_packet(Bytes::from_array(pkt4[:])).unwrap()
  assert_true(code3v.vbr)
  assert_eq(code3v.frame_sizes, [3, 7])
  // 60 ms config (3) with three frames exceeds the 120 ms packet limit.
  let long : Bytes = b"\x1b\x03"
  match @libavcodec.opus_parse_packet(long) {
    Ok(_) => fail("expected duration error")
    Err(e) => assert_true(e.contains("120"))
  }
}

///|
test "vp9: real WebM keyframe header" {
  let bytes = @libavutil.av_base64_decode(webm_vp9_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let key = mkv.packets[0]
  assert_true(key.is_keyframe)
  let h = @libavcodec.vp9_parse_frame_header(key.data).unwrap()
  assert_true(h.keyframe)
  assert_false(h.show_existing_frame)
  assert_true(h.show_frame)
  assert_eq(h.profile, 0)
  assert_eq(h.width, 64)
  assert_eq(h.height, 48)
  assert_eq(h.bit_depth, 8)
  assert_eq(h.color_space, 0) // unspecified
  assert_true(h.chroma_subsampling_x)
  assert_true(h.chroma_subsampling_y)
  assert_eq(h.refresh_frame_flags, 0xFF)
}

///|
test "av1: av1C and OBU sequence header" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let av1c = mkv.tracks[0].codec_priv.unwrap()
  let s = @libavcodec.av1_parse_sequence_header(av1c).unwrap()
  assert_eq(s.profile, 0)
  assert_eq(s.level, 0)
  assert_eq(s.bitdepth, 8)
  assert_false(s.monochrome)
  assert_true(s.chroma_subsampling_x)
  assert_true(s.chroma_subsampling_y)
  // The keyframe packet starts with a temporal delimiter and sequence header.
  let packet = mkv.packets[0].data
  let from_obu = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_eq(from_obu.profile, 0)
  assert_eq(from_obu.bitdepth, 8)
  assert_eq(from_obu.width, 64)
  assert_eq(from_obu.height, 48)
  assert_eq(from_obu.chroma_subsampling_x, true)
}

///|
test "av1: rejects malformed OBU input" {
  match @libavcodec.av1_parse_sequence_header(b"\xff\xff") {
    Ok(_) => fail("expected OBU error")
    Err(e) => assert_true(e.contains("av1"))
  }
}

///|
test "vp9: rejects bad frame marker and sync code" {
  match @libavcodec.vp9_parse_frame_header(b"\x00\x00\x00") {
    Ok(_) => fail("expected marker error")
    Err(e) => assert_true(e.contains("marker"))
  }
  // marker 10, profile 0, show_existing 0, keyframe 1, show_frame 1,
  // error_resilient 0, then a wrong 24-bit sync code.
  let bad : Bytes = b"\x82\x00\x00\x00"
  match @libavcodec.vp9_parse_frame_header(bad) {
    Ok(_) => fail("expected sync error")
    Err(e) => assert_true(e.contains("sync"))
  }
}

///|
test "av1: keyframe frame header matches trace_headers" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let packet = mkv.packets[0].data
  let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_true(seq.enable_order_hint)
  assert_eq(seq.order_hint_bits, 7)
  assert_eq(seq.seq_force_screen_content_tools, 2)
  let fh = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
  assert_false(fh.show_existing_frame)
  assert_eq(fh.frame_type, @libavcodec.av1_frame_key)
  assert_true(fh.show_frame)
  assert_true(fh.error_resilient_mode) // KEY+show_frame infers resilient
  assert_false(fh.disable_cdf_update)
  assert_true(fh.allow_screen_content_tools)
  assert_false(fh.force_integer_mv)
  assert_false(fh.frame_size_override_flag)
  assert_eq(fh.order_hint, 0)
  assert_eq(fh.width, 64)
  assert_eq(fh.height, 48)
  assert_eq(fh.render_width, 64)
  assert_eq(fh.render_height, 48)
  assert_false(fh.use_superres)
  assert_false(fh.allow_intrabc)
  assert_false(fh.disable_frame_end_update_cdf)
  assert_eq(fh.tile_cols, 1)
  assert_eq(fh.tile_rows, 1)
  assert_eq(fh.base_q_idx, 122)
  assert_false(fh.using_qmatrix)
  assert_false(fh.segmentation_enabled)
  assert_false(fh.delta_q_present)
  assert_eq(fh.loop_filter_level, [0, 0])
  assert_eq(fh.loop_filter_sharpness, 0)
  assert_eq(fh.cdef_damping_minus_3, 1)
  assert_eq(fh.cdef_bits, 0)
  assert_eq(fh.tx_mode, 2)
  assert_false(fh.reduced_tx_set)
}

///|
test "av1: inter frame header reference slots match trace_headers" {
  let bytes = @libavutil.av_base64_decode(webm_av1_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(mkv.packets[0].data).unwrap()
  let f1 = @libavcodec.av1_parse_frame_header(mkv.packets[1].data, seq).unwrap()
  assert_eq(f1.frame_type, @libavcodec.av1_frame_inter)
  assert_true(f1.show_frame)
  assert_false(f1.error_resilient_mode)
  assert_eq(f1.order_hint, 1)
  assert_eq(f1.primary_ref_frame, 7)
  assert_eq(f1.refresh_frame_flags, 2)
  assert_false(f1.frame_refs_short_signaling)
  assert_eq(f1.ref_frame_idx.length(), 7)
  for i in 0..<7 {
    assert_eq(f1.ref_frame_idx[i], 0)
  }
  assert_eq(f1.width, 64)
  assert_eq(f1.height, 48)
  assert_eq(f1.render_width, 64)
  assert_false(f1.allow_high_precision_mv)
  assert_eq(f1.interpolation_filter, 0)
  assert_true(f1.is_motion_mode_switchable)
  assert_true(f1.use_ref_frame_mvs)
  assert_false(f1.disable_frame_end_update_cdf)
  assert_eq(f1.tile_cols, 1)
  assert_eq(f1.tile_rows, 1)
  assert_eq(f1.base_q_idx, 159)
  assert_eq(f1.loop_filter_level, [4, 4, 8, 0])
  assert_eq(f1.tx_mode, 1)
  assert_false(f1.reference_select)
  assert_true(f1.allow_warped_motion)
  assert_false(f1.reduced_tx_set)
  assert_eq(f1.is_global.length(), 7)
  for i in 0..<7 {
    assert_false(f1.is_global[i])
  }
  let f2 = @libavcodec.av1_parse_frame_header(mkv.packets[2].data, seq).unwrap()
  assert_eq(f2.frame_type, @libavcodec.av1_frame_inter)
  assert_eq(f2.order_hint, 2)
  assert_eq(f2.refresh_frame_flags, 4)
  assert_eq(f2.ref_frame_idx[0], 1)
  assert_eq(f2.ref_frame_idx[6], 0)
}

///|
let av1_seg_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAU4EU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggMkTbuMU6uEHFO7a1OsggUi7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAaQAAAAAAABZUrmtCSK4BAAAAAAACP9eBAXPFiIFZs31eQqh5nIEAIrWcg3Vu",
  b"ZIiBAIaFVl9BVjGDgQEj44OEC+vCAOCQsIFAuoEwmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOikIEADAAKCgAAAAKv95tfIAjs",
  b"AQAAAAAAAdUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElTDZ/5zc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WI",
  b"gVmzfV5CqHlnyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYmFvbS1hdjFnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIw",
  b"MDAwMDAwMAAfQ7Z1QXXngQCjQW+BAACACgoAAAACr/ebXyAIMtwCFAA0AfEAeoA+QB+gD+gEAAIIAQgAAACgAKDcXow0ZXUygYnB",
  b"GZ9ZM5s3sKuwcldw647HxPHgIytoC5p+oVVUwlnsOvIz5oTFyxGpws0HdGT2woC+T7pAn0KCNhkyrWEuHzABy7nodOC2LJfJMiUV",
  b"+KY8NLUYUdkuwICHNB0QREoyWdVTLzZtjG1oKi4NL2A1rWaSpsrwjph2xa9QbOOTl3TfI+KUdDMxC5e6lHMo55c0+aWib3RGd2yS",
  b"k3zq/nLKxZeAZBFJbOxe/ohuyx+7YjQNno7/3Ct7s4ZF166kkAkN2veRGQjlMBnZtHagCJZUWVeSrqIOJxPlAk6qv9sZ2+S5BQJp",
  b"VBaDT2sxAp9vmtAUnjtWk8vYC0zHP8tQ2Ax5C2BSz5pZk6Bq6GqBU9LJSb+dI3UJ4AdzhzXVf3j2xvfXVP+MOD5czmgPp46/SmLX",
  b"fjZhAzkYjJZqcO6QHFO7a5G7j7OBALeK94EB8YIDp/CBAw==",
])

///|
test "av1: segmentation parameters from libaom AQ stream" {
  let bytes = @libavutil.av_base64_decode(av1_seg_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let packet = mkv.packets[0].data
  let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  let fh = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
  assert_true(fh.segmentation_enabled)
  assert_eq(fh.segmentation_feature_mask.length(), 8)
  assert_eq(fh.segmentation_alt_q, [-60, -44, -28, -12, -6, 0, 8, 16])
  for i in 0..<8 {
    assert_eq(fh.segmentation_feature_mask[i], 1)
  }
}

///|
let av1_tiles_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAbZEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggMkTbuMU6uEHFO7a1OsggbD7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAaQAAAAAAABZUrmtCSK4BAAAAAAACP9eBAXPFiEVlMV11SHJTnIEAIrWcg3Vu",
  b"ZIiBAIaFVl9BVjGDgQEj44OEC+vCAOCQsIGAuoFgmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOikIEADAAKCgAAAAM3++bXyALs",
  b"AQAAAAAAAdUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElTDZ/5zc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WI",
  b"RWUxXXVIclNnyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYmFvbS1hdjFnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIw",
  b"MDAwMDAwMAAfQ7Z1QxbngQCjQxCBAACACgoAAAADN/vm18gCMv0FFAA1oADTUEBRddAAQAHbcaQszjKTJoMoklN2JdrEmfr5gVbh",
  b"VHCs+0OqZc5BhY6DJ+A6teQObtQvR9Hfm2wNGShFzZIzAjQ200V1mrh1JK6T/yXJLGU6w5W8yip+0RAgbP/UH5mLE2u0Byel5z/D",
  b"sIMZ4YD/y+X6e0+u0zamrtG3iFV4KYvAcVWolKaGvd8nLShlJdmO+E9RNWnQWK2YAU+ssCddbRYgxBvq/VZ5ZwvykcCyBeEaub1b",
  b"cfGtk3e+lcXnWq29fbH+uMSCJPDhHjBIbMvcDglNbYesHEXRclbAEYfbKg7CSS03LDUTaw/BQdinEtRyJExz3nGD8u4MW9fJLNQe",
  b"BGj4IqylM6sVuDOUZnEI3t+lKkvY9sI3D6+EXvhsb5s+tIFg1jeUED4ttkQ07fAjZvT3D1I0kLlMCCmkTQXeH6A8DDfLJhhGUYDb",
  b"xukJ3EsqO8+EadQGffu0KBj8EVdv1aizICrCvGMs8w1PbnahgzS173IV8lkkOZl5W4COrfz914kESHvVgAsPUDotfdT8f9jmSTYo",
  b"Dq1DFc7j/+pm1PyJ/rC/vgqW1Junm43MjOu4BoCbghp1VXRnsyablMnvKNKtFfP50FLHGrd0sJ2QdU/U1uch/du4IDpfEHYeK2e0",
  b"uz9tXfRuJLGnZRPz13RB8WN97pdVtqo28q+iRwbaeUcdmPdEzbyEq3qmFhrVelDt32fPHE8QHs/m0mIj+pNdW4a28UvoIb4w57Oc",
  b"HeeBCYBw5UNERpKJA2R9T8oXMRbcW/2My9chq/80uKM0RjC/ZYlWIDR3pfDI5Z4r3dqPROhWa0XfELUqrKAtfH7//w0E9E2FEL0u",
  b"WuSvyixNZDTe+JkNpCgKXtEZRMzciCxACk9lDUykmGzf+N4h58kKaQ9CfBxO1YzpqzAa607Wj/bi8a60azl2W060Unt60LxNfkLt",
  b"5RKFsQ5JxJJ7NZ00bEKn6pEoq7i3l8uDU2LiB8cTEs0ncjMxpX2ZiIfGZiV4lbsMHDnRvc30HFO7a5G7j7OBALeK94EB8YIDp/CB",
  b"Aw==",
])

///|
test "av1: multi-tile layout and tile group header" {
  let bytes = @libavutil.av_base64_decode(av1_tiles_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let packet = mkv.packets[0].data
  let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_eq(seq.width, 128)
  assert_eq(seq.height, 96)
  let fh = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
  assert_eq(fh.tile_cols, 2)
  assert_eq(fh.tile_rows, 1)
  assert_eq(fh.tile_cols_log2, 1)
  assert_eq(fh.tile_rows_log2, 0)
  assert_eq(fh.context_update_tile_id, 1)
  assert_eq(fh.tile_size_bytes_minus1, 1)
  assert_eq(fh.header_bits, 88)
  let tg = @libavcodec.av1_parse_tile_group(packet, fh).unwrap()
  assert_eq(tg.num_tiles, 2)
  assert_eq(tg.tile_start, 0)
  assert_eq(tg.tile_end, 1)
  assert_eq(tg.data_offset, 14) // aligned header + first 2-byte size prefix
  assert_eq(tg.tile_sizes.length(), 2)
  let mut sum = 0
  for sz in tg.tile_sizes {
    assert_true(sz > 0)
    sum = sum + sz
  }
  assert_eq(sum, tg.data_size)
}

///|
let av1_grain_b64 : Bytes = bcat([
  b"GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAWEEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU",
  b"rmtTrIHWTbuMU6uEElTDZ1OsggMkTbuMU6uEHFO7a1OsggVu7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxM",
  b"YXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAaQAAAAAAABZUrmtCSK4BAAAAAAACP9eBAXPFiBB/fzHtLAdRnIEAIrWcg3Vu",
  b"ZIiBAIaFVl9BVjGDgQEj44OEC+vCAOCQsIFAuoEwmoECVbCEVbmBAVXugQDsAQAAAAAAAAIAAGOikIEADAAKCgAAAAKv95tfIBjs",
  b"AQAAAAAAAdUAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  b"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAElTDZ/5zc59jwIBnyJlFo4dFTkNPREVSRIeMTGF2ZjYzLjEuMTAyc3PZY8CLY8WI",
  b"EH9/Me0sB1FnyKRFo4dFTkNPREVSRIeXTGF2YzYzLjEuMTAyIGxpYmFvbS1hdjFnyKFFo4hEVVJBVElPTkSHkzAwOjAwOjAwLjIw",
  b"MDAwMDAwMAAfQ7Z1QcHngQCjQbuBAACACgoAAAACr/ebXyAYMqgDFAA0AAAAoAuthX8IAAzEEMgU0BhUHEQhwClIMMw4yEBYR9RP",
  b"WFlcIEAAUQBxYPGhaiGmghqio0JEAAcYDhQQmBQaGxgenCJcKmw6AgEaAgIA05FWATdKAgE+AgIBclmKAWoengIBRgICAYZ9ngGC",
  b"NHI98AJcuANk23GkLM5N83gvC7U5r4Tnb7SAfGY3pPLGQFmYHMuZvqWqXjBNjkiaQIwtZ52qNnrAYEAvyQ3AigL5PukCfQoKFq4l",
  b"reqOi0zAZ0btsdwKAGlP2/Gjt60IWiteZlfpjWzMg8efm+sE3lvn23n7YYmUbjzTSz7fWo8g7YR2HnTGLeFaBCfsdUQbdUcpMtxv",
  b"kJhJY3n3UtcAIVSYFSqHwSEqU2g/1DD+cSXmGPrYbvXvktxcWGXwkB+VAtcOLLf49uugT1QFSsbl7iBFpG5MSFpwd2RyHIrsroXi",
  b"I4E6YbInPiqauI4p7gNJS04fupEUHHnTqiYO4lwsdt7ziY9+VmyFcIwVQQetB66/EF8pHqVYuQW9JPFT7JXD9fT+F83FekDMY4sY",
  b"4EZ2eVGK1rsbcR27chxTu2uRu4+zgQC3iveBAfGCA6fwgQM=",
])

///|
test "av1: film grain parameters" {
  let bytes = @libavutil.av_base64_decode(av1_grain_b64, 100000).unwrap()
  let mkv = av_matroska_open(bytes).unwrap()
  let packet = mkv.packets[0].data
  let seq = @libavcodec.av1_parse_sequence_header(packet).unwrap()
  assert_true(seq.film_grain_params_present)
  let fh = @libavcodec.av1_parse_frame_header(packet, seq).unwrap()
  assert_true(fh.apply_grain)
  assert_eq(fh.grain_seed, 45231)
  assert_eq(fh.num_y_points, 14)
  assert_eq(fh.num_cb_points, 8)
  assert_eq(fh.num_cr_points, 9)
  assert_false(fh.chroma_scaling_from_luma)
  assert_eq(fh.grain_scaling_minus_8, 3)
  assert_eq(fh.ar_coeff_lag, 2)
  assert_eq(fh.ar_coeff_shift_minus_6, 2)
  assert_eq(fh.grain_scale_shift, 0)
  assert_eq(fh.cb_mult, 247)
  assert_eq(fh.cb_luma_mult, 192)
  assert_eq(fh.cb_offset, 18)
  assert_eq(fh.cr_mult, 229)
  assert_eq(fh.cr_luma_mult, 192)
  assert_eq(fh.cr_offset, 54)
  assert_false(fh.overlap_flag)
  assert_true(fh.clip_to_restricted_range)
}
