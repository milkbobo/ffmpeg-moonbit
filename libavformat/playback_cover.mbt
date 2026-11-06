///|
/// Cover-art extraction for the CLI's `extract-cover` command (proposal
/// deliverable ②, fifth command): Matroska `Attachments` (the first
/// image/* file) and MP4 `ilst/covr` both land here through one API.

///|
/// One embedded cover image: raw image bytes plus the container-declared
/// MIME type (`image/jpeg`, `image/png`, ...).
pub struct MediaCover {
  mime : String
  data : Bytes
}

///|
/// The MIME type of the cover.
pub fn MediaCover::mime(self : MediaCover) -> String {
  self.mime
}

///|
/// The raw image bytes.
pub fn MediaCover::data(self : MediaCover) -> Bytes {
  self.data
}

///|
/// The file's embedded cover art, if any. Matroska yields the first
/// `AttachedFile` whose MIME starts with `image/` (FFmpeg turns exactly
/// those into attached-pic streams); MP4 yields the `ilst/covr` artwork.
/// The Ogg and WAV adapters carry no container-level artwork.
pub fn MediaFile::cover(self : MediaFile) -> MediaCover? {
  match self.source {
    Mkv(mh) => {
      let mut found : MediaCover? = None
      for a in mh.attachments {
        if found is None && a.mime.length() >= 6 && a.mime[0:6].to_owned() == "image/" {
          found = Some({ mime: a.mime, data: a.data })
        }
      }
      found
    }
    Mov(movie, _) =>
      match movie.cover {
        Some((data, mime)) => Some({ mime, data })
        None => None
      }
    _ => None
  }
}
