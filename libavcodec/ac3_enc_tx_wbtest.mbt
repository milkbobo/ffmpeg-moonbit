///|
test "ac3enc: switching BAP banks rebinds exponent-reuse blocks" {
  let enc = match Ac3FixedEncoder::new(48000, 0x3, 192000) {
    Ok(enc) => enc
    Err(err) => fail(err)
  }
  enc.exp_ref_block[1][1] = 0
  enc.reset_block_bap(enc.bap_bank())
  enc.bap_cur = !enc.bap_cur
  // The coupling slots in the two banks contain identical values.
  // Switching banks must still move references for every channel.
  enc.reset_block_bap(enc.bap_bank())
  enc.ref_bap[1][1][23] = 2
  assert_eq(enc.ref_bap[1][0][23], 2)
  assert_eq(enc.bap_bank1[1][0][23], 2)
  assert_eq(enc.bap_bank0[1][0][23], 0)
}
