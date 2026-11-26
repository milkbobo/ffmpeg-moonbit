///|
fn dsd_fixture_byte(sample : Int32, channel : Int32) -> Int32 {
  (sample * 73 + (sample >> 3) * 19 + channel * 43) & 255
}

///|
/// 8,301 DSD64 bytes per channel in three 4,096-byte planar blocks.
/// Each channel in the final block has 109 valid bytes then zero padding.
fn dsd_fixture_dsf(lsb : Bool) -> Bytes {
  let b64 = if lsb {
    b"RFNEIBwAAAAAAAAAXGAAAAAAAAAAAAAAAAAAAGZtdCA0AAAAAAAAAAEAAAAAAAAAAgAAAAIAAAAAESsAAQAAAGgDAQAAAAAAABAAAAAAAABkYXRhDGAAAAAAAAA="
  } else {
    b"RFNEIBwAAAAAAAAAXGAAAAAAAAAAAAAAAAAAAGZtdCA0AAAAAAAAAAEAAAAAAAAAAgAAAAIAAAAAESsACAAAAGgDAQAAAAAAABAAAAAAAABkYXRhDGAAAAAAAAA="
  }
  let out = @libavutil.av_base64_decode(b64, 128).unwrap().to_array()
  for packet in 0..<3 {
    for ch in 0..<2 {
      for i in 0..<4096 {
        let index = packet * 4096 + i
        let value = if index < 8301 { dsd_fixture_byte(index, ch) } else { 0 }
        if lsb {
          let mut reversed = 0
          for bit in 0..<8 {
            reversed = (reversed << 1) | ((value >> bit) & 1)
          }
          out.push(reversed.to_byte())
        } else {
          out.push(value.to_byte())
        }
      }
    }
  }
  Bytes::from_array(out)
}

///|
fn dsd_fixture_dff() -> Bytes {
  let b64 = b"RlJNOAAAAAAAAEFERFNEIEZWRVIAAAAAAAAABAEFAABQUk9QAAAAAAAAAD5TTkQgRlMgIAAAAAAAAAAEACsRAENITkwAAAAAAAAACgACU0xGVFNSR1RDTVBSAAAAAAAAAAhEU0QgA0RTRERTRCAAAAAAAABA2g=="
  let out = @libavutil.av_base64_decode(b64, 128).unwrap().to_array()
  for i in 0..<8301 {
    for ch in 0..<2 {
      out.push(dsd_fixture_byte(i, ch).to_byte())
    }
  }
  Bytes::from_array(out)
}

///|
test "DSF and DSDIFF reproduce FFmpeg's float PCM and packet indexing" {
  for
    (file, format, codec) in [
      (dsd_fixture_dsf(true), "dsf", "dsd_lsbf_planar"),
      (dsd_fixture_dsf(false), "dsf", "dsd_msbf_planar"),
      (dsd_fixture_dff(), "iff", "dsd_msbf"),
    ] {
    let dsf = format == "dsf"
    let track = (if dsf { av_dsf_open(file) } else { av_dff_open(file) }).unwrap()
    let expected = if dsf {
      [
        (92L, 0L, 8192, 4096),
        (8284L, 4096L, 8192, 4096),
        (16476L, 8192L, 218, 109),
      ]
    } else {
      [(118L, 0L, 16384, 8192), (16502L, 8192L, 218, 109)]
    }
    assert_eq(
      track.frames.map(p => (p.pos, p.pts, p.size, p.duration)),
      expected,
    )
    let audio = decode_audio_file(file)
    assert_eq(audio.format_name, format)
    assert_eq(audio.codec_id, codec)
    assert_eq(audio.sample_rate, 352800)
    assert_eq(audio.channels, 2)
    assert_eq(audio.duration_seconds, Some(8301.0 / 352800.0))
    let pcm : Array[Byte] = []
    assert_eq(audio.samples[0].length(), 8301)
    assert_eq(audio.samples[1].length(), 8301)
    for i in 0..<8301 {
      for row in audio.samples {
        let word = Float::from_double(row[i]).reinterpret_as_int()
        for byte in 0..<4 {
          pcm.push((word >> (byte * 8)).to_byte())
        }
      }
    }
    // Docker FFmpeg 9.0.2, -c:a pcm_f32le -f md5.
    assert_eq(
      caf_md5(Bytes::from_array(pcm)),
      "bb8c89540b49cce738320389ab3df4d5",
    )
  }
}

///|
test "DSD demuxers reject truncated chunks and missing DST payloads" {
  let dsf = dsd_fixture_dsf(true)
  let dff = dsd_fixture_dff()
  assert_true(
    av_dsf_open(dsf[:dsf.length() - 1].to_owned())
    is Err("dsf: invalid data chunk"),
  )
  assert_true(
    av_dff_open(dff[:dff.length() - 1].to_owned())
    is Err("dff: invalid form size"),
  )
  let dst = dff.to_array()
  dst[100] = b'T' // CMPR's DSD tag becomes DST.
  assert_true(
    av_dff_open(Bytes::from_array(dst)) is Err("dff: missing DST audio chunk"),
  )
}
