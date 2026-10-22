///|
test "opus CELT: invalid setup and allocation parameters preserve entropy state" {
  let rc = @libavcodec.opus_rc_init(b"\x00\x23\x88\x61").unwrap()
  let before = rc.tell_frac()
  for channels in [0,3] {
    assert_true(rc.decode_celt_allocation(channels,0,0,21,32,false) is Err("opus: CELT requires one or two coded channels"))
    assert_true(rc.decode_celt_setup(channels,120,0,21) is Err("opus: CELT requires one or two coded channels"))
  }
  for size in [-1,4] {
    assert_true(rc.decode_celt_allocation(1,size,0,21,32,false) is Err("opus: invalid CELT block size"))
  }
  for frame_size in [0,119,121,1920] {
    assert_true(rc.decode_celt_setup(1,frame_size,0,21) is Err("opus: invalid CELT frame size"))
  }
  for (start, end) in [(-1,21),(0,0),(21,21),(0,22),(17,13)] {
    assert_true(rc.decode_celt_setup(1,120,start,end) is Err("opus: invalid CELT band interval"))
    assert_true(rc.decode_celt_allocation(1,0,start,end,32,false) is Err("opus: invalid CELT band interval"))
  }
  for bits in [-1,33] {
    assert_true(rc.decode_celt_allocation(1,0,0,21,bits,false) is Err("opus: invalid CELT frame bit budget"))
  }
  assert_true(rc.decode_celt_setup(1,120,0,21,previous_energy=[0.0]) is Err("opus: CELT energy history must have 42 bands"))
  for value in [Float::reinterpret_from_uint(0x7f800000U),Float::reinterpret_from_uint(0x7fc00000U)] {
    let history = Array::make(42,value)
    assert_true(rc.decode_celt_setup(1,120,0,21,previous_energy=history) is Err("opus: nonfinite CELT energy history"))
  }
  assert_eq(rc.tell_frac(), before)
}
