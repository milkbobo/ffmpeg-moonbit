import { WasmPlayer } from "./player.js";

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
const videoLabels = { h264: "H.264", hevc: "HEVC", webm: "WebM" };
const recorderType = ["video/webm;codecs=vp8,opus", "video/webm"].find(
  (type) => globalThis.MediaRecorder?.isTypeSupported(type),
);
const captureStream = video.captureStream ?? video.mozCaptureStream;

let current;
let revision = 0;
let requestId = 0;
let engineState = "loading";
const requests = new Map();
const worker = new Worker("./worker.js", { type: "module" });

worker.onmessage = ({ data }) => {
  if (data.type) {
    setEngine(data.type === "ready" ? "ready" : "error", data.error);
    return;
  }
  const request = requests.get(data.id);
  if (!request) return;
  requests.delete(data.id);
  if (data.error) request.reject(new Error(data.error));
  else request.resolve(data.result);
};
worker.onerror = () => {
  const message = "媒体处理线程无法启动。请通过本地 HTTP 服务访问演示。";
  setEngine("error", message);
  for (const request of requests.values()) request.reject(new Error(message));
  requests.clear();
};

function setEngine(state, error) {
  engineState = state;
  const status = $("engineStatus");
  status.dataset.state = state;
  status.textContent = state === "ready" ? "Wasm 已就绪" : "Wasm 无法启动";
  status.title = error ?? "";
  if (error) $("probeMessage").textContent = error;
  updateControls();
}

function request(file, action, options = {}) {
  const id = ++requestId;
  return new Promise((resolve, reject) => {
    try {
      worker.postMessage({ id, fileId: file.id, action, ...options });
      requests.set(id, { resolve, reject });
    } catch (error) {
      reject(error);
    }
  });
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
  playerMode.disabled = !file?.wasmPlayer && (engineState !== "ready" || !file?.hasVideo);
  const webm = videoFormat.value === "webm";
  const canRecord = recorderType && captureStream;
  const canConvert = webm ? videoReady && canRecord : engineState === "ready" && file?.hasVideo;
  $("capture").disabled = !hasFrame || !!file?.capturing;
  $("convert").disabled = !canConvert || !!file?.conversion;
  videoFormat.disabled = !!file?.conversion;
  $("cancel").hidden = !file?.conversion;
  progress.hidden = !file?.conversion;
  if (webm) {
    $("convertInfo").textContent = canRecord
      ? "浏览器按原速编码，保留可播放的音轨。"
      : "当前浏览器缺少 WebM 转码支持。";
  } else {
    $("convertInfo").textContent = "使用 MoonBit 编码，保留首条单声道或立体声音轨。";
  }
  const wasmReady = engineState === "ready" && file?.probe && !file.processing;
  $("exportAudio").disabled = !wasmReady || !file.hasAudio;
  $("thumbnail").disabled = !wasmReady || !file.hasVideo;
  $("cover").disabled = !wasmReady;
}

function resetMedia() {
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
    for (const url of current.results.values()) URL.revokeObjectURL(url);
  }
  $("emptyPlayer").hidden = false;
  $("outputs").replaceChildren();
  $("results").hidden = true;
  $("probe").hidden = true;
  $("probeMessage").hidden = false;
  notice();
}

function closeWasmPlayer(file) {
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
  });
  file.wasmPlayer = player;
  if (file.hasAudio) {
    request(file, "audio", { format: "wav", rate: 0 }).then(({ blob }) => player.setAudio(blob), () => {
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
  resetMedia();
  const selection = {
    id,
    file,
    base: file.name.replace(/\.[^.]+$/, "") || file.name,
    url: URL.createObjectURL(file),
    results: new Map(),
  };
  current = selection;
  $("fileName").textContent = file.name;
  $("fileInfo").textContent = `${sizeLabel(file.size)} · 本地文件`;
  $("audioTitle").textContent = "转音频 / 提取音轨";
  const audioOnly = file.type.startsWith("audio/") || /\.(mp3|wav|flac|aac|m4a|oga|opus|aiff?)$/i.test(file.name);
  usePlayer(selection, audioOnly ? audio : video);
  $("probeMessage").textContent = engineState === "error" ? $("engineStatus").title : "正在探测媒体流…";
  updateControls();

  try {
    const probe = await request(selection, "probe", { file });
    if (current !== selection) return;
    selection.probe = probe;
    selection.hasVideo = probe.streams.some((stream) => stream.codec_type === "video");
    selection.hasAudio = probe.streams.some((stream) => stream.codec_type === "audio");
    if (selection.hasAudio && !selection.hasVideo) usePlayer(selection, audio);
    if (selection.hasVideo) usePlayer(selection, video);
    if (selection.hasAudio) {
      $("audioTitle").textContent = selection.hasVideo ? "提取音轨" : "音频转换";
    }
    renderProbe(probe);
  } catch (error) {
    if (current === selection) $("probeMessage").textContent = error.message;
  }
  if (current === selection) updateControls();
}

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
  if (previewTag === "video") {
    const preview = item.querySelector("video");
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

async function runTool(action, options, description, render) {
  const file = current;
  file.processing = true;
  updateControls();
  notice(`正在${description}…`);
  try {
    const result = await request(file, action, options);
    if (current !== file) return;
    await render(file, result);
    if (current === file) notice(`${description}完成，可在输出文件中预览或下载。`);
  } catch (error) {
    if (current === file) notice(error.message, true);
  } finally {
    file.processing = false;
    if (current === file) updateControls();
  }
}

for (const player of [video, audio]) {
  player.addEventListener("loadedmetadata", () => {
    if (current?.player !== player || current.wasmPlayer || player.currentSrc !== current.url) return;
    player.hidden = false;
    $("emptyPlayer").hidden = true;
    $("playerInfo").textContent = [
      video === player && video.videoWidth ? `${video.videoWidth} × ${video.videoHeight}` : "",
      timeLabel(player.duration),
    ].filter(Boolean).join(" · ");
    updateControls();
  });
  player.addEventListener("error", () => {
    if (current?.player !== player || current.wasmPlayer || player.src !== current.url || !player.error) return;
    player.hidden = true;
    $("emptyPlayer").hidden = false;
    $("playerMessage").textContent = "浏览器无法播放此文件。";
    $("playerInfo").textContent = "可查看媒体信息和可用工具";
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

$("thumbnail").onclick = () => runTool("thumbnail", {}, "提取首帧", async (file, frame) => {
  const canvas = document.createElement("canvas");
  canvas.width = frame.width;
  canvas.height = frame.height;
  canvas.getContext("2d").putImageData(new ImageData(frame.rgba, frame.width, frame.height), 0, 0);
  const blob = await png(canvas);
  if (current === file) {
    addOutput(file, "thumbnail", "首帧 PNG", blob, "-first-frame.png",
      `${frame.width} × ${frame.height}`, "img");
  }
});

$("cover").onclick = () => runTool("cover", {}, "提取封面", (file, { blob }) => {
  const extensions = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/bmp": "bmp" };
  addOutput(file, "cover", "内嵌封面", blob, `-cover.${extensions[blob.type] ?? "bin"}`, blob.type,
    extensions[blob.type] ? "img" : null);
});

$("exportAudio").onclick = () => {
  const format = $("audioFormat").value;
  const rate = Number($("sampleRate").value);
  return runTool("audio", { format, rate }, "生成音频", (file, result) => {
    addOutput(file, `${format}-${result.rate}`, format.toUpperCase(), result.blob, `-${result.rate}Hz.${format}`,
      `${result.rate} Hz · ${result.channels} 声道 · ${timeLabel(result.duration)}`, "audio");
  });
};

async function convertVideo(file, signal) {
  const input = document.createElement("video");
  input.muted = true;
  input.playsInline = true;
  let stream;
  let recorder;
  const timeout = AbortSignal.timeout(20000);
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
    stream = captureStream.call(input);
    if (!stream.getVideoTracks().length || (file.hasAudio && !stream.getAudioTracks().length)) {
      throw new Error("浏览器无法捕获所需的视频或音轨。");
    }
    recorder = new MediaRecorder(stream, { mimeType: recorderType });
    return await new Promise((resolve, reject) => {
      const chunks = [];
      let finished = false;
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
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

async function encodeMp4(file, codec, signal) {
  const encoder = new Worker("./worker.js", { type: "module" });
  try {
    return await new Promise((resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), { once: true });
      encoder.onerror = () => reject(new Error("视频编码线程无法启动。"));
      encoder.onmessage = ({ data }) => {
        if (data.error) reject(new Error(data.error));
        if (data.result) resolve(data.result.blob);
      };
      encoder.postMessage({ id: 1, action: "transcode", file, codec });
    });
  } finally {
    encoder.terminate();
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
      : await encodeMp4(file.file, codec, controller.signal);
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
