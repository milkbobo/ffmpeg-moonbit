///|
/// Matroska/WebM slice 4: Clusters and Blocks — `matroska_cluster_parsing[]`,
/// `matroska_cluster_enter[]`, `matroska_blockgroup[]`,
/// `matroska_parse_laces`, `matroska_parse_block` and the packet queue of
/// `matroska_parse_frame`/`matroska_parse_cluster` from FFmpeg 9.0.2
/// `libavformat/matroskadec.c`.
///
/// Out of scope (later work, per README): BlockAdditions side data
/// (recognised, parsed into the block record, not attached to packets),
/// header-removal compression application, RM audio / WebVTT / wavpack /
/// ProRes specialisations, `ms_compat` DTS mode, and the seek integration
/// (`skip_to_keyframe`) — packets are materialised eagerly instead of
/// demuxed lazily, matching this port's MP4 design.

// ---------------------------------------------------------------------------
// element ids (matroska.h)
// ---------------------------------------------------------------------------

pub let matroska_id_clustertimecode : UInt = 0xE7

///|
pub let matroska_id_blockgroup : UInt = 0xA0

///|
pub let matroska_id_block : UInt = 0xA1

///|
pub let matroska_id_blockduration : UInt = 0x9B

///|
pub let matroska_id_referenceblock : UInt = 0xFB

///|
pub let matroska_id_discardpadding : UInt = 0x75A2

///|
pub let matroska_id_simpleblock : UInt = 0xA3

///|
pub let matroska_id_clusterposition : UInt = 0xA7

///|
pub let matroska_id_clusterprevsize : UInt = 0xAB

///|
pub let matroska_id_blockaddid : UInt = 0xEE

///|
pub let matroska_id_blockadditional : UInt = 0xA5

///|
pub let matroska_id_blockmore : UInt = 0xA6

///|
pub let matroska_id_blockadditions : UInt = 0x75A1

// ---------------------------------------------------------------------------
// data model
// ---------------------------------------------------------------------------

///|
/// One demuxed packet (the fields of AVPacket this slice produces). */
pub struct MkvPacket {
  /// Index into `MatroskaHeader.tracks` (AVPacket.stream_index).
  stream_index : Int
  /// Payload bytes (already lace-split).
  data : Bytes
  /// Presentation timestamp in track time_scale units (the C's timecode;
  /// AV_NOPTS_VALUE when unsynced).
  pts : Int64
  /// Packet duration (lace duration for laced blocks).
  duration : UInt64
  /// Absolute payload position.
  pos : Int64
  is_keyframe : Bool
  /// DiscardPadding in nanoseconds (BlockGroup only).
  discard_padding : Int64
}

// ---------------------------------------------------------------------------
// lacing (matroska_parse_laces)
// ---------------------------------------------------------------------------

///|
/// Copy `data[from..to)`. `BytesView::data()` hands back the *underlying*
/// buffer, not the view's window, so materialise with `to_owned()`. */
fn bytes_sub(data : Bytes, from : Int, to : Int) -> Bytes {
  data.clamped_view(start=from, end=to).to_owned()
}

///|
/// `matroska_parse_laces`: split a block payload into frames. `type` is the
/// block flags' lacing bits ((flags & 0x06) >> 1): 0 none, 1 Xiph, 2
/// fixed-size, 3 EBML. `data` starts at the lace-count byte (the C's
/// `*buf` right after the track number, time offset and flags).
/// Returns the per-frame sizes and the header byte count consumed.
pub fn matroska_parse_laces(
  data : Bytes,
  lace_type : Int,
) -> Result[(Array[UInt], Int), String] {
  if lace_type == 0 {
    return Ok(([data.length().reinterpret_as_uint()], 0))
  }
  if data.length() <= 0 {
    return Err("EINVAL")
  }
  let laces = data[0].to_int() + 1
  let body = bytes_sub(data, 1, data.length())
  let sizes : Array[UInt] = []
  match lace_type {
    1 => {
      // Xiph: (laces-1) lengths as 0xFF-terminated byte chains
      let mut total : UInt = 0
      let mut off = 0
      for n = 0; n < laces - 1; n = n + 1 {
        let mut sz : UInt = 0
        let mut temp = 0
        let mut looping = true
        while looping {
          if off >= body.length() {
            return Err("EINVAL")
          }
          temp = body[off].to_int()
          total = total + temp.reinterpret_as_uint()
          sz = sz + temp.reinterpret_as_uint()
          off = off + 1
          looping = temp == 0xFF
        }
        sizes.push(sz)
      }
      if body.length() - off < total.reinterpret_as_int() {
        return Err("EINVAL")
      }
      sizes.push(
        (body.length() - off - total.reinterpret_as_int()).reinterpret_as_uint(),
      )
      Ok((sizes, 1 + off))
    }
    2 => {
      // fixed-size
      if body.length() % laces != 0 {
        return Err("EINVAL")
      }
      let sz = (body.length() / laces).reinterpret_as_uint()
      for n = 0; n < laces; n = n + 1 {
        sizes.push(sz)
      }
      Ok((sizes, 1))
    }
    3 => {
      // EBML lacing: the first frame size is an *unsigned* vint, the next
      // (laces-2) are signed deltas rebased by `matroska_ebmlnum_sint`, and
      // the last frame takes whatever is left.
      let pb = AvioContext::init_read_context(body)
      let (num, n0) = match ebml_read_num(pb, 8, true) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      let mut total : Int64 = num.reinterpret_as_int64()
      let mut off = n0
      if num > 2147483647UL {
        return Err("EINVAL")
      }
      // sizes are non-negative and < 2^31 in any valid block
      sizes.push(num.to_int().reinterpret_as_uint())
      for k = 1; k < laces - 1; k = k + 1 {
        let (snum, r) = match matroska_ebmlnum_sint(pb) {
          Err(e) => return Err(e)
          Ok(v) => v
        }
        let next = sizes[k - 1].reinterpret_as_int().to_int64() + snum
        // a delta may not make the size negative or overflow int
        if next < 0L || next > 2147483647L {
          return Err("EINVAL")
        }
        sizes.push(next.to_int().reinterpret_as_uint())
        total = total + next
        off = off + r
      }
      let remaining = body.length() - off
      if remaining.to_int64() < total {
        return Err("EINVAL")
      }
      sizes.push((remaining - total.to_int()).reinterpret_as_uint())
      Ok((sizes, 1 + off))
    }
    _ => Err("EINVAL")
  }
}

// ---------------------------------------------------------------------------
// cluster tables
// ---------------------------------------------------------------------------

///|
/// `sink_i64`: Sint sink helper. */
fn sink_i64(
  dst : (Int64) -> Unit,
) -> (EbmlValue, Int64) -> Result[Unit, String] {
  (v, _) => {
    match v {
      I(i) => {
        dst(i)
        Ok(())
      }
      _ => Err("EINVAL")
    }
  }
}

///|
/// Additional blockmores. */
fn matroska_blockmore_table() -> Array[EbmlSyntax] {
  let more : (UInt64, Bytes?) = (0UL, None)
  [
    {
      id: matroska_id_blockaddid,
      kind: Uint(1),
      sink: Some(
        sink_u64(u => {
          let _ = u
        }),
      ),
    },
    {
      id: matroska_id_blockadditional,
      kind: Bin,
      sink: Some((v, _) => {
        match v {
          B(b) => {
            let _ = more
            ignore(b)
            Ok(())
          }
          _ => Err("EINVAL")
        }
      }),
    },
  ]
}

///|
/// The BlockAdditions sub-table (records discarded for now). */
fn matroska_blockadditions_table() -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_blockmore,
      kind: Nest(() => matroska_blockmore_table()),
      sink: None,
    },
  ]
}

// ---------------------------------------------------------------------------
// block → packets (matroska_parse_block)
// ---------------------------------------------------------------------------

///|
/// `track->codec_delay_in_track_tb` — `av_rescale_q(codec_delay,
/// {1,1000000000}, st->time_base)` where `st->time_base` is
/// `{matroska->time_scale * track->time_scale, 1000000000}`. av_rescale_q
/// rounds to nearest (AV_ROUND_NEAR_INF), so 6.5 ms at a 1 ms timebase
/// becomes 7 ticks, not 6.
fn codec_delay_in_track_tb(
  codec_delay : UInt64,
  time_scale : UInt64,
  track_time_scale : Double,
) -> Int64 {
  let denom = time_scale.to_double() * track_time_scale
  if denom == 0.0 {
    return 0L
  }
  let ticks = codec_delay.reinterpret_as_int64().to_double() / denom
  if ticks >= 0.0 {
    (ticks + 0.5).to_int().to_int64()
  } else {
    (ticks - 0.5).to_int().to_int64()
  }
}

///|
/// `matroska_parse_block`: decode a Block/SimpleBlock payload into packets.
/// Payload layout: VINT track number, BE16 signed time offset, flags byte
/// (bit7 keyframe, bits1-2 lacing), then the laced frames. Packets are
/// appended to `packets` (the C queues them on the demuxer).
pub fn matroska_parse_block(
  tracks : Array[MkvTrack],
  data : Bytes,
  pos : Int64,
  cluster_time : UInt64,
  block_duration : UInt64,
  is_keyframe_in : Int, // -1: derive from flags
  discard_padding : Int64,
  time_scale : UInt64,
  packets : Array[MkvPacket],
) -> Result[Unit, String] {
  let pb = AvioContext::init_read_context(data)
  let (num, n) = match ebml_read_num(pb, 8, true) {
    Err(e) => return Err(e)
    Ok(v) => v
  }
  let size = data.length() - n
  if size < 3 {
    return Err("EINVAL")
  }
  // matroska_find_track_by_num
  let mut track : MkvTrack? = None
  for i = 0; i < tracks.length(); i = i + 1 {
    if tracks[i].num == num {
      track = Some(tracks[i])
      break
    }
  }
  match track {
    None => Err("EINVAL")
    Some(tr) => {
      let offset = bytes_sub(data, n, data.length())
      let block_time = offset[0].to_int() * 256 + offset[1].to_int()
      // sign_extend(AV_RB16(data), 16)
      let block_time = if block_time >= 0x8000 {
        block_time - 0x10000
      } else {
        block_time
      }
      let flags = offset[2].to_int()
      let rest = bytes_sub(offset, 3, offset.length())
      let is_keyframe = if is_keyframe_in == -1 {
        (flags & 0x80) != 0
      } else {
        is_keyframe_in != 0
      }
      // timecode = cluster_time / track.time_scale + block_time
      //           - codec_delay (all in track timebase)
      let mut timecode : Int64 = -9223372036854775807L - 1L
      let synced = cluster_time != 0xFFFFFFFFFFFFFFFFUL &&
        (
          block_time >= 0 ||
          cluster_time.reinterpret_as_int64() >= -block_time.to_int64()
        )
      if synced {
        let scaled : Int64 = if tr.time_scale != 0.0 {
          (cluster_time.reinterpret_as_int64().to_double() / tr.time_scale)
          .to_int()
          .to_int64()
        } else {
          cluster_time.reinterpret_as_int64()
        }
        timecode = scaled +
          block_time.to_int64() -
          codec_delay_in_track_tb(tr.codec_delay, time_scale, tr.time_scale)
      }
      // lacing
      let lace_type = (flags & 0x06) >> 1
      let (sizes, hdr) = match matroska_parse_laces(rest, lace_type) {
        Err(e) => return Err(e)
        Ok(v) => v
      }
      let frames = bytes_sub(rest, hdr, rest.length())
      // duration: explicit, else default_duration * laces / time_scale
      let mut block_duration = block_duration
      if block_duration == 0UL && tr.default_duration != 0UL {
        block_duration = tr.default_duration *
          sizes.length().to_uint64() /
          time_scale
      }
      let mut off = 0
      for k = 0; k < sizes.length(); k = k + 1 {
        let sz = sizes[k].reinterpret_as_int()
        let lace_duration : UInt64 = if sizes.length() > 0 {
          block_duration * (k + 1).to_uint64() / sizes.length().to_uint64() -
          block_duration * k.to_uint64() / sizes.length().to_uint64()
        } else {
          0UL
        }
        packets.push({
          stream_index: track_index(tracks, tr),
          data: bytes_sub(frames, off, off + sz),
          pts: timecode,
          duration: lace_duration,
          // FFmpeg 9.0.2 sets `pkt->pos = pos` for every lace: the Block
          // payload start, not the lace's own offset.
          pos,
          is_keyframe,
          discard_padding,
        })
        off = off + sz
        if timecode != -9223372036854775807L - 1L {
          timecode = if lace_duration != 0UL {
            timecode + lace_duration.reinterpret_as_int64()
          } else {
            -9223372036854775807L - 1L
          }
        }
      }
      Ok(())
    }
  }
}

///|
/// Index of `tr` in `tracks` (AVPacket.stream_index). */
fn track_index(tracks : Array[MkvTrack], tr : MkvTrack) -> Int {
  for i = 0; i < tracks.length(); i = i + 1 {
    if tracks[i].num == tr.num {
      return i
    }
  }
  0
}

// ---------------------------------------------------------------------------
// cluster walk (the read_segment tail: every cluster, all blocks)
// ---------------------------------------------------------------------------

///|
/// Walk every Cluster of the segment, queueing packets into `mh.packets`.
/// Entry state: the first Cluster id is in `current_id` (the segment-level
/// STOP just fired). The C walks one cluster per `read_packet` call
/// (`matroska_parse_cluster`); delivery here is eager, so loop until the
/// stream ends. Damage and a truncated tail are tolerated the way the C's
/// read loop tolerates them: packets queued so far stay valid.
fn matroska_walk_clusters(
  st : EbmlState,
  mh : MatroskaHeader,
) -> Result[Unit, String] {
  let rows = cluster_enter_table(mh)
  let mut go = true
  while go {
    let before = st.pb.avio_tell()
    match ebml_parse(st, rows, []) {
      // one Cluster walked: continue with the next element
      Ok(0) => ()
      // a stop (or a level ending at EOF)
      Ok(_) => go = false
      Err(e) =>
        // EOF in the middle of the tail: keep what was queued
        if e == "EOF" || e == "EIO" {
          go = false
        } else {
          return Err(e)
        }
    }
    if go && st.pb.avio_tell() == before {
      // defensive: no forward progress (empty/damaged element)
      go = false
    }
  }
  // stream order by payload position (blocks appear in decode order)
  mh.packets.sort_by((a, b) => a.pos.compare(b.pos))
  Ok(())
}

///|
/// `matroska_cluster_enter[]`: the Cluster nest wired to a MatroskaHeader. */
fn cluster_enter_table(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  [
    {
      id: matroska_id_cluster,
      kind: Nest(() => matroska_cluster_rows(mh)),
      sink: None,
    },
  ]
}

///|
/// A BlockGroup's children collected before its Block is decoded. The C
/// fills `MatroskaBlock` from `matroska_blockgroup[]` and only calls
/// `matroska_parse_block` once the master element is complete, so
/// BlockDuration/ReferenceBlock/DiscardPadding must not be read lazily
/// while the Block element itself is being sunk (they may follow it).
priv struct MkvBlockGroup {
  mut data : Bytes?
  mut pos : Int64
  mut duration : UInt64
  mut reference_count : Int
  mut discard_padding : Int64
}

///|
/// The live cluster rows (the `matroska_cluster_parsing[]` payload rows):
/// each Block/SimpleBlock sink parses and queues immediately against the
/// header's tracks.
fn matroska_cluster_rows(mh : MatroskaHeader) -> Array[EbmlSyntax] {
  let cluster_time : Array[UInt64] = [0UL]
  // BlockGroups in flight; the master-end sink pops the one that just
  // finished (nested BlockGroups are not a thing in Matroska).
  let pending : Array[MkvBlockGroup] = []
  let rows : Array[EbmlSyntax] = []
  rows.push({
    id: matroska_id_clustertimecode,
    kind: Uint(0),
    sink: Some(sink_u64(u => cluster_time[0] = u)),
  })
  rows.push({
    id: matroska_id_simpleblock,
    kind: Bin,
    sink: Some((v, pos) => {
      match v {
        B(b) =>
          matroska_parse_block(
            mh.tracks,
            b,
            pos,
            cluster_time[0],
            0UL,
            -1,
            0L,
            mh.time_scale,
            mh.packets,
          )
        _ => Err("EINVAL")
      }
    }),
  })
  rows.push({
    id: matroska_id_blockgroup,
    kind: Nest(() => {
      let bg : MkvBlockGroup = {
        data: None,
        pos: 0L,
        duration: 0UL,
        reference_count: 0,
        discard_padding: 0L,
      }
      pending.push(bg)
      [
        {
          id: matroska_id_block,
          kind: Bin,
          sink: Some((v, p) => {
            match v {
              B(b) => {
                bg.data = Some(b)
                bg.pos = p
                Ok(())
              }
              _ => Err("EINVAL")
            }
          }),
        },
        {
          id: matroska_id_blockduration,
          kind: Uint(0),
          sink: Some(sink_u64(u => bg.duration = u)),
        },
        {
          id: matroska_id_discardpadding,
          kind: Sint(0),
          sink: Some(sink_i64(i => bg.discard_padding = i)),
        },
        {
          id: matroska_id_referenceblock,
          kind: Sint(0),
          sink: Some((v, _) => {
            match v {
              I(_) => {
                bg.reference_count = bg.reference_count + 1
                Ok(())
              }
              _ => Err("EINVAL")
            }
          }),
        },
        // CodecState: EBML_NONE in the C
        { id: 0x63A0, kind: Skip, sink: None, },
      ]
    }),
    // The BlockGroup is complete now: decode its Block with the bookkeeping
    // the children filled in (the C's `non_simple + !reference.count` rule).
    sink: Some((v, _) => {
      match v {
        Master => {
          let bg = pending.pop().unwrap()
          match bg.data {
            None => Ok(())
            Some(b) =>
              matroska_parse_block(
                mh.tracks,
                b,
                bg.pos,
                cluster_time[0],
                bg.duration,
                if bg.reference_count == 0 {
                  1
                } else {
                  0
                },
                bg.discard_padding,
                mh.time_scale,
                mh.packets,
              )
          }
        }
        _ => Err("EINVAL")
      }
    }),
  })
  rows.push({
    id: matroska_id_blockadditions,
    kind: Nest(() => matroska_blockadditions_table()),
    sink: None,
  })
  // ClusterPosition / PrevSize: EBML_NONE in the C
  rows.push({ id: matroska_id_clusterposition, kind: Skip, sink: None, })
  rows.push({ id: matroska_id_clusterprevsize, kind: Skip, sink: None, })
  rows
}
