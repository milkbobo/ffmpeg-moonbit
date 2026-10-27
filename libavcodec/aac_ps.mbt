///|
/// MoonBit port of FFmpeg 9.0.2 `libavcodec/aacps_common.c` (Parametric
/// Stereo syntax: `ff_ps_read_data`, the parameter Huffman decoders of
/// `READ_PAR_DATA`, `num_env_tab` / `nr_*_par_tab`) and the
/// `PSCommonContext` state of `aacps.h`. The ten Huffman tries are built
/// from the canonical (length, code) tables of `aac_ps_tables.mbt` with the
/// `huff_offset` baked into the symbols, matching
/// `ff_vlc_init_tables_from_lengths`.
///
/// Original FFmpeg code is LGPL-2.1-or-later; this port keeps the same
/// license.

///|
/// `num_env_tab`.
let ps_num_env_tab : Array[Array[Int32]] = [[0, 1, 2, 4], [1, 2, 3, 4]]

///|
/// `nr_iidicc_par_tab`.
let ps_nr_iidicc_par_tab : Array[Int32] = [10, 20, 34, 10, 20, 34]

///|
/// `nr_iidopd_par_tab`.
let ps_nr_iidopd_par_tab : Array[Int32] = [5, 11, 17, 5, 11, 17]

///|
/// `ff_log2_tab` for `num_env` in 1..=4 (floor log2).
fn ps_log2_num_env(n : Int32) -> Int32 {
  match n {
    1 => 0
    2 | 3 => 1
    _ => 2
  }
}

///|
/// Decode one base64'd little-endian f64 blob into doubles (the float32
/// tablegen values widened exactly). Called only from the generated
/// `aac_ps_tables.mbt` initializers, keeping the wasm init locals flat.
fn ps_unpack_f64(b64 : Bytes) -> Array[Double] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 20) {
    Ok(v) => v
    Err(_) => abort("ps f64 table: invalid base64")
  }
  let n = raw.length() / 8
  let out = Array::make(n, 0.0)
  for i in 0..<n {
    let mut v : UInt64 = 0
    for k in 0..<8 {
      v = v | (raw[i * 8 + k].to_uint().to_uint64() << (k * 8))
    }
    out[i] = v.reinterpret_as_double()
  }
  out
}

///|
/// Decode one base64'd byte blob (each value 0..255) into Int32.
fn ps_unpack_i32(b64 : Bytes) -> Array[Int32] {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 20) {
    Ok(v) => v
    Err(_) => abort("ps i32 table: invalid base64")
  }
  let n = raw.length()
  let out = Array::make(n, 0)
  for i in 0..<n {
    out[i] = raw[i].to_uint().reinterpret_as_int()
  }
  out
}

///|
/// Build a decode trie from the packed Huffman blob of `aac_ps_tables.mbt`:
/// `n` lengths, `n` offset-baked symbols (+32 bias), `3n` code bytes
/// (little-endian), in table order — the exact code assignment of
/// `ff_vlc_init_from_lengths` (`code += 1 << (32 - len)`, left-aligned).
fn ps_unpack_huff(b64 : Bytes) -> AacVlc {
  let raw = match @libavutil.av_base64_decode(b64, 1 << 20) {
    Ok(v) => v
    Err(_) => abort("ps huff table: invalid base64")
  }
  let n = raw.length() / 5
  let nodes : Array[AacVlcNode] = [{ c0: -1, c1: -1, sym: -1, }]
  for i in 0..<n {
    let len = raw[i].to_uint().reinterpret_as_int()
    // The trie leaves must stay non-negative (AacVlc treats sym < 0 as
    // an interior node), so the +32 byte bias is kept and the callers
    // subtract it after decoding.
    let sym = raw[n + i].to_uint().reinterpret_as_int()
    let code = raw[2 * n + 3 * i].to_uint().reinterpret_as_int() |
      (raw[2 * n + 3 * i + 1].to_uint().reinterpret_as_int() << 8) |
      (raw[2 * n + 3 * i + 2].to_uint().reinterpret_as_int() << 16)
    if len > 0 {
      let mut node = 0
      for k = len - 1; k >= 0; k = k - 1 {
        let bit = (code >> k) & 1
        let cur = nodes[node]
        let next = if bit == 0 { cur.c0 } else { cur.c1 }
        if next < 0 {
          nodes.push({ c0: -1, c1: -1, sym: -1, })
          let idx = nodes.length() - 1
          if bit == 0 {
            nodes[node] = { c0: idx, c1: cur.c1, sym: cur.sym, }
          } else {
            nodes[node] = { c0: cur.c0, c1: idx, sym: cur.sym, }
          }
          node = idx
        } else {
          node = next
        }
      }
      nodes[node] = { c0: nodes[node].c0, c1: nodes[node].c1, sym, }
    }
  }
  { nodes, }
}

///|
/// The ten PS parameter Huffman tries, in `huff_iid_df1..huff_opd_dt`
/// order.
let ps_vlc_iid_df1 : AacVlc = ps_unpack_huff(ps_huff_iid_df1)

///|
let ps_vlc_iid_dt1 : AacVlc = ps_unpack_huff(ps_huff_iid_dt1)

///|
let ps_vlc_iid_df0 : AacVlc = ps_unpack_huff(ps_huff_iid_df0)

///|
let ps_vlc_iid_dt0 : AacVlc = ps_unpack_huff(ps_huff_iid_dt0)

///|
let ps_vlc_icc_df : AacVlc = ps_unpack_huff(ps_huff_icc_df)

///|
let ps_vlc_icc_dt : AacVlc = ps_unpack_huff(ps_huff_icc_dt)

///|
let ps_vlc_ipd_df : AacVlc = ps_unpack_huff(ps_huff_ipd_df)

///|
let ps_vlc_ipd_dt : AacVlc = ps_unpack_huff(ps_huff_ipd_dt)

///|
let ps_vlc_opd_df : AacVlc = ps_unpack_huff(ps_huff_opd_df)

///|
let ps_vlc_opd_dt : AacVlc = ps_unpack_huff(ps_huff_opd_dt)

///|
/// `PSCommonContext`: the syntax half of the PS state. Parameter rows are
/// `[PS_MAX_NUM_ENV=5][PS_MAX_NR_IIDICC=34]`, flattened to `e * 34 + b`.
pub struct AacPsCommon {
  mut start : Bool
  mut enable_iid : Bool
  mut iid_quant : Int32
  mut nr_iid_par : Int32
  mut nr_ipdopd_par : Int32
  mut enable_icc : Bool
  mut icc_mode : Int32
  mut nr_icc_par : Int32
  mut enable_ext : Bool
  mut frame_class : Int32
  mut num_env_old : Int32
  mut num_env : Int32
  mut enable_ipdopd : Bool
  border_position : Array[Int32]
  iid_par : Array[Int32]
  icc_par : Array[Int32]
  /// ipd/opd are iid/icc sized so the same helpers handle both.
  ipd_par : Array[Int32]
  opd_par : Array[Int32]
  mut is34bands : Bool
  mut is34bands_old : Bool
}

///|
/// Zero-initialized `PSCommonContext` (the C's calloc).
fn aac_ps_new_common() -> AacPsCommon {
  {
    start: false,
    enable_iid: false,
    iid_quant: 0,
    nr_iid_par: 0,
    nr_ipdopd_par: 0,
    enable_icc: false,
    icc_mode: 0,
    nr_icc_par: 0,
    enable_ext: false,
    frame_class: 0,
    num_env_old: 0,
    num_env: 0,
    enable_ipdopd: false,
    border_position: Array::make(6, 0),
    iid_par: Array::make(5 * 34, 0),
    icc_par: Array::make(5 * 34, 0),
    ipd_par: Array::make(5 * 34, 0),
    opd_par: Array::make(5 * 34, 0),
    is34bands: false,
    is34bands_old: false,
  }
}

///|
/// `READ_PAR_DATA(iid, ...)`: Huffman deltas with the |iid| > 7+8*quant
/// rejection. Returns false on the error path.
fn AacPsCommon::read_iid_data(
  self : AacPsCommon,
  gb : BitReader,
  vlc : AacVlc,
  e : Int32,
  dt : Bool,
) -> Bool {
  let num = self.nr_iid_par
  let limit = 7 + 8 * self.iid_quant
  if dt {
    let e_prev = if e > 0 {
      e - 1
    } else if self.num_env_old - 1 > 0 {
      self.num_env_old - 1
    } else {
      0
    }
    for b in 0..<num {
      let val = self.iid_par[e_prev * 34 + b] + (vlc.decode(gb) - 32)
      self.iid_par[e * 34 + b] = val
      if val > limit || val < -limit {
        return false
      }
    }
  } else {
    let mut val = 0
    for b in 0..<num {
      val = val + (vlc.decode(gb) - 32)
      self.iid_par[e * 34 + b] = val
      if val > limit || val < -limit {
        return false
      }
    }
  }
  true
}

///|
/// `READ_PAR_DATA(icc, ...)`: the C compares `icc_par > 7U`, so negative
/// values (possible after a dt wrap) also reject.
fn AacPsCommon::read_icc_data(
  self : AacPsCommon,
  gb : BitReader,
  vlc : AacVlc,
  e : Int32,
  dt : Bool,
) -> Bool {
  let num = self.nr_icc_par
  if dt {
    let e_prev = if e > 0 {
      e - 1
    } else if self.num_env_old - 1 > 0 {
      self.num_env_old - 1
    } else {
      0
    }
    for b in 0..<num {
      let val = self.icc_par[e_prev * 34 + b] + (vlc.decode(gb) - 32)
      self.icc_par[e * 34 + b] = val
      if val < 0 || val > 7 {
        return false
      }
    }
  } else {
    let mut val = 0
    for b in 0..<num {
      val = val + (vlc.decode(gb) - 32)
      self.icc_par[e * 34 + b] = val
      if val < 0 || val > 7 {
        return false
      }
    }
  }
  true
}

///|
/// `READ_PAR_DATA(ipdopd, 0x07, ...)`: values accumulate modulo 8, no
/// error condition. Used for both ipd and opd rows.
fn AacPsCommon::read_ipdopd_data(
  self : AacPsCommon,
  gb : BitReader,
  vlc : AacVlc,
  par : Array[Int32],
  e : Int32,
  dt : Bool,
) -> Unit {
  ignore(self)
  let num = self.nr_ipdopd_par
  if dt {
    let e_prev = if e > 0 {
      e - 1
    } else if self.num_env_old - 1 > 0 {
      self.num_env_old - 1
    } else {
      0
    }
    for b in 0..<num {
      par[e * 34 + b] = (par[e_prev * 34 + b] + (vlc.decode(gb) - 32)) & 7
    }
  } else {
    let mut val = 0
    for b in 0..<num {
      val = val + (vlc.decode(gb) - 32)
      par[e * 34 + b] = val & 7
    }
  }
}

///|
/// `ps_read_extension_data` (`ps_extension_id == 0`: ipd/opd enable and
/// rows). Returns the number of bits consumed.
fn AacPsCommon::read_extension_data(
  self : AacPsCommon,
  gb : BitReader,
  ps_extension_id : Int32,
) -> Int32 {
  if ps_extension_id != 0 {
    return 0
  }
  let count = gb.count()
  self.enable_ipdopd = gb.read1() != 0
  if self.enable_ipdopd {
    for e in 0..<self.num_env {
      let mut dt = gb.read1() != 0
      self.read_ipdopd_data(
        gb,
        if dt {
          ps_vlc_ipd_dt
        } else {
          ps_vlc_ipd_df
        },
        self.ipd_par,
        e,
        dt,
      )
      dt = gb.read1() != 0
      self.read_ipdopd_data(
        gb,
        if dt {
          ps_vlc_opd_dt
        } else {
          ps_vlc_opd_df
        },
        self.opd_par,
        e,
        dt,
      )
    }
  }
  gb.skip(1) // reserved_ps
  gb.count() - count
}

///|
/// Temporary debug: which error return fired last.
let aac_ps_err_tag : Ref[String] = { val: "", }

///|
/// White-box hook of the PS syntax tests: when enabled, every
/// `read_data` call appends its post-parse state in exactly the format of
/// the instrumented C `ps_dump_syntax` (`_build/ps_work`), so the dumps can
/// be diffed line by line.
let aac_ps_syntax_trace : Ref[Array[String]] = { val: [], }

///|
let aac_ps_syntax_trace_on : Ref[Bool] = { val: false, }

///|
let aac_ps_read_count : Ref[Int32] = { val: 0, }

///|
/// Debug: bit cursor + first bits at each read_data entry.
let aac_ps_entry_dbg : Ref[Array[String]] = { val: [], }

///|
/// One `ps_dump_syntax` line.
fn AacPsCommon::trace_line(self : AacPsCommon, id : Int32) -> String {
  fn d(b : Bool) -> Int32 {
    if b {
      1
    } else {
      0
    }
  }
  let mut s = "PS \{id} start=\{d(self.start)} eiid=\{d(self.enable_iid)} iquant=\{self.iid_quant} nriid=\{self.nr_iid_par} nripd=\{self.nr_ipdopd_par} eicc=\{d(self.enable_icc)} iccm=\{self.icc_mode} nricc=\{self.nr_icc_par} eext=\{d(self.enable_ext)} fcls=\{self.frame_class} nenvo=\{self.num_env_old} nenv=\{self.num_env} eipd=\{d(self.enable_ipdopd)} is34=\{d(self.is34bands)} is34o=\{d(self.is34bands_old)} bp="
  for i in 0..<6 {
    s = s + "\{self.border_position[i]},"
  }
  s = s + " iid="
  for i in 0..<(5 * 34) {
    s = s + "\{self.iid_par[i]},"
  }
  s = s + " icc="
  for i in 0..<(5 * 34) {
    s = s + "\{self.icc_par[i]},"
  }
  s = s + " ipd="
  for i in 0..<(5 * 34) {
    s = s + "\{self.ipd_par[i]},"
  }
  s = s + " opd="
  for i in 0..<(5 * 34) {
    s = s + "\{self.opd_par[i]},"
  }
  s
}

///|
/// The `err:` label of `ff_ps_read_data`: rewind the whole payload, drop
/// `start`, zero the parameter rows.
fn AacPsCommon::read_data_err(
  self : AacPsCommon,
  gb : BitReader,
  start_pos : Int32,
  bits_left : Int32,
) -> Int32 {
  if aac_ps_syntax_trace_on.val {
    aac_ps_syntax_trace.val.push(self.trace_line(-aac_ps_read_count.val))
  }
  self.start = false
  gb.set_pos(start_pos + bits_left)
  for i in 0..<(5 * 34) {
    self.iid_par[i] = 0
    self.icc_par[i] = 0
    self.ipd_par[i] = 0
    self.opd_par[i] = 0
  }
  bits_left
}

///|
/// `ff_ps_read_data`: parses one PS extension payload. `bits_left` is the
/// payload's remaining bit budget; returns the number of bits consumed
/// (`bits_left` itself on the error path, which also rewinds the reader).
fn AacPsCommon::read_data(
  self : AacPsCommon,
  gb : BitReader,
  bits_left : Int32,
) -> Int32 {
  let bit_count_start = gb.count()
  if aac_ps_syntax_trace_on.val {
    let peek = gb.show(24)
    let mut b = ""
    for k in 0..<24 {
      b = b + "\{((peek >> (23 - k)) & 1).reinterpret_as_int()}"
    }
    aac_ps_entry_dbg.val.push(
      "pos=\{bit_count_start} left=\{bits_left} bits=\{b}",
    )
  }
  let header = gb.read1().reinterpret_as_int()
  if header != 0 {
    // enable_ps_header
    self.enable_iid = gb.read1() != 0
    if self.enable_iid {
      let iid_mode = gb.read(3).reinterpret_as_int()
      if iid_mode > 5 {
        // "iid_mode %d is reserved."
        aac_ps_err_tag.val = "iid_mode"
        return self.read_data_err(gb, bit_count_start, bits_left)
      }
      self.nr_iid_par = ps_nr_iidicc_par_tab[iid_mode]
      self.iid_quant = if iid_mode > 2 { 1 } else { 0 }
      self.nr_ipdopd_par = ps_nr_iidopd_par_tab[iid_mode]
    }
    self.enable_icc = gb.read1() != 0
    if self.enable_icc {
      let icc_mode = gb.read(3).reinterpret_as_int()
      if icc_mode > 5 {
        // "icc_mode %d is reserved."
        aac_ps_err_tag.val = "icc_mode"
        return self.read_data_err(gb, bit_count_start, bits_left)
      }
      self.icc_mode = icc_mode
      self.nr_icc_par = ps_nr_iidicc_par_tab[icc_mode]
    }
    self.enable_ext = gb.read1() != 0
  }
  self.frame_class = gb.read1().reinterpret_as_int()
  self.num_env_old = self.num_env
  self.num_env = ps_num_env_tab[self.frame_class][gb
    .read(2)
    .reinterpret_as_int()]
  self.border_position[0] = -1
  if self.frame_class != 0 {
    for e in 1..<=self.num_env {
      self.border_position[e] = gb.read(5).reinterpret_as_int()
      if self.border_position[e] < self.border_position[e - 1] {
        // "border_position non monotone."
        aac_ps_err_tag.val = "border"
        return self.read_data_err(gb, bit_count_start, bits_left)
      }
    }
  } else {
    for e in 1..<=self.num_env {
      self.border_position[e] = ((e * 32) >> ps_log2_num_env(self.num_env)) - 1
    }
  }
  if self.enable_iid {
    for e in 0..<self.num_env {
      let dt = gb.read1() != 0
      // huff_iid[2*dt + iid_quant] = {df0, df1, dt0, dt1}
      let vlc = match (dt, self.iid_quant) {
        (false, 0) => ps_vlc_iid_df0
        (false, _) => ps_vlc_iid_df1
        (true, 0) => ps_vlc_iid_dt0
        (true, _) => ps_vlc_iid_dt1
      }
      if !self.read_iid_data(gb, vlc, e, dt) {
        aac_ps_err_tag.val = "read_iid dt=\{dt} q=\{self.iid_quant}"
        return self.read_data_err(gb, bit_count_start, bits_left)
      }
    }
  } else {
    for i in 0..<(5 * 34) {
      self.iid_par[i] = 0
    }
  }
  if self.enable_icc {
    for e in 0..<self.num_env {
      let dt = gb.read1() != 0
      let vlc = if dt { ps_vlc_icc_dt } else { ps_vlc_icc_df }
      if !self.read_icc_data(gb, vlc, e, dt) {
        aac_ps_err_tag.val = "read_icc dt=\{dt}"
        return self.read_data_err(gb, bit_count_start, bits_left)
      }
    }
  } else {
    for i in 0..<(5 * 34) {
      self.icc_par[i] = 0
    }
  }
  if self.enable_ext {
    let mut cnt = gb.read(4).reinterpret_as_int()
    if cnt == 15 {
      cnt = cnt + gb.read(8).reinterpret_as_int()
    }
    cnt = cnt * 8
    while cnt > 7 {
      let ps_extension_id = gb.read(2).reinterpret_as_int()
      cnt = cnt - 2 - self.read_extension_data(gb, ps_extension_id)
    }
    if cnt < 0 {
      // "ps extension overflow"
      aac_ps_err_tag.val = "generic"
      return self.read_data_err(gb, bit_count_start, bits_left)
    }
    gb.skip(cnt)
  }
  // PS_BASELINE is 0 upstream, so `enable_ipdopd &= !PS_BASELINE` is a no-op.
  // Fix up envelopes: create a fake envelope when the last one ends early.
  if self.num_env == 0 || self.border_position[self.num_env] < 31 {
    let source = if self.num_env > 0 {
      self.num_env - 1
    } else {
      self.num_env_old - 1
    }
    if source >= 0 && source != self.num_env {
      if self.enable_iid {
        for b in 0..<34 {
          self.iid_par[self.num_env * 34 + b] = self.iid_par[source * 34 + b]
        }
      }
      if self.enable_icc {
        for b in 0..<34 {
          self.icc_par[self.num_env * 34 + b] = self.icc_par[source * 34 + b]
        }
      }
      if self.enable_ipdopd {
        for b in 0..<34 {
          self.ipd_par[self.num_env * 34 + b] = self.ipd_par[source * 34 + b]
          self.opd_par[self.num_env * 34 + b] = self.opd_par[source * 34 + b]
        }
      }
    }
    let limit = 7 + 8 * self.iid_quant
    if self.enable_iid {
      for b in 0..<self.nr_iid_par {
        let v = self.iid_par[self.num_env * 34 + b]
        if v > limit || v < -limit {
          // "iid_par invalid"
          aac_ps_err_tag.val = "iid_par invalid"
          return self.read_data_err(gb, bit_count_start, bits_left)
        }
      }
    }
    if self.enable_icc {
      // The C bounds this check by nr_iid_par, not nr_icc_par.
      for b in 0..<self.nr_iid_par {
        let v = self.icc_par[self.num_env * 34 + b]
        if v < 0 || v > 7 {
          // "icc_par invalid"
          aac_ps_err_tag.val = "icc_par invalid"
          return self.read_data_err(gb, bit_count_start, bits_left)
        }
      }
    }
    self.num_env = self.num_env + 1
    self.border_position[self.num_env] = 31
  }
  self.is34bands_old = self.is34bands
  if self.enable_iid || self.enable_icc {
    self.is34bands = (self.enable_iid && self.nr_iid_par == 34) ||
      (self.enable_icc && self.nr_icc_par == 34)
  }
  // Baseline: no ipd/opd without the extension.
  if !self.enable_ipdopd {
    for i in 0..<(5 * 34) {
      self.ipd_par[i] = 0
      self.opd_par[i] = 0
    }
  }
  if header != 0 {
    self.start = true
  }
  let bits_consumed = gb.count() - bit_count_start
  if bits_consumed <= bits_left {
    if aac_ps_syntax_trace_on.val {
      aac_ps_read_count.val = aac_ps_read_count.val + 1
      aac_ps_syntax_trace.val.push(self.trace_line(aac_ps_read_count.val))
    }
    bits_consumed
  } else {
    // "Expected to read %d PS bits actually read %d."
    self.read_data_err(gb, bit_count_start, bits_left)
  }
}
