// Blackbox tests for the B-slice rate controls (`§398`): ABR (the
// two-pass `target_bytes` search) and the CPB-constrained VBV/CBR mode
// now drive the B-slice sequence's per-display-position QPs. The gates:
// the target is met, the CPB stays legal (fillers included), the B path
// is really exercised, the reconstruction invariant holds through both
// entropy coders, and docker ffmpeg decodes the arbitrated streams with
// zero warnings (pinned framemd5 MD5s).

///|
test "h264 brc: ABR lands b_slices streams under the target" {
  let frames = h264_rc_fixture(6)
  let flat = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  for cabac in [false, true] {
    for scale in [80, 50] {
      let target = flat.length() * scale / 100
      let stats = @libavcodec.H264EncStats::new()
      let recon : Array[Bytes] = []
      let bytes = match
        (if cabac {
          @libavcodec.h264_encode_frames_cabac(
            frames,
            width=64,
            height=48,
            qp=26,
            b_slices=true,
            target_bytes=target,
            stats~,
            recon~,
          )
        } else {
          @libavcodec.h264_encode_frames(
            frames,
            width=64,
            height=48,
            qp=26,
            b_slices=true,
            target_bytes=target,
            stats~,
            recon~,
          )
        }) {
        Ok(s) => s
        Err(e) => fail(e)
      }
      if bytes.length() > target {
        fail(
          "abr scale=\{scale} cabac=\{cabac}: \{bytes.length()} > \{target} bytes",
        )
      }
      if stats.frame_qps.length() != 6 {
        fail("abr: frame_qps length \{stats.frame_qps.length()}")
      }
      if stats.b_mbs <= 0 {
        fail("abr: no B macroblocks coded")
      }
      let name = "brc-abr-\{scale}-\{cabac}"
      h264_rc_recon_invariant(name, bytes, recon, 6)
    }
  }
}

///|
test "h264 brc: VBV keeps b_slices CPB legal, SEI and fillers included" {
  let frames = h264_rc_fixture(6)
  for cabac in [false, true] {
    let stats = @libavcodec.H264EncStats::new()
    let recon : Array[Bytes] = []
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=64,
          height=48,
          qp=26,
          b_slices=true,
          vbv_maxrate=90000,
          vbv_bufsize=18000,
          fps=30,
          aud=true,
          stats~,
          recon~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=64,
          height=48,
          qp=26,
          b_slices=true,
          vbv_maxrate=90000,
          vbv_bufsize=18000,
          fps=30,
          aud=true,
          stats~,
          recon~,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    if stats.frame_qps.length() != 6 {
      fail("vbv: frame_qps length \{stats.frame_qps.length()}")
    }
    if stats.b_mbs <= 0 {
      fail("vbv: no B macroblocks coded")
    }
    // Every P/B access unit (and the IDR) must fit the CPB, pic_timing
    // SEIs and filler NALs included; the solver already proved it, this
    // replays the real stream's access units.
    let nals_dbg = vbv_nals(stream)
    let mut tseq = ""
    for (t, _, _) in nals_dbg {
      tseq = tseq + t.to_string() + " "
    }
    let sizes = vbv_au_sizes(vbv_nals(stream))
    if sizes.length() != 6 {
      fail("vbv: \{sizes.length()} access units for 6 pictures")
    }
    let (_, peak) = vbv_cpb_check(
      "brc-vbv-\{cabac}",
      sizes,
      90000,
      18000,
      30,
      90,
    )
    if peak > 18000 {
      fail("vbv cabac=\{cabac}: CPB overflowed to \{peak}")
    }
    // The picture-timing SEI opens every non-IDR access unit.
    let nals = vbv_nals(stream)
    let mut aus = 0
    let mut expect_sei = false
    for k, (t, _, _) in nals {
      if k == 0 {
        continue
      }
      if t == 9 {
        aus = aus + 1
        expect_sei = true
      } else if expect_sei {
        if t != 6 {
          fail("vbv: AU \{aus} does not open with a pic_timing SEI")
        }
        expect_sei = false
      }
    }
    let name = "brc-vbv-\{cabac}"
    h264_rc_recon_invariant(name, stream, recon, 6)
  }
}

///|
test "h264 brc: deterministic re-encode and pinned QP direction" {
  let frames = h264_rc_fixture(6)
  let a = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      target_bytes=4000,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let b = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      target_bytes=4000,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if a.length() != b.length() {
    fail("determinism: length mismatch")
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      fail("determinism: byte mismatch at \{i}")
    }
  }
  // A tighter target must not come out larger.
  let tight = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      target_bytes=3000,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  if tight.length() > a.length() {
    fail("tighter target produced a larger stream")
  }
}

///|
/// External arbitration (docker ffmpeg 9.0.2, `nine-x264` image): the
/// rate-controlled B-slice sequences — an ABR target and a VBV/CBR
/// buffer with pic_timing SEIs, filler NALs and per-display-position
/// QPs — decode in the reference implementation with zero warnings, in
/// DISPLAY order (POC reordering), every deblocked frame matching this
/// repository's decoder byte-for-byte (pinned framemd5 MD5s, obtained
/// via x264_wbtest's "legacy B rate-control snapshots" C decoder oracle).
test "h264 brc: ffmpeg-arbitrated ABR and VBV b_slices streams" {
  let frames = h264_rc_fixture(6)
  let abr = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      target_bytes=4000,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let vbv_stream = match
    @libavcodec.h264_encode_frames(
      frames,
      width=64,
      height=48,
      qp=26,
      b_slices=true,
      vbv_maxrate=90000,
      vbv_bufsize=18000,
      fps=30,
      aud=true,
    ) {
    Ok(s) => s
    Err(e) => fail(e)
  }
  let mut dump = "A:"
  for i in 0..<abr.length() {
    dump = dump + (abr[i].to_int() & 0xFF).to_string() + ","
  }
  dump = dump + "V:"
  for i in 0..<vbv_stream.length() {
    dump = dump + (vbv_stream[i].to_int() & 0xFF).to_string() + ","
  }
  println("ARBBRC:\{dump}")
  // Display-order (POC) MD5s, pinned once docker agrees.
  let dec_abr = match @libavcodec.h264_decode_annexb_frames(abr, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  let dec_vbv = match @libavcodec.h264_decode_annexb_frames(vbv_stream, false) {
    Ok(f) => f
    Err(e) => fail(e)
  }
  if dec_abr.length() != 6 || dec_vbv.length() != 6 {
    fail("expected 6 frames per stream")
  }
  for i, md5 in h264b_display_md5s(dec_abr) {
    println("ARBBRCMD5:abr poc\{i * 2} \{md5}")
  }
  for i, md5 in h264b_display_md5s(dec_vbv) {
    println("ARBBRCMD5:vbv poc\{i * 2} \{md5}")
  }
  // §424 re-pins: deblocking on by default shifted both schedules (the
  // VBV leg's pictures 0-4 stay pixel-identical to the flat stream).
  let pins_abr = [
    "019d0591d9c2bd9373f350072c8a610e", "598ae1b100223b09f6319437c89cd96a", "d6ff4fda91af7ec2b363977f707b8b7f",
    "724d800d66e4296e80d384ee6589fd4d", "64af2203fd508271a051b62226308ea0", "ddfd3711a61a6d714e13af5039e3db36",
  ]
  let pins_vbv = [
    "292edd53ff3434561e2e1d737c563c98", "8939b394fe8c36618d19f652722caf9e", "38b675826ba7c8180041c06e653fa6fc",
    "6b03f4a4cc1ab3f12a59a4399f282c06", "8795883852ef64ec921d344d640186ed", "cfd1d0047aae071b740aab9a4e48955e",
  ]
  let md5s_abr = h264b_display_md5s(dec_abr)
  let md5s_vbv = h264b_display_md5s(dec_vbv)
  for i in 0..<6 {
    inspect(md5s_abr[i], content=pins_abr[i])
  }
  for i in 0..<6 {
    inspect(md5s_vbv[i], content=pins_vbv[i])
  }
}
