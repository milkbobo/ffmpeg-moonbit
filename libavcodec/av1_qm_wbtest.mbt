///|
test "AV1 qmatrix all levels planes and transform shapes match dav1d C" {
  for level in 0..<16 {
    for chroma in 0..<2 {
      for tx in 0..<19 {
        let w = 4 << av1_imin(av1_txfm_lw(tx), 3)
        let h = 4 << av1_imin(av1_txfm_lh(tx), 3)
        let mut hash = 2166136261U
        for rc in 0..<(w * h) {
          hash = (
              hash ^ av1_qm_weight(level, chroma, tx, rc).reinterpret_as_uint()
            ) *
            16777619U
        }
        assert_eq(
          hash,
          av1_qm_reference[(level * 2 + chroma) * 19 + tx],
          msg="qmatrix level=\{level} chroma=\{chroma} tx=\{tx}",
        )
      }
    }
  }
}
