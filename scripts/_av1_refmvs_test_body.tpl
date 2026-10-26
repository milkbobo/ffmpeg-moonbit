///|
fn av1_refmvs_test_check(k : Int, res : @libavcodec.Av1RefmvsResult) -> Unit raise {
  let base = av1_refmvs_test_offsets[k]
  let want_cnt = av1_refmvs_test_expect[base]
  if res.cnt != want_cnt {
    fail("case \{k} cnt: got \{res.cnt}, want \{want_cnt}")
  }
  if res.ctx != av1_refmvs_test_expect[base + 1] {
    fail("case \{k} ctx: got \{res.ctx}, want \{av1_refmvs_test_expect[base + 1]}")
  }
  for n in 0..<res.cnt {
    let o = base + 2 + n * 5
    if res.candidate_weight(n) != av1_refmvs_test_expect[o] {
      fail("case \{k} cand \{n} weight")
    }
    let (mv0, mv1) = res.candidate(n)
    if mv0.0 != av1_refmvs_test_expect[o + 1] ||
      mv0.1 != av1_refmvs_test_expect[o + 2] {
      fail("case \{k} cand \{n} mv0: got (\{mv0.0},\{mv0.1})")
    }
    if mv1.0 != av1_refmvs_test_expect[o + 3] ||
      mv1.1 != av1_refmvs_test_expect[o + 4] {
      fail("case \{k} cand \{n} mv1: got (\{mv1.0},\{mv1.1})")
    }
  }
}

///|
test "av1 refmvs find matches dav1d C reference" {
  // bs list mirrors dump_refmvs.c (dav1d enum BlockSize values).
  let bs_list : FixedArray[Int] = [
    0, 3, 7, 8, 11, 12, 13, 16, 17, 18, 20, 21, 4, 6,
  ]
  let mut k = 0
  for seed in 1..=24 {
    let (rf, rows, rp, _) = av1_refmvs_test_build(seed)
    for bi in 0..<14 {
      let bs = bs_list[bi]
      let by4 = 8 + (bi % 2) * 4
      let bx4 = 4 + (bi % 3) * 4
      for variant in 0..<3 {
        let (ref0, ref1) = if variant == 0 {
          (1, -1)
        } else if variant == 1 {
          (4, -1)
        } else {
          (1 + seed % 7, 4)
        }
        let thr = (bi & 1) == 1
        let res = @libavcodec.av1_refmvs_find(
          rf, rows, rp, 40, 0, 32, 0, 32, ref0, ref1, bs, thr, by4, bx4,
        )
        av1_refmvs_test_check(k, res)
        k = k + 1
      }
    }
  }
  inspect(k, content="1008")
}

///|
test "av1 get_gmv_2d matches dav1d" {
  let types : FixedArray[Int] = [1, 2, 3]
  let mats : FixedArray[FixedArray[Int]] = [
    [73728, 67584, 0, 0, 0, 0],
    [73728, 67584, 64458, 72, -72, 64458],
    [73728, 67584, 64458, 72, 128, 64000],
  ]
  let mut k = 0
  for t in 0..<3 {
    for pos in 0..<4 {
      let g = @libavcodec.av1_rmv_get_gmv_2d_probe(
        types[t], mats[t], 4 * pos, 2 * pos, 4 + pos, 8 - pos, true, false,
      )
      if g.0 != av1_refmvs_gmv_expect[k * 2] ||
        g.1 != av1_refmvs_gmv_expect[k * 2 + 1] {
        fail("gmv \{k}: got (\{g.0},\{g.1})")
      }
      k = k + 1
    }
  }
}

///|
test "av1 mv_projection matches dav1d" {
  for k in 0..<16 {
    let p = @libavcodec.av1_rmv_projection_probe(
      (
        av1_refmvs_proj_expect[k * 6 + 2],
        av1_refmvs_proj_expect[k * 6 + 3],
      ),
      av1_refmvs_proj_expect[k * 6],
      av1_refmvs_proj_expect[k * 6 + 1],
    )
    if p.0 != av1_refmvs_proj_expect[k * 6 + 4] ||
      p.1 != av1_refmvs_proj_expect[k * 6 + 5] {
      fail("proj \{k}: got (\{p.0},\{p.1})")
    }
  }
}

///|
test "av1 refmvs init_frame matches dav1d" {
  // rnd state continues after build_case(24) in the dumper
  let (_, _, _, tail) = av1_refmvs_test_build(24)
  let st : Ref[UInt] = Ref(tail)
  for t in 0..<20 {
    let ref_poc = FixedArray::make(7, 0)
    let has = FixedArray::make(7, false)
    let rrp = FixedArray::makei(7, _ => FixedArray::make(7, 0))
    for i in 0..<7 {
      ref_poc[i] = av1_refmvs_test_inrange(st, 128)
      has[i] = av1_refmvs_test_inrange(st, 3) != 0
      for m in 0..<7 {
        rrp[i][m] = av1_refmvs_test_inrange(st, 128)
      }
    }
    let r = @libavcodec.av1_refmvs_init_frame(
      7, 9, true, ref_poc, has, rrp,
    )
    let want : Array[String] = []
    for sv in av1_refmvs_init_expect[t].split(" ") {
      want.push(sv.to_owned())
    }
    inspect(r.n_mfmvs.to_string(), content=want[1])
    for i in 0..<7 {
      let tri : Array[StringView] = want[2 + i].split(",").to_array()
      inspect(r.sign_bias[i].to_string(), content=(tri[0]).to_owned())
      inspect(r.mfmv_sign[i].to_string(), content=(tri[1]).to_owned())
      inspect(r.pocdiff[i].to_string(), content=(tri[2]).to_owned())
    }
    for n in 0..<3 {
      let pair : Array[StringView] = want[9 + n].split(":").to_array()
      inspect(r.mfmv_ref[n].to_string(), content=(pair[0]).to_owned())
      inspect(r.mfmv_ref2cur[n].to_string(), content=(pair[1]).to_owned())
    }
    let refs_all : Array[StringView] = want[12].split(",").to_array()
    let refs : Array[StringView] = []
    for i in 1..<refs_all.length() {
      refs.push(refs_all[i])
    }
    let mut k = 0
    for n in 0..<3 {
      for m in 0..<7 {
        inspect(r.mfmv_ref2ref[n][m].to_string(), content=(refs[k]).to_owned())
        k = k + 1
      }
    }
    inspect((if r.use_ref_frame_mvs { "1" } else { "0" }), content=want[13])
  }
}
