# Native H.264 input formats

The libx264 binding accepts planar 4:2:0, 4:2:2 and 4:4:4, each at
8-bit or 10-bit little-endian, plus the semi-planar `Nv12`/`Nv21`/`Nv16`/
`Nv20le`. Check `x264_supports` against the installed
encoder before selecting a format. Planes contain only the visible area.
For 4:2:2, chroma has half the luma width and full height; for 4:4:4 all
three planes have the same dimensions. Ten-bit samples occupy two bytes.

`Gray8` and `Gray10le` accept luma only: pass empty `u` and `v` buffers.
FFmpeg decodes the monochrome bitstream into 4:2:0 planes with neutral chroma;
the packed decoder helper returns those same planes, including rounded-up
chroma dimensions for odd visible widths or heights.

Full-range input goes through FFmpeg's deprecated `yuvj` aliases:
`Yuvj420p`, `Yuvj422p` and `Yuvj444p` share the plane layout of their
limited-range counterparts. FFmpeg 9's encode core pins every selected
`yuvj` format to `AVCOL_RANGE_JPEG` (encode.c `ff_encode_preinit`), so these
formats always signal full-range in the VUI regardless of `color_range`.
The decoder oracle reads the VUI-derived colour metadata back through
`X264DecFrames::color_range` / `colorspace` / `color_primaries` /
`color_trc` / `chroma_location`.

Colour metadata rides `X264Encoder::open`'s optional parameters onto the
SPS VUI: pass raw `AVCOL_*` / `AVCHROMA_LOC_*` values (`0` = unspecified
for everything except `colorspace`, whose unspecified value is **2** —
`0` there is RGB and selects GBR-planar decoding for 4:4:4 streams).
The `x264_color_*` / `x264_col_*` / `x264_chroma_loc_*` constants carry
the common values.

The semi-planar formats carry one interleaved chroma plane instead of
separate U and V planes: pass it as `u` with an empty `v`. `Nv12` pairs
are U then V, `Nv21` pairs are V then U; `Nv16` is the 4:2:2 variant and
`Nv20le` its 10-bit form. The decoder still emits planar output.

Packed RGB goes through the separate `libx264rgb` encoder: open with
`codec = "libx264rgb"` and one of `Bgr0` (32-bit BGRX, alpha ignored),
`Bgr24` or `Rgb24`. The single packed plane is `y` sized
`width * height * bytes_per_pixel()` bytes with empty `u`/`v`. x264
keeps RGB plane order: the bitstream is 4:4:4 and decodes to GBR
planar output (sink kind 7).

```mbt check
///|
test "native bgr24 encoder example" {
  if @x264.x264_supports("libx264rgb", @x264.Bgr24) {
    let enc = @x264.X264Encoder::open(
      width=32,
      height=16,
      pix_fmt=@x264.Bgr24,
      codec="libx264rgb",
      global_header=false,
      options=[("preset", "ultrafast"), ("x264-params", "keyint=25:bframes=0")],
    )
    let bgr = Bytes::makei(32 * 16 * 3, i => (i * 5 + 40).to_byte())
    let packets = enc.encode_all([(0L, bgr, b"", b"")])
    enc.close()
    assert_true(packets.length() > 0)
    let mut stream = b""
    for packet in packets {
      stream = stream + packet.data
    }
    let decoded = match @x264.x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.frame_y(0).length(), 32 * 16)
    assert_eq(decoded.frame_u(0).length(), 32 * 16)
  }
}
```

```mbt check
///|
test "native nv12 encoder example" {
  if @x264.x264_supports("libx264", @x264.Nv12) {
    let enc = @x264.X264Encoder::open(
      width=32,
      height=16,
      pix_fmt=@x264.Nv12,
      global_header=false,
      options=[("preset", "ultrafast"), ("x264-params", "keyint=25:bframes=0")],
    )
    let y = Bytes::make(32 * 16, b'\x80')
    // One interleaved plane: 16 x 8 U,V byte pairs.
    let uv = Bytes::makei(16 * 8 * 2, i => {
      (if i % 2 == 0 { 90 } else { 160 }).to_byte()
    })
    let packets = enc.encode_all([(0L, y, uv, b"")])
    enc.close()
    assert_true(packets.length() > 0)
    let mut stream = b""
    for packet in packets {
      stream = stream + packet.data
    }
    let decoded = match @x264.x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.frame_y(0).length(), 32 * 16)
    assert_eq(decoded.frame_u(0).length(), 16 * 8)
  }
}
```

```mbt check
///|
test "native grayscale encoder example" {
  if @x264.x264_supports("libx264", @x264.Gray8) {
    let enc = @x264.X264Encoder::open(
      width=35,
      height=19,
      pix_fmt=@x264.Gray8,
      global_header=false,
      options=[("preset", "ultrafast")],
    )
    let packets = enc.encode_all([(0L, Bytes::make(35 * 19, b'\x80'), b"", b"")])
    enc.close()
    let mut stream = b""
    for packet in packets {
      stream = stream + packet.data
    }
    let decoded = match @x264.x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.frame_y(0).length(), 35 * 19)
    assert_eq(decoded.frame_u(0), Bytes::make(18 * 10, b'\x80'))
  }
}
```

```mbt check
///|
test "native 444 encoder example" {
  let fmt = @x264.Yuv444p
  if @x264.x264_supports("libx264", fmt) {
    let enc = @x264.X264Encoder::open(
      width=32,
      height=16,
      pix_fmt=fmt,
      global_header=false,
      options=[("preset", "ultrafast"), ("x264-params", "keyint=25:bframes=0")],
    )
    let plane = Bytes::make(32 * 16, b'\x80')
    let packets = enc.encode_all([(0L, plane, plane, plane)])
    enc.close()
    assert_true(packets.length() > 0)
    let mut stream = b""
    for packet in packets {
      stream = stream + packet.data
    }
    let decoded = match @x264.x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    assert_eq(decoded.frame_y(0).length(), 32 * 16)
    assert_eq(decoded.frame_u(0).length(), 32 * 16)
    assert_eq(decoded.frame_v(0).length(), 32 * 16)
  }
}
```

Both `x264_probe_frames` and `x264_decode_annexb` support these formats.
The latter exposes the visible Y/Cb/Cr planes through `frame_y`, `frame_u`,
and `frame_v`; each call returns a MoonBit-owned copy.

```mbt check
///|
test "native full-range encoder example" {
  if @x264.x264_supports("libx264", @x264.Yuvj420p) {
    let enc = @x264.X264Encoder::open(
      width=32,
      height=16,
      pix_fmt=@x264.Yuvj420p,
      global_header=false,
      // Optional VUI metadata: raw AVCOL_* values (0/2 = unspecified).
      colorspace=@x264.x264_col_spc_bt709,
      color_trc=@x264.x264_col_trc_bt709,
      options=[("preset", "ultrafast"), ("bf", "0")],
    )
    let y = Bytes::make(32 * 16, b'\x80')
    let c = Bytes::make(16 * 8, b'\x80')
    let packets = enc.encode_all([(0L, y, c, c)])
    enc.close()
    let mut stream = b""
    for packet in packets {
      stream = stream + packet.data
    }
    let decoded = match @x264.x264_decode_annexb(stream) {
      Ok(d) => d
      Err(e) => fail(e)
    }
    // The yuvj format itself forces full-range; the explicit colour
    // description passes through the SPS VUI.
    assert_eq(decoded.color_range, @x264.x264_color_range_jpeg)
    assert_eq(decoded.colorspace, @x264.x264_col_spc_bt709)
    assert_eq(decoded.color_trc, @x264.x264_col_trc_bt709)
  }
}
```

Pass option values literally. Nested lists such as
`("x264-params", "keyint=25:bframes=0")` retain their separators; the binding
escapes the outer FFmpeg dictionary. Empty keys/values and embedded NUL are
rejected before entering C.

For incremental encoding, drain packets whenever `send_frame` returns `false`,
then resend that frame. At the end, `flush()` collects all pending packets and
retries EOF when necessary. Calling `flush()` again returns an empty array.
If using `send_eof()` directly, `SendFailed(1)` means EOF was not accepted:
receive pending packets and retry EOF. After EOF is accepted, receive until
`Eof`; new frames are rejected. `close()` may be called repeatedly.
