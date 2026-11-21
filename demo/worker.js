import { checkMediaFiles, MAX_MEDIA_BYTES } from "./media-task.js";

// The wasm string ABI represents byte b as UTF-16 code unit b + 0x100.
let source;
const engine = loadWasm();
engine.then(
  () => postMessage({ type: "ready" }),
  (error) => postMessage({ type: "unavailable", error: error.message }),
);

async function loadWasm() {
  const response = await fetch("./api.wasm", { cache: "no-cache" });
  if (!response.ok) throw new Error("缺少 api.wasm，请先构建演示模块。");
  try {
    const module = await WebAssembly.compile(await response.arrayBuffer(), {
      builtins: ["js-string"],
      importedStringConstants: "_",
    });
    return (await WebAssembly.instantiate(module, {})).exports;
  } catch {
    throw new Error("无法加载 Wasm，请检查构建产物及浏览器的 WasmGC 支持。");
  }
}

function encode(bytes) {
  const parts = [];
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    const chunk = bytes.subarray(offset, offset + 8192);
    parts.push(String.fromCharCode(...Uint16Array.from(chunk, (byte) => byte + 0x100)));
  }
  return parts.join("");
}

function decode(string) {
  if (string.length > MAX_MEDIA_BYTES) throw new Error("输出文件超过 64 MiB。");
  const bytes = new Uint8Array(string.length);
  for (let i = 0; i < bytes.length; i++) bytes[i] = string.charCodeAt(i) - 0x100;
  return bytes;
}

function call(fn, ...args) {
  if (!fn) throw new Error("当前 Wasm 产物缺少此功能，请重新构建演示模块。");
  const result = JSON.parse(fn(...args));
  if (!result.ok) {
    throw new Error(`${result.error.message}（${result.error.code}）`);
  }
  return result;
}

function pixels({ width, height, rgb24, ...timing }) {
  if (!rgb24) return timing;
  if (!Number.isSafeInteger(width * height) || width <= 0 || height <= 0
    || width * height > 4096 * 2160 || rgb24.length !== width * height * 3) {
    throw new Error("解码画面超出像素预算或数据不完整。");
  }
  const rgba = new Uint8ClampedArray(width * height * 4);
  for (let i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
    rgba[i] = rgb24.charCodeAt(j) - 0x100;
    rgba[i + 1] = rgb24.charCodeAt(j + 1) - 0x100;
    rgba[i + 2] = rgb24.charCodeAt(j + 2) - 0x100;
    rgba[i + 3] = 255;
  }
  return { ...timing, width, height, rgba };
}

const actions = {
  probe(wasm, _, encoded) {
    return call(wasm.ff_probe, encoded).probe;
  },
  cover(wasm, _, encoded) {
    const result = call(wasm.ff_cover, encoded);
    if (result.cover === null) throw new Error("该文件没有可提取的内嵌封面。");
    const mime = result.mime === "image/jpg" ? "image/jpeg" : result.mime;
    return { blob: new Blob([decode(result.data)], { type: mime }) };
  },
  thumbnail(wasm, _, encoded) {
    return pixels(call(wasm.ff_thumbnail, encoded, 640));
  },
  analyzeAudio(wasm, _, encoded) {
    return call(wasm.ff_analyze_audio, encoded);
  },
  subtitleTracks(wasm, _, encoded) {
    const { tracks } = call(wasm.ff_subtitle_tracks, encoded);
    for (const track of tracks) track.cues.sort((a, b) => a.start - b.start || a.end - b.end);
    return tracks;
  },
  diagnostics(wasm, { hasAudio }, encoded) {
    const { issues } = call(wasm.ff_video_issues, encoded);
    if (!hasAudio) return issues;
    try {
      issues.silence = call(wasm.ff_analyze_audio, encoded).silence;
    } catch (error) {
      issues.audioError = error.message;
    }
    return issues;
  },
  trim(wasm, { start, end }, encoded) {
    return mp4Result(call(wasm.ff_trim_mp4, encoded, start, end));
  },
  async concat(wasm, { files }, encoded) {
    try {
      call(wasm.ff_concat_add, encoded);
      for (const file of files) {
        call(wasm.ff_concat_add, encode(new Uint8Array(await file.arrayBuffer())));
      }
      return mp4Result(call(wasm.ff_concat_finish));
    } finally {
      wasm.ff_concat_clear?.();
    }
  },
  contactSheet(wasm, { count }, encoded) {
    if (!Number.isSafeInteger(count) || count < 1 || count > 24) {
      throw new Error("缩略图数量须在 1 到 24 之间。");
    }
    try {
      const { duration } = call(wasm.ff_player_open_bulk, encoded);
      const interval = duration > 0 ? duration / count : 5;
      const frames = [];
      for (let i = 0; i < count; i++) {
        const target = interval * i;
        if (target < (frames.at(-1)?.end ?? 0)) continue;
        const frame = pixels(call(wasm.ff_player_frame, target, 280));
        if (frame.eof) break;
        frames.push(frame);
        if (frame.end <= target) break;
      }
      if (!frames.length) throw new Error("该视频没有可生成缩略图的画面。");
      return { frames, interval, estimatedInterval: !(duration > 0) };
    } finally {
      wasm.ff_player_close?.();
    }
  },
  audio(wasm, { format, rate }, encoded) {
    const result = call(format === "flac" ? wasm.ff_encode_flac : wasm.ff_decode_audio, encoded, rate);
    return audioResult(result, format);
  },
  async processAudio(wasm, { format, rate, trim, fadeIn, fadeOut, normalize, target, ceiling, mixFile, mixWeight }, encoded) {
    const secondary = mixFile
      ? encode(new Uint8Array(await mixFile.arrayBuffer()))
      : "";
    const result = call(wasm.ff_process_audio, encoded, secondary, format, rate,
      trim, fadeIn, fadeOut, normalize, target, ceiling, mixWeight);
    return audioResult(result, format);
  },
  transcode(wasm, { codec }, encoded) {
    const result = call(wasm.ff_transcode_mp4, encoded, codec);
    return { blob: new Blob([decode(result.mp4)], { type: "video/mp4" }) };
  },
  playerOpen(wasm, _, encoded) {
    return call(wasm.ff_player_open, encoded);
  },
  playerFrame(wasm, { target }) {
    return pixels(call(wasm.ff_player_frame, target, 640));
  },
  playerSeek(wasm, { target }) {
    return call(wasm.ff_player_seek, target);
  },
  playerLocate(wasm, { target }) {
    return pixels(call(wasm.ff_player_locate, target, 640));
  },
};

function mp4Result({ mp4, start, end }) {
  return { blob: new Blob([decode(mp4)], { type: "video/mp4" }), start, end };
}

function audioResult(result, format) {
  return {
    blob: new Blob([decode(result[format])], { type: `audio/${format}` }),
    rate: result.sample_rate,
    channels: result.channels,
    duration: result.duration_seconds,
    processing: result.processing,
  };
}

// Serialize commands so a slow file read cannot replace a more recent source.
let pending = Promise.resolve();
self.onmessage = ({ data }) => {
  pending = pending.then(async () => {
    const { id, fileId, action } = data;
    try {
      const wasm = await engine;
      if (!data.file && (!source || source.fileId !== fileId)) {
        throw new Error("文件已切换，请重新运行工具。");
      }
      const file = data.file ?? source.file;
      const extras = action === "concat" ? data.files
        : action === "processAudio" && data.mixFile ? [data.mixFile] : [];
      checkMediaFiles(file, extras);
      if (data.file) {
        source = { file, fileId, encoded: encode(new Uint8Array(await file.arrayBuffer())) };
      }
      const result = await actions[action](wasm, data, source?.encoded);
      if (action === "playerOpen") source.encoded = "";
      const transfer = result.frames?.map((frame) => frame.rgba.buffer)
        ?? (result.rgba ? [result.rgba.buffer] : []);
      postMessage({ id, result }, transfer);
    } catch (error) {
      postMessage({ id, error: error.message });
    }
  });
};
