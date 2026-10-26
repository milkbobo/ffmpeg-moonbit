///|
/// Inter-frame header vectors: docker linuxserver/ffmpeg:9.0.2
/// (libaom). testsrc2 -crf 30 (plain P frame) and mandelbrot
/// -crf 20 (rot-zoom LAST model, skip mode). Regenerate with
/// scripts/_gen_av1_inter_hdr_vectors.py.

///|
test "av1 inter frame header parse" {
  let key_pkt = @libavutil.av_base64_decode(
      b"EgAKCgAAAAO0/3Nr5gEyjQgUACOAMGGFJEhSQEDbI8Y7Pz4gyRCIUPVU72JR1hoxeq9e9sAJUUYSlM5VjzZXfey9DzQy4lHS5c7Ie/IpGILmE6ioC1Vzdx/rl9ip9VvGV9rus3lIcgV8vt35wM8sSNCpe8fVrvqX8C0LqwCYH8MkQqK4TZRtm4I8oPQKSPRFh6AjlfLiyRFlP2AYDy/W06INunTc4eWaJ1pmgghcDy6p80wZ8u5ztZur61yGM9j+mrBffM/nrQk0ExrEOHwZJ2as3erFHmB80WacMbwMg991FDs1OQFpCElYubGXC7OVePTVUoYR/bQW6mzWnFE0tKR8XHw22v2G64xSOBrVh7QMOBQ3yzMBCvAdlselCKk8BUUgM6RzMsL+t7eGFX5G1wtvmhus9cShEhdKPQGjNRKF82OkAm3OCG1Ilf8fQN61mGvuKyiu6a/oi3ZGL1aRo4+h5P8ZYnNuXsis3kH1Qt+aB+baJyUK2HVXQEaucBYaVC940z8wIndp5BFfRvj7EMa5I8Wa566ZgoTCKwoHG1xWpvH0I27zKN9Itd9cTYLDYALidMzCkNnR0xrQZnJi/mVZvuHYbfiYLWl8Y/H9gFQtXLsPhq8shFXirxU2ljj7GYltJ0nwzHvdTNyCMkRa0d12+JVUPzkiyzHsU1/rqHINdT4HmpGbsm16aZR9a3QBM47Qb7ID4jPNn+wAYH/EOH4M+5uViSeHrecA+X8zmuj8Boc6IrQaApF25Q5zolRY/JMQgonFBI/FPxgnBkqZPOm2qUW3jhfrpc7Ok3VOJFMOgmLtbuHD9PkKvdCpw+lsgM2OkBjeFlVZlQtZ8g24qevFFbK24zwRMRqbxD2DotG4vCfKrcBz3ABnWqTcfAz9cIpFRT+i4FNBEYvySqQJF8KNwl2+kYvCwuwpuqvWPqjWsLD8xcbZAL33AQtCkycB5ZK+g63+TioCDR3iTc3wAASAD+eT1+iAHJp0k5zWE+ppekwRBAtTzW9QwNzrjb1ZqRBXRHw9w6+63o0POGbZdBe4kFAPGKWSiAtFoID+oYNWYU+UGnXf94fjOMirSxVecyzCYH8u+ypaGx3sFF19vTWNl5GYl/b99j5gkpk1fWYpgZV9pzr+Tk2PbsfiP7nXiMhJbXKZh4RH4jMS4M1jC5d9bCMD0MsSy5ckppxwdTZs4j22h3r/FjAybfH/N9N4US/iWgBjEDe5E9ywiugqnfAG4rZuuwuW5m+ySMvyDPmF2XFAWVamaYzPFJAPPBuxbPhr0TxC52FAIcHMo//ByUaXiZ2lUHemHesX3ywg4PBLewVABnQVfBf6QHLPRVeUbFnPg2qqKyBgmnAoGdCDzE7XhshlzZLlXhDf5NZFDZKPigk2KaUJxPsYcO18UA==",
      65536,
    ).unwrap()
  let inter_pkt = @libavutil.av_base64_decode(
      b"EgAywQQyAeBAAAAjR4AGGRJEnXQFAN05VOwJCGR30WFDswJZ2x10AQuOuG6OJMDkXAIiEnj7Gijg00JabZKBXl5+1B4XcWpv1yI+2ia8Jr4L7bCvGyxaPL18jrG1i0DJqEgw9xmQmyUG01EelnE6k7abCw0OJZtBwmEVIFKM6SufUj8T+hXuwS4qZJmIkfRNIo6ycMRrxCtr+KG55jlLzTVkQPviyXX4akJg8suvsZBsxd1p4MlM/TW+PyWzdRTzyvzpxwXppQoyhTrXmk0ec3xFTG/2JodvnuOHInutuNVXqefgQTrKNlaDN13jgE0W5r8roiKVpCjQ/O7d8wZt3QFQtCJv3T0ImPpHwMkwtccbqYyU6ZOcJCbedCS84MhG/EWrF2bXy+rmmOFVmdAzbKyHBg9CRKJzwfD4PrPVjrET8NqRLqDWCa+DLdjMDM8O67M8KeFFg42k/E1xefp7kytbUMLhMLP3NSVKiyFFUw1ovnrdgaLgmt0nwCivoepGkhcpgQASKsle/FDJLl0GSQwgbGRYtbopPtYrd8DwIlRU0eg1F280Y/EzyRiD1nZL22+hZfK69fYGzl8a1+KHM7rA/Xg/2bOvghWVPZEA+d+YfHEwpt1wCkTgO2/Q8+1hgwbUOgQSjnQgeoNmh9e3gxkcKR+TwvbFKHsQskep+gIsVgkGDb/wc9zztW9eGjTEaiRxg1imS9AVA34aA6w5KwnMOZ/P6MlnHFJk3eWTly8LrWJVcbKKTjEKl2G2i0KPe3MCoEzg",
      65536,
    ).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(key_pkt).unwrap()
  // ref slot 0 holds the decoded key frame (identity GM, same size).
  let slot0 = @libavcodec.av1_ref_slot_state(0, seq.width, seq.height)
  let hdr = @libavcodec.av1_parse_frame_header(inter_pkt, seq, ref_slots=[slot0]).unwrap()
  inspect(hdr.frame_type, content="1")
  inspect(hdr.upscaled_width, content="160")
  inspect(hdr.height, content="120")
  inspect(hdr.reference_select, content="false")
  inspect(hdr.skip_mode_enabled, content="false")
  inspect(hdr.allow_warped_motion, content="true")
  inspect(hdr.use_ref_frame_mvs, content="true")
  inspect(hdr.allow_high_precision_mv, content="true")
  inspect(hdr.is_motion_mode_switchable, content="true")
  inspect(hdr.order_hint, content="1")
  inspect(hdr.refresh_frame_flags, content="2")
  inspect(hdr.primary_ref_frame, content="7")
  inspect(hdr.ref_frame_idx.length(), content="7")
  for i in 0..<7 {
    inspect(hdr.gm_types[i], content="0")
  }
  let refmvs = @libavcodec.av1_refmvs_reference_store_new()
  refmvs.refresh_without_mvs(0, seq.width, seq.height, 255)
  let prepared = refmvs.prepare_header(seq, hdr).unwrap()
  inspect(prepared.poc, content="1")
  // The motion grid follows `width[0]` (upscaled width), not the height-only
  // reference picture geometry.
  inspect(prepared.state.tile.iw8, content="20")
  inspect(prepared.state.tile.rp_stride, content="32")
  assert_true(!prepared.state.init.use_ref_frame_mvs)
  // Bit-exactness of the header path: the tile group must still split.
  let group = @libavcodec.av1_parse_tile_group(inter_pkt, hdr).unwrap()
  inspect(group.num_tiles, content="1")
  ignore(key_pkt)
}

///|
test "av1 inter frame header parse with global motion" {
  let mkey_pkt = @libavutil.av_base64_decode(
      b"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",
      65536,
    ).unwrap()
  let p1_pkt = @libavutil.av_base64_decode(
      b"EgAy+QMgA+BAAAAjRNBhhgxolAIA6Ar/wa+I+IfBANC4A9pEMN1cv9yzfXPK6/69WkVRO4TyNHjWF02HGzEcobbIHvEBBFdZyu4mDe2TBu1yX0ttEeV0lNj2uE1su1wtNgeKQvnf4pTs1IYyqf+yCE9dwK6dsmOf8RTfn/X1RnpLqF0Gxejyngomkm3b8ghG54eVqbf0AqBGRrjAZIVgLXbG7gYOwFpIFvVj/SPJ/jvn3yxcCTP/wqEIyUIt/e0v3dD8OoA18DSOJlFzb0a/OLnxvQL80wtQVQw7qCF35rTz0iS35/rx7kgt+69niz4TwBBJBPK7mKRwXJ22jJXM7XpgqUSZFwUAjLC1GigXLljU0oO9V+nP09fWLXYj6pXFLlhcVZGT+oIcSVXubkHIOWv0If9jMtUHtKvlsMAwMnXnTwxRIeByWRfeWJl8oQn2/JhwmWnFJwSVL3ozUnS8mO7sN3IQbAfCkRqMPFue1lYU8j2l8pnvVoUbeiGR8WpMVNK82H1a/65PP1QdS5a++Uyt4hPRLHFw51DKfgh99pN56IDStBrBI8OHEDoMVYoJMi/9BByXAs61CdENoq4g6f+xZ75xJB1K2+NUO5tyAbPMteeB602j3qoIclp5ISIPvVLGYgUNfkDz5wg9PVdIgGONiy5+r47+PcRLRhpoMhwwA8EAAEBGiAAggEKJAAACD/xEeR+O/EyZCI34",
      65536,
    ).unwrap()
  let p2_pkt = @libavutil.av_base64_decode(
      b"EgAydjAEAggAAUaKABhgwokAAA8A1aAvOc7gIzpnRoep9/y9fQNvOAE7VVr8yDMjXaF/suliHBZTqwRVvam2lVyzLaCVVG+QSoZbWybT/xf8DxfsgWwz9EokHWv7kUQJUsuzanV7mtHJWLkv4SVyG6nJ74dnS1jIAnA=",
      65536,
    ).unwrap()
  let seq = @libavcodec.av1_parse_sequence_header(mkey_pkt).unwrap()
  // The key frame (order hint 0) refreshes all 8 slots; the first P
  // frame (order hint 1) then refreshes slot 1 only.
  let slot0 = @libavcodec.av1_ref_slot_state(0, seq.width, seq.height)
  let hdr1 = @libavcodec.av1_parse_frame_header(p1_pkt, seq, ref_slots=[slot0]).unwrap()
  inspect(hdr1.frame_type, content="1")
  inspect(hdr1.refresh_frame_flags, content="2")
  let slot1 = @libavcodec.av1_ref_slot_state(1, seq.width, seq.height)
  let pool = [
    slot0, slot1, slot0, slot0, slot0, slot0, slot0, slot0,
  ]
  let hdr2 = @libavcodec.av1_parse_frame_header(p2_pkt, seq, ref_slots=pool).unwrap()
  inspect(hdr2.frame_type, content="1")
  // P1: LAST ref carries a rot-zoom model (zoom ~0.983, dx ~1.125),
  // exercising the subexp delta decoding.
  inspect(hdr1.gm_types[0], content="2")
  for i in 1..<7 {
    inspect(hdr1.gm_types[i], content="0")
  }
  inspect(hdr1.gm_matrices[0][0], content="73728")
  inspect(hdr1.gm_matrices[0][1], content="67584")
  inspect(hdr1.gm_matrices[0][2], content="64458")
  inspect(hdr1.gm_matrices[0][3], content="72")
  inspect(hdr1.gm_matrices[0][4], content="-72")
  inspect(hdr1.gm_matrices[0][5], content="64458")
  // P2: skip mode enabled over refs [0, 6]; the refidx list mixes the
  // key (slot 2) and first P (slot 1).
  for i in 0..<7 {
    inspect(hdr2.gm_types[i], content="0")
  }
  inspect(hdr2.skip_mode_enabled, content="true")
  inspect(hdr2.skip_mode_refs[0], content="0")
  inspect(hdr2.skip_mode_refs[1], content="6")
  inspect(hdr2.ref_frame_idx[0], content="2")
  for i in 1..<6 {
    inspect(hdr2.ref_frame_idx[i], content="0")
  }
  inspect(hdr2.ref_frame_idx[6], content="1")
  inspect(@libavcodec.av1_parse_tile_group(p1_pkt, hdr1).unwrap().num_tiles, content="1")
  inspect(@libavcodec.av1_parse_tile_group(p2_pkt, hdr2).unwrap().num_tiles, content="1")
}
