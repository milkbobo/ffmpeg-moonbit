///|
/// dav1d decode.c uses a->field[bx & 31] and l.field[by & 31]; the above
/// bank survives reset_context(l) between superblock rows.
test "inter edge writes use the same bank coordinates as readers" {
  let first = @libavcodec.av1_inter_tile_state_new(32, 32)
  let second : @libavcodec.Av1InterTileState = {
    top: FixedArray::makei(32, i => first.top[i]),
    left: first.left,
  }
  let n : @libavcodec.Av1InterNeighbor = {
    intra: false,
    comp_type: 2,
    ref0: 1,
    ref1: 4,
    filter0: 0,
    filter1: 2,
  }
  // At x=144px,y=264px this previously indexed well past a 32-entry bank.
  first.set_block(36, 66, 4, 2, n)
  assert_eq(first.top[4].ref0, 1)
  assert_eq(first.top[7].ref1, 4)
  assert_eq(first.left[2].filter0, 0)
  assert_eq(first.left[3].filter1, 2)
  assert_true(first.has_overlappable_neighbor(4, 2, 4, 2, true, true))
  assert_true(second.top[4].intra)
  second.set_block(68, 66, 2, 2, n)
  assert_eq(second.top[4].ref0, 1)
  first.reset_left()
  assert_true(second.left[2].intra)
  assert_eq(second.left[2].ref0, -1)
  assert_eq(second.left[2].ref1, -1)
  assert_eq(second.left[2].comp_type, 0)
  assert_eq(second.left[2].filter0, 3)
  assert_eq(second.left[2].filter1, 3)
  assert_eq(first.top[4].ref0, 1)
  assert_eq(second.top[4].ref0, 1)
}
