///|
/// The §420 4:2:2 round-trip fixture: moving luma box, column-gradient Cb
/// and row-stepped Cr at full chroma height, five frames for the B
/// schedule.
fn c422_fixture(n : Int32) -> Array[(Bytes, Bytes, Bytes)] {
  let w = 96
  let h = 64
  let frames : Array[(Bytes, Bytes, Bytes)] = []
  for f = 0; f < n; f = f + 1 {
    let y : Array[Byte] = []
    let u : Array[Byte] = []
    let v : Array[Byte] = []
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w; col = col + 1 {
        y.push(((col * 2 + row * 3 + f * 7) & 0xFF).to_byte())
      }
    }
    for row = 0; row < h; row = row + 1 {
      for col = 0; col < w / 2; col = col + 1 {
        u.push((((col + f * 3) & 0x3F) + 96).to_byte())
        v.push((((row / 2 + f) & 0x3F) + 96).to_byte())
      }
    }
    frames.push(
      (
        Bytes::from_array(y[:]),
        Bytes::from_array(u[:]),
        Bytes::from_array(v[:]),
      ),
    )
  }
  frames
}

///|
test "h264 c422: round trip with the recon invariant in both entropies" {
  for cabac in [false, true] {
    let frames = c422_fixture(7)
    let recon : Array[Bytes] = []
    let stats = @libavcodec.H264EncStats::new()
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=2,
          recon~,
          stats~,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=2,
          recon~,
          stats~,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    assert_true(stats.b_mbs > 0)
    // Profile 122 parameter sets.
    let ps = @libavcodec.new_h264_param_sets()
    let mut profile = 0
    for nal in vbv_nals(stream) {
      if nal.0 == 7 {
        profile = vbv_nal_payload(stream, nal)[0].to_int()
        match
          @libavcodec.ff_h264_decode_seq_parameter_set(
            @libavcodec.BitReader::new(vbv_nal_payload(stream, nal)),
            ps,
            false,
          ) {
          Ok(_) => ()
          Err(e) => fail(e)
        }
      }
    }
    assert_eq(profile, 122)
    assert_eq(ps.sps_list[0].unwrap().chroma_format_idc, 2)
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, true) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 7)
    for i, r in recon {
      assert_eq(
        mr_md5(r),
        mr_md5(dec[i + 1].yuvp()),
        msg="cabac=\{cabac} frame \{i}",
      )
    }
  }
}

///|
test "h264 c422: streaming matches the batch stream byte for byte" {
  let frames = c422_fixture(7)
  for cabac in [false, true] {
    let batch = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=2,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=26,
          chroma_format=2,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let enc = match
      @libavcodec.H264StreamEncoder::open(
        width=96,
        height=64,
        qp=26,
        cabac~,
        chroma_format=2,
      ) {
      Ok(e) => e
      Err(e) => fail(e)
    }
    let out : Array[Byte] = []
    for (y, u, v) in frames {
      match enc.push_frame(y, u, v) {
        Ok(_) => ()
        Err(e) => fail(e)
      }
      for au in enc.drain() {
        for b in au {
          out.push(b)
        }
      }
    }
    match enc.finish() {
      Ok(aus) =>
        for au in aus {
          for b in au {
            out.push(b)
          }
        }
      Err(e) => fail(e)
    }
    assert_eq(mr_md5(Bytes::from_array(out[:])), mr_md5(batch))
  }
}

///|
test "h264 c422: validation rejects bad formats" {
  let frames = c422_fixture(3)
  for bad in [0, 3, -1] {
    match
      @libavcodec.h264_encode_frames(
        frames,
        width=96,
        height=64,
        chroma_format=bad,
      ) {
      Ok(_) => fail("chroma_format \{bad} accepted")
      Err(_) => ()
    }
  }
}

///|
/// External arbitration anchors (`§420`): CAVLC and CABAC 4:2:2 streams
/// for the docker ffmpeg framemd5 oracle; `ARBC22:`/`ARBC22C:` carry the
/// annexb bytes for re-arbitration.
test "h264 c422: ffmpeg-arbitrated streams" {
  for cabac in [false, true] {
    let frames = c422_fixture(6)
    let stream = match
      (if cabac {
        @libavcodec.h264_encode_frames_cabac(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=2,
        )
      } else {
        @libavcodec.h264_encode_frames(
          frames,
          width=96,
          height=64,
          qp=24,
          chroma_format=2,
        )
      }) {
      Ok(s) => s
      Err(e) => fail(e)
    }
    let mut dump = ""
    for i = 0; i < stream.length(); i = i + 1 {
      dump = dump + (stream[i].to_int() & 0xFF).to_string() + ","
    }
    println("ARBC22\{if cabac { "C" } else { "" }}:\{dump}")
    let dec = match @libavcodec.h264_decode_annexb_frames(stream, false) {
      Ok(f) => f
      Err(e) => fail(e)
    }
    assert_eq(dec.length(), 6)
    let disp = h264p_decode_to_display(6)
    let by_display : Array[@libavcodec.H264Frame] = Array::make(6, dec[0])
    for i, f in dec {
      by_display[disp[i]] = f
    }
    let mut md5s = "C22MD5 cabac=\{cabac}:"
    for f in by_display {
      md5s = md5s + " " + mr_md5(f.yuvp())
    }
    println(md5s)
  }
}

///|
