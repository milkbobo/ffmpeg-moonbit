// 白盒：CABAC 引擎 bin 级往返（编码器 → 共享解码核）。
// 覆盖中途 terminate(0)（每个 CTB 末尾都有 end_of_slice_segment_flag=0）
// 后继续编码的场景——这是 H.264 引擎验证没走过的路径。回放按写端轨迹
// 逐 bin 驱动解码器：决策/绕过取同一 ctx，terminate 用 get_cabac_terminate。

///|
fn hevc_enc_cabac_sweep_case(at_term : Int32) -> Unit raise {
  let mut seed = 12345
  let next = fn() -> Int32 {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    seed >> 16
  }
  let states_enc = ff_hevc_init_cabac_states(26, hevc_slice_i, false)
  let states_dec = ff_hevc_init_cabac_states(26, hevc_slice_i, false)
  let enc = { eng: hevc_cabac_enc_new(), states: states_enc, trace: [], }
  let mut terminated = false
  for i in 0..<400 {
    let ctx = next() % 199
    let bit = next() % 2
    enc.eng.decision(enc.states, ctx, bit)
    if i % 7 == 0 {
      let bp = next() % 2
      enc.eng.bypass(bp)
    }
    if i == at_term {
      enc.eng.terminate(0)
      terminated = true
    }
  }
  enc.eng.terminate(1)
  // 回放轨迹（含 terminate 标记）：把 terminate(0) 的位置记成 ctx=-2。
  let trace : Array[(Int32, Int32)] = []
  let mut term_at = -1
  seed = 12345
  for i in 0..<400 {
    let ctx = next() % 199
    let bit = next() % 2
    trace.push((ctx, bit))
    if i % 7 == 0 {
      let bp = next() % 2
      trace.push((-1, bp))
    }
    if i == at_term {
      trace.push((-2, 0))
      term_at = trace.length() - 1
    }
  }
  trace.push((-2, 1))
  let bytes = Bytes::from_array(enc.eng.to_bytes())
  let cc = match ff_init_cabac_decoder(bytes, 0) {
    Ok(c) => c
    Err(e) => fail("\{e}")
  }
  for i in 0..<trace.length() {
    let (ctx, want) = trace[i]
    let got = if ctx >= 0 {
      cc.get_cabac(states_dec, ctx)
    } else if ctx == -1 {
      cc.get_cabac_bypass()
    } else {
      let t = cc.get_cabac_terminate()
      if want == 1 && t == 0 && i < trace.length() - 1 {
        fail("term@\{at_term}: terminate(1) not detected at bin \{i}")
      }
      if want == 0 && t != 0 {
        fail("term@\{at_term}: spurious terminate at bin \{i}")
      }
      0
    }
    if ctx >= 0 && got != want {
      fail(
        "term@\{at_term}: FAIL at bin \{i}: ctx=\{ctx} want=\{want} got=\{got}",
      )
    }
    if ctx == -1 && got != want {
      fail("term@\{at_term}: bypass FAIL at bin \{i}: want=\{want} got=\{got}")
    }
    ignore(terminated)
    ignore(term_at)
  }
}

///|
test "hevc enc cabac: terminate0 sweep" {
  for at_term in [0, 1, 50, 100, 199, 200, 201, 250, 300, 399] {
    hevc_enc_cabac_sweep_case(at_term)
  }
}

///|
test "hevc enc cabac: terminate0 at every 13th bin" {
  for
    at_term in [
      13, 26, 39, 52, 65, 78, 91, 104, 117, 130, 143, 156, 169, 182, 195, 208, 221,
      234, 247, 260, 273, 286, 299, 312,
    ] {
    hevc_enc_cabac_sweep_case(at_term)
  }
}
