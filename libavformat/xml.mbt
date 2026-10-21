///|
/// Minimal XML parser for the DASH MPD and other FFmpeg XML metadata slices.
///
/// Scope: elements, attributes (single/double quoted), text, self-closing
/// tags, comments, CDATA, processing instructions and a DOCTYPE prolog. Entity
/// references `&amp; &lt; &gt; &quot; &apos;` and numeric `&#..;`/`&#x..;` are
/// decoded. Namespace prefixes are preserved verbatim; `attr_local` /
/// `children_named` match both `name` and `prefix:name`.
///
/// Out of scope: DTD validation, external entities, namespace resolution and
/// mixed-content whitespace normalisation.

///|
pub struct XmlNode {
  name : String
  attributes : Array[(String, String)]
  children : Array[XmlNode]
  text : String
}

///|
fn xml_local_name(name : String) -> String {
  match name.rev_find(":") {
    Some(i) => name[i + 1:].to_owned()
    None => name
  }
}

///|
/// Attribute lookup by local name (exact match first, then namespace-suffix). */
pub fn XmlNode::attr(self : XmlNode, name : String) -> String? {
  for pair in self.attributes {
    let (k, v) = pair
    if k == name {
      return Some(v)
    }
  }
  for pair in self.attributes {
    let (k, v) = pair
    if xml_local_name(k) == name {
      return Some(v)
    }
  }
  None
}

///|
/// Attribute lookup with a default. */
pub fn XmlNode::attr_or(
  self : XmlNode,
  name : String,
  default : String,
) -> String {
  match self.attr(name) {
    Some(v) => v
    None => default
  }
}

///|
/// Direct children whose local name matches `name`. */
pub fn XmlNode::children_named(self : XmlNode, name : String) -> Array[XmlNode] {
  let out : Array[XmlNode] = []
  for child in self.children {
    if xml_local_name(child.name) == name {
      out.push(child)
    }
  }
  out
}

///|
/// First direct child with the given local name. */
pub fn XmlNode::child(self : XmlNode, name : String) -> XmlNode? {
  for child in self.children {
    if xml_local_name(child.name) == name {
      return Some(child)
    }
  }
  None
}

///|
priv struct XmlParser {
  text : String
  mut pos : Int32
}

///|
fn xml_starts_with_at(p : XmlParser, s : String) -> Bool {
  let n = s.length()
  if p.pos + n > p.text.length() {
    return false
  }
  for i in 0..<n {
    if p.text[p.pos + i].to_int() != s[i].to_int() {
      return false
    }
  }
  true
}

///|
fn xml_skip_ws(p : XmlParser) -> Unit {
  while p.pos < p.text.length() {
    let c = p.text[p.pos].to_int()
    if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
      p.pos = p.pos + 1
    } else {
      break
    }
  }
}

///|
fn xml_decode_entities(s : String) -> String {
  if !s.contains("&") {
    return s
  }
  let sb = StringBuilder()
  let mut i = 0
  while i < s.length() {
    if s[i].to_int() == '&'.to_int() {
      let mut end = i + 1
      while end < s.length() && s[end].to_int() != ';'.to_int() {
        end = end + 1
      }
      if end < s.length() {
        let ent = s[i + 1:end]
        if ent == "amp" {
          sb.write_char('&')
        } else if ent == "lt" {
          sb.write_char('<')
        } else if ent == "gt" {
          sb.write_char('>')
        } else if ent == "quot" {
          sb.write_char('"')
        } else if ent == "apos" {
          sb.write_char('\'')
        } else if ent.has_prefix("#x") || ent.has_prefix("#X") {
          let code = @string.parse_int(ent[2:], base=16) catch { _ => 0 }
          sb.write_char(code.unsafe_to_char())
        } else if ent.has_prefix("#") {
          let code = @string.parse_int(ent[1:]) catch { _ => 0 }
          sb.write_char(code.unsafe_to_char())
        } else {
          sb.write_string(s[i:end + 1].to_owned())
        }
        i = end + 1
      } else {
        sb.write_char('&')
        i = i + 1
      }
    } else {
      sb.write_char(s[i].to_int().unsafe_to_char())
      i = i + 1
    }
  }
  sb.to_string()
}

///|
fn xml_skip_until(p : XmlParser, marker : String) -> Unit {
  while p.pos < p.text.length() && !xml_starts_with_at(p, marker) {
    p.pos = p.pos + 1
  }
  if p.pos < p.text.length() {
    p.pos = p.pos + marker.length()
  }
}

///|
fn xml_read_name(p : XmlParser) -> String {
  let start = p.pos
  while p.pos < p.text.length() {
    let c = p.text[p.pos].to_int()
    if c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == '>'.to_int() ||
      c == '/'.to_int() ||
      c == '='.to_int() {
      break
    }
    p.pos = p.pos + 1
  }
  p.text[start:p.pos].to_owned()
}

///|
fn xml_skip_prolog(p : XmlParser) -> Unit {
  while p.pos < p.text.length() {
    xml_skip_ws(p)
    if xml_starts_with_at(p, "<?") {
      xml_skip_until(p, "?>")
    } else if xml_starts_with_at(p, "<!--") {
      xml_skip_until(p, "-->")
    } else if xml_starts_with_at(p, "<!DOCTYPE") {
      xml_skip_until(p, ">")
    } else {
      break
    }
  }
}

///|
fn xml_parse_element(p : XmlParser, depth : Int32) -> Result[XmlNode, String] {
  if depth > 256 {
    return Err("EINVAL: XML nesting too deep")
  }
  if p.pos >= p.text.length() || p.text[p.pos].to_int() != '<'.to_int() {
    return Err("EINVAL: expected '<'")
  }
  p.pos = p.pos + 1
  let name = xml_read_name(p)
  if name == "" {
    return Err("EINVAL: empty element name")
  }
  let attributes : Array[(String, String)] = []
  let mut self_closing = false
  for ;; {
    xml_skip_ws(p)
    if p.pos >= p.text.length() {
      return Err("EINVAL: unterminated element")
    }
    if xml_starts_with_at(p, "/>") {
      p.pos = p.pos + 2
      self_closing = true
      break
    }
    if p.text[p.pos].to_int() == '>'.to_int() {
      p.pos = p.pos + 1
      break
    }
    let aname = xml_read_name(p)
    if aname == "" {
      return Err("EINVAL: bad attribute name")
    }
    xml_skip_ws(p)
    if p.pos >= p.text.length() || p.text[p.pos].to_int() != '='.to_int() {
      return Err("EINVAL: expected '='")
    }
    p.pos = p.pos + 1
    xml_skip_ws(p)
    if p.pos >= p.text.length() {
      return Err("EINVAL: unterminated attribute")
    }
    let quote = p.text[p.pos].to_int()
    if quote != '"'.to_int() && quote != '\''.to_int() {
      return Err("EINVAL: unquoted attribute")
    }
    p.pos = p.pos + 1
    let start = p.pos
    while p.pos < p.text.length() && p.text[p.pos].to_int() != quote {
      p.pos = p.pos + 1
    }
    if p.pos >= p.text.length() {
      return Err("EINVAL: unterminated attribute value")
    }
    let value = xml_decode_entities(p.text[start:p.pos].to_owned())
    p.pos = p.pos + 1
    attributes.push((aname, value))
  }
  let children : Array[XmlNode] = []
  let text = StringBuilder()
  if !self_closing {
    for ;; {
      if p.pos >= p.text.length() {
        return Err("EINVAL: missing closing tag for \{name}")
      }
      if xml_starts_with_at(p, "</") {
        p.pos = p.pos + 2
        let closing = xml_read_name(p)
        xml_skip_ws(p)
        if p.pos >= p.text.length() || p.text[p.pos].to_int() != '>'.to_int() {
          return Err("EINVAL: bad closing tag")
        }
        p.pos = p.pos + 1
        if closing != name {
          return Err("EINVAL: mismatched closing tag \{closing}")
        }
        break
      } else if xml_starts_with_at(p, "<!--") {
        xml_skip_until(p, "-->")
      } else if xml_starts_with_at(p, "<![CDATA[") {
        p.pos = p.pos + 9
        let start = p.pos
        xml_skip_until(p, "]]>")
        text.write_string(p.text[start:p.pos - 3].to_owned())
      } else if xml_starts_with_at(p, "<?") {
        xml_skip_until(p, "?>")
      } else if p.text[p.pos].to_int() == '<'.to_int() {
        match xml_parse_element(p, depth + 1) {
          Ok(child) => children.push(child)
          Err(e) => return Err(e)
        }
      } else {
        let start = p.pos
        while p.pos < p.text.length() && p.text[p.pos].to_int() != '<'.to_int() {
          p.pos = p.pos + 1
        }
        text.write_string(xml_decode_entities(p.text[start:p.pos].to_owned()))
      }
    }
  }
  Ok({ name, attributes, children, text: text.to_string(), })
}

///|
/// Parse an XML document, returning its root element. */
pub fn xml_parse(text : String) -> Result[XmlNode, String] {
  let p : XmlParser = { text, pos: 0, }
  xml_skip_prolog(p)
  if p.pos >= text.length() {
    return Err("EINVAL: empty XML document")
  }
  match xml_parse_element(p, 0) {
    Ok(root) => {
      xml_skip_prolog(p)
      Ok(root)
    }
    Err(e) => Err(e)
  }
}
