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
  async probe(wasm, { file, fileId }) {
    source = { fileId, encoded: encode(new Uint8Array(await file.arrayBuffer())) };
    return call(wasm.ff_probe, source.encoded).probe;
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
  audio(wasm, { format, rate }, encoded) {
    const result = call(format === "flac" ? wasm.ff_encode_flac : wasm.ff_decode_audio, encoded, rate);
    return {
      blob: new Blob([decode(result[format])], { type: `audio/${format}` }),
      rate: result.sample_rate,
      channels: result.channels,
      duration: result.duration_seconds,
    };
  },
  async transcode(wasm, { file, codec }) {
    const encoded = encode(new Uint8Array(await file.arrayBuffer()));
    const result = call(wasm.ff_transcode_mp4, encoded, codec);
    return { blob: new Blob([decode(result.mp4)], { type: "video/mp4" }) };
  },
  async playerOpen(wasm, { file, fileId }) {
    source = { fileId, encoded: encode(new Uint8Array(await file.arrayBuffer())) };
    return call(wasm.ff_player_open, source.encoded);
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

// Serialize commands so a slow file read cannot replace a more recent source.
let pending = Promise.resolve();
self.onmessage = ({ data }) => {
  pending = pending.then(async () => {
    const { id, fileId, action } = data;
    try {
      const wasm = await engine;
      if (!data.file && source?.fileId !== fileId) {
        throw new Error("文件已切换，请重新运行工具。");
      }
      const result = await actions[action](wasm, data, source?.encoded);
      postMessage({ id, result }, result.rgba ? [result.rgba.buffer] : []);
    } catch (error) {
      postMessage({ id, error: error.message });
    }
  });
};
