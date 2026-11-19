// 白盒：残差写端 vs 解码器 hevc_decode_residual 直接对拍。
// 构造已知 levels → 编码器写 bins → 解码器读出（coeffs 为变换后空间残差）
// → 与编码端 hevc_enc_recon_transform 的重建逐点比对。覆盖：DC-only、
// 最后系数落在不同 CG、16x16 多子集、大 remaining 值、负电平。

///|
/// 残差对拍驱动：写 levels → 解码 → 与编码端重建比较。
fn hevc_enc_residual_compare(
  levels : FixedArray[Int32],
  n : Int32,
  scan_idx : Int32,
  qp : Int32,
) -> Unit raise {
  let log2 = match n {
    4 => 2
    8 => 3
    16 => 4
    _ => 5
  }
  let enc = {
    eng: hevc_cabac_enc_new(),
    states: ff_hevc_init_cabac_states(qp, hevc_slice_i, false),
    trace: [],
  }
  enc.residual(levels, n, scan_idx, 0)
  enc.terminate(1)
  let payload = Bytes::from_array(enc.eng.to_bytes())
  let pad = 32
  let ps = new_hevc_param_sets()
  let ps_bytes = hevc_enc_concat([
    hevc_enc_nal(hevc_enc_vps(), 32),
    hevc_enc_nal(hevc_enc_sps(pad, pad, 0, 0, false), 33),
    hevc_enc_nal(hevc_enc_pps(qp, false), 34),
  ])
  match ff_hevc_decode_extradata(ps_bytes, ps, true) {
    Ok(_) => ()
    Err(e) => fail("extradata: \{e}")
  }
  let sps = match ps.sps_list[0] {
    Some(s) => s
    None => fail("no sps")
  }
  let pps = match ps.pps_list[0] {
    Some(p) => p
    None => fail("no pps")
  }
  let header = hevc_enc_slice_header(sps, pps, qp, hevc_slice_i)
  let rbsp : Array[Byte] = []
  for i in 0..<header.length() {
    rbsp.push(header[i])
  }
  for i in 0..<payload.length() {
    rbsp.push(payload[i])
  }
  let slice_nal = hevc_enc_nal(Bytes::from_array(rbsp), 19)
  let stream = hevc_enc_concat([ps_bytes, slice_nal])
  let pkt = match ff_h2645_packet_split(stream, 0, Hevc, false) {
    Ok(p) => p
    Err(e) => fail("\{e}")
  }
  let mut slice : H2645Nal? = None
  for nal in pkt.nals {
    if nal.nal_type <= 31 {
      slice = Some(nal)
    }
  }
  let nal = match slice {
    Some(x) => x
    None => fail("no slice")
  }
  let gb = BitReader::with_size(nal.data, nal.size_bits)
  gb.skip(16)
  let sh = match ff_hevc_decode_slice_header(gb, nal.nal_type, ps, 0) {
    Ok(h) => h
    Err(e) => fail("sh: \{e}")
  }
  let states = ff_hevc_init_cabac_states(qp, hevc_slice_i, false)
  let cabac = match
    hevc_cabac_new(nal.data, (sh.header_bits + 7) >> 3, states) {
    Ok(c) => c
    Err(e) => fail("\{e}")
  }
  let pic = hevc_picture_new(pad, pad, pad >> 1, pad >> 1)
  let coeffs = match
    hevc_decode_residual(
      cabac, sps, pps, sh, pic, 0, 0, log2, scan_idx, 0, qp, true,
    ) {
    Ok(c) => c
    Err(e) => fail("residual: \{e}")
  }
  let last_x = hevc_enc_last_x(levels, n, scan_idx)
  let last_y = hevc_enc_last_y(levels, n, scan_idx)
  let recon = hevc_enc_recon_transform(levels, n, qp, 8, false, last_x, last_y)
  for i in 0..<(n * n) {
    if coeffs[i] != recon[i] {
      // 打印整个矩阵便于定位：仅首个失败时输出。
      let mut drow = ""
      let mut erow = ""
      for yy in 0..<n {
        for xx in 0..<n {
          drow = drow + " " + coeffs[yy * n + xx].to_string()
          erow = erow + " " + recon[yy * n + xx].to_string()
        }
        println("DEC r\{yy}:\{drow}")
        println("ENC r\{yy}:\{erow}")
        drow = ""
        erow = ""
      }
      fail(
        "n=\{n} qp=\{qp} scan=\{scan_idx}: pos(\{i % n},\{i / n}) dec=\{coeffs[i]} enc=\{recon[i]} last=(\{last_x},\{last_y})",
      )
    }
  }
}

///|
test "hevc enc residual: dc-only 8x8" {
  let levels : FixedArray[Int32] = FixedArray::make(64, 0)
  levels[0] = 11
  hevc_enc_residual_compare(levels, 8, hevc_scan_diag, 26)
}

///|
test "hevc enc residual: 8x8 last in each CG" {
  // 最后系数分别落在四个 CG（diag 扫描 p=15/31/47/63）。
  for p in [15, 31, 47, 63] {
    let levels : FixedArray[Int32] = FixedArray::make(64, 0)
    // 扫描位 p → 行主序：CG (p>>4) + 块内 (p&15)。
    let cgx = hevc_diag_scan2x2_x[p >> 4]
    let cgy = hevc_diag_scan2x2_y[p >> 4]
    let ox = hevc_diag_scan4x4_x[p & 15]
    let oy = hevc_diag_scan4x4_y[p & 15]
    levels[(cgy * 4 + oy) * 8 + cgx * 4 + ox] = 7
    levels[0] = 5
    hevc_enc_residual_compare(levels, 8, hevc_scan_diag, 26)
  }
}

///|
test "hevc enc residual: 8x8 full noise multi-cg" {
  let vals = hevc_enc_test_rand(42, 64)
  let levels : FixedArray[Int32] = FixedArray::make(64, 0)
  for i in 0..<64 {
    levels[i] = vals[i] / 8
  }
  levels[0] = 40
  levels[63] = -9
  hevc_enc_residual_compare(levels, 8, hevc_scan_diag, 26)
}

///|
test "hevc enc residual: big values prefix>=3 with rice growth" {
  let levels : FixedArray[Int32] = FixedArray::make(64, 0)
  levels[0] = 300
  levels[5] = -127
  levels[20] = 64
  levels[33] = 15
  levels[48] = -3
  hevc_enc_residual_compare(levels, 8, hevc_scan_diag, 0)
  hevc_enc_residual_compare(levels, 8, hevc_scan_diag, 26)
}

///|
test "hevc enc residual: 16x16 multi-subset with cg flags" {
  let vals = hevc_enc_test_rand(7, 256)
  let levels : FixedArray[Int32] = FixedArray::make(256, 0)
  for i in 0..<256 {
    levels[i] = vals[i] / 4
  }
  levels[0] = 55
  levels[255] = -21
  hevc_enc_residual_compare(levels, 16, hevc_scan_diag, 26)
}

///|
test "hevc enc residual: vert and horiz scans" {
  let vals = hevc_enc_test_rand(31, 64)
  let levels : FixedArray[Int32] = FixedArray::make(64, 0)
  for i in 0..<64 {
    levels[i] = vals[i] / 8
  }
  levels[7] = 13
  hevc_enc_residual_compare(levels, 8, hevc_scan_vert, 26)
  hevc_enc_residual_compare(levels, 8, hevc_scan_horiz, 26)
}

///|
test "hevc enc residual: 32x32 four subsets" {
  let vals = hevc_enc_test_rand(88, 1024)
  let levels : FixedArray[Int32] = FixedArray::make(1024, 0)
  for i in 0..<1024 {
    levels[i] = vals[i] / 32
  }
  levels[0] = 90
  levels[1023] = -31
  hevc_enc_residual_compare(levels, 32, hevc_scan_diag, 26)
}
