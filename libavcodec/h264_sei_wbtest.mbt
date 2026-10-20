///|
/// White-box tests for `h264_sei.mbt` against FFmpeg-derived vectors. The
/// real streams live in `h264_sei_realdata_wbtest.mbt`; expected values were
/// transcribed from `ffmpeg -c copy -bsf:v trace_headers` runs on those
/// exact bytes (generation commands in that file's header).

///|
/// Decode every SEI NAL (and the parameter sets) of one Annex B stream into
/// a fresh `H264SeiContext`, mirroring `h264dec.c`'s NAL loop. The SEI
/// payload handed to `h264_sei_decode` is the NAL RBSP minus the header
/// byte, trimmed to `size_bits` like the C's `get_bits_left(gb) / 8`.
fn sei_decode_stream(data : Bytes) -> Result[H264SeiContext, String] {
  let pkt = match ff_h2645_packet_split(data, 4, H264, false) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let ps = new_h264_param_sets()
  let sei = new_h264_sei_context()
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_seq_parameter_set(gb, ps, false) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == h264_nal_pps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_picture_parameter_set(gb, ps, gb.size_bits()) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if nal.nal_type == 6 {
      let nbytes = (nal.size_bits - 8) / 8
      if nbytes <= 0 {
        continue
      }
      let payload = nal.data.clamped_view(start=1, end=1 + nbytes).to_owned()
      match sei.h264_sei_decode(payload, ps) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    }
  }
  Ok(sei)
}

///|
/// Expected payload of the first unregistered user-data message of the
/// synthetic stream (trace_headers: uuid 0x10..0x1f, then ASCII text).
fn sei_synthetic_user_data_0() -> Bytes {
  let text = b"moonbit-sei-test"
  let out = FixedArray::make(32, b'\x00')
  for i = 0; i < 16; i = i + 1 {
    out[i] = (0x10 + i).to_byte()
  }
  for i = 0; i < 16; i = i + 1 {
    out[16 + i] = text[i]
  }
  Bytes::from_array(out)
}

///|
/// Expected payload of the second unregistered message (0xAA UUID x16,
/// then "second-unreg-data").
fn sei_synthetic_user_data_1() -> Bytes {
  let text = b"second-unreg-data"
  let out = FixedArray::make(33, b'\xAA')
  for i = 0; i < 17; i = i + 1 {
    out[16 + i] = text[i]
  }
  Bytes::from_array(out)
}

///|
/// x264 CBR stream: buffering period + picture timing SEI (VUI HRD) and the
/// x264 user-data SEI. trace_headers of this stream gives, in stream order:
///   AU1: BP initial_cpb_removal_delay[0] = 80999, offset = 9001;
///        picture timing cpb_removal_delay = 0 (5 bits), dpb_output = 0;
///   AU2: BP 73898 / 16102; picture timing cpb_removal_delay = 2, dpb = 0.
/// The SPS carries nal_hrd=1, cpb_cnt=1, initial_cpb_removal_delay_length=19,
/// cpb_removal_delay_length=5, dpb_output_delay_length=23, pic_struct=0.
test "h264: x264 CBR stream - buffering period / picture timing / user data" {
  let data = @libavutil.av_base64_decode(sei_hrd_b64, 8192).unwrap()
  let sei = sei_decode_stream(data).unwrap()
  // Last buffering period wins (AU2)
  assert_eq(sei.buffering_period.present, 1)
  assert_eq(sei.buffering_period.initial_cpb_removal_delay[0], 73898)
  // Last picture timing wins (AU2); values are only materialised by the
  // deferred parse, like the C (decode_picture_timing only stashes).
  assert_eq(sei.picture_timing.present, 1)
  assert_eq(sei.picture_timing.cpb_removal_delay, -1)
  // Deferred parse against the SPS
  let sps = sei_process_sps_of_stream(data).unwrap()
  let _ = sei.sei_process_picture_timing(sps).unwrap()
  assert_eq(sei.picture_timing.cpb_removal_delay, 2)
  assert_eq(sei.picture_timing.dpb_output_delay, 0)
  // x264 writes exactly one user-data SEI (per trace_headers); build sniffed
  // from the ASCII text
  assert_eq(sei.unregistered.nb_buf_ref, 1)
  assert_eq(sei.unregistered.x264_build, 165)
}

///|
/// Display orientation SEI inserted by the h264_metadata bsf. trace_headers:
/// cancel=0, hor_flip=1, ver_flip=1, anticlockwise_rotation=16384 (90 deg),
/// repetition_period=1; the x264 user-data SEI is still present.
test "h264: display orientation SEI from h264_metadata bsf" {
  let data = @libavutil.av_base64_decode(sei_orient_b64, 4096).unwrap()
  let sei = sei_decode_stream(data).unwrap()
  assert_eq(sei.display_orientation.present, 1)
  assert_eq(sei.display_orientation.anticlockwise_rotation, 16384)
  assert_eq(sei.display_orientation.hflip, 1)
  assert_eq(sei.display_orientation.vflip, 1)
  assert_eq(sei.unregistered.x264_build, 165)
}

///|
/// Synthetic SEI stream, every field cross-checked against trace_headers.
/// Green metadata has no CBS dumper, so its expectations come from the
/// payload bytes the trace shows (00 02 01 2C 0A 14 1E 28 -> type 0,
/// period 2, num_seconds 300, percents 10/20/30/40).
test "h264: synthetic SEI messages align with trace_headers" {
  let data = @libavutil.av_base64_decode(sei_synthetic_b64, 4096).unwrap()
  let sei = sei_decode_stream(data).unwrap()
  // user data unregistered x2 (payloads byte-exact per trace)
  assert_eq(sei.unregistered.nb_buf_ref, 2)
  assert_eq(sei.unregistered.buf_ref[0], sei_synthetic_user_data_0())
  assert_eq(sei.unregistered.buf_ref[1], sei_synthetic_user_data_1())
  assert_eq(sei.unregistered.x264_build, 0)
  // recovery point: recovery_frame_cnt=3 (exact/broken/ChangingSliceGroup skipped)
  assert_eq(sei.recovery_point.recovery_frame_cnt, 3)
  // green metadata
  assert_eq(sei.green_metadata.green_metadata_type, 0)
  assert_eq(sei.green_metadata.period_type, 2)
  assert_eq(sei.green_metadata.num_seconds, 300)
  assert_eq(sei.green_metadata.percent_non_zero_macroblocks, 10)
  assert_eq(sei.green_metadata.percent_intra_coded_macroblocks, 20)
  assert_eq(sei.green_metadata.percent_six_tap_filtering, 30)
  assert_eq(sei.green_metadata.percent_alpha_point_deblocking_instance, 40)
  // film grain characteristics
  let fgc = sei.film_grain_characteristics.unwrap()
  assert_eq(fgc.present, 1)
  assert_eq(fgc.model_id, 1)
  assert_eq(fgc.separate_colour_description_present_flag, 1)
  assert_eq(fgc.bit_depth_luma, 9)
  assert_eq(fgc.bit_depth_chroma, 10)
  assert_eq(fgc.full_range, 1)
  assert_eq(fgc.color_primaries, 9)
  assert_eq(fgc.transfer_characteristics, 16)
  assert_eq(fgc.matrix_coeffs, 0)
  assert_eq(fgc.blending_mode_id, 1)
  assert_eq(fgc.log2_scale_factor, 2)
  assert_eq(fgc.comp_model_present_flag[0], 1)
  assert_eq(fgc.comp_model_present_flag[1], 0)
  assert_eq(fgc.comp_model_present_flag[2], 1)
  assert_eq(fgc.num_intensity_intervals[0], 1)
  assert_eq(fgc.num_model_values[0], 3)
  assert_eq(fgc.intensity_interval_lower_bound[0][0], 10)
  assert_eq(fgc.intensity_interval_upper_bound[0][0], 200)
  assert_eq(fgc.comp_model_value[0][0][0], -5)
  assert_eq(fgc.comp_model_value[0][0][1], 0)
  assert_eq(fgc.comp_model_value[0][0][2], 100)
  assert_eq(fgc.num_intensity_intervals[2], 1)
  assert_eq(fgc.num_model_values[2], 1)
  assert_eq(fgc.intensity_interval_lower_bound[2][0], 0)
  assert_eq(fgc.intensity_interval_upper_bound[2][0], 255)
  assert_eq(fgc.comp_model_value[2][0][0], -511)
  assert_eq(fgc.repetition_period, 8)
  // frame packing arrangement
  assert_eq(sei.frame_packing.present, 1)
  assert_eq(sei.frame_packing.arrangement_id, 42)
  assert_eq(sei.frame_packing.arrangement_cancel_flag, 0)
  assert_eq(sei.frame_packing.arrangement_type, 3)
  assert_eq(sei.frame_packing.quincunx_sampling_flag, 0)
  assert_eq(sei.frame_packing.content_interpretation_type, 1)
  assert_eq(sei.frame_packing.current_frame_is_frame0_flag, 1)
  assert_eq(sei.frame_packing.arrangement_repetition_period, 2)
  // alternative transfer characteristics
  assert_eq(sei.alternative_transfer.present, 1)
  assert_eq(sei.alternative_transfer.preferred_transfer_characteristics, 16)
  // ambient viewing environment
  assert_eq(sei.ambient_viewing_environment.present, 1)
  assert_eq(sei.ambient_viewing_environment.ambient_illuminance, 78125U)
  assert_eq(sei.ambient_viewing_environment.ambient_light_x, 15635)
  assert_eq(sei.ambient_viewing_environment.ambient_light_y, 16450)
  // mastering display colour volume
  assert_eq(sei.mastering_display.present, 2)
  assert_eq(sei.mastering_display.display_primaries[0][0], 13250)
  assert_eq(sei.mastering_display.display_primaries[0][1], 34500)
  assert_eq(sei.mastering_display.display_primaries[1][0], 7500)
  assert_eq(sei.mastering_display.display_primaries[1][1], 3000)
  assert_eq(sei.mastering_display.display_primaries[2][0], 34000)
  assert_eq(sei.mastering_display.display_primaries[2][1], 16000)
  assert_eq(sei.mastering_display.white_point[0], 15635)
  assert_eq(sei.mastering_display.white_point[1], 16450)
  assert_eq(sei.mastering_display.max_luminance, 10000000U)
  assert_eq(sei.mastering_display.min_luminance, 1U)
  // content light level
  assert_eq(sei.content_light.present, 2)
  assert_eq(sei.content_light.max_content_light_level, 1000)
  assert_eq(sei.content_light.max_pic_average_light_level, 400)
  // display orientation: cancel flag -> not present
  assert_eq(sei.display_orientation.present, 0)
  // picture timing with clock timestamps
  assert_eq(sei.picture_timing.present, 1)
  let sps = sei_process_sps_of_stream(data).unwrap()
  let _ = sei.sei_process_picture_timing(sps).unwrap()
  assert_eq(sei.picture_timing.cpb_removal_delay, 13)
  assert_eq(sei.picture_timing.dpb_output_delay, 7777)
  assert_eq(sei.picture_timing.pic_struct, 3)
  assert_eq(sei.picture_timing.ct_type, 2)
  assert_eq(sei.picture_timing.timecode_cnt, 1)
  let tc = sei.picture_timing.timecode[0]
  assert_eq(tc.full, 1)
  assert_eq(tc.dropframe, 1)
  assert_eq(tc.frame, 25)
  assert_eq(tc.seconds, 30)
  assert_eq(tc.minutes, 45)
  assert_eq(tc.hours, 13)
}

///|
/// Parse the single SPS of a stream and return it (test helper).
fn sei_process_sps_of_stream(data : Bytes) -> Result[H264Sps, String] {
  let pkt = match ff_h2645_packet_split(data, 4, H264, false) {
    Ok(v) => v
    Err(e) => return Err(e)
  }
  let ps = new_h264_param_sets()
  for k = 0; k < pkt.nals.length(); k = k + 1 {
    let nal = pkt.nals[k]
    if nal.nal_type == h264_nal_sps {
      let gb = BitReader::with_size(nal.data, nal.size_bits)
      gb.skip(8)
      match ff_h264_decode_seq_parameter_set(gb, ps, false) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      break
    }
  }
  match ps.sps_list[0] {
    Some(s) => Ok(s)
    None => Err("no SPS")
  }
}

///|
/// Buffering period referencing a missing SPS: the C returns
/// AVERROR_PS_NOT_FOUND, the loop continues and `master_ret` ends negative.
test "h264: buffering period with missing SPS is non-fatal" {
  let sei = new_h264_sei_context()
  let ps = new_h264_param_sets()
  // message: type 0, size 1, payload = ue(0) + rbsp stop
  let ret = sei.h264_sei_decode(b"\x00\x01\x80", ps)
  assert_eq(ret.unwrap(), -1)
  assert_eq(sei.buffering_period.present, 0)
}

///|
/// Negative vectors: exact error strings (the C returns AVERROR_INVALIDDATA
/// in each of these paths).
test "h264: SEI negative vectors" {
  let sei = new_h264_sei_context()
  let ps = new_h264_param_sets()
  // unregistered user data shorter than 16 bytes
  assert_eq(
    sei.h264_sei_decode(b"\x05\x08\xAA\xAA\xAA\xAA\xAA\xAA\xAA\xAA", ps),
    Err("EINVAL"),
  )
  // declared size larger than the remaining payload
  assert_eq(
    sei.h264_sei_decode(b"\x05\x28\xAA\xAA\xAA\xAA\xAA\xAA\xAA\xAA\xAA\xAA", ps),
    Err("EINVAL"),
  )
  // recovery_frame_cnt >= 1 << MAX_LOG2_MAX_FRAME_NUM (ue(65536))
  assert_eq(
    sei.h264_sei_decode(b"\x06\x05\x00\x00\x80\x00\xD4", ps),
    Err("EINVAL"),
  )
  // film grain with num_model_values_minus1 = 6 (7 values > 6)
  assert_eq(sei.h264_sei_decode(b"\x13\x04\x00\x10\x06\x80", ps), Err("EINVAL"))
  // unknown SEI types are skipped without error; two zero bytes end the NAL
  assert_eq(sei.h264_sei_decode(b"\x0A\x01\x55\x00\x00", ps), Ok(0))
  // SPS id beyond 31 in buffering period is EINVAL even with SPS present
  assert_eq(sei.h264_sei_decode(b"\x00\x01\x80", new_h264_param_sets()), Ok(-1))
}
