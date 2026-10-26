///|
/// H.264 frame side data: the `AVFrameSideData` entries the C decoder
/// attaches when a picture starts (`h264_slice.c: h264_export_frame_props` →
/// `h2645_sei.c: ff_h2645_sei_to_frame`, with `h2645_sei_to_side_data`).
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same license.
///
/// Implementation deviations from the C:
/// - Side data is a plain tagged list on `H264Frame` instead of the
///   AVFrameSideData/AVBufferRef machinery; "moving" a buffer means
///   clearing the SEI slot after copying the reference.
/// - `ff_h2645_sei_to_context` (codec-level `decoded_side_data`) is not
///   ported: the C only calls it from the HEVC decoder.
/// - `ff_aom_attach_film_grain_sets` is `#if CONFIG_HEVC_SEI` in the C but
///   runs for H.264 frames in FFmpeg's default build; ported unconditionally.
/// - The T.35 metadata parsed but never exported by the C H.264 path
///   (HDR10+ / SMPTE 2094-40 App5 / HDR Vivid — those reach frames only via
///   `ff_itut_t35_parse_payload_to_frame`, which just the AV1 decoders
///   call) stays in the SEI context, exactly like the C.
/// - `avctx->strict_std_compliance >= FF_COMPLIANCE_STRICT` for the
///   mastering-display min-luminance check becomes a `strict~` argument
///   (default false = FF_COMPLIANCE_NORMAL).

///|
/// `AVStereo3DType`. */
pub let av_stereo3d_2d : Int32 = 0

///|
pub let av_stereo3d_side_by_side : Int32 = 1

///|
pub let av_stereo3d_top_bottom : Int32 = 2

///|
pub let av_stereo3d_frame_sequence : Int32 = 3

///|
pub let av_stereo3d_checkerboard : Int32 = 4

///|
pub let av_stereo3d_side_by_side_quincunx : Int32 = 5

///|
pub let av_stereo3d_lines : Int32 = 6

///|
pub let av_stereo3d_columns : Int32 = 7

///|
/// `AVStereo3DView`. */
pub let av_stereo3d_view_packed : Int32 = 0

///|
pub let av_stereo3d_view_left : Int32 = 1

///|
pub let av_stereo3d_view_right : Int32 = 2

///|
pub let av_stereo3d_view_unspec : Int32 = 3

///|
/// `AV_STEREO3D_FLAG_INVERT`. */
pub let av_stereo3d_flag_invert : Int32 = 1 << 0

///|
/// `SEIFpaType` (`sei.h`). */
pub let sei_fpa_h264_type_checkerboard : Int32 = 0

///|
pub let sei_fpa_h264_type_interleave_column : Int32 = 1

///|
pub let sei_fpa_h264_type_interleave_row : Int32 = 2

///|
pub let sei_fpa_type_side_by_side : Int32 = 3

///|
pub let sei_fpa_type_top_bottom : Int32 = 4

///|
pub let sei_fpa_type_interleave_temporal : Int32 = 5

///|
pub let sei_fpa_h264_type_2d : Int32 = 6

///|
/// `AVFilmGrainParamsType`. */
pub let av_film_grain_params_none : Int32 = 0

///|
pub let av_film_grain_params_av1 : Int32 = 1

///|
pub let av_film_grain_params_h274 : Int32 = 2

///|
/// `AVStereo3D`. */
pub struct H264Stereo3d {
  /// `AV_STEREO3D_*`.
  mut stereo_type : Int32
  /// `AV_STEREO3D_FLAG_*`.
  mut flags : Int32
  /// `AV_STEREO3D_VIEW_*`.
  mut view : Int32
}

///|
/// `AVAmbientViewingEnvironment`. */
pub struct H264AmbientViewingEnvironment {
  ambient_illuminance : @libavutil.AVRational
  ambient_light_x : @libavutil.AVRational
  ambient_light_y : @libavutil.AVRational
}

///|
/// `AVMasteringDisplayMetadata`, primaries in r,g,b order. */
pub struct H264MasteringDisplay {
  display_primaries : Array[Array[@libavutil.AVRational]]
  white_point : Array[@libavutil.AVRational]
  mut has_primaries : Int32
  min_luminance : @libavutil.AVRational
  max_luminance : @libavutil.AVRational
  mut has_luminance : Int32
}

///|
/// `AVContentLightMetadata`. */
pub struct H264ContentLight {
  max_cll : Int32
  max_fall : Int32
}

///|
/// `AVFilmGrainParams` with `codec.h274` (`AVFilmGrainH274Params`). */
pub struct H264FilmGrainH274 {
  seed : UInt32
  width : Int32
  height : Int32
  subsampling_x : Int32
  subsampling_y : Int32
  mut bit_depth_luma : Int32
  mut bit_depth_chroma : Int32
  mut color_range : Int32
  mut color_primaries : Int32
  mut color_trc : Int32
  mut color_space : Int32
  model_id : Int32
  blending_mode_id : Int32
  log2_scale_factor : Int32
  component_model_present : Array[Int32]
  num_intensity_intervals : Array[Int32]
  num_model_values : Array[Int32]
  intensity_interval_lower_bound : Array[Array[Int32]]
  intensity_interval_upper_bound : Array[Array[Int32]]
  comp_model_value : Array[Array[Array[Int32]]]
}

///|
/// One `AVFrameSideData` entry; the label mirrors the C enum type
/// (`AV_FRAME_DATA_*`). */
pub enum H264FrameSideData {
  A53Cc(Bytes)
  Afd(Int32)
  Lcevc(Bytes)
  SeiUnregistered(Bytes)
  AmbientViewingEnvironment(H264AmbientViewingEnvironment)
  MasteringDisplay(H264MasteringDisplay)
  ContentLight(H264ContentLight)
  Stereo3d(H264Stereo3d)
  DisplayMatrix(Array[Int32])
  FilmGrainH274(H264FilmGrainH274)
  AomFilmGrain(AomFilmGrainParams)
}

///|
/// `is_frame_packing_type_valid` for H.264: the checkerboard..2D range. */
fn frame_packing_type_valid(type_ : Int32) -> Bool {
  type_ <= sei_fpa_h264_type_2d && type_ >= sei_fpa_h264_type_checkerboard
}

///|
/// `ff_h2645_sei_to_frame` (H.264 path): move the per-access-unit messages
/// of `sei` into `out` at the picture boundary. Messages that persist until
/// the next uninit (frame packing, display orientation, ambient, mastering
/// display, content light, AOM sets) are appended without being cleared;
/// the buffer-held ones (unregistered, A53, AFD, LCEVC) are drained, and
/// `film_grain_characteristics.present` keeps only sets with
/// `repetition_period != 0`.
pub fn H264SeiContext::sei_to_frame(
  self : H264SeiContext,
  out : Array[H264FrameSideData],
  vui : H2645Vui,
  bit_depth_luma : Int32,
  bit_depth_chroma : Int32,
  width : Int32,
  height : Int32,
  seed : UInt32,
  strict~ : Bool = false,
) -> Unit {
  let fp = self.frame_packing
  if fp.present != 0 &&
    frame_packing_type_valid(fp.arrangement_type) &&
    fp.content_interpretation_type > 0 &&
    fp.content_interpretation_type < 3 {
    // `av_stereo3d_create_side_data` zero-allocates: type 2D, no flags,
    // view PACKED (0).
    let stereo : H264Stereo3d = {
      stereo_type: av_stereo3d_2d,
      flags: 0,
      view: av_stereo3d_view_packed,
    }
    match fp.arrangement_type {
      t if t == sei_fpa_h264_type_checkerboard =>
        stereo.stereo_type = av_stereo3d_checkerboard
      t if t == sei_fpa_h264_type_interleave_column =>
        stereo.stereo_type = av_stereo3d_columns
      t if t == sei_fpa_h264_type_interleave_row =>
        stereo.stereo_type = av_stereo3d_lines
      t if t == sei_fpa_type_side_by_side =>
        stereo.stereo_type = if fp.quincunx_sampling_flag != 0 {
          av_stereo3d_side_by_side_quincunx
        } else {
          av_stereo3d_side_by_side
        }
      t if t == sei_fpa_type_top_bottom =>
        stereo.stereo_type = av_stereo3d_top_bottom
      t if t == sei_fpa_type_interleave_temporal =>
        stereo.stereo_type = av_stereo3d_frame_sequence
      t if t == sei_fpa_h264_type_2d => stereo.stereo_type = av_stereo3d_2d
      _ => ()
    }
    if fp.content_interpretation_type == 2 {
      stereo.flags = av_stereo3d_flag_invert
    }
    if fp.arrangement_type == sei_fpa_type_interleave_temporal {
      stereo.view = if fp.current_frame_is_frame0_flag != 0 {
        av_stereo3d_view_left
      } else {
        av_stereo3d_view_right
      }
    }
    out.push(Stereo3d(stereo))
  }
  let o = self.display_orientation
  if o.present != 0 &&
    (o.anticlockwise_rotation != 0 || o.hflip != 0 || o.vflip != 0) {
    let mut angle = o.anticlockwise_rotation.to_double() * 360.0 / 65536.0
    let rotation : Array[Int32] = Array::make(9, 0)
    // av_display_rotation_set() expects the angle in the clockwise
    // direction, hence the first minus. The flips must apply before the
    // rotation, so negate the degree once per applied flip
    // (R O(phi) = O(-phi) R).
    angle = -angle *
      (1 - 2 * (if o.hflip != 0 { 1 } else { 0 })).to_double() *
      (1 - 2 * (if o.vflip != 0 { 1 } else { 0 })).to_double()
    @libavutil.av_display_rotation_set(rotation, angle)
    @libavutil.av_display_matrix_flip(rotation, o.hflip, o.vflip)
    out.push(DisplayMatrix(rotation))
  }
  let itut_t35 = self.itut_t35
  match itut_t35.a53_cc {
    Some(buf) => {
      out.push(A53Cc(buf))
      itut_t35.a53_cc = None
    }
    None => ()
  }
  // h2645_sei_to_side_data()
  let unreg = self.unregistered
  for i = 0; i < unreg.buf_ref.length(); i = i + 1 {
    out.push(SeiUnregistered(unreg.buf_ref[i]))
  }
  unreg.buf_ref.clear()
  unreg.nb_buf_ref = 0
  if self.ambient_viewing_environment.present != 0 {
    let env = self.ambient_viewing_environment
    out.push(
      AmbientViewingEnvironment({
        ambient_illuminance: @libavutil.av_make_q(
          env.ambient_illuminance.reinterpret_as_int(),
          10000,
        ),
        ambient_light_x: @libavutil.av_make_q(env.ambient_light_x, 50000),
        ambient_light_y: @libavutil.av_make_q(env.ambient_light_y, 50000),
      }),
    )
  }
  if self.mastering_display.present != 0 {
    // HEVC uses a g,b,r ordering, which we convert to a more natural r,g,b
    let mapping : Array[Int32] = [2, 0, 1]
    let chroma_den = 50000
    let luma_den = 10000
    let md = self.mastering_display
    let metadata : H264MasteringDisplay = {
      display_primaries: [
        [@libavutil.av_make_q(0, 1), @libavutil.av_make_q(0, 1)],
        [@libavutil.av_make_q(0, 1), @libavutil.av_make_q(0, 1)],
        [@libavutil.av_make_q(0, 1), @libavutil.av_make_q(0, 1)],
      ],
      white_point: [@libavutil.av_make_q(0, 1), @libavutil.av_make_q(0, 1)],
      has_primaries: 1,
      min_luminance: @libavutil.av_make_q(
        md.min_luminance.reinterpret_as_int(),
        luma_den,
      ),
      max_luminance: @libavutil.av_make_q(
        md.max_luminance.reinterpret_as_int(),
        luma_den,
      ),
      has_luminance: 1,
    }
    for i = 0; i < 3; i = i + 1 {
      let j = mapping[i]
      metadata.display_primaries[i][0] = @libavutil.av_make_q(
        md.display_primaries[j][0],
        chroma_den,
      )
      metadata.has_primaries = metadata.has_primaries &
        (if md.display_primaries[j][0] >= 5 &&
          md.display_primaries[j][0] <= 37000 {
          1
        } else {
          0
        })
      metadata.display_primaries[i][1] = @libavutil.av_make_q(
        md.display_primaries[j][1],
        chroma_den,
      )
      metadata.has_primaries = metadata.has_primaries &
        (if md.display_primaries[j][1] >= 5 &&
          md.display_primaries[j][1] <= 42000 {
          1
        } else {
          0
        })
    }
    metadata.white_point[0] = @libavutil.av_make_q(
      md.white_point[0],
      chroma_den,
    )
    metadata.has_primaries = metadata.has_primaries &
      (if md.white_point[0] >= 5 && md.white_point[0] <= 37000 { 1 } else { 0 })
    metadata.white_point[1] = @libavutil.av_make_q(
      md.white_point[1],
      chroma_den,
    )
    metadata.has_primaries = metadata.has_primaries &
      (if md.white_point[1] >= 5 && md.white_point[1] <= 42000 { 1 } else { 0 })
    metadata.has_luminance = metadata.has_luminance &
      (if md.max_luminance >= 50000U && md.max_luminance <= 100000000U {
        1
      } else {
        0
      })
    metadata.has_luminance = metadata.has_luminance &
      (if md.min_luminance <= 50000U && md.min_luminance < md.max_luminance {
        1
      } else {
        0
      })
    // Real (blu-ray) releases in the wild come with minimum luminance
    // values of 0.000 cd/m2, so permit this edge case
    if strict {
      metadata.has_luminance = metadata.has_luminance &
        (if md.min_luminance >= 1U { 1 } else { 0 })
    }
    out.push(MasteringDisplay(metadata))
  }
  if self.content_light.present != 0 {
    let cl = self.content_light
    out.push(
      ContentLight({
        max_cll: cl.max_content_light_level,
        max_fall: cl.max_pic_average_light_level,
      }),
    )
  }
  match itut_t35.afd {
    Some(afd) => {
      out.push(Afd(afd))
      itut_t35.afd = None
    }
    None => ()
  }
  match itut_t35.lcevc {
    Some(lcevc) => {
      out.push(Lcevc(lcevc))
      itut_t35.lcevc = None
    }
    None => ()
  }
  match self.film_grain_characteristics {
    Some(fgc) =>
      if fgc.present != 0 {
        let fgp : H264FilmGrainH274 = {
          seed,
          width,
          height,
          // H.274 mandates film grain be applied to 4:4:4 frames
          subsampling_x: 0,
          subsampling_y: 0,
          bit_depth_luma: 0,
          bit_depth_chroma: 0,
          color_range: 0,
          color_primaries: 0,
          color_trc: 0,
          color_space: 0,
          model_id: fgc.model_id,
          blending_mode_id: fgc.blending_mode_id,
          log2_scale_factor: fgc.log2_scale_factor,
          component_model_present: fgc.comp_model_present_flag.copy(),
          num_intensity_intervals: fgc.num_intensity_intervals.copy(),
          num_model_values: fgc.num_model_values.copy(),
          intensity_interval_lower_bound: fgc.intensity_interval_lower_bound.copy(),
          intensity_interval_upper_bound: fgc.intensity_interval_upper_bound.copy(),
          comp_model_value: fgc.comp_model_value.copy(),
        }
        if fgc.separate_colour_description_present_flag != 0 {
          fgp.bit_depth_luma = fgc.bit_depth_luma
          fgp.bit_depth_chroma = fgc.bit_depth_chroma
          fgp.color_range = fgc.full_range + 1
          fgp.color_primaries = fgc.color_primaries
          fgp.color_trc = fgc.transfer_characteristics
          fgp.color_space = fgc.matrix_coeffs
        } else {
          fgp.bit_depth_luma = bit_depth_luma
          fgp.bit_depth_chroma = bit_depth_chroma
          if vui.video_signal_type_present_flag != 0 {
            fgp.color_range = vui.video_full_range_flag + 1
          }
          if vui.colour_description_present_flag != 0 {
            fgp.color_primaries = vui.colour_primaries
            fgp.color_trc = vui.transfer_characteristics
            fgp.color_space = vui.matrix_coeffs
          }
        }
        out.push(FilmGrainH274(fgp))
        fgc.present = if fgc.repetition_period != 0 { 1 } else { 0 }
      }
    None => ()
  }
  // ff_aom_attach_film_grain_sets()
  if itut_t35.aom_film_grain.enable != 0 {
    for i = 0; i < itut_t35.aom_film_grain.sets.length(); i = i + 1 {
      match itut_t35.aom_film_grain.sets[i] {
        Some(set) => out.push(AomFilmGrain(set))
        None => ()
      }
    }
  }
}
