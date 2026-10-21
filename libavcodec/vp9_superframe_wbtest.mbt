///|
/// VP9 superframe split test.
///
/// Fixture: one 776-byte IVF frame produced by libvpx-vp9 (2-pass, lag 25,
/// auto-alt-ref=1). Its trailing superframe index (marker 0xc9, length_size 2,
/// 2 frames) declares 528 + 242 bytes.

///|
let vp9_sf_frame_b64 : Bytes = bcat([
  b"hACASU6AIAAAEAB6iLWabWmnHOsucU6+jihQp6rFum3VCnGVqVRQG+AAAH4X///U5O7sMjv/2B8VajStw1Ub/7dJr9D360NzI75Z",
  b"/Uys8pWNL98CgH5Kqp4Krf/wgRCSCeS4hvQHFr///+B8OmOL8+PL91drAOgGm7cMmq6YcVB/nWyIz2m5VgBEZNJj8Nof///fzZ1F",
  b"htRLJc89vujMw70M1/BUtalYZgxh+nK9rsuLG+VCHRoR5mmOjHAbGw+FoQUgeY1U/kiyDSg+VAqv4Fk/g3kSQ10hbcC/bxvrFRbW",
  b"gwhPPixkz/SapaEbkBTQhBgEHm9un17Dvar9P8yMFehW2PhnqiUYfXyqV1qDin+wdrf6mPZf3/32sAJXPnSUmX0k59cJurkGXTXJ",
  b"40GSnsBWEXZ2JNQ5ckvYNlreSnhU2HCyzIN1IyUCps23ieloyQE86F0LfvfftpvIQXyLqbJK1Sf6c4oSQ90raVafwnxQHh7TjmBe",
  b"/z5ZNPfg/sASEJhF8W10H3yBW5PXmuY5y8mI8TTfiIat9AAKBsVaJ3v//6r6aTdlozDRxXjy6WOUKKDddgEDv/xInb9UP1Q4m0NS",
  b"cX6N62tPTeX///T4izqPLvH/V0kiKrZaO3vms+4r/g6jv1EbdZXWXy13Bxr+r525506BxOXoFqI+2gYIH7eR19fxiIWeVY4+jhz2",
  b"O40AhgBAlpwAQAAADlbRFwBYFwCtnnGmpAAAf6UhUNrtPfbDK4OFakgzBzH4hn9FmKgWIYCZa5rQSL5VmKh27v3ffwNEFXaFo1jG",
  b"fiwG5nd7tw1wv992TAen5/CSlFQ3tfOWrGMmTNaEzNjAer97BLPVALR9YokcaDwHM5HYttv0uf6ATeZ+2T//GmducF/y5VclbX/7",
  b"Jj3L8mayDLZNkGgF5nECv3HtZ+WGRV996e2bk/66WoIFlOIH9MO9Pm3jUrTscTMuJd0QVDPtdTXRsEnJmKDdAv9lgzXHMyl59BiQ",
  b"T23R1TpS/4+xoQnpVgltdZNxz6DJEALyAMk=",
])

///|
test "vp9: superframe index splits into two frames" {
  let data = @libavutil.av_base64_decode(vp9_sf_frame_b64, 100000).unwrap()
  assert_eq(data.length(), 776)
  let sf = vp9_split_superframe(data).unwrap()
  assert_true(sf.is_superframe)
  assert_eq(sf.frames.length(), 2)
  assert_eq(sf.frames[0].length(), 528)
  assert_eq(sf.frames[1].length(), 242)
  for f in sf.frames {
    let h = vp9_parse_frame_header(f).unwrap()
    assert_eq(h.profile, 0)
  }
  let single = vp9_split_superframe(sf.frames[1]).unwrap()
  assert_false(single.is_superframe)
  assert_eq(single.frames.length(), 1)
}
