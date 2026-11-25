import { WasmPlayer } from "./player.js";
import { indexSubtitles, subtitleAt, subtitleFile } from "./subtitles.js";
import { checkMediaFiles, MAX_MEDIA_BYTES, runMediaTask } from "./media-task.js";

const $ = (id) => document.getElementById(id);
const video = $("video");
const audio = $("audio");
const canvasPlayer = $("wasmCanvas");
const playerMode = $("playMode");
const decoderControls = {
  play: $("wasmPlay"),
  start: $("wasmStart"),
  seek: $("wasmSeek"),
  mute: $("wasmMute"),
  time: $("wasmTime"),
};
const progress = $("convertProgress");
const videoFormat = $("videoFormat");
const videoLabels = { h264: "H.264", hevc: "HEVC", av1: "AV1", webm: "WebM" };
const audioFormats = {
  wav: ["WAV", "导出首条音轨为 16 位 PCM WAV。", true],
  flac: ["FLAC", "导出首条音轨为 16 位 FLAC。", true],
  wv: ["WavPack", "导出单声道或立体声，使用 16 位无损编码。", false],
  ac3: ["AC-3", "支持单声道和立体声，请选 32、44.1 或 48 kHz。", false],
  ogg: ["Ogg / Vorbis", "实验性 Vorbis 编码，输入需要立体声。", true],
};
const recorderType = ["video/webm;codecs=vp8,opus", "video/webm"].find(
  (type) => globalThis.MediaRecorder?.isTypeSupported(type),
);
const captureStream = video.captureStream ?? video.mozCaptureStream;

let current;
let revision = 0;
let engineState = "loading";

function setEngine(state, error) {
  engineState = state;
  const status = $("engineStatus");
  status.dataset.state = state;
  status.textContent = state === "ready" ? "Wasm 已就绪" : "Wasm 无法启动";
  status.title = error ?? "";
  if (error) $("probeMessage").textContent = error;
  updateControls();
}

function request(file, action, options = {}, signal) {
  const lifetime = signal ? AbortSignal.any([file.lifetime.signal, signal]) : file.lifetime.signal;
  return runMediaTask(action, { file: file.file, fileId: file.id, ...options }, lifetime);
}

function notice(text = "", error = false) {
  const node = $("taskStatus");
  node.textContent = text;
  node.hidden = !text;
  node.dataset.state = error ? "error" : "normal";
}

function sizeLabel(bytes) {
  if (bytes >= 1048576) return `${(bytes / 1048576).toFixed(1)} MiB`;
  if (bytes >= 1024) return `${(bytes / 1024).toFixed(1)} KiB`;
  return `${bytes} B`;
}

function timeLabel(seconds) {
  return Number.isFinite(seconds) ? `${seconds.toFixed(2)} 秒` : "未知时长";
}

function updateControls() {
  const file = current;
  const videoReady = file?.player === video && !video.error && video.videoWidth > 0;
  const hasFrame = file?.wasmPlayer
    ? !canvasPlayer.hidden && !file.wasmPlayer.seeking
    : videoReady && video.readyState >= 2 && !video.seeking;
  const audioOnly = file?.hasAudio && !file.hasVideo;
  const wasmPlayback = !!(file?.wasmPlayer || file?.audioPreviewUrl);
  playerMode.textContent = wasmPlayback ? "浏览器播放" : "Wasm 播放";
  playerMode.setAttribute("aria-pressed", String(wasmPlayback));
  playerMode.disabled = !file?.wasmPlayer && !file?.audioPreviewUrl
    && (engineState !== "ready" || !(file?.hasVideo || audioOnly) || !!file?.processing || !!file?.conversion);
  const webm = videoFormat.value === "webm";
  const canRecord = recorderType && captureStream;
  const canConvert = webm ? videoReady && canRecord : engineState === "ready" && file?.hasVideo;
  $("capture").disabled = !hasFrame || !!file?.capturing;
  $("convert").disabled = !canConvert || !!file?.conversion || !!file?.processing;
  videoFormat.disabled = !!file?.conversion;
  $("cancel").hidden = !file?.conversion;
  progress.hidden = !file?.conversion;
  if (webm) {
    $("convertInfo").textContent = canRecord
      ? "浏览器按原速编码，保留可播放的音轨。"
      : "当前浏览器缺少 WebM 转码支持。";
  } else if (videoFormat.value === "av1") {
    $("convertInfo").textContent = "实验性 AV1 编码，最多 120 帧，长边不超过 512 像素，画面按需补边。";
  } else {
    $("convertInfo").textContent = "使用 MoonBit 编码，保留首条单声道或立体声音轨。";
  }
  const wasmReady = engineState === "ready" && file?.probe && !file.processing && !file.conversion;
  $("cancelTool").hidden = !file?.processing;
  $("exportAudio").disabled = !wasmReady || !file.hasAudio;
  $("audioPostOptions").disabled = $("exportAudio").disabled;
  $("analyzeAudio").disabled = !wasmReady || !file.hasAudio;
  $("thumbnail").disabled = !wasmReady || !file.hasVideo;
  $("thumbnailFormat").disabled = $("thumbnail").disabled;
  $("contactSheet").disabled = !wasmReady || !file.hasVideo;
  $("contactCount").disabled = $("contactSheet").disabled;
  $("contactFormat").disabled = $("contactSheet").disabled;
  $("diagnose").disabled = !wasmReady || !file.canDiagnose;
  $("trim").disabled = !wasmReady || !file.canEditClips;
  $("chooseClips").disabled = !wasmReady || !file.canEditClips;
  $("concat").disabled = !wasmReady || !file.canEditClips || !file.clips.length;
  $("cover").disabled = !wasmReady;
}

function resetMedia() {
  current?.lifetime.abort();
  current?.conversion?.abort();
  if (current) closeWasmPlayer(current);
  for (const player of [audio, video]) {
    player.pause();
    player.removeAttribute("src");
    player.load();
    player.hidden = true;
  }
  if (current) {
    URL.revokeObjectURL(current.url);
    if (current.audioPreviewUrl) URL.revokeObjectURL(current.audioPreviewUrl);
    for (const url of current.results.values()) URL.revokeObjectURL(url);
  }
  $("emptyPlayer").hidden = false;
  $("outputs").replaceChildren();
  $("results").hidden = true;
  $("audioAnalysis").hidden = true;
  $("videoDiagnostics").hidden = true;
  $("subtitleControls").hidden = true;
  $("subtitleTrack").replaceChildren();
  $("subtitleStatus").textContent = "";
  $("trimStart").value = "0";
  $("trimEnd").value = "";
  $("clipList").replaceChildren();
  $("audioMixFile").value = "";
  updateAudioPostControls();
  updateSubtitle(null);
  $("probe").hidden = true;
  $("probeMessage").hidden = false;
  notice();
}

function closeWasmPlayer(file) {
  file.playbackAudio?.abort();
  file.playbackAudio = null;
  file.wasmPlayer?.close();
  file.wasmPlayer = null;
  $("wasmControls").hidden = true;
  decoderControls.start.hidden = true;
  canvasPlayer.hidden = true;
  playerMode.textContent = "Wasm 播放";
  playerMode.setAttribute("aria-pressed", "false");
}

playerMode.onclick = () => {
  const file = current;
  if (!file) return;
  if (file.hasAudio && !file.hasVideo) {
    if (file.audioPreviewUrl) {
      audio.src = file.url;
      URL.revokeObjectURL(file.audioPreviewUrl);
      file.audioPreviewUrl = null;
      updateControls();
      return;
    }
    return runTool("audio", { format: "wav", rate: 0 }, "解码音频", (selection, { blob }) => {
      selection.audioPreviewUrl = URL.createObjectURL(blob);
      audio.src = selection.audioPreviewUrl;
    }, "点击播放控件试听。");
  }
  if (file.wasmPlayer) {
    const position = file.wasmPlayer.clock();
    closeWasmPlayer(file);
    if (video.readyState >= 1 && !video.error) {
      video.currentTime = Math.min(position, video.duration || position);
      video.hidden = false;
      $("emptyPlayer").hidden = true;
      $("playerInfo").textContent = `${video.videoWidth} × ${video.videoHeight} · ${timeLabel(video.duration)}`;
    } else {
      $("emptyPlayer").hidden = false;
      $("playerMessage").textContent = video.error ? "浏览器无法播放此文件。" : "正在加载预览…";
      $("playerInfo").textContent = "浏览器播放";
    }
    updateSubtitle(file, video.currentTime);
    updateControls();
    return;
  }

  video.pause();
  video.hidden = true;
  $("emptyPlayer").hidden = false;
  $("playerMessage").textContent = "正在解码首帧…";
  $("playerInfo").textContent = "MoonBit Wasm 解码";
  $("wasmControls").hidden = false;
  decoderControls.play.disabled = true;
  decoderControls.play.textContent = "播放";
  decoderControls.seek.disabled = true;
  decoderControls.seek.value = 0;
  decoderControls.time.textContent = "0:00";
  decoderControls.mute.disabled = true;
  decoderControls.mute.textContent = "静音";
  decoderControls.mute.setAttribute("aria-pressed", "false");
  playerMode.textContent = "浏览器播放";
  playerMode.setAttribute("aria-pressed", "true");
  let audioFailed = false;
  const playerDetails = () => `MoonBit Wasm · ${canvasPlayer.width} × ${canvasPlayer.height} · ${timeLabel(player.duration)}`
    + (audioFailed ? " · 音轨无法播放" : "");
  const audioUnavailable = () => {
    audioFailed = true;
    if (!player.buffering && !player.seeking && !player.error) {
      $("playerInfo").textContent = player.frame ? playerDetails() : "MoonBit Wasm 解码 · 音轨无法播放";
    }
  };
  const player = new WasmPlayer(file.file, file.id, canvasPlayer, decoderControls, {
    ready() {
      $("emptyPlayer").hidden = true;
      canvasPlayer.hidden = false;
      $("playerInfo").textContent = playerDetails();
      if (file.pendingJump != null) {
        const target = file.pendingJump;
        delete file.pendingJump;
        player.seek(target);
      }
      updateControls();
    },
    seeking(target, decoded) {
      $("playerInfo").textContent = decoded === undefined
        ? `正在定位到 ${timeLabel(target)}…`
        : `正在定位到 ${timeLabel(target)} · 已解码至 ${timeLabel(decoded)}`;
      updateControls();
    },
    seeked() {
      $("playerInfo").textContent = playerDetails();
      updateControls();
    },
    buffering(active) {
      $("playerInfo").textContent = active ? "正在解码下一帧…" : playerDetails();
    },
    error(message) {
      $("playerInfo").textContent = message;
      $("playerMessage").textContent = "Wasm 无法播放此文件。";
      updateControls();
    },
    audioUnavailable,
    timeChanged(time) {
      if (current === file) updateSubtitle(file, time);
    },
  });
  file.wasmPlayer = player;
  if (file.hasAudio) {
    file.playbackAudio = new AbortController();
    request(file, "audio", { format: "wav", rate: 0 }, file.playbackAudio.signal).then(({ blob }) => player.setAudio(blob), () => {
      if (file.wasmPlayer === player) audioUnavailable();
    });
  }
  updateControls();
};

decoderControls.play.onclick = () => {
  const player = current?.wasmPlayer;
  if (player?.playing) player.pause();
  else player?.play();
};
decoderControls.mute.onclick = () => current?.wasmPlayer?.toggleMute();
decoderControls.start.onclick = () => current?.wasmPlayer?.play();
decoderControls.seek.oninput = () => current?.wasmPlayer?.previewSeek(Number(decoderControls.seek.value));
decoderControls.seek.onpointercancel = () => current?.wasmPlayer?.cancelPreviewSeek();
decoderControls.seek.onchange = () => current?.wasmPlayer?.seek(Number(decoderControls.seek.value));

function usePlayer(file, player) {
  if (file.player === player) return;
  const previous = file.player;
  if (previous) {
    previous.pause();
    previous.removeAttribute("src");
    previous.load();
    previous.hidden = true;
  }
  file.player = player;
  $("emptyPlayer").hidden = false;
  $("playerMessage").textContent = "正在加载预览…";
  $("playerInfo").textContent = "正在读取播放参数";
  player.src = file.url;
}

async function openFile(file, id) {
  try {
    checkMediaFiles(file);
  } catch (error) {
    notice(error.message, true);
    return;
  }
  resetMedia();
  const selection = {
    id,
    file,
    base: file.name.replace(/\.[^.]+$/, "") || file.name,
    url: URL.createObjectURL(file),
    results: new Map(),
    clips: [],
    lifetime: new AbortController(),
  };
  current = selection;
  $("fileName").textContent = file.name;
  $("fileInfo").textContent = `${sizeLabel(file.size)} · 本地文件`;
  $("audioTitle").textContent = "转音频 / 提取音轨";
  const audioOnly = file.type.startsWith("audio/") || /\.(mp3|wav|flac|aac|m4a|oga|opus|aiff?|aifc|ape|wma|dts|ac3|eac3|ec3|mlp|thd|truehd|wv|shn|mpc|ra|rm|amr|awb)$/i.test(file.name);
  usePlayer(selection, audioOnly ? audio : video);
  $("probeMessage").textContent = engineState === "error" ? $("engineStatus").title : "正在探测媒体流…";
  updateControls();

  try {
    const probe = await request(selection, "probe", { file });
    if (current !== selection) return;
    selection.probe = probe;
    selection.hasVideo = probe.streams.some((stream) => stream.codec_type === "video");
    selection.hasAudio = probe.streams.some((stream) => stream.codec_type === "audio");
    const videos = probe.streams.filter((stream) => stream.codec_type === "video");
    const audios = probe.streams.filter((stream) => stream.codec_type === "audio");
    selection.canDiagnose = ["h264", "hevc", "vp9", "av1"].includes(videos[0]?.codec_name);
    selection.canEditClips = probe.format.format_name.startsWith("mov,")
      && videos.length === 1 && videos[0].codec_name === "h264"
      && audios.length <= 1 && audios.every((stream) => stream.codec_name === "aac");
    if (selection.canEditClips && probe.format.duration > 0) $("trimEnd").value = probe.format.duration;
    if (selection.hasAudio && !selection.hasVideo) usePlayer(selection, audio);
    if (selection.hasVideo) usePlayer(selection, video);
    if (selection.hasAudio) {
      $("audioTitle").textContent = selection.hasVideo ? "提取音轨" : "音频转换";
    }
    renderProbe(probe);
    if (probe.streams.some((stream) => stream.codec_type === "subtitle")) loadSubtitles(selection);
  } catch (error) {
    if (current === selection) $("probeMessage").textContent = error.message;
  }
  if (current === selection) updateControls();
}

function updateSubtitle(file, time) {
  const text = subtitleAt(file?.subtitle, time ?? 0);
  const overlay = $("subtitleOverlay");
  if (overlay.textContent !== text) overlay.textContent = text;
  overlay.hidden = !text;
}

async function loadSubtitles(file) {
  $("subtitleControls").hidden = false;
  $("subtitleTrack").disabled = true;
  $("subtitleFormat").disabled = true;
  $("exportSubtitle").disabled = true;
  $("subtitleStatus").textContent = "正在读取字幕…";
  try {
    const result = await request(file, "subtitleTracks");
    if (current !== file) return;
    file.subtitles = indexSubtitles(result.filter((track) => track.cues.length));
    if (!file.subtitles.length) {
      $("subtitleStatus").textContent = "未找到可预览的文本字幕。支持 MP4 mov_text 和 MKV UTF-8。";
      return;
    }
    $("subtitleTrack").replaceChildren(new Option("关闭", ""), ...file.subtitles.map((track, index) =>
      new Option(`轨道 ${track.index} · ${track.language || "und"}`, String(index))));
    $("subtitleTrack").disabled = false;
    $("subtitleTrack").value = "0";
    $("subtitleStatus").textContent = "";
    selectSubtitle();
  } catch (error) {
    if (current === file) $("subtitleStatus").textContent = error.message;
  }
}

function selectSubtitle() {
  const index = $("subtitleTrack").value;
  current.subtitle = index === "" ? undefined : current.subtitles[Number(index)];
  $("subtitleFormat").disabled = !current.subtitle;
  $("exportSubtitle").disabled = !current.subtitle;
  updateSubtitle(current, current.wasmPlayer?.clock() ?? current.player.currentTime);
}

$("subtitleTrack").onchange = selectSubtitle;
$("exportSubtitle").onclick = () => {
  const file = current;
  const track = file?.subtitle;
  if (!track) return;
  const format = $("subtitleFormat").value;
  addOutput(file, "subtitle", "文本字幕", subtitleFile(track, format), `-track-${track.index}.${format}`,
    `${track.cues.length} 条 · ${format === "srt" ? "SRT" : "WebVTT"}`);
};

function renderProbe(probe) {
  const summary = $("summary");
  summary.replaceChildren();
  for (const [label, value] of [
    ["容器格式", probe.format.format_name],
    ["时长", timeLabel(probe.format.duration)],
    ["流数量", probe.format.nb_streams],
  ]) {
    const group = document.createElement("div");
    const term = document.createElement("dt");
    const definition = document.createElement("dd");
    term.textContent = label;
    definition.textContent = value;
    group.append(term, definition);
    summary.append(group);
  }
  const kinds = { video: "视频", audio: "音频", subtitle: "字幕" };
  const rows = probe.streams.map((stream) => {
    const row = document.createElement("tr");
    const details = {
      video: `${stream.width} × ${stream.height}`,
      audio: `${stream.sample_rate} Hz · ${stream.channels} 声道`,
    };
    for (const value of [
      stream.index, kinds[stream.codec_type], stream.codec_name, details[stream.codec_type] ?? "—",
    ]) {
      row.insertCell().textContent = value;
    }
    return row;
  });
  $("streams").replaceChildren(...rows);
  $("probeMessage").hidden = true;
  $("probe").hidden = false;
}

function addOutput(file, key, title, blob, extension, details, previewTag) {
  const url = URL.createObjectURL(blob);
  const filename = `${file.base}${extension}`;
  const item = document.createElement("li");
  item.className = "output";
  item.dataset.key = key;
  if (previewTag) {
    const preview = document.createElement(previewTag);
    preview.src = url;
    if (previewTag === "img") preview.alt = title;
    else {
      preview.controls = true;
      preview.preload = "metadata";
      preview.setAttribute("aria-label", title);
    }
    item.append(preview);
  }
  const text = document.createElement("div");
  text.className = "output-text";
  const label = document.createElement("strong");
  label.textContent = title;
  const info = document.createElement("p");
  info.textContent = [filename, details, sizeLabel(blob.size)].filter(Boolean).join(" · ");
  text.append(label, info);
  if (previewTag === "video" || previewTag === "audio") {
    const preview = item.querySelector(previewTag);
    preview.addEventListener("error", () => {
      preview.hidden = true;
      const message = document.createElement("p");
      message.textContent = "当前浏览器无法预览此编码，可下载播放。";
      text.append(message);
    }, { once: true });
  }
  const link = document.createElement("a");
  link.className = "download";
  link.href = url;
  link.download = filename;
  link.textContent = "下载";
  link.setAttribute("aria-label", `下载 ${filename}`);
  item.append(text, link);

  const old = [...$("outputs").children].find((output) => output.dataset.key === key);
  if (old) {
    old.replaceWith(item);
    URL.revokeObjectURL(file.results.get(key));
  } else $("outputs").prepend(item);
  file.results.set(key, url);
  $("results").hidden = false;
}

function png(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error("无法生成 PNG。"));
    }, "image/png");
  });
}

async function runTool(action, options, description, render, resultMessage = "可在输出文件中预览或下载。") {
  const file = current;
  if (!file || file.processing || file.conversion) return;
  const controller = new AbortController();
  file.processing = controller;
  updateControls();
  notice(`正在${description}…`);
  try {
    const result = await request(file, action, options, controller.signal);
    if (current !== file || controller.signal.aborted) return;
    $("cancelTool").hidden = true;
    await render(file, result);
    if (current === file) notice(`${description}完成。${resultMessage}`);
  } catch (error) {
    if (current === file) {
      notice(controller.signal.aborted ? "已取消处理。" : error.message, !controller.signal.aborted);
    }
  } finally {
    file.processing = null;
    if (current === file) updateControls();
  }
}

$("cancelTool").onclick = () => current?.processing?.abort();

function timestamp(seconds) {
  const centiseconds = Math.round(seconds * 100);
  const minutes = Math.floor(centiseconds / 6000);
  const remainder = ((centiseconds % 6000) / 100).toFixed(2).padStart(5, "0");
  return `${minutes}:${remainder}`;
}

function renderAudioAnalysis(_, { rate, channels, duration, peak, lufs, lows, highs, silence }) {
  $("analysisSource").textContent = `${rate} Hz · ${channels} 声道`;
  $("analysisPeak").textContent = peak > 0 ? `${(20 * Math.log10(peak)).toFixed(1)} dBFS` : "−∞ dBFS";
  $("analysisLoudness").textContent = lufs != null ? `${lufs.toFixed(1)} LUFS`
    : channels > 2 ? "仅支持单声道或立体声" : "无可计量的响度";
  $("silenceCount").textContent = `${silence.length} 段`;
  $("analysisDuration").textContent = timestamp(duration);
  const canvas = $("analysisWaveform");
  const ctx = canvas.getContext("2d");
  const { width, height } = canvas;
  ctx.fillStyle = "#111214";
  ctx.fillRect(0, 0, width, height);
  ctx.fillStyle = "#504030";
  for (const [start, end] of silence) {
    ctx.fillRect(start / duration * width, 0, (end - start) / duration * width, height);
  }
  const center = height / 2;
  ctx.fillStyle = "#64605c";
  ctx.fillRect(0, center, width, 1);
  ctx.fillStyle = "#ffb76d";
  const scale = (center - 3) / Math.max(1, peak);
  const binWidth = width / lows.length;
  for (let i = 0; i < lows.length; i++) {
    const amplitude = (highs[i] - lows[i]) * scale;
    if (amplitude > 0) ctx.fillRect(i * binWidth, center - highs[i] * scale, binWidth, Math.max(1, amplitude));
  }
  const intervals = document.createDocumentFragment();
  for (const [start, end] of silence) {
    const item = document.createElement("li");
    item.textContent = `${timestamp(start)} – ${timestamp(end)}`;
    intervals.append(item);
  }
  $("silenceIntervals").replaceChildren(intervals);
  $("silenceDetails").hidden = !silence.length;
  $("silenceDetails").open = false;
  $("audioAnalysis").hidden = false;
}

async function renderContactSheet(file, { frames, interval, estimatedInterval }) {
  const columns = Math.min(3, frames.length);
  const cellWidth = 288;
  const cellHeight = 200;
  const canvas = document.createElement("canvas");
  canvas.width = columns * cellWidth;
  canvas.height = Math.ceil(frames.length / columns) * cellHeight;
  const ctx = canvas.getContext("2d");
  ctx.fillStyle = "#111214";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.font = "15px monospace";
  const thumbnail = document.createElement("canvas");
  const thumbnailCtx = thumbnail.getContext("2d");
  frames.forEach(({ rgba, width, height, start }, index) => {
    const x = (index % columns) * cellWidth;
    const y = Math.floor(index / columns) * cellHeight;
    const scale = Math.min(280 / width, 168 / height, 1);
    const w = width * scale;
    const h = height * scale;
    thumbnail.width = width;
    thumbnail.height = height;
    thumbnailCtx.putImageData(new ImageData(rgba, width, height), 0, 0);
    ctx.drawImage(thumbnail, x + (cellWidth - w) / 2, y + 4 + (168 - h) / 2, w, h);
    ctx.fillStyle = "#ffb76d";
    ctx.fillText(timestamp(start), x + 12, y + 190);
  });
  const blob = await png(canvas);
  if (current !== file) return;
  const spacing = estimatedInterval ? "时长未知，每 5 秒取样" : `每 ${timeLabel(interval)}取样`;
  addOutput(file, "contact-sheet", "视频缩略图总览", blob, "-contact-sheet.png",
    `${frames.length} 帧 · ${spacing}`, "img");
}

$("analyzeAudio").onclick = () => runTool("analyzeAudio", {}, "分析音轨", renderAudioAnalysis, "");
$("contactSheet").onclick = () => {
  const format = $("contactFormat").value;
  const options = { count: Number($("contactCount").value), format };
  if (format === "apng") {
    return runTool("contactSheet", options, "生成缩略动图", (file, { blob, count }) => {
      addOutput(file, "contact-apng", "APNG 缩略动图", blob, "-thumbnails.apng",
        `${count} 帧 · 每帧 0.5 秒`, "img");
    });
  }
  return runTool("contactSheet", options, "生成缩略图总览", renderContactSheet);
};

function jumpToIssue(file, time) {
  if (file !== current) return;
  if (file.wasmPlayer?.frame) {
    file.wasmPlayer.seek(time);
  } else if (file.wasmPlayer) {
    file.pendingJump = time;
  } else if (!video.error && video.readyState >= 1) {
    video.currentTime = time;
  } else {
    file.pendingJump = time;
    playerMode.click();
  }
  $("playTitle").scrollIntoView({ block: "nearest" });
}

function renderDiagnostics(file, { black, frozen, silence, estimated, audioError }) {
  const entries = [
    ...black.map(([start, end]) => ({ label: "黑场", start, end })),
    ...frozen.map(([start, end]) => ({ label: "画面冻结", start, end })),
    ...(silence ?? []).map(([start, end]) => ({ label: "静音", start, end })),
  ].sort((a, b) => a.start - b.start);
  const list = document.createDocumentFragment();
  for (const { label, start, end } of entries) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = `${label} · ${timestamp(start)} – ${timestamp(end)}`;
    button.onclick = () => jumpToIssue(file, start);
    item.append(button);
    list.append(item);
  }
  $("diagnosticList").replaceChildren(list);
  $("diagnosticNote").textContent = [
    entries.length ? `检测到 ${entries.length} 段，请点击时间定位。` : "未检测到符合阈值的区间。",
    "黑场与冻结至少持续 2 秒。静音低于 −60 dBFS 且至少持续 0.5 秒。",
    estimated ? "视频时间按帧率估算。" : "",
    file.hasAudio ? "" : "文件无音轨。",
    audioError ? `音轨分析失败。${audioError}` : "",
  ].filter(Boolean).join(" ");
  $("videoDiagnostics").hidden = false;
}

$("diagnose").onclick = () => runTool("diagnostics", { hasAudio: current.hasAudio },
  "检测视频", renderDiagnostics, "");

$("trimForm").onsubmit = (event) => {
  event.preventDefault();
  const start = $("trimStart").valueAsNumber;
  const end = $("trimEnd").valueAsNumber;
  if (!(end > start)) {
    notice("裁剪终点须晚于起点。", true);
    return;
  }
  return runTool("trim", { start, end }, "裁剪视频", (file, result) => {
    addOutput(file, "trim", "关键帧裁剪", result.blob, "-trim.mp4",
      `实际区间 ${timestamp(result.start)} – ${timestamp(result.end)}`, "video");
  });
};

function renderClips(file) {
  const items = file.clips.map((clip, index) => {
    const item = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = clip.name;
    const up = document.createElement("button");
    up.type = "button";
    up.textContent = "上移";
    up.setAttribute("aria-label", `上移 ${clip.name}`);
    up.disabled = !!file.processing || index === 0;
    up.onclick = () => {
      [file.clips[index - 1], file.clips[index]] = [file.clips[index], file.clips[index - 1]];
      renderClips(file);
    };
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "移除";
    remove.setAttribute("aria-label", `移除 ${clip.name}`);
    remove.disabled = !!file.processing;
    remove.onclick = () => {
      file.clips.splice(index, 1);
      renderClips(file);
      updateControls();
    };
    item.append(label, up, remove);
    return item;
  });
  $("clipList").replaceChildren(...items);
}

$("chooseClips").onclick = () => {
  $("clipPicker").dataset.fileId = String(current.id);
  $("clipPicker").click();
};
$("clipPicker").onchange = (event) => {
  const picker = event.currentTarget;
  const files = [...picker.files];
  picker.value = "";
  if (!current?.canEditClips || picker.dataset.fileId !== String(current.id)) return;
  try {
    checkMediaFiles(current.file, [...current.clips, ...files]);
  } catch (error) {
    notice(error.message, true);
    return;
  }
  current.clips.push(...files);
  renderClips(current);
  updateControls();
};
$("concat").onclick = async () => {
  const file = current;
  const files = [...file.clips];
  const task = runTool("concat", { files }, "拼接视频", (_, result) => {
    addOutput(file, "concat", "片段拼接", result.blob, "-concat.mp4",
      `${files.length + 1} 段 · ${timeLabel(result.end)}`, "video");
  });
  renderClips(file);
  await task;
  if (file === current) renderClips(file);
};

for (const player of [video, audio]) {
  player.addEventListener("timeupdate", () => {
    if (current?.player === player && !current.wasmPlayer) updateSubtitle(current, player.currentTime);
  });
  player.addEventListener("loadedmetadata", () => {
    if (current?.player !== player || current.wasmPlayer || player.currentSrc !== (current.audioPreviewUrl ?? current.url)) return;
    player.hidden = false;
    $("emptyPlayer").hidden = true;
    $("playerInfo").textContent = [
      video === player && video.videoWidth ? `${video.videoWidth} × ${video.videoHeight}` : "",
      timeLabel(player.duration),
    ].filter(Boolean).join(" · ");
    updateControls();
  });
  player.addEventListener("error", () => {
    if (current?.player !== player || current.wasmPlayer || player.src !== (current.audioPreviewUrl ?? current.url) || !player.error) return;
    player.hidden = true;
    $("emptyPlayer").hidden = false;
    $("playerMessage").textContent = "浏览器无法播放此文件。";
    $("playerInfo").textContent = player === audio && !current.audioPreviewUrl
      ? "可试用 Wasm 播放，或转换为 WAV。" : "可查看媒体信息和可用工具";
    updateControls();
  });
}
for (const event of ["loadeddata", "seeking", "seeked", "resize"]) {
  video.addEventListener(event, updateControls);
}

$("capture").onclick = async () => {
  const file = current;
  file.capturing = true;
  updateControls();
  try {
    const rendered = file.wasmPlayer;
    const timestamp = rendered ? rendered.frame.start : video.currentTime;
    const canvas = document.createElement("canvas");
    canvas.width = rendered ? canvasPlayer.width : video.videoWidth;
    canvas.height = rendered ? canvasPlayer.height : video.videoHeight;
    canvas.getContext("2d").drawImage(rendered ? canvasPlayer : video, 0, 0);
    const blob = await png(canvas);
    if (current !== file) return;
    addOutput(file, "capture", "当前帧截图", blob, `-${timestamp.toFixed(2)}s.png`,
      `${canvas.width} × ${canvas.height}`, "img");
    notice("截图已生成。");
  } catch (error) {
    if (current === file) notice(error.message, true);
  } finally {
    file.capturing = false;
    if (current === file) updateControls();
  }
};

$("thumbnail").onclick = () => {
  const format = $("thumbnailFormat").value;
  return runTool("thumbnail", { format }, "提取首帧", (file, frame) => {
    const label = format === "jpg" ? "JPEG" : "PNG";
    addOutput(file, `thumbnail-${format}`, `首帧 ${label}`, frame.blob, `-first-frame.${format}`,
      `${frame.width} × ${frame.height}`, "img");
  });
};

$("cover").onclick = () => runTool("cover", {}, "提取封面", (file, { blob }) => {
  const extensions = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp" };
  addOutput(file, "cover", "内嵌封面", blob, `-cover.${extensions[blob.type] ?? "bin"}`, blob.type,
    extensions[blob.type] ? "img" : null);
});

function updateAudioPostControls() {
  const normalize = $("audioNormalize").checked;
  const selected = $("audioMixFile").files.length > 0;
  const mixing = selected && $("audioMixWeight").valueAsNumber !== 0;
  $("audioTarget").disabled = !normalize;
  $("audioCeiling").disabled = !normalize && !mixing;
  $("audioMixWeight").disabled = !selected;
  $("clearAudioMix").hidden = !selected;
}

$("audioNormalize").onchange = updateAudioPostControls;
$("audioMixFile").onchange = updateAudioPostControls;
$("audioMixWeight").oninput = updateAudioPostControls;
$("clearAudioMix").onclick = () => {
  $("audioMixFile").value = "";
  updateAudioPostControls();
};

$("audioFormat").onchange = () => {
  const format = $("audioFormat").value;
  $("audioFormatInfo").textContent = audioFormats[format][1];
  const rate = $("sampleRate");
  rate.querySelector('option[value="16000"]').disabled = format === "ac3";
  if (format === "ac3" && rate.value === "16000") rate.value = "48000";
};

$("audioExportForm").onsubmit = (event) => {
  event.preventDefault();
  if ($("exportAudio").disabled) return;
  const format = $("audioFormat").value;
  const rate = Number($("sampleRate").value);
  const trim = $("audioTrimSilence").checked;
  const fadeIn = $("audioFadeIn").valueAsNumber;
  const fadeOut = $("audioFadeOut").valueAsNumber;
  const normalize = $("audioNormalize").checked;
  const mixFile = $("audioMixFile").files[0];
  const mixWeight = mixFile ? $("audioMixWeight").valueAsNumber / 100 : 0;
  const processed = trim || fadeIn > 0 || fadeOut > 0 || normalize || mixWeight > 0;
  const target = normalize ? $("audioTarget").valueAsNumber : -16;
  const ceiling = $("audioCeiling").disabled ? -1 : $("audioCeiling").valueAsNumber;
  const options = { format, rate, trim, fadeIn, fadeOut, normalize, target, ceiling, mixWeight,
    mixFile: mixWeight > 0 ? mixFile : undefined };
  return runTool(processed ? "processAudio" : "audio", options, "生成音频", (file, result) => {
    const details = [`${result.rate} Hz`, `${result.channels} 声道`, timeLabel(result.duration)];
    const info = result.processing;
    if (info?.lufs != null) details.push(`${info.lufs.toFixed(1)} LUFS`);
    else if (normalize && info) details.push("输出低于响度测量门限");
    if (info?.peak_limited) details.push("增益受峰值上限约束");
    if (info?.trim_start > 0 || info?.trim_end > 0) {
      details.push(`去除首尾静音 ${timeLabel(info.trim_start + info.trim_end)}`);
    }
    const suffix = processed ? "processed-" : "";
    const [label, , preview] = audioFormats[format];
    addOutput(file, `${suffix}${format}-${result.rate}`, `${label}${processed ? " · 后期处理" : ""}`,
      result.blob, `-${suffix}${result.rate}Hz.${format}`, details.join(" · "), preview ? "audio" : undefined);
  });
};

async function convertVideo(file, signal) {
  const input = document.createElement("video");
  input.muted = true;
  input.playsInline = true;
  let stream;
  let recorder;
  const timeout = AbortSignal.timeout(20000);
  const encoding = AbortSignal.any([signal, AbortSignal.timeout(150000)]);
  try {
    await new Promise((resolve, reject) => {
      const loading = AbortSignal.any([signal, timeout]);
      loading.addEventListener("abort", () => reject(loading.reason), { once: true });
      input.addEventListener("loadeddata", resolve, { once: true, signal: loading });
      input.addEventListener("error", () => reject(new Error("无法读取视频。")), { once: true, signal: loading });
      input.src = file.url;
    });
    signal.throwIfAborted();
    if (!Number.isFinite(input.duration) || input.duration <= 0) {
      throw new Error("请选用时长已知的视频文件。");
    }
    if (input.duration > 120 || input.videoWidth > 4096 || input.videoHeight > 4096
      || input.videoWidth * input.videoHeight > 4096 * 2160) {
      throw new Error("浏览器 WebM 转码支持两分钟以内、画面不超过 4096 × 2160 像素的视频。");
    }
    stream = captureStream.call(input);
    if (!stream.getVideoTracks().length || (file.hasAudio && !stream.getAudioTracks().length)) {
      throw new Error("浏览器无法捕获所需的视频或音轨。");
    }
    recorder = new MediaRecorder(stream, { mimeType: recorderType });
    return await new Promise((resolve, reject) => {
      const chunks = [];
      let finished = false;
      let bytes = 0;
      encoding.throwIfAborted();
      encoding.addEventListener("abort", () => reject(encoding.reason), { once: true });
      input.addEventListener("timeupdate", () => {
        if (current === file) progress.value = 100 * input.currentTime / input.duration;
      });
      stream.getVideoTracks()[0].addEventListener("ended", () => {
        finished = input.ended;
        if (finished && recorder.state !== "inactive") recorder.stop();
      });
      input.addEventListener("ended", () => {
        finished = true;
        if (recorder.state !== "inactive") recorder.stop();
      });
      input.addEventListener("error", () => reject(new Error("转码时视频解码失败。")));
      recorder.ondataavailable = (event) => {
        bytes += event.data.size;
        if (bytes > MAX_MEDIA_BYTES) {
          reject(new Error("WebM 输出超过 64 MiB。"));
          return;
        }
        if (event.data.size) chunks.push(event.data);
      };
      recorder.onerror = (event) => reject(event.error ?? new Error("WebM 编码失败。"));
      recorder.onstop = () => {
        if (finished && chunks.length) resolve(new Blob(chunks, { type: "video/webm" }));
        else reject(new Error("转码提前结束，未生成完整的视频。"));
      };
      recorder.start(1000);
      input.play().catch(reject);
    });
  } finally {
    if (recorder && recorder.state !== "inactive") recorder.stop();
    stream?.getTracks().forEach((track) => track.stop());
    input.pause();
    input.removeAttribute("src");
    input.load();
  }
}

videoFormat.onchange = updateControls;
$("convert").onclick = async () => {
  const file = current;
  const codec = videoFormat.value;
  const webm = codec === "webm";
  const label = videoLabels[codec];
  const controller = new AbortController();
  file.conversion = controller;
  file.wasmPlayer?.pause();
  video.pause();
  if (webm) progress.value = 0;
  else progress.removeAttribute("value");
  updateControls();
  notice(`正在编码 ${label}，请保持页面打开。`);
  try {
    const blob = webm
      ? await convertVideo(file, controller.signal)
      : (await request(file, "transcode", { codec }, controller.signal)).blob;
    if (current !== file) return;
    addOutput(file, codec, webm ? "WebM 视频" : `MP4 · ${label}`, blob,
      webm ? ".webm" : `-${codec}.mp4`, "", "video");
    notice(`${label} 转码完成。`);
  } catch (error) {
    if (current === file) {
      notice(controller.signal.aborted ? "已取消转码。" : error.message, !controller.signal.aborted);
    }
  } finally {
    file.conversion = null;
    if (current === file) updateControls();
  }
};
$("cancel").onclick = () => current?.conversion?.abort();

const drop = $("drop");
const picker = $("picker");
$("choose").onclick = () => picker.click();
picker.onchange = () => {
  if (picker.files[0]) openFile(picker.files[0], ++revision);
  picker.value = "";
};
for (const event of ["dragenter", "dragover"]) {
  drop.addEventListener(event, (e) => {
    if (!e.dataTransfer.types.includes("Files")) return;
    e.preventDefault();
    drop.classList.add("is-dragging");
  });
}
drop.addEventListener("dragleave", (event) => {
  if (!drop.contains(event.relatedTarget)) drop.classList.remove("is-dragging");
});
drop.addEventListener("drop", (event) => {
  event.preventDefault();
  drop.classList.remove("is-dragging");
  if (event.dataTransfer.files[0]) openFile(event.dataTransfer.files[0], ++revision);
});

$("sample").onclick = async () => {
  const id = ++revision;
  $("sample").disabled = true;
  notice("正在载入样片…");
  try {
    const response = await fetch("./sample.mp4", { cache: "no-cache" });
    if (!response.ok) throw new Error("无法加载演示样片。");
    const blob = await response.blob();
    if (revision === id) openFile(new File([blob], "sample.mp4", { type: "video/mp4" }), id);
  } catch (error) {
    if (revision === id) notice(error.message, true);
  } finally {
    $("sample").disabled = false;
  }
};
updateControls();
runMediaTask("init").then(() => setEngine("ready"), (error) => setEngine("error", error.message));
