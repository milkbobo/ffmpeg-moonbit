function upperBound(items, time, value) {
  let low = 0;
  let high = items.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    if (value(items[middle]) <= time) low = middle + 1;
    else high = middle;
  }
  return low;
}

export function indexSubtitles(tracks) {
  return tracks.map((track) => {
    let latestEnd = 0;
    const ends = track.cues.map(({ end }) => (latestEnd = Math.max(latestEnd, end)));
    return { ...track, ends };
  });
}

export function subtitleAt(track, time) {
  if (!track) return "";
  const start = upperBound(track.ends, time, (end) => end);
  const end = upperBound(track.cues, time, (cue) => cue.start);
  return track.cues.slice(start, end).filter((cue) => cue.end > time).map((cue) => cue.text).join("\n");
}

function cueTime(milliseconds, format) {
  const h = Math.floor(milliseconds / 3600000);
  const m = Math.floor(milliseconds / 60000) % 60;
  const s = Math.floor(milliseconds / 1000) % 60;
  const fraction = String(milliseconds % 1000).padStart(3, "0");
  const clock = [h, m, s].map((part) => String(part).padStart(2, "0")).join(":");
  return `${clock}${format === "srt" ? "," : "."}${fraction}`;
}

export function subtitleFile(track, format) {
  const cues = track.cues.map(({ start, end, text }, index) => {
    const from = Math.round(start * 1000);
    const until = Math.max(from + 1, Math.round(end * 1000));
    const content = text.replaceAll("\r\n", "\n").replaceAll("\r", "\n")
      .split("\n").filter((line) => line.trim()).join("\n");
    const safe = format === "vtt"
      ? content.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;")
      : content;
    return `${index + 1}\n${cueTime(from, format)} --> ${cueTime(until, format)}\n${safe}\n`;
  });
  const header = format === "vtt" ? "WEBVTT\n\n" : "";
  return new Blob([header, cues.join("\n")], {
    type: format === "vtt" ? "text/vtt;charset=utf-8" : "application/x-subrip;charset=utf-8",
  });
}
