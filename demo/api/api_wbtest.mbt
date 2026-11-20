// 白盒：U+0100 编码全 256 字节值双向无损 + json_escape 的 RFC 8259 覆盖。

///|
test "u0100: 全 256 字节值双向无损" {
  let all : Array[Byte] = []
  for i in 0..<256 {
    all.push(i.to_byte())
  }
  let b = Bytes::from_array(all)
  let s = bytes_to_u0100(b)
  inspect(s.length(), content="256")
  // 每个码元都落在 U+0100..U+01FF，JSON 字符串字面量合法区间
  for i in 0..<s.length() {
    let n = s[i].to_int()
    assert_true(n >= 0x100 && n <= 0x1FF)
  }
  let back = u0100_to_bytes(s)
  inspect(back.length(), content="256")
  for i in 0..<256 {
    assert_eq(back[i], b[i])
  }
}

///|
test "u0100: 空串往返" {
  inspect(bytes_to_u0100(b""), content="")
  inspect(u0100_to_bytes("").length(), content="0")
}

///|
test "json_escape: 引号、反斜杠与控制符" {
  // " \ \n \r \t 与 0x00
  let s = "a\"b\\c\nd\re\tf\u{0}g"
  inspect(json_escape(s), content="a\\\"b\\\\c\\nd\\re\\tf\\u0000g")
  // DEL(0x7F) 不需要转义，原样保留
  inspect(json_escape("\u{7F}"), content="\u{7F}")
}
