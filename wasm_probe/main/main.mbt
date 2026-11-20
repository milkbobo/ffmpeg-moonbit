// !! 本文件由 scripts/generate_wasm_size_probe.py 生成，勿手改 !!
// 用 abort("p") 发散实参调用每个公开函数：调用点无法被 DCE 消除，
// 函数体必须链接进 wasm；main 不会真的跑完（首个调用即发散），仅测体积。

///|
fn main raise {
  let _ = @libavutil.av_add_stable(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_adler32_update(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_aes_alloc()
  let _ = @libavutil.av_aes_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_aes_ctr_alloc()
  let _ = @libavutil.av_aes_ctr_crypt(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_aes_ctr_get_iv(abort("p"))
  let _ = @libavutil.av_aes_ctr_increment_iv(abort("p"))
  let _ = @libavutil.av_aes_ctr_init(abort("p"), abort("p"))
  let _ = @libavutil.av_aes_ctr_set_full_iv(abort("p"), abort("p"))
  let _ = @libavutil.av_aes_ctr_set_iv(abort("p"), abort("p"))
  let _ = @libavutil.av_aes_init(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_append_path_component(abort("p"), abort("p"))
  let _ = @libavutil.av_base64_decode(abort("p"), abort("p"))
  let _ = @libavutil.av_base64_decode_syntax(abort("p"))
  let _ = @libavutil.av_base64_encode(abort("p"))
  let _ = @libavutil.av_base64_size(abort("p"))
  let _ = @libavutil.av_basename(abort("p"))
  let _ = @libavutil.av_bessel_i0(abort("p"))
  let _ = @libavutil.av_blowfish_alloc()
  let _ = @libavutil.av_blowfish_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_blowfish_crypt_ecb(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_blowfish_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_cast5_alloc()
  let _ = @libavutil.av_cast5_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_cast5_crypt2(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_cast5_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_cmp_q(abort("p"), abort("p"))
  let _ = @libavutil.av_compare_mod(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_compare_ts(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_crc(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_crc_get_table(abort("p"))
  let _ = @libavutil.av_crc_ids()
  let _ = @libavutil.av_crc_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_d2q(abort("p"), abort("p"))
  let _ = @libavutil.av_dirname(abort("p"))
  let _ = @libavutil.av_display_matrix_flip(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_display_rotation_set(abort("p"), abort("p"))
  let _ = @libavutil.av_div_q(abort("p"), abort("p"))
  let _ = @libavutil.av_escape(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_gcd(abort("p"), abort("p"))
  let _ = @libavutil.av_gcd_q(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_get_token(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_inv_q(abort("p"))
  let _ = @libavutil.av_log2(abort("p"))
  let _ = @libavutil.av_make_q(abort("p"), abort("p"))
  let _ = @libavutil.av_match_list(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_match_name(abort("p"), abort("p"))
  let _ = @libavutil.av_md5_alloc()
  let _ = @libavutil.av_md5_final(abort("p"), abort("p"))
  let _ = @libavutil.av_md5_init(abort("p"))
  let _ = @libavutil.av_md5_sum(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_md5_update(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_mul_q(abort("p"), abort("p"))
  let _ = @libavutil.av_q2d(abort("p"))
  let _ = @libavutil.av_q2intfloat(abort("p"))
  let _ = @libavutil.av_rc4_alloc()
  let _ = @libavutil.av_rc4_crypt(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_rc4_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_reduce(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_rescale(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_rescale_q(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_rescale_q_rnd(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_rescale_rnd(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_sat_add64(abort("p"), abort("p"))
  let _ = @libavutil.av_sha_alloc()
  let _ = @libavutil.av_sha_final(abort("p"), abort("p"))
  let _ = @libavutil.av_sha_init(abort("p"), abort("p"))
  let _ = @libavutil.av_sha_sum(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_sha_update(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_strcasecmp(abort("p"), abort("p"))
  let _ = @libavutil.av_strireplace(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_stristart(abort("p"), abort("p"))
  let _ = @libavutil.av_stristr(abort("p"), abort("p"))
  let _ = @libavutil.av_strlcat(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_strlcpy(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_strncasecmp(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_strnstr(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_strstart(abort("p"), abort("p"))
  let _ = @libavutil.av_sub_q(abort("p"), abort("p"))
  let _ = @libavutil.av_tea_alloc()
  let _ = @libavutil.av_tea_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_tea_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavutil.av_utf8_decode(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_xtea_alloc()
  let _ = @libavutil.av_xtea_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_xtea_init(abort("p"), abort("p"))
  let _ = @libavutil.av_xtea_le_crypt(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavutil.av_xtea_le_init(abort("p"), abort("p"))
  let _ = @libavutil.ff_ctzll(abort("p"))
  let _ = @libavformat.adts_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.aiff_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.au_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.av1c_parse(abort("p"))
  let _ = @libavformat.av_ac3_open(abort("p"))
  let _ = @libavformat.av_adts_open(abort("p"))
  let _ = @libavformat.av_aiff_open(abort("p"))
  let _ = @libavformat.av_amr_open(abort("p"))
  let _ = @libavformat.av_asf_open(abort("p"))
  let _ = @libavformat.av_au_open(abort("p"))
  let _ = @libavformat.av_caf_open(abort("p"))
  let _ = @libavformat.av_dash_parse(abort("p"))
  let _ = @libavformat.av_hls_parse(abort("p"))
  let _ = @libavformat.av_matroska_open(abort("p"))
  let _ = @libavformat.av_matroska_parse_cues(abort("p"))
  let _ = @libavformat.av_mov_open(abort("p"))
  let _ = @libavformat.av_mov_open_avio(abort("p"))
  let _ = @libavformat.av_mov_open_with(abort("p"), abort("p"))
  let _ = @libavformat.av_mp3_open(abort("p"))
  let _ = @libavformat.av_mpegts_open(abort("p"))
  let _ = @libavformat.av_ogg_flac_open(abort("p"))
  let _ = @libavformat.av_ogg_opus_open(abort("p"))
  let _ = @libavformat.av_ogg_vorbis_open(abort("p"))
  let _ = @libavformat.av_probe_input_buffer(abort("p"))
  let _ = @libavformat.av_probe_input_format(abort("p"))
  let _ = @libavformat.av_probe_input_format2(abort("p"))
  let _ = @libavformat.av_w64_open(abort("p"))
  let _ = @libavformat.av_wav_open(abort("p"))
  let _ = @libavformat.av_wav_probe(abort("p"))
  let _ = @libavformat.avio_open_dyn_buf()
  let _ = @libavformat.caf_alac_muxer_new(abort("p"))
  let _ = @libavformat.caf_lpcm_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.codec_parameters_from_extradata(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.dash_fill_template(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.dash_parse_duration(abort("p"))
  let _ = @libavformat.dash_segment_reader_new(abort("p"), abort("p"))
  let _ = @libavformat.dash_write_segment_base_mpd(
    abort("p"),
    media_duration_seconds=abort("p"),
  )
  let _ = @libavformat.dash_write_segment_list_mpd(
    abort("p"),
    media_duration_seconds=abort("p"),
  )
  let _ = @libavformat.dash_write_segment_template_mpd(
    abort("p"),
    media_duration_seconds=abort("p"),
  )
  let _ = @libavformat.dash_write_segment_template_mpd_periods(
    abort("p"),
    media_duration_seconds=abort("p"),
  )
  let _ = @libavformat.dash_write_timeline_mpd(
    abort("p"),
    media_duration_seconds=abort("p"),
  )
  let _ = @libavformat.decode_audio_file(abort("p"))
  let _ = @libavformat.ebml_parse(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_parse_nest(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_read_ascii(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_read_binary(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_read_float(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.ebml_read_length(abort("p"))
  let _ = @libavformat.ebml_read_master(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_read_num(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ebml_read_sint(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.ebml_read_uint(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.ff_crc04C11DB7_update(abort("p"), abort("p"))
  let _ = @libavformat.ff_crcA001_update(abort("p"), abort("p"))
  let _ = @libavformat.ff_crcEDB88320_update(abort("p"), abort("p"))
  let _ = @libavformat.ff_id3v2_match(abort("p"))
  let _ = @libavformat.ff_id3v2_tag_len(abort("p"))
  let _ = @libavformat.ff_mkv_codec_id(abort("p"))
  let _ = @libavformat.ff_mpegts_stream_type(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ff_wav_codec_id(abort("p"), abort("p"))
  let _ = @libavformat.ffio_open_dyn_packet_buf(abort("p"))
  let _ = @libavformat.ffio_open_null_buf()
  let _ = @libavformat.flac_add_tags(abort("p"), abort("p"))
  let _ = @libavformat.flac_read_tags(abort("p"))
  let _ = @libavformat.fmp4_aac_init_segment(abort("p"), abort("p"))
  let _ = @libavformat.fmp4_ac3_init_segment(abort("p"))
  let _ = @libavformat.fmp4_av1_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_av_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_av_media_segment(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.fmp4_eac3_init_segment(abort("p"))
  let _ = @libavformat.fmp4_h264_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_hevc_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_media_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_opus_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.fmp4_sample(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.fmp4_sidx(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.fmp4_vp9_init_segment(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.hls_decrypt_aes128(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.hls_encrypt_aes128(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.hls_iv_from_sequence(abort("p"))
  let _ = @libavformat.hls_parse_attributes(abort("p"))
  let _ = @libavformat.hls_parse_byterange(abort("p"))
  let _ = @libavformat.hls_parse_iv(abort("p"))
  let _ = @libavformat.hls_resolve_uri(abort("p"), abort("p"))
  let _ = @libavformat.hls_segment_reader_new(abort("p"), abort("p"))
  let _ = @libavformat.hls_subtitle_track_open(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.hls_vtt_cue_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.hls_vtt_parse(abort("p"))
  let _ = @libavformat.hls_vtt_parse_document(abort("p"))
  let _ = @libavformat.hls_write_master_playlist(abort("p"))
  let _ = @libavformat.hls_write_media_playlist(abort("p"))
  let _ = @libavformat.hls_write_media_playlist_byterange(abort("p"))
  let _ = @libavformat.hls_write_media_playlist_specs(abort("p"))
  let _ = @libavformat.hls_write_vtt_segment(abort("p"))
  let _ = @libavformat.id3v2_add_tags(abort("p"), abort("p"))
  let _ = @libavformat.id3v2_read_tags(abort("p"))
  let _ = @libavformat.id3v2_write_tag(abort("p"))
  let _ = @libavformat.index_search_timestamp(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.is_ebml_id_valid(abort("p"))
  let _ = @libavformat.matroska_ebmlnum_sint(abort("p"))
  let _ = @libavformat.matroska_parse_block(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.matroska_parse_laces(abort("p"), abort("p"))
  let _ = @libavformat.matroska_read_ebml_header(abort("p"))
  let _ = @libavformat.matroska_scan_metadata(abort("p"), abort("p"))
  let _ = @libavformat.media_fetch_from_map(abort("p"))
  let _ = @libavformat.media_fetch_from_reader(abort("p"))
  let _ = @libavformat.media_fetch_path_key(abort("p"))
  let _ = @libavformat.mkv_aac_muxer_new(abort("p"))
  let _ = @libavformat.mkv_ac3_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mkv_add_chapters(abort("p"), abort("p"))
  let _ = @libavformat.mkv_add_tags(abort("p"), abort("p"))
  let _ = @libavformat.mkv_alac_muxer_new(abort("p"))
  let _ = @libavformat.mkv_av_ac3_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mkv_av_eac3_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mkv_av_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mkv_chapter_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mkv_chapters_element(abort("p"))
  let _ = @libavformat.mkv_eac3_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mkv_flac_muxer_new(abort("p"))
  let _ = @libavformat.mkv_h264_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mkv_hevc_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mkv_mjpeg_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mkv_mp3_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mkv_png_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mkv_seek_cue(abort("p"), abort("p"))
  let _ = @libavformat.mkv_subtitle_cue_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mkv_subtitle_muxer_new()
  let _ = @libavformat.mkv_tags_element(abort("p"))
  let _ = @libavformat.mkv_track_codec_parameters(abort("p"))
  let _ = @libavformat.mov_codec_name(abort("p"), abort("p"))
  let _ = @libavformat.mov_decrypt_sample(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mov_seek_stream(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mov_seek_track(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_aac_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mp4_ac3_entry(abort("p"))
  let _ = @libavformat.mp4_ac3_muxer_new(abort("p"))
  let _ = @libavformat.mp4_add_chapters(abort("p"), abort("p"))
  let _ = @libavformat.mp4_add_metadata(abort("p"), abort("p"))
  let _ = @libavformat.mp4_alac_muxer_new(abort("p"))
  let _ = @libavformat.mp4_audio_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_av1_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_av_ac3_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mp4_av_eac3_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mp4_av_muxer_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavformat.mp4_chapter_new(abort("p"), abort("p"))
  let _ = @libavformat.mp4_eac3_entry(abort("p"))
  let _ = @libavformat.mp4_eac3_muxer_new(abort("p"))
  let _ = @libavformat.mp4_faststart(abort("p"))
  let _ = @libavformat.mp4_flac_muxer_new(abort("p"))
  let _ = @libavformat.mp4_h264_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_hevc_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_metadata_udta(abort("p"))
  let _ = @libavformat.mp4_mjpeg_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mp4_mp3_muxer_new(abort("p"))
  let _ = @libavformat.mp4_opus_muxer_new()
  let _ = @libavformat.mp4_png_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.mp4_subtitle_cue_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.mp4_subtitle_muxer_new()
  let _ = @libavformat.mp4_subtitle_samples(abort("p"))
  let _ = @libavformat.mp4_track_codec_parameters(abort("p"))
  let _ = @libavformat.mp4_tx3g_sample_entry()
  let _ = @libavformat.mp4_tx3g_text(abort("p"))
  let _ = @libavformat.mp4_vp9_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ogg_flac_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ogg_opus_muxer_new()
  let _ = @libavformat.opus_head_parse(abort("p"))
  let _ = @libavformat.probe_json_escape_for_test(abort("p"))
  let _ = @libavformat.ts_adts_to_asc(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.ts_muxer_new()
  let _ = @libavformat.vorbis_comment_body(abort("p"), abort("p"))
  let _ = @libavformat.vorbis_comment_read(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.vp9_parse_vpcc(abort("p"))
  let _ = @libavformat.w64_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.w64_read_tags(abort("p"))
  let _ = @libavformat.wav_add_tags(abort("p"), abort("p"))
  let _ = @libavformat.wav_bits_per_sample(abort("p"))
  let _ = @libavformat.wav_fourcc(abort("p"), abort("p"))
  let _ = @libavformat.wav_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.wav_read_bext(abort("p"))
  let _ = @libavformat.wav_read_tags(abort("p"))
  let _ = @libavformat.webm_av1_muxer_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavformat.webm_av_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.webm_opus_muxer_new()
  let _ = @libavformat.webm_vp9_muxer_new(abort("p"), abort("p"))
  let _ = @libavformat.xml_parse(abort("p"))
  let _ = @libavcodec.aac_apply_tns(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_decode_ics(abort("p"))
  let _ = @libavcodec.aac_decode_ics_info(abort("p"))
  let _ = @libavcodec.aac_decode_ics_with_info(abort("p"), abort("p"))
  let _ = @libavcodec.aac_decode_raw_stream(abort("p"), abort("p"))
  let _ = @libavcodec.aac_decode_scalefactors(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_decode_spectrum(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_decode_tns(abort("p"), abort("p"))
  let _ = @libavcodec.aac_encode_config(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.aac_encode_config_perceptual(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_encode_config_with_is(abort("p"))
  let _ = @libavcodec.aac_encode_config_with_ms(abort("p"))
  let _ = @libavcodec.aac_encode_config_with_perceptual_short(abort("p"))
  let _ = @libavcodec.aac_encode_config_with_pns(abort("p"))
  let _ = @libavcodec.aac_encoder_new(abort("p"))
  let _ = @libavcodec.aac_imdct(abort("p"), abort("p"))
  let _ = @libavcodec.aac_imdct_and_window(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_is_apply(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_is_in(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_is_search(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.aac_kbd_window(abort("p"), abort("p"))
  let _ = @libavcodec.aac_mdct_forward(abort("p"), abort("p"))
  let _ = @libavcodec.aac_ms_in(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_ms_search(abort("p"), abort("p"))
  let _ = @libavcodec.aac_new_sbr(abort("p"))
  let _ = @libavcodec.aac_parse_audio_specific_config(abort("p"))
  let _ = @libavcodec.aac_pns_mark(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_pns_search(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_pns_search_in(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_psy_model_bandwidth(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_psy_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_sf_dequant(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.aac_swb_tables(abort("p"))
  let _ = @libavcodec.aac_two_shape_long()
  let _ = @libavcodec.aac_two_shape_short(abort("p"))
  let _ = @libavcodec.aac_two_sticky(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.aac_twoloop_pns(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.aac_twoloop_quantize_band(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_twoloop_search(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_twoloop_search_pns(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.aac_window_grouping_expand(abort("p"))
  let _ = @libavcodec.ac3_decoder_new()
  let _ = @libavcodec.ac3_find_syncword(abort("p"))
  let _ = @libavcodec.ac3_parse_header(abort("p"))
  let _ = @libavcodec.adpcm_decoder_new(abort("p"), abort("p"))
  let _ = @libavcodec.adpcm_ima_qt_decoder_new(abort("p"))
  let _ = @libavcodec.alac_decoder_new(abort("p"))
  let _ = @libavcodec.alac_encode(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.amrnb_decoder_new()
  let _ = @libavcodec.amrnb_frame_size(abort("p"))
  let _ = @libavcodec.aom_fgs_uninit(abort("p"))
  let _ = @libavcodec.apply_window(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_apply_grain(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.av1_cdf_copy_defaults(abort("p"))
  let _ = @libavcodec.av1_create_lf_mask_inter(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_decode_coefs(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_decode_keyframe(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.av1_decode_keyframe_tiles(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_decode_txtp(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_enc_write_ac_tile()
  let _ = @libavcodec.av1_enc_write_ac_token_tile(abort("p"), abort("p"))
  let _ = @libavcodec.av1_enc_write_directional_tile()
  let _ = @libavcodec.av1_enc_write_key_frame_obu(abort("p"), abort("p"))
  let _ = @libavcodec.av1_enc_write_minimal_residual_tile()
  let _ = @libavcodec.av1_enc_write_minimal_tile()
  let _ = @libavcodec.av1_enc_write_modes_tile(abort("p"))
  let _ = @libavcodec.av1_enc_write_sequence_header_obu(abort("p"))
  let _ = @libavcodec.av1_enc_write_split_tile()
  let _ = @libavcodec.av1_enc_write_temporal_delimiter()
  let _ = @libavcodec.av1_extract_tiles(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_comp_ctx(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_comp_dir_ctx(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_derive_warpmv(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_drl_ctx(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_filter2d(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_filter_ctx(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_find_matching_ref(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_intra_ctx(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_jnt_comp_ctx(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_mask_comp_ctx(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_read_block(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_block_motion(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_compound_mask(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_compound_mv(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_filter(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_interintra(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_motion_mode(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_refs(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_read_single_mv(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_inter_ref_tree_ctx(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_tile_state_new(abort("p"), abort("p"))
  let _ = @libavcodec.av1_inter_wedge_allowed(abort("p"))
  let _ = @libavcodec.av1_interintra_allowed(abort("p"))
  let _ = @libavcodec.av1_itxfm_add(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_jnt_comp_weight(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_lf_filter_kernel(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_lr_filter_probe(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_parse_frame_header(abort("p"), abort("p"))
  let _ = @libavcodec.av1_parse_sequence_header(abort("p"))
  let _ = @libavcodec.av1_parse_tile_group(abort("p"), abort("p"))
  let _ = @libavcodec.av1_read_inter_residual(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_read_mv_residual(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_read_vartx_tree(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_recon_b_inter(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_recon_predict_block(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_ref_slot_state(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.av1_ref_slot_state_default()
  let _ = @libavcodec.av1_ref_slot_state_from_header(abort("p"))
  let _ = @libavcodec.av1_refmvs_find(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_refmvs_frame_init_probe(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_refmvs_frame_state_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_refmvs_init_frame(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_refmvs_intrabc_state(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_refmvs_reference_store_new()
  let _ = @libavcodec.av1_refmvs_tile_state_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_rmv_get_gmv_2d_probe(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_rmv_projection_probe(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_warpmv_default()
  let _ = @libavcodec.av1_warpmv_find_affine_int(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av1_warpmv_get_shear_params(abort("p"))
  let _ = @libavcodec.av1_warpmv_set_affine_mv2d(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.av_apng_decode(abort("p"))
  let _ = @libavcodec.av_mjpeg_decode(abort("p"))
  let _ = @libavcodec.av_png_decode(abort("p"))
  let _ = @libavcodec.av_png_decode_ex(abort("p"), abort("p"))
  let _ = @libavcodec.avpriv_mpegaudio_decode_header(abort("p"))
  let _ = @libavcodec.clip_uint8(abort("p"))
  let _ = @libavcodec.clip_uintp2(abort("p"), abort("p"))
  let _ = @libavcodec.ctz8(abort("p"))
  let _ = @libavcodec.dct32(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.decode_mp3_stream(abort("p"))
  let _ = @libavcodec.exp_table(abort("p"))
  let _ = @libavcodec.expval_table(abort("p"), abort("p"))
  let _ = @libavcodec.ff_add_pixels_clamped_c(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_adts_header_parse(abort("p"))
  let _ = @libavcodec.ff_adts_header_parse_buf(abort("p"))
  let _ = @libavcodec.ff_aptx_decode(abort("p"))
  let _ = @libavcodec.ff_flac_decode(abort("p"))
  let _ = @libavcodec.ff_h2645_decode_common_vui_params(abort("p"), abort("p"))
  let _ = @libavcodec.ff_h2645_extract_rbsp(abort("p"))
  let _ = @libavcodec.ff_h2645_packet_split(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_h2645_unit_requires_zero_byte(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_h264_decode_extradata(abort("p"), abort("p"))
  let _ = @libavcodec.ff_h264_decode_picture_parameter_set(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_h264_decode_seq_parameter_set(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_h264_decode_slice_header(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_h264_init_cabac_states(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_compute_poc2(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_extradata(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_frames(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.ff_hevc_decode_frames_ex(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_intra_frame(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_intra_frame_unfiltered(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_nal_pps(abort("p"), abort("p"))
  let _ = @libavcodec.ff_hevc_decode_nal_sps(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_nal_vps(abort("p"), abort("p"))
  let _ = @libavcodec.ff_hevc_decode_short_term_rps(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_decode_slice_header(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_init_cabac_states(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_parse_sei(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.ff_hevc_parse_slice_headers(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_hevc_split_access_units(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_huff_build_tree(abort("p"), abort("p"))
  let _ = @libavcodec.ff_huff_gen_len_table(abort("p"), abort("p"))
  let _ = @libavcodec.ff_init_cabac_decoder(abort("p"), abort("p"))
  let _ = @libavcodec.ff_init_scantable_permutation(abort("p"))
  let _ = @libavcodec.ff_mpa_check_header(abort("p"))
  let _ = @libavcodec.ff_mpa_decode_header(abort("p"))
  let _ = @libavcodec.ff_mpeg4audio_get_config(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_permute_scantable(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.ff_put_pixels_clamped_c(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_ref_dct_init()
  let _ = @libavcodec.ff_ref_fdct(abort("p"))
  let _ = @libavcodec.ff_ref_idct(abort("p"))
  let _ = @libavcodec.ff_simple_idct_add_int16_10bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_simple_idct_add_int16_12bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_simple_idct_add_int16_8bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_simple_idct_int16_10bit(abort("p"))
  let _ = @libavcodec.ff_simple_idct_int16_12bit(abort("p"))
  let _ = @libavcodec.ff_simple_idct_int16_8bit(abort("p"))
  let _ = @libavcodec.ff_simple_idct_put_int16_10bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_simple_idct_put_int16_12bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_simple_idct_put_int16_8bit(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.ff_tta_decode(abort("p"))
  let _ = @libavcodec.ff_wavpack_decode(abort("p"))
  let _ = @libavcodec.flac_encode(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.g722_decoder_new()
  let _ = @libavcodec.g726_decoder_new(abort("p"))
  let _ = @libavcodec.get_bit_length(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_annexb_display_frames(abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_annexb_frames(abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_annexb_i_frames(abort("p"))
  let _ = @libavcodec.h264_decode_annexb_i_frames_ex(abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_avc_display_frames(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.h264_decode_avc_frames(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_i_slice(abort("p"), abort("p"))
  let _ = @libavcodec.h264_decode_i_slice_ex(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.h264_display_order(abort("p"))
  let _ = @libavcodec.h264_enc_residual_roundtrip(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.h264_encode_frames(
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.h264_encode_frames_cabac(
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.h264_encode_intra_frame(
    abort("p"),
    abort("p"),
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.h264_encode_intra_frame_cabac(
    abort("p"),
    abort("p"),
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.hevc_add_residual(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_cabac_new(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.hevc_deblock_picture(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_decoder_new()
  let _ = @libavcodec.hevc_dequant(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.hevc_encode_frames(
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.hevc_encode_intra_frame(
    abort("p"),
    abort("p"),
    abort("p"),
    width=abort("p"),
    height=abort("p"),
  )
  let _ = @libavcodec.hevc_hls_residual_coding(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_idct(abort("p"), abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.hevc_idct_dc(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.hevc_intra_predict(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_neighbour_avail()
  let _ = @libavcodec.hevc_picture_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_pred_angular(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_pred_dc(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_pred_planar(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_sao_apply(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_sao_params_new(abort("p"), abort("p"))
  let _ = @libavcodec.hevc_sao_parse(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.hevc_transform_4x4_luma(abort("p"), abort("p"))
  let _ = @libavcodec.huffman_build_codes(abort("p"), abort("p"))
  let _ = @libavcodec.idct_block_to_bytes(abort("p"))
  let _ = @libavcodec.idct_bytes_to_block(abort("p"))
  let _ = @libavcodec.inflate_adler32(abort("p"))
  let _ = @libavcodec.inflate_zlib(abort("p"), abort("p"))
  let _ = @libavcodec.itut_t35_parse_buffer(abort("p"), abort("p"))
  let _ = @libavcodec.itut_t35_parse_payload(abort("p"), abort("p"))
  let _ = @libavcodec.itut_t35_unref(abort("p"))
  let _ = @libavcodec.l3_unscale(abort("p"), abort("p"))
  let _ = @libavcodec.latm_parse_stream(abort("p"))
  let _ = @libavcodec.mp3_encode_check_config(abort("p"), abort("p"))
  let _ = @libavcodec.mp3_encode_config(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.mp3_encode_find_bitrate_index(abort("p"), abort("p"))
  let _ = @libavcodec.mp3_encode_find_samplerate_index(abort("p"))
  let _ = @libavcodec.mp3_encode_mpeg_version(abort("p"))
  let _ = @libavcodec.mp3_encoder_new(abort("p"))
  let _ = @libavcodec.mpa_encode_config(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.mpa_encoder_new(abort("p"))
  let _ = @libavcodec.new_aac_channel_state()
  let _ = @libavcodec.new_aac_decoder(abort("p"), abort("p"))
  let _ = @libavcodec.new_aac_decoder_from_adts(abort("p"), abort("p"))
  let _ = @libavcodec.new_aac_decoder_from_asc(abort("p"))
  let _ = @libavcodec.new_aac_decoder_from_asc_channels(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.new_aac_spectrum_state()
  let _ = @libavcodec.new_aom_fgs1_params()
  let _ = @libavcodec.new_h2645_vui()
  let _ = @libavcodec.new_h264_decoder()
  let _ = @libavcodec.new_h264_param_sets()
  let _ = @libavcodec.new_h264_pred_weight()
  let _ = @libavcodec.new_h264_sei_context()
  let _ = @libavcodec.new_hevc_param_sets()
  let _ = @libavcodec.new_itut_t35_meta()
  let _ = @libavcodec.new_mp3_decoder()
  let _ = @libavcodec.new_mpeg4_audio_config()
  let _ = @libavcodec.opus_enc_atan2f(abort("p"), abort("p"))
  let _ = @libavcodec.opus_enc_cosf(abort("p"))
  let _ = @libavcodec.opus_enc_expf(abort("p"))
  let _ = @libavcodec.opus_enc_log2f(abort("p"))
  let _ = @libavcodec.opus_enc_rintf(abort("p"))
  let _ = @libavcodec.opus_enc_sinf(abort("p"))
  let _ = @libavcodec.opus_enc_tables_probe()
  let _ = @libavcodec.opus_encode_config(abort("p"), abort("p"))
  let _ = @libavcodec.opus_encoder_new(abort("p"))
  let _ = @libavcodec.opus_parse_head(abort("p"))
  let _ = @libavcodec.opus_parse_packet(abort("p"))
  let _ = @libavcodec.opus_parse_packet_with(abort("p"), abort("p"))
  let _ = @libavcodec.opus_pvq_size(abort("p"), abort("p"))
  let _ = @libavcodec.opus_pvq_unrank(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.opus_rc_init(abort("p"))
  let _ = @libavcodec.parse_aom_film_grain_sets(abort("p"), abort("p"))
  let _ = @libavcodec.pcm_alaw_decode(abort("p"))
  let _ = @libavcodec.pcm_alaw_encode(abort("p"))
  let _ = @libavcodec.pcm_mulaw_decode(abort("p"))
  let _ = @libavcodec.pcm_mulaw_encode(abort("p"))
  let _ = @libavcodec.put_signed_pixels_clamped_c(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.simple_idct(abort("p"), abort("p"))
  let _ = @libavcodec.simple_idct_add(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.simple_idct_put(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.table_4_3_exp(abort("p"))
  let _ = @libavcodec.table_4_3_value(abort("p"))
  let _ = @libavcodec.video_encode(
    abort("p"),
    codec=abort("p"),
    config=abort("p"),
  )
  let _ = @libavcodec.video_pixel_format(abort("p"))
  let _ = @libavcodec.vorbis_decoder_new(abort("p"), abort("p"))
  let _ = @libavcodec.vp9_decoder_new()
  let _ = @libavcodec.vp9_parse_frame_header(abort("p"))
  let _ = @libavcodec.vp9_parse_frame_header_with_refs(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.vp9_parse_packet(abort("p"))
  let _ = @libavcodec.vp9_parse_packet_with_refs(
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @libavcodec.vp9_rac_get(abort("p"))
  let _ = @libavcodec.vp9_rac_get_bool(abort("p"))
  let _ = @libavcodec.vp9_rac_get_prob(abort("p"), abort("p"))
  let _ = @libavcodec.vp9_rac_get_uint(abort("p"), abort("p"))
  let _ = @libavcodec.vp9_rac_init(abort("p"), abort("p"), abort("p"))
  let _ = @libavcodec.vp9_rac_is_end(abort("p"))
  let _ = @libavcodec.vp9_rac_update_prob(abort("p"), abort("p"))
  let _ = @libavcodec.vp9_split_superframe(abort("p"))
  let _ = @libavcodec.wma_decoder_new(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_avg(abort("p"), abort("p"), abort("p"))
  let _ = @av1_mc_core.av1_mc_blend_pixels(abort("p"), abort("p"), abort("p"))
  let _ = @av1_mc_core.av1_mc_compound_blend(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_diffwtd_mask(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_mask(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_obmc_horizontal(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_obmc_vertical(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_plane_position(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_predict_plane(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_prep_scaled(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_prep_unscaled(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_prepare_plane(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_put_scaled(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_put_unscaled(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_resize(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_w_avg(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_warp_affine_8x8(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_warp_affine_8x8t(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_warp_predict_plane(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_mc_warp_prepare_plane(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  let _ = @av1_mc_core.av1_wedge_mask(
    abort("p"),
    abort("p"),
    abort("p"),
    abort("p"),
  )
  abort("end")
}
