///|
/// One *selectable* track of a stream: what a caller needs to build a language
/// menu for audio or subtitles, without fetching a single byte of it.
///
/// The two backends address their tracks differently - an HLS `EXT-X-MEDIA`
/// rendition has its own playlist URI, a DASH AdaptationSet member is an index
/// pair inside the current Period - so both addresses are carried and the
/// unused one stays empty (`uri == ""`) or `-1`. The track actually playing
/// (`StreamingMedia`'s audio sub-session, `SubtitleTrack`'s cues) is a separate
/// type for the same reason.
pub struct Rendition {
  language : String
  name : String
  /// `FORCED=YES` for a subtitle rendition; always false for audio.
  forced : Bool
  /// `DEFAULT=YES` for HLS; always false for DASH, which has no such flag.
  is_default : Bool
  /// HLS: the rendition's own playlist URI.
  uri : String
  /// DASH: AdaptationSet and Representation inside the current Period.
  /// HLS: `-1`.
  set : Int32
  rep : Int32
}

///|
pub fn Rendition::language(self : Rendition) -> String {
  self.language
}

///|
pub fn Rendition::name(self : Rendition) -> String {
  self.name
}

///|
pub fn Rendition::forced(self : Rendition) -> Bool {
  self.forced
}

///|
pub fn Rendition::is_default(self : Rendition) -> Bool {
  self.is_default
}

///|
pub fn Rendition::uri(self : Rendition) -> String {
  self.uri
}

///|
/// An HLS choice: addressed by its rendition playlist URI.
fn rendition_hls(rendition : HlsRendition) -> Rendition {
  {
    language: rendition.language,
    name: rendition.name,
    forced: rendition.forced,
    is_default: rendition.is_default,
    uri: rendition.uri,
    set: -1,
    rep: -1,
  }
}

///|
/// A DASH choice: addressed by its position inside the current Period.
fn rendition_dash(
  set : DashAdaptationSet,
  rep : DashRepresentation,
  set_index : Int32,
  rep_index : Int32,
) -> Rendition {
  {
    language: set.lang,
    name: rep.id,
    forced: false,
    is_default: false,
    uri: "",
    set: set_index,
    rep: rep_index,
  }
}

///|
/// Whether two choices designate the same track. The HLS side is identified by
/// its playlist URI, the DASH side by its index pair - comparing the pair first
/// would make every DASH track look like every other one when indexes repeat
/// across Periods. Also used by the accessors that report which choice is live.
fn rendition_same(a : Rendition, b : Rendition) -> Bool {
  if a.uri != "" || b.uri != "" {
    a.uri == b.uri
  } else {
    a.set == b.set && a.rep == b.rep
  }
}
