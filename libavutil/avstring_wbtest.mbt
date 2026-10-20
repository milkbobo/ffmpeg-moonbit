///|
/// Whitebox tests for the `avstring` port.
///
/// `av_get_token` is checked against `tests/ref/fate/avstring` (the FATE
/// reference output of `libavutil/tests/avstring.c`), and
/// `av_append_path_component` / `av_strireplace` / `av_strnstr` against the
/// expectations written into that same C test. The remaining cases are derived
/// by hand from the algorithms in `libavutil/avstring.c` and
/// `libavutil/bprint.c`.

///|
/// Read a NUL-terminated byte buffer back into a String (ASCII). */
fn buf_str(b : FixedArray[Byte]) -> String {
  let chars : Array[Char] = []
  let mut i = 0
  while i < b.length() && b[i] != b'\x00' {
    chars.push(b[i].to_char())
    i = i + 1
  }
  String::from_array(chars[:])
}

///|
/// input / expected token / expected remainder, transcribed from
/// `tests/ref/fate/avstring` (the `|input| -> |token| + |rest|` lines).
let get_token_cases : Array[(String, String, String)] = [
  ("''", "", ""),
  ("", "", ""),
  (":", "", ":"),
  ("\\", "\\", ""),
  ("'", "", ""),
  ("    ''    :", "", ":"),
  ("    ''  ''  :", "  ", ":"),
  ("foo   '' :", "foo   ", ":"),
  ("'foo'", "foo", ""),
  ("foo     ", "foo", ""),
  ("  '  foo  '  ", "  foo  ", ""),
  ("foo\\", "foo\\", ""),
  ("foo':  blah:blah", "foo:  blah:blah", ""),
  ("foo\\:  blah:blah", "foo:  blah", ":blah"),
  ("foo'", "foo", ""),
  ("'foo :  '  :blahblah", "foo :  ", ":blahblah"),
  ("\\ :blah", " ", ":blah"),
  ("     foo", "foo", ""),
  ("      foo       ", "foo", ""),
  ("      foo     \\ ", "foo      ", ""),
  ("foo ':blah", "foo :blah", ""),
  (" foo   bar    :   blahblah", "foo   bar", ":   blahblah"),
  ("\\f\\o\\o", "foo", ""),
  ("'foo : \\ \\  '   : blahblah", "foo : \\ \\  ", ": blahblah"),
  ("'\\fo\\o:': blahblah", "\\fo\\o:", ": blahblah"),
  ("\\'fo\\o\\:':  foo  '  :blahblah", "'foo::  foo  ", ":blahblah"),
]

///|
test "avstring: av_get_token matches fate/avstring" {
  for i = 0; i < get_token_cases.length(); i = i + 1 {
    let (input, token, rest) = get_token_cases[i]
    let (got_token, pos) = av_get_token(input, 0, ":")
    assert_eq(got_token, token)
    let got_rest = if pos < input.length() {
      String::from_array(input.to_array()[pos:])
    } else {
      ""
    }
    assert_eq(got_rest, rest)
  }
}

///|
/// The 7 cases listed by `TEST_APPEND_PATH_COMPONENT` in the C test. */
test "avstring: av_append_path_component matches the C test" {
  assert_eq(av_append_path_component(None, None), None)
  assert_eq(av_append_path_component(Some("path"), None), Some("path"))
  assert_eq(av_append_path_component(None, Some("comp")), Some("comp"))
  assert_eq(
    av_append_path_component(Some("path"), Some("comp")),
    Some("path/comp"),
  )
  assert_eq(
    av_append_path_component(Some("path/"), Some("comp")),
    Some("path/comp"),
  )
  assert_eq(
    av_append_path_component(Some("path"), Some("/comp")),
    Some("path/comp"),
  )
  assert_eq(
    av_append_path_component(Some("path/"), Some("/comp")),
    Some("path/comp"),
  )
  assert_eq(
    av_append_path_component(Some("path/path2/"), Some("/comp/comp2")),
    Some("path/path2/comp/comp2"),
  )
}

///|
/// The `TEST_STRIREPLACE` expectations from the C test. */
test "avstring: av_strireplace matches the C test" {
  let haystack = "Education consists mainly in what we have unlearned."
  assert_eq(
    av_strireplace(haystack, "learned.", "instead"),
    "Education consists mainly in what we have uninstead",
  )
  assert_eq(
    av_strireplace(haystack, "unlearned.", "instead"),
    "Education consists mainly in what we have instead",
  )
  // Case-insensitive matching, so the capitalised needle still hits.
  assert_eq(
    av_strireplace(haystack, "Unlearned", "instead"),
    "Education consists mainly in what we have instead.",
  )
}

///|
/// `av_strnstr` offsets reported by the C test (pointer minus haystack). */
test "avstring: av_strnstr matches the C test offsets" {
  let haystack = "Education consists mainly in what we have unlearned."
  assert_eq(av_strnstr(haystack, "learned.", haystack.length()), Some(44))
  assert_eq(av_strnstr(haystack, "unlearned.", haystack.length()), Some(42))
  // Matching is case-sensitive, and "Unlearned" does not occur.
  assert_eq(av_strnstr(haystack, "Unlearned", haystack.length()), None)
  // An empty needle matches at offset 0.
  assert_eq(av_strnstr(haystack, "", haystack.length()), Some(0))
}

///|
test "avstring: prefix helpers" {
  assert_eq(av_strstart("foobar", "foo"), Some(3))
  assert_eq(av_strstart("foobar", "FOO"), None)
  assert_eq(av_strstart("foo", "foobar"), None)
  assert_eq(av_stristart("FooBar", "fOOb"), Some(4))
  assert_eq(av_stristart("foo", "baz"), None)
  // The remainder index is the prefix length, as with the C `*ptr` out-param.
  // "oBar" at index 2 matches "obar" case-insensitively.
  assert_eq(av_stristr("FooBar", "obar"), Some(2))
  assert_eq(av_stristr("foo", ""), Some(0))
  assert_eq(av_stristr("foo", "z"), None)
}

///|
test "avstring: bounded copy and concatenate" {
  let big : FixedArray[Byte] = FixedArray::make(16, b'\x7F')
  // A long enough buffer gets the whole string, and the return value is its length.
  assert_eq(av_strlcpy(big, "hello", 16), 5)
  assert_eq(buf_str(big), "hello")

  let small : FixedArray[Byte] = FixedArray::make(16, b'\x7F')
  // size 3 truncates to two characters but still reports the full length.
  assert_eq(av_strlcpy(small, "hello", 3), 5)
  assert_eq(buf_str(small), "he")

  let zero : FixedArray[Byte] = FixedArray::make(16, b'\x7F')
  // size 0 writes nothing at all: not even the terminator is stored.
  assert_eq(av_strlcpy(zero, "hello", 0), 5)
  assert_eq(zero[0], b'\x7F')

  let cat : FixedArray[Byte] = FixedArray::make(16, b'\x00')
  assert_eq(av_strlcpy(cat, "foo", 16), 3)
  assert_eq(av_strlcat(cat, "bar", 16), 6)
  assert_eq(buf_str(cat), "foobar")
  // Already "foobar" (6) with a budget of 5: nothing is written, and the return
  // is still the needed length, 6 + 3.
  assert_eq(av_strlcat(cat, "baz", 5), 9)
  assert_eq(buf_str(cat), "foobar")
}

///|
test "avstring: case-insensitive comparison" {
  // The C code returns the raw difference of the first differing characters,
  // not a normalised -1/0/1.
  assert_eq(av_strcasecmp("abc", "ABC"), 0)
  assert_eq(av_strcasecmp("abc", "abd"), -1)
  assert_eq(av_strcasecmp("abd", "abc"), 1)
  // "abc" vs "ab": the loop stops at 'c' against the terminator, so 99 - 0.
  assert_eq(av_strcasecmp("abc", "ab"), 99)
  assert_eq(av_strncasecmp("abc", "abd", 2), 0)
  assert_eq(av_strncasecmp("abc", "abd", 3), -1)
  assert_eq(av_strncasecmp("abc", "xyz", 0), 0)
}

///|
test "avstring: paths" {
  assert_eq(av_basename("/foo/bar/baz"), "baz")
  assert_eq(av_basename("baz"), "baz")
  assert_eq(av_basename(""), ".")
  // A trailing slash yields an empty basename, as in the C code.
  assert_eq(av_basename("a/b/"), "")
  assert_eq(av_dirname("/foo/bar/baz"), "/foo/bar")
  assert_eq(av_dirname("baz"), ".")
  assert_eq(av_dirname("/foo"), "")
}

///|
test "avstring: name and list matching" {
  assert_true(av_match_name("foo", "foo,bar"))
  assert_true(av_match_name("bar", "foo,bar"))
  assert_true(av_match_name("FOO", "foo"))
  assert_true(!av_match_name("baz", "foo,bar"))
  // A leading '-' negates the entry, so a match on "-bar" reports false.
  assert_true(!av_match_name("bar", "foo,-bar"))
  assert_true(!av_match_name("bar", "-bar,foo"))
  // The first matching entry decides, so "ALL" short-circuits anything after it.
  assert_true(av_match_name("bar", "ALL,-bar"))
  // Lowercase "all" is not the "ALL" literal, so the negation still applies.
  assert_true(!av_match_name("bar", "all,-bar"))
  // The intended "everything except bar" spelling puts the negation first.
  assert_true(!av_match_name("bar", "-bar,ALL"))
  assert_true(av_match_name("foo", "-bar,ALL"))
  // "ALL" matches any name.
  assert_true(av_match_name("anything", "ALL"))
  assert_true(!av_match_name("", "ALL"))

  assert_true(av_match_list("a,b", "b,c", ','))
  assert_true(av_match_list("a,b", "a", ','))
  assert_true(av_match_list("a", "a", ','))
  assert_true(!av_match_list("a,b", "c,d", ','))
  assert_true(!av_match_list("x", "ax,b", ','))
  assert_true(av_match_list("x:y", "y:z", ':'))
}

///|
test "avstring: av_escape modes" {
  // QUOTE wraps the value and escapes embedded single quotes.
  assert_eq(av_escape("a'b", None, av_escape_mode_quote, 0), "'a'\\''b'")
  // AUTO behaves like BACKSLASH.
  assert_eq(av_escape("plain", None, av_escape_mode_auto, 0), "plain")
  // Without the whitespace flag a space is left alone.
  assert_eq(av_escape("foo bar", None, av_escape_mode_backslash, 0), "foo bar")
  // With AV_ESCAPE_FLAG_WHITESPACE it is backslash-escaped.
  assert_eq(
    av_escape(
      "foo bar",
      None,
      av_escape_mode_backslash,
      av_escape_flag_whitespace,
    ),
    "foo\\ bar",
  )
  // Leading/trailing whitespace is escaped even without the whitespace flag.
  assert_eq(av_escape(" foo", None, av_escape_mode_backslash, 0), "\\ foo")
  // STRICT disables the whitespace heuristics but keeps explicit specials.
  assert_eq(
    av_escape("x y", Some("x"), av_escape_mode_backslash, av_escape_flag_strict),
    "\\x y",
  )
  // Without the whitespace flag, and not at either end, the space is left alone.
  assert_eq(av_escape("x y", Some("x"), av_escape_mode_backslash, 0), "\\x y")
  // STRICT also disables the leading-whitespace heuristic.
  assert_eq(
    av_escape(" foo", None, av_escape_mode_backslash, av_escape_flag_strict),
    " foo",
  )
  // XML escaping of the markup characters, with optional quote handling.
  assert_eq(
    av_escape("a<b&c>d", None, av_escape_mode_xml, 0),
    "a&lt;b&amp;c&gt;d",
  )
  assert_eq(av_escape("'\"", None, av_escape_mode_xml, 0), "'\"")
  assert_eq(
    av_escape("\"", None, av_escape_mode_xml, av_escape_flag_xml_double_quotes),
    "&quot;",
  )
  assert_eq(
    av_escape("'", None, av_escape_mode_xml, av_escape_flag_xml_single_quotes),
    "&apos;",
  )
}

///|
test "avstring: av_utf8_decode" {
  let (r1, p1) = av_utf8_decode(b"A", 0, 1, 0)
  assert_eq(r1, Ok(0x41))
  assert_eq(p1, 1)

  // U+00E9 (é) is two bytes.
  let (r2, p2) = av_utf8_decode(b"\xc3\xa9", 0, 2, 0)
  assert_eq(r2, Ok(0xE9))
  assert_eq(p2, 2)

  // U+20AC (€) is three bytes.
  let (r3, p3) = av_utf8_decode(b"\xe2\x82\xac", 0, 3, 0)
  assert_eq(r3, Ok(0x20AC))
  assert_eq(p3, 3)

  // An overlong two-byte encoding of NUL is rejected.
  let (r4, _) = av_utf8_decode(b"\xc0\x80", 0, 2, 0)
  assert_true(r4 is Err(_))

  // A lone continuation byte cannot start a sequence.
  let (r5, _) = av_utf8_decode(b"\x80", 0, 1, 0)
  assert_true(r5 is Err(_))

  // 0xFE never starts a valid sequence.
  let (r6, _) = av_utf8_decode(b"\xfe", 0, 1, 0)
  assert_true(r6 is Err(_))

  // U+D800 is a surrogate: rejected unless explicitly accepted.
  let (r7, _) = av_utf8_decode(b"\xed\xa0\x80", 0, 3, 0)
  assert_true(r7 is Err(_))
  let (r8, _) = av_utf8_decode(
    b"\xed\xa0\x80", 0, 3, av_utf8_flag_accept_surrogates,
  )
  assert_eq(r8, Ok(0xD800))

  // U+FFFE is a non-character: rejected unless explicitly accepted.
  let (r9, _) = av_utf8_decode(b"\xef\xbf\xbe", 0, 3, 0)
  assert_true(r9 is Err(_))
  let (r10, _) = av_utf8_decode(
    b"\xef\xbf\xbe", 0, 3, av_utf8_flag_accept_non_characters,
  )
  assert_eq(r10, Ok(0xFFFE))

  // An incomplete three-byte sequence is rejected.
  let (r11, _) = av_utf8_decode(b"\xe2\x82", 0, 2, 0)
  assert_true(r11 is Err(_))

  // Past the end there is nothing to decode.
  let (r12, p12) = av_utf8_decode(b"", 0, 0, 0)
  assert_eq(r12, Err("EOF"))
  assert_eq(p12, 0)
}
