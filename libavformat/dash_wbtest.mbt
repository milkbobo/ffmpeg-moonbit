///|
/// Tests for the minimal XML parser and the DASH MPD layer.
///
/// The real MPD was produced by `linuxserver/ffmpeg:9.0.2`:
///
///   ffmpeg ... -f dash -seg_duration 1 -use_template 1 -use_timeline 1 out.mpd
///
/// It exercises SegmentTemplate + SegmentTimeline, `$Number%05d$`,
/// `$RepresentationID$`, video/audio AdaptationSets and inherited attributes.

///|
let dash_real_mpd : String =
  #|<?xml version="1.0" encoding="utf-8"?>
  #|<MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  #|	xmlns="urn:mpeg:dash:schema:mpd:2011"
  #|	xmlns:xlink="http://www.w3.org/1999/xlink"
  #|	xsi:schemaLocation="urn:mpeg:DASH:schema:MPD:2011 http://standards.iso.org/ittf/PubliclyAvailableStandards/MPEG-DASH_schema_files/DASH-MPD.xsd"
  #|	profiles="urn:mpeg:dash:profile:isoff-live:2011"
  #|	type="static"
  #|	mediaPresentationDuration="PT2.6S"
  #|	maxSegmentDuration="PT1.0S"
  #|	minBufferTime="PT2.0S">
  #|	<ProgramInformation>
  #|	</ProgramInformation>
  #|	<ServiceDescription id="0">
  #|	</ServiceDescription>
  #|	<Period id="0" start="PT0.0S">
  #|		<AdaptationSet id="0" contentType="video" startWithSAP="1" segmentAlignment="true" bitstreamSwitching="true" frameRate="5/1" maxWidth="64" maxHeight="48" par="4:3">
  #|			<Representation id="0" mimeType="video/mp4" codecs="avc1.42c00a" bandwidth="30264" width="64" height="48" sar="1:1">
  #|				<SegmentTemplate timescale="10240" initialization="init-stream$RepresentationID$.m4s" media="chunk-stream$RepresentationID$-$Number%05d$.m4s" startNumber="1">
  #|					<SegmentTimeline>
  #|						<S t="0" d="10240" r="1" />
  #|						<S d="6144" />
  #|					</SegmentTimeline>
  #|				</SegmentTemplate>
  #|			</Representation>
  #|		</AdaptationSet>
  #|		<AdaptationSet id="1" contentType="audio" startWithSAP="1" segmentAlignment="true" bitstreamSwitching="true">
  #|			<Representation id="1" mimeType="audio/mp4" codecs="mp4a.40.2" bandwidth="32000" audioSamplingRate="44100">
  #|				<AudioChannelConfiguration schemeIdUri="urn:mpeg:dash:23003:3:audio_channel_configuration:2011" value="1" />
  #|				<SegmentTemplate timescale="44100" initialization="init-stream$RepresentationID$.m4s" media="chunk-stream$RepresentationID$-$Number%05d$.m4s" startNumber="1">
  #|					<SegmentTimeline>
  #|						<S t="0" d="44032" />
  #|						<S d="45056" />
  #|						<S d="21162" />
  #|					</SegmentTimeline>
  #|				</SegmentTemplate>
  #|			</Representation>
  #|		</AdaptationSet>
  #|	</Period>
  #|</MPD>
  #|

///|
test "xml: elements, attributes, comments, CDATA and entities" {
  let doc =
    #|<?xml version="1.0"?>
    #|<!-- leading comment -->
    #|<root a="1" b='two' ns:c="3">
    #|  <child>text &amp; more</child>
    #|  <empty/>
    #|  <![CDATA[raw <tag> & stuff]]>
    #|  <nested><deep x="&#65;&#x42;"/></nested>
    #|</root>
    #|
  let root = xml_parse(doc).unwrap()
  assert_eq(root.name, "root")
  assert_eq(root.attr("a").unwrap(), "1")
  assert_eq(root.attr("b").unwrap(), "two")
  assert_eq(root.attr("c").unwrap(), "3")
  assert_eq(root.children.length(), 3)
  assert_eq(root.children[0].name, "child")
  assert_eq(root.children[0].text, "text & more")
  assert_eq(root.children[1].name, "empty")
  assert_eq(root.children[1].children.length(), 0)
  assert_true(root.text.contains("raw <tag> & stuff"))
  let deep = root.children[2].children[0]
  assert_eq(deep.name, "deep")
  assert_eq(deep.attr("x").unwrap(), "AB")
}

///|
test "xml: rejects mismatched and unterminated tags" {
  match xml_parse("<a><b></a></b>") {
    Ok(_) => fail("expected mismatch")
    Err(e) => assert_true(e.contains("mismatched"))
  }
  match xml_parse("<a><b></b>") {
    Ok(_) => fail("expected missing close")
    Err(e) => assert_true(e.contains("missing closing"))
  }
}

///|
test "dash: real ffmpeg MPD with SegmentTimeline" {
  let mpd = av_dash_parse(dash_real_mpd).unwrap()
  assert_eq(mpd.type_, "static")
  assert_eq(mpd.profiles, "urn:mpeg:dash:profile:isoff-live:2011")
  assert_true(mpd.media_presentation_duration == 2.6)
  assert_true(mpd.min_buffer_time == 2.0)
  assert_eq(mpd.periods.length(), 1)
  let period = mpd.periods[0]
  assert_eq(period.id, "0")
  assert_true(period.start == 0.0)
  assert_true(period.duration == 2.6)
  assert_eq(period.adaptation_sets.length(), 2)
  let video = period.adaptation_sets[0]
  assert_eq(video.content_type, "video")
  assert_eq(video.frame_rate, "5/1")
  assert_eq(video.width, 64)
  assert_eq(video.height, 48)
  assert_eq(video.representations.length(), 1)
  let v = video.representations[0]
  assert_eq(v.id, "0")
  assert_eq(v.codec, "h264")
  assert_eq(v.codecs, "avc1.42c00a")
  assert_eq(v.bandwidth, 30264L)
  assert_eq(v.width, 64)
  assert_eq(v.height, 48)
  assert_eq(v.timescale, 10240L)
  assert_eq(v.initialization, "init-stream0.m4s")
  assert_eq(v.segments.length(), 3)
  assert_eq(v.segments[0].number, 1L)
  assert_eq(v.segments[0].time, 0L)
  assert_eq(v.segments[0].duration, 10240L)
  assert_eq(v.segments[0].uri, "chunk-stream0-00001.m4s")
  assert_eq(v.segments[1].number, 2L)
  assert_eq(v.segments[1].time, 10240L)
  assert_eq(v.segments[1].uri, "chunk-stream0-00002.m4s")
  assert_eq(v.segments[2].number, 3L)
  assert_eq(v.segments[2].time, 20480L)
  assert_eq(v.segments[2].duration, 6144L)
  assert_eq(v.segments[2].uri, "chunk-stream0-00003.m4s")
  let audio = period.adaptation_sets[1]
  assert_eq(audio.content_type, "audio")
  let a = audio.representations[0]
  assert_eq(a.id, "1")
  assert_eq(a.codec, "aac")
  assert_eq(a.bandwidth, 32000L)
  assert_eq(a.audio_sampling_rate, 44100)
  assert_eq(a.timescale, 44100L)
  assert_eq(a.segments.length(), 3)
  assert_eq(a.segments[0].duration, 44032L)
  assert_eq(a.segments[1].time, 44032L)
  assert_eq(a.segments[1].duration, 45056L)
  assert_eq(a.segments[2].time, 89088L)
  assert_eq(a.segments[2].duration, 21162L)
  assert_eq(a.segments[2].uri, "chunk-stream1-00003.m4s")
}

///|
test "dash: duration-driven SegmentTemplate with BaseURL inheritance" {
  let mpd_text =
    #|<MPD type="static" mediaPresentationDuration="PT10S" minBufferTime="PT1.5S">
    #|  <BaseURL>https://cdn.example.com/vod/</BaseURL>
    #|  <Period id="p0" start="PT0S">
    #|    <BaseURL>p0/</BaseURL>
    #|    <AdaptationSet contentType="video" mimeType="video/mp4" codecs="avc1.64001f" frameRate="25/1" width="640" height="360">
    #|      <SegmentTemplate timescale="1000" duration="2000" startNumber="5"
    #|        initialization="init-$RepresentationID$.mp4"
    #|        media="seg-$Number%03d$.m4s" />
    #|      <Representation id="v1" bandwidth="1000000" width="640" height="360" />
    #|    </AdaptationSet>
    #|  </Period>
    #|</MPD>
    #|
  let mpd = av_dash_parse(mpd_text).unwrap()
  assert_true(mpd.media_presentation_duration == 10.0)
  assert_true(mpd.min_buffer_time == 1.5)
  let period = mpd.periods[0]
  assert_true(period.duration == 10.0)
  let adapt = period.adaptation_sets[0]
  assert_eq(adapt.codecs, "avc1.64001f")
  assert_eq(adapt.frame_rate, "25/1")
  let rep = adapt.representations[0]
  assert_eq(rep.base_url, "https://cdn.example.com/vod/p0/")
  assert_eq(rep.initialization, "https://cdn.example.com/vod/p0/init-v1.mp4")
  assert_eq(rep.segments.length(), 5)
  assert_eq(rep.segments[0].number, 5L)
  assert_eq(rep.segments[0].time, 0L)
  assert_eq(rep.segments[0].uri, "https://cdn.example.com/vod/p0/seg-005.m4s")
  assert_eq(rep.segments[4].number, 9L)
  assert_eq(rep.segments[4].time, 8000L)
  assert_eq(rep.segments[4].uri, "https://cdn.example.com/vod/p0/seg-009.m4s")
}

///|
test "dash: SegmentTimeline r=-1 and $Time$ expansion" {
  let mpd_text =
    #|<MPD type="static" mediaPresentationDuration="PT10S">
    #|  <Period id="p" duration="PT10S">
    #|    <AdaptationSet contentType="video" codecs="hvc1.1.6.L93.B0">
    #|      <SegmentTemplate timescale="1" media="t$Time$.m4s" startNumber="1">
    #|        <SegmentTimeline>
    #|          <S t="0" d="2" r="-1" />
    #|        </SegmentTimeline>
    #|      </SegmentTemplate>
    #|      <Representation id="h1" bandwidth="500000" width="320" height="240" />
    #|    </AdaptationSet>
    #|  </Period>
    #|</MPD>
    #|
  let mpd = av_dash_parse(mpd_text).unwrap()
  let rep = mpd.periods[0].adaptation_sets[0].representations[0]
  assert_eq(rep.codec, "hevc")
  assert_eq(rep.segments.length(), 5)
  assert_eq(rep.segments[0].time, 0L)
  assert_eq(rep.segments[0].uri, "t0.m4s")
  assert_eq(rep.segments[4].time, 8L)
  assert_eq(rep.segments[4].uri, "t8.m4s")
}

///|
test "dash: ISO 8601 durations and template formatting" {
  assert_true(dash_parse_duration("PT2.6S") == 2.6)
  assert_true(dash_parse_duration("PT1H2M3.5S") == 3723.5)
  assert_true(dash_parse_duration("P1DT2H") == 93600.0)
  assert_true(dash_parse_duration("bad") == 0.0)
  assert_eq(
    dash_fill_template(
      "$RepresentationID$-$Number%05d$-$Time$-$Bandwidth$", "v", 900L, 7L, 1234L,
    ),
    "v-00007-1234-900",
  )
  assert_eq(dash_fill_template("a$$b", "v", 0L, 0L, 0L), "a$b")
}

///|
test "dash: rejects non-MPD documents" {
  match av_dash_parse("<html></html>") {
    Ok(_) => fail("expected MPD error")
    Err(e) => assert_true(e.contains("MPD"))
  }
}
