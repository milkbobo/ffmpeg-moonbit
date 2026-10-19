///|
/// MoonBit port of FFmpeg 9.0.2 `libavutil/avstring.c` / `avstring.h`, plus the
/// `av_bprint_escape` body that `av_escape` delegates to
/// (`libavutil/bprint.c`).
///
/// Original FFmpeg code is LGPL-2.1-or-later, copyright (c) 2007 Nicolas George
/// and others. This port keeps the same license.
///
/// Signature adaptations:
///   * C's `char *` outputs and pointer-returning functions become MoonBit
///     `String` / `Int?` (an index into the haystack, `None` for the C `NULL`).
///   * `av_strlcpy`/`av_strlcat` keep the C contract of writing into a caller
///     buffer (`FixedArray[Byte]`, assumed at least `size` long) and returning
///     the untruncated length.
///   * `av_get_token`/`av_dirname`/`av_strtok` mutate their input in C; here the
///     cursor position is an explicit `Int` in and out.
///   * `av_escape` returns the escaped string instead of allocating through
///     `AVBPrint`, and `av_utf8_decode` returns `(result, new position)` so the
///     cursor advance is visible in the error cases too.
///   * Not ported: the varargs trio `av_strlcatf`/`av_asprintf`/`av_bprintf`,
///     and `av_strtok`. `av_basename`/`av_dirname` implement the POSIX branch
///     only (`HAVE_DOS_PATHS` handling is omitted).

// ---------------------------------------------------------------------------
// Small helpers mirroring libavutil/common.h / C string.h
// ---------------------------------------------------------------------------

///| ASCII-only lowercasing, `av_tolower` from libavutil/avstring.h. */
fn ch_tolower(c : Char) -> Char {
  let u = c.to_uint()
  if u >= 65 && u <= 90 {
    (u ^ 32).to_byte().to_char()
  } else {
    c
  }
}

///| One of the `WHITESPACES` characters (space, newline, tab, carriage return). */
fn is_ws(c : Char) -> Bool {
  c == ' ' || c == '\n' || c == '\t' || c == '\r'
}

///| `strchr`: index of the first `needle` at or after `start`, or `len` if absent. */
fn find_from(a : Array[Char], start : Int, needle : Char) -> Int {
  let mut i = start
  while i < a.length() {
    if a[i] == needle {
      return i
    }
    i = i + 1
  }
  a.length()
}

///| `strspn(p, set) != 0`: true when `c` occurs in `set`. */
fn char_in(c : Char, set : Array[Char]) -> Bool {
  find_from(set, 0, c) < set.length()
}

///| Build a `String` from `a[start..end)`. */
fn str_of(a : Array[Char], start : Int, end : Int) -> String {
  if end <= start {
    ""
  } else {
    String::from_array(a[start:end])
  }
}

///| `strncmp(a, b, n)`, treating out-of-range indices as NUL. */
fn strncmp_n(a : Array[Char], b : Array[Char], n : Int) -> Int {
  let mut i = 0
  while i < n {
    let ca = if i < a.length() { a[i] } else { '\u{0}' }
    let cb = if i < b.length() { b[i] } else { '\u{0}' }
    if ca != cb {
      return ca.to_int() - cb.to_int()
    }
    if ca == '\u{0}' {
      break
    }
    i = i + 1
  }
  0
}

// ---------------------------------------------------------------------------
// Prefix and substring search
// ---------------------------------------------------------------------------

///|
/// `av_strstart`: `Some(pfx.length())` when `pfx` is a prefix of `str`
/// (the C `*ptr` out-parameter), `None` otherwise.
pub fn av_strstart(str : String, pfx : String) -> Int? {
  let s = str.to_array()
  let p = pfx.to_array()
  let mut i = 0
  while i < p.length() && i < s.length() && p[i] == s[i] {
    i = i + 1
  }
  if i == p.length() {
    Some(i)
  } else {
    None
  }
}

///| `av_stristart`: case-insensitive `av_strstart`. */
pub fn av_stristart(str : String, pfx : String) -> Int? {
  let s = str.to_array()
  let p = pfx.to_array()
  let mut i = 0
  while i < p.length() && i < s.length() && ch_tolower(p[i]) == ch_tolower(s[i]) {
    i = i + 1
  }
  if i == p.length() {
    Some(i)
  } else {
    None
  }
}

///| `av_stristr`: index of the first case-insensitive occurrence of `s2` in `s1`. */
pub fn av_stristr(s1 : String, s2 : String) -> Int? {
  stristr_from(s1.to_array(), s2.to_array(), 0)
}

///| `av_stristr` starting at `start` (used by `av_strireplace`). */
fn stristr_from(a : Array[Char], n : Array[Char], start : Int) -> Int? {
  if n.length() == 0 {
    return Some(start)
  }
  let mut i = start
  while i <= a.length() {
    if i + n.length() <= a.length() {
      let mut k = 0
      let mut hit = true
      while k < n.length() {
        if ch_tolower(a[i + k]) != ch_tolower(n[k]) {
          hit = false
        }
        k = k + 1
      }
      if hit {
        return Some(i)
      }
    }
    i = i + 1
  }
  None
}

///|
/// `av_strnstr`: index of the first occurrence of `needle` in `haystack`,
/// searching only the first `hay_length` characters.
pub fn av_strnstr(haystack : String, needle : String, hay_length : Int) -> Int? {
  let h = haystack.to_array()
  let n = needle.to_array()
  let nl = n.length()
  if nl == 0 {
    return Some(0)
  }
  let mut hl = hay_length
  let mut i = 0
  while hl >= nl {
    hl = hl - 1
    if i + nl <= h.length() {
      let mut k = 0
      let mut hit = true
      while k < nl {
        if h[i + k] != n[k] {
          hit = false
        }
        k = k + 1
      }
      if hit {
        return Some(i)
      }
    }
    i = i + 1
  }
  None
}

// ---------------------------------------------------------------------------
// Bounded copying
// ---------------------------------------------------------------------------

///|
/// `av_strlcpy`: copy `src` into `dst` with a `size` byte budget, always
/// NUL-terminating when `len <= size`, and return the length `src` would need.
pub fn av_strlcpy(dst : FixedArray[Byte], src : String, size : Int) -> Int {
  strlcpy_at(dst, 0, src, size)
}

///| `av_strlcpy` writing to `dst` starting at byte `off` (used by `av_strlcat`). */
fn strlcpy_at(dst : FixedArray[Byte], off : Int, src : String, size : Int) -> Int {
  let sb = src.to_array()
  let mut len = 0
  let mut si = 0
  let mut di = 0
  let mut cont = true
  while cont {
    // `while (++len < size && *src)`
    len = len + 1
    if len < size && si < sb.length() {
      if off + di < dst.length() {
        dst[off + di] = sb[si].to_uint().to_byte()
      }
      di = di + 1
      si = si + 1
    } else {
      cont = false
    }
  }
  if len <= size && off + di < dst.length() {
    dst[off + di] = b'\x00'
  }
  len + (sb.length() - si) - 1
}

///| `av_strlcat`: append `src` to the NUL-terminated `dst`, returning the needed length. */
pub fn av_strlcat(dst : FixedArray[Byte], src : String, size : Int) -> Int {
  let mut len = 0
  while len < dst.length() && dst[len] != b'\x00' {
    len = len + 1
  }
  if size <= len + 1 {
    return len + src.length()
  }
  len + strlcpy_at(dst, len, src, size - len)
}

// ---------------------------------------------------------------------------
// Comparisons
// ---------------------------------------------------------------------------

///| `av_strcasecmp`: case-insensitive comparison, 0 when equal. */
pub fn av_strcasecmp(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let mut c1 : UInt = 0
  let mut c2 : UInt = 0
  let mut i = 0
  let mut cont = true
  while cont {
    c1 = if i < ca.length() { ch_tolower(ca[i]).to_uint() } else { 0 }
    c2 = if i < cb.length() { ch_tolower(cb[i]).to_uint() } else { 0 }
    i = i + 1
    if !(c1 != 0 && c1 == c2) {
      cont = false
    }
  }
  c1.reinterpret_as_int() - c2.reinterpret_as_int()
}

///| `av_strncasecmp`: case-insensitive comparison of at most `n` characters. */
pub fn av_strncasecmp(a : String, b : String, n : Int) -> Int {
  if n <= 0 {
    return 0
  }
  let ca = a.to_array()
  let cb = b.to_array()
  let mut c1 : UInt = 0
  let mut c2 : UInt = 0
  let mut i = 0
  let mut rem = n
  let mut cont = true
  while cont {
    c1 = if i < ca.length() { ch_tolower(ca[i]).to_uint() } else { 0 }
    c2 = if i < cb.length() { ch_tolower(cb[i]).to_uint() } else { 0 }
    i = i + 1
    rem = rem - 1
    if !(rem != 0 && c1 != 0 && c1 == c2) {
      cont = false
    }
  }
  c1.reinterpret_as_int() - c2.reinterpret_as_int()
}

// ---------------------------------------------------------------------------
// Token extraction
// ---------------------------------------------------------------------------

///|
/// `av_get_token`: extract the next token from `buf` starting at `pos`, stopping
/// at any character of `term`. Returns the token and the new cursor position.
///
/// `\` escapes the next character and a `'...'` run is taken verbatim; trailing
/// whitespace is then trimmed back to the last escaped or quoted character, as
/// in the C implementation.
pub fn av_get_token(buf : String, pos : Int, term : String) -> (String, Int) {
  let b = buf.to_array()
  let t = term.to_array()
  let out : Array[Char] = []
  let mut end_i = 0
  let mut i = pos
  while i < b.length() && is_ws(b[i]) {
    i = i + 1
  }
  while i < b.length() && !char_in(b[i], t) {
    let c = b[i]
    i = i + 1
    if c == '\\' && i < b.length() {
      out.push(b[i])
      i = i + 1
      end_i = out.length()
    } else if c == '\'' {
      while i < b.length() && b[i] != '\'' {
        out.push(b[i])
        i = i + 1
      }
      if i < b.length() {
        i = i + 1
        end_i = out.length()
      }
    } else {
      out.push(c)
    }
  }
  // Trim trailing whitespace, never cutting into the escaped/quoted prefix.
  let mut term_i = out.length()
  let mut p = out.length() - 1
  let mut trimming = true
  while trimming {
    if p >= 0 && p >= end_i && is_ws(out[p]) {
      term_i = p
      p = p - 1
    } else {
      trimming = false
    }
  }
  (str_of(out, 0, term_i), i)
}

///|
/// `av_strireplace`: case-insensitive replacement of every `from` with `to`.
/// An empty `from` returns `str` unchanged: the C loop never advances in that
/// case, which the port turns into an explicit guard instead of a hang.
pub fn av_strireplace(str : String, from : String, to : String) -> String {
  if from.length() == 0 {
    return str
  }
  let sa = str.to_array()
  let fa = from.to_array()
  let out : Array[Char] = []
  let mut pstr = 0
  let mut found = stristr_from(sa, fa, pstr)
  while found is Some(k) {
    for i = pstr; i < k; i = i + 1 {
      out.push(sa[i])
    }
    for i = 0; i < to.length(); i = i + 1 {
      out.push(to.to_array()[i])
    }
    pstr = k + fa.length()
    found = stristr_from(sa, fa, pstr)
  }
  for i = pstr; i < sa.length(); i = i + 1 {
    out.push(sa[i])
  }
  String::from_array(out[:])
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

///| `av_basename`: the part of `path` after the last `/`, or `path` itself. */
pub fn av_basename(path : String) -> String {
  if path.length() == 0 {
    return "."
  }
  let a = path.to_array()
  let mut p = -1
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] == '/' {
      p = i
    }
  }
  if p < 0 {
    path
  } else {
    str_of(a, p + 1, a.length())
  }
}

///| `av_dirname`: the part of `path` before the last `/`, or `.` when there is none. */
pub fn av_dirname(path : String) -> String {
  if path.length() == 0 {
    return "."
  }
  let a = path.to_array()
  let mut p = -1
  for i = 0; i < a.length(); i = i + 1 {
    if a[i] == '/' {
      p = i
    }
  }
  if p < 0 {
    "."
  } else {
    str_of(a, 0, p)
  }
}

///|
/// `av_append_path_component`: join `path` and `component` with exactly one
/// separator, collapsing a doubled slash. `None` stands for the C `NULL`.
pub fn av_append_path_component(path : String?, component : String?) -> String? {
  match (path, component) {
    (None, None) => None
    (Some(p), None) => Some(p)
    (None, Some(c)) => Some(c)
    (Some(p), Some(c)) => {
      if p.length() == 0 {
        return Some(c)
      }
      if c.length() == 0 {
        return Some(p)
      }
      let pa = p.to_array()
      let ca = c.to_array()
      let ends_slash = pa[pa.length() - 1] == '/'
      let starts_slash = ca[0] == '/'
      if ends_slash && starts_slash {
        Some(str_of(pa, 0, pa.length() - 1) + c)
      } else if !ends_slash && !starts_slash {
        Some(p + "/" + c)
      } else {
        Some(p + c)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Name matching
// ---------------------------------------------------------------------------

///|
/// `av_match_name`: true when `name` matches the comma-separated `names` list,
/// where a `-` prefix negates an entry and `ALL` matches everything.
pub fn av_match_name(name : String, names : String) -> Bool {
  if name.length() == 0 || names.length() == 0 {
    return false
  }
  let na = name.to_array()
  let ra = names.to_array()
  let namelen = na.length()
  let mut i = 0
  while i < ra.length() {
    let negate = ra[i] == '-'
    let p = find_from(ra, i, ',')
    let start = i + (if negate { 1 } else { 0 })
    let entry = str_of(ra, start, p)
    let len = if p - start > namelen { p - start } else { namelen }
    let hit = av_strncasecmp(name, entry, len) == 0 ||
      strncmp_n("ALL".to_array(), entry.to_array(), if 3 > p - start { 3 } else { p - start }) == 0
    if hit {
      return !negate
    }
    i = if p < ra.length() { p + 1 } else { p }
  }
  false
}

///|
/// `av_match_list`: true when `name` shares at least one token with `list`,
/// where tokens are separated by `separator`.
pub fn av_match_list(name : String, list : String, separator : Char) -> Bool {
  let pa = name.to_array()
  let qa = list.to_array()
  let mut pi = 0
  while pi < pa.length() {
    let mut qstart = 0
    while qstart < qa.length() {
      // Inner comparison: equal characters, or one of them being NUL while the
      // other is the separator (C's `p[k]*q[k] == 0 && p[k]+q[k] == separator`).
      let mut k = 0
      let mut matched = false
      let mut running = true
      while running {
        let pc = if pi + k < pa.length() { pa[pi + k] } else { '\u{0}' }
        let qc = if qstart + k < qa.length() { qa[qstart + k] } else { '\u{0}' }
        let nuls = pc == '\u{0}' || qc == '\u{0}'
        let cont = pc == qc || (nuls && (if pc == '\u{0}' { qc } else { pc }) == separator)
        if cont {
          if k > 0 && (pc == '\u{0}' || pc == separator) {
            matched = true
            running = false
          } else {
            k = k + 1
          }
        } else {
          running = false
        }
      }
      if matched {
        return true
      }
      let nq = find_from(qa, qstart, separator)
      qstart = if nq < qa.length() { nq + 1 } else { qa.length() }
    }
    let np = find_from(pa, pi, separator)
    pi = if np < pa.length() { np + 1 } else { pa.length() }
  }
  false
}

// ---------------------------------------------------------------------------
// Escaping
// ---------------------------------------------------------------------------

///| `AV_ESCAPE_MODE_*` from libavutil/avstring.h. */
pub let av_escape_mode_auto : Int = 0

pub let av_escape_mode_backslash : Int = 1

pub let av_escape_mode_quote : Int = 2

pub let av_escape_mode_xml : Int = 3

///| `AV_ESCAPE_FLAG_WHITESPACE`. */
pub let av_escape_flag_whitespace : Int = 1

///| `AV_ESCAPE_FLAG_STRICT`. */
pub let av_escape_flag_strict : Int = 2

///| `AV_ESCAPE_FLAG_XML_SINGLE_QUOTES`. */
pub let av_escape_flag_xml_single_quotes : Int = 4

///| `AV_ESCAPE_FLAG_XML_DOUBLE_QUOTES`. */
pub let av_escape_flag_xml_double_quotes : Int = 8

///| `AV_UTF8_FLAG_ACCEPT_INVALID_BIG_CODES`. */
pub let av_utf8_flag_accept_invalid_big_codes : Int = 1

///| `AV_UTF8_FLAG_ACCEPT_NON_CHARACTERS`. */
pub let av_utf8_flag_accept_non_characters : Int = 2

///| `AV_UTF8_FLAG_ACCEPT_SURROGATES`. */
pub let av_utf8_flag_accept_surrogates : Int = 4

///| `AV_UTF8_FLAG_EXCLUDE_XML_INVALID_CONTROL_CODES`. */
pub let av_utf8_flag_exclude_xml_invalid_control_codes : Int = 8

///|
/// `av_escape`: escape `src` for command-line/option round-tripping.
/// Corresponds to `av_escape` (avstring.c) plus the `av_bprint_escape` body it
/// calls (bprint.c).
pub fn av_escape(src : String, special_chars : String?, mode : Int, flags : Int) -> String {
  let mode = if mode == av_escape_mode_auto {
    av_escape_mode_backslash
  } else {
    mode
  }
  let a = src.to_array()
  let out : Array[Char] = []
  if mode == av_escape_mode_quote {
    out.push('\'')
    for i = 0; i < a.length(); i = i + 1 {
      if a[i] == '\'' {
        out.push('\'')
        out.push('\\')
        out.push('\'')
        out.push('\'')
      } else {
        out.push(a[i])
      }
    }
    out.push('\'')
  } else if mode == av_escape_mode_xml {
    for i = 0; i < a.length(); i = i + 1 {
      let c = a[i]
      if c == '&' {
        push_str(out, "&amp;")
      } else if c == '<' {
        push_str(out, "&lt;")
      } else if c == '>' {
        push_str(out, "&gt;")
      } else if c == '\'' && (flags & av_escape_flag_xml_single_quotes) != 0 {
        push_str(out, "&apos;")
      } else if c == '"' && (flags & av_escape_flag_xml_double_quotes) != 0 {
        push_str(out, "&quot;")
      } else {
        out.push(c)
      }
    }
  } else {
    // AV_ESCAPE_MODE_BACKSLASH (and unknown modes).
    let sc = match special_chars {
      None => []
      Some(s) => s.to_array()
    }
    let quotes : Array[Char] = ['\'', '\\']
    for i = 0; i < a.length(); i = i + 1 {
      let c = a[i]
      let is_first_last = i == 0 || i + 1 == a.length()
      let is_ws = is_ws(c)
      let is_strictly_special = char_in(c, sc)
      let is_special = is_strictly_special ||
        char_in(c, quotes) ||
        (is_ws && (flags & av_escape_flag_whitespace) != 0)
      if is_strictly_special ||
        ((flags & av_escape_flag_strict) == 0 &&
          (is_special || (is_ws && is_first_last))) {
        out.push('\\')
      }
      out.push(c)
    }
  }
  String::from_array(out[:])
}

///| Append an ASCII literal to a character buffer. */
fn push_str(out : Array[Char], s : String) -> Unit {
  let a = s.to_array()
  for i = 0; i < a.length(); i = i + 1 {
    out.push(a[i])
  }
}

// ---------------------------------------------------------------------------
// UTF-8 decoding
// ---------------------------------------------------------------------------

///|
/// `av_utf8_decode`: decode one UTF-8 sequence starting at `pos`, bounded by
/// `end`. Returns `(decoded code point, new cursor)` on success and
/// `(Err("EILSEQ"), new cursor)` on a malformed sequence.
///
/// C reports "no input left" by returning 0 without setting the code point;
/// that case is surfaced here as `Err("EOF")` with the cursor unchanged.
pub fn av_utf8_decode(
  buf : Bytes,
  pos : Int,
  end : Int,
  flags : Int
) -> (Result[UInt, String], Int) {
  if pos >= end {
    return (Err("EOF"), pos)
  }
  let overlong_mins : Array[UInt] = [
    0x00000000, 0x00000080, 0x00000800, 0x00010000, 0x00200000, 0x04000000,
  ]
  let mut p = pos
  let mut code : UInt = buf[p].to_uint()
  p = p + 1

  // A continuation byte (10xxxxxx) or 0xFE/0xFF cannot start a sequence.
  if (code & 0xC0) == 0x80 || code >= 0xFE {
    return (Err("EILSEQ"), p)
  }
  let mut top = (code & 128) >> 1

  let mut tail_len = 0
  while (code & top) != 0 {
    tail_len = tail_len + 1
    if p >= end {
      return (Err("EILSEQ"), pos + 1)
    }
    let tmp = buf[p].to_uint() - 128
    if tmp >= 64 {
      return (Err("EILSEQ"), pos + 1)
    }
    p = p + 1
    code = (code << 6) + tmp
    top = top << 5
  }
  code = code & ((top << 1) - 1)

  // Overlong encodings, out-of-range values and the optional rejections.
  let bad = code < overlong_mins[tail_len] ||
    code >= (1 : UInt) << 31 ||
    (code > 0x10FFFF && (flags & av_utf8_flag_accept_invalid_big_codes) == 0) ||
    (code < 0x20 &&
      code != 0x9 &&
      code != 0xA &&
      code != 0xD &&
      (flags & av_utf8_flag_exclude_xml_invalid_control_codes) != 0) ||
    (code >= 0xD800 && code <= 0xDFFF && (flags & av_utf8_flag_accept_surrogates) == 0) ||
    ((code == 0xFFFE || code == 0xFFFF) && (flags & av_utf8_flag_accept_non_characters) == 0)
  if bad {
    return (Err("EILSEQ"), p)
  }
  (Ok(code), p)
}
