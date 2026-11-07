///|
/// Local-file adapter for the adaptive-streaming `MediaFetch` boundary.
///
/// `StreamingMedia` is deliberately IO-agnostic: the caller supplies a
/// `MediaFetch` callback for segment bytes. This module provides a reusable
/// adapter for the common case where every resource lives in one directory
/// (a downloaded HLS/DASH bundle), plus the pure URI-to-filename mapping it
/// needs. No filesystem or network code lives here - the CLI passes a reader
/// function, so the mapping stays testable on every target including Wasm.

///|
/// Reduce a resource URI to a single filename suitable for a local lookup.
///
/// Playlist URIs may be absolute URLs (`https://cdn/x/seg.ts?token=a/b`),
/// scheme-relative (`//host/x/seg.ts`), absolute paths (`/x/seg.ts`) or
/// plain relative names. Query and fragment are stripped first (an HLS
/// byterange playlist legitimately puts slashes inside a query value), then
/// the last path component is taken. A trailing slash, an empty component,
/// `.` or `..` are rejected rather than passed to the filesystem, so a
/// malicious playlist cannot escape the bundle directory.
pub fn media_fetch_path_key(uri : String) -> Result[String, String] {
  if uri == "" {
    return Err("fetch: empty resource URI")
  }
  let mut end = uri.length()
  for i = 0; i < uri.length(); i = i + 1 {
    let c = uri[i].to_int()
    if c == '?'.to_int() || c == '#'.to_int() {
      end = i
      break
    }
  }
  // Check the whole path, not just the final component: an encoded
  // separator in a directory component is just as dangerous once a reader
  // decodes it (e.g. `%2F..%2F` resolving outside the bundle).
  let path = uri[:end].to_owned()
  if path.contains("%2F") ||
    path.contains("%2f") ||
    path.contains("%5C") ||
    path.contains("%5c") {
    return Err("fetch: encoded path separator in resource URI")
  }
  let mut start = 0
  for i = 0; i < end; i = i + 1 {
    if uri[i].to_int() == '/'.to_int() {
      start = i + 1
    }
  }
  if start >= end {
    return Err("fetch: resource URI has no filename")
  }
  let name = uri[start:end].to_owned()
  if name == "." || name == ".." || name.contains("/") || name.contains("\\") {
    return Err("fetch: unsafe resource name")
  }
  Ok(name)
}

///|
/// Build a `MediaFetch` from a filename-based reader. `read` receives the
/// resource key from `media_fetch_path_key` and returns the whole file; this
/// adapter applies `(offset, length)` itself, matching the C readers'
/// contract: `length = -1` means "to EOF", otherwise exactly that many bytes
/// must be available. Errors are returned unchanged so callers can retry.
///
/// Keeping the boundary as a reader function (rather than importing a
/// filesystem package) means the same adapter works for disks, in-memory
/// maps, test fixtures and HTTP clients.
pub fn media_fetch_from_reader(
  read : (String) -> Result[Bytes, String],
) -> MediaFetch {
  (uri, offset, length) => {
    let key = match media_fetch_path_key(uri) {
      Ok(k) => k
      Err(e) => return Err(e)
    }
    if offset < 0L || length < -1L {
      return Err("fetch: invalid byte range")
    }
    let whole = match read(key) {
      Ok(v) => v
      Err(e) => return Err(e)
    }
    let size = whole.length().to_int64()
    if offset > size {
      return Err("fetch: range starts past end of resource")
    }
    let start = offset.to_int()
    let available = whole.length() - start
    if length == -1L {
      Ok(whole[start:].to_owned())
    } else if length > available.to_int64() {
      Err("fetch: response length does not match byte range")
    } else {
      Ok(whole[start:start + length.to_int()].to_owned())
    }
  }
}

///|
/// Convenience adapter for a fixed map of resource name to bytes. Useful for
/// tests and for callers that already hold the whole bundle in memory.
pub fn media_fetch_from_map(resources : Map[String, Bytes]) -> MediaFetch {
  media_fetch_from_reader(key => {
    match resources.get(key) {
      Some(v) => Ok(v)
      None => Err("fetch: unknown resource \{key}")
    }
  })
}
