// FFmpeg-MoonBit 浏览器演示（申报书⑤）。
// wasm 导出面见 ../demo/api/api.mbt：ff_probe / ff_cover / ff_thumbnail /
// ff_decode_audio，统一 {ok, error:{code,message}} JSON 信封；
// 二进制载荷以 U+0100 偏移编码过界（字节 b ↔ UTF-16 码元 b + 0x100）。

const $ = (id) => document.getElementById(id);
const status = $("status"), banner = $("banner");

let wasm = null;        // WebAssembly.Instance exports
let current = null;     // { name, encoded } 当前文件的 U+0100 编码与文件名

function setStatus(text, cls) {
  status.textContent = text;
  status.className = cls || "";
}
function showError(code, message) {
  banner.style.display = "block";
  banner.innerHTML = "";
  const c = document.createElement("code");
  c.textContent = code;
  banner.append(c, " " + message);
  banner.scrollIntoView({ behavior: "smooth", block: "nearest" });
}
function clearError() { banner.style.display = "none"; }

// ---- 二进制 ↔ U+0100 编码 ----
function encodeBin(u8) {
  const CH = 8192, parts = [];
  for (let i = 0; i < u8.length; i += CH) {
    const end = Math.min(i + CH, u8.length);
    const c = new Array(end - i);
    for (let j = i; j < end; j++) c[j - i] = u8[j] + 0x100;
    parts.push(String.fromCharCode.apply(null, c));
  }
  return parts.join("");
}
function decodeBin(s, u8) {
  for (let i = 0; i < u8.length; i++) u8[i] = s.charCodeAt(i) - 0x100;
  return u8;
}

// ---- wasm 加载 ----
async function loadWasm() {
  if (typeof WebAssembly !== "object") throw new Error("此浏览器不支持 WebAssembly");
  let bytes;
  try {
    bytes = await (await fetch("./api.wasm")).arrayBuffer();
  } catch {
    throw new Error("未找到 demo/api.wasm——先运行 scripts/build_demo.sh");
  }
  let mod;
  try {
    mod = await WebAssembly.compile(bytes, {
      builtins: ["js-string"], importedStringConstants: "_",
    });
  } catch {
    throw new Error("此浏览器不支持 WasmGC / JS String Builtins（需 Chrome ~130+ 或 Firefox 133+）");
  }
  const inst = await WebAssembly.instantiate(mod, {});
  return inst.exports;
}

// ---- 信封解析 ----
function call(fn, ...args) {
  const env = JSON.parse(fn(...args));
  if (!env.ok) throw Object.assign(new Error(env.error.message), { code: env.error.code });
  return env;
}

// ---- 面板渲染 ----
function hidePanels() {
  for (const id of ["metaPanel", "thumbPanel", "audioPanel"]) $(id).style.display = "none";
}
const KIND_ZH = { video: "视频", audio: "音频", subtitle: "字幕" };
const MEDIA_ZH = { video: "video", audio: "audio", subtitle: "data" };

function renderMeta(probe, name) {
  const f = probe.format;
  const rows = [
    ["文件", name],
    ["format_name", f.format_name],
    ["流数量", f.nb_streams],
    ["时长", f.duration != null ? f.duration.toFixed(3) + " s" : "未知"],
  ];
  const kv = $("formatKv");
  kv.innerHTML = "";
  for (const [k, v] of rows) {
    const kd = document.createElement("div"); kd.className = "k"; kd.textContent = k;
    const vd = document.createElement("div"); vd.textContent = v;
    kv.append(kd, vd);
  }
  const tbody = $("streamTable").querySelector("tbody");
  tbody.innerHTML = "";
  for (const s of probe.streams) {
    const tr = document.createElement("tr");
    const geom = s.codec_type === "audio"
      ? `${s.sample_rate} Hz · ${s.channels} ch`
      : `${s.width} × ${s.height}`;
    const cells = [s.index, KIND_ZH[s.codec_type] || s.codec_type, s.codec_name,
      geom, s.codec_type, s.has_extradata ? "有" : "无"];
    for (const c of cells) {
      const td = document.createElement("td");
      td.textContent = c;
      tr.append(td);
    }
    tbody.append(tr);
  }
  $("metaPanel").style.display = "block";
  return probe;
}

async function renderThumb(encoded) {
  const cover = call(wasm.ff_cover, encoded);
  const wrap = $("thumbWrap"), img = $("coverImg"), canvas = $("thumbCanvas");
  const note = $("thumbNote"), cap = $("thumbCap");
  wrap.style.display = "none";
  if (cover.cover !== null && cover.mime && cover.data) {
    const u8 = new Uint8Array(cover.data.length);
    decodeBin(cover.data, u8);
    img.src = URL.createObjectURL(new Blob([u8], { type: cover.mime }));
    img.style.display = "block"; canvas.style.display = "none";
    cap.textContent = `容器封面 · ${cover.mime} · ${u8.length.toLocaleString()} B`;
    wrap.style.display = "inline-block";
    note.textContent = "封面来自容器的元数据区（MP4 ilst/covr 或 MKV Attachments），未解码任何媒体流。";
    $("thumbPanel").style.display = "block";
    return;
  }
  // 无内嵌封面：解码视频首帧并缩放
  const th = call(wasm.ff_thumbnail, encoded, 320);
  const w = th.width, h = th.height;
  canvas.width = w; canvas.height = h;
  const ctx = canvas.getContext("2d");
  const imgd = ctx.createImageData(w, h);
  const px = imgd.data;
  for (let i = 0, j = 0; i < w * h * 3; i += 3, j += 4) {
    px[j] = th.rgb24.charCodeAt(i) - 0x100;
    px[j + 1] = th.rgb24.charCodeAt(i + 1) - 0x100;
    px[j + 2] = th.rgb24.charCodeAt(i + 2) - 0x100;
    px[j + 3] = 255;
  }
  ctx.putImageData(imgd, 0, 0);
  canvas.style.display = "block"; img.style.display = "none";
  cap.textContent = `视频首帧 · ${w} × ${h} · RGB24`;
  wrap.style.display = "inline-block";
  note.textContent = "首帧经纯 MoonBit 解码器（H.264/HEVC/VP9/AV1/MJPEG/PNG）解码，libswscale 移植（SwsRgbScaler，BT.601）缩放转 RGB。";
  $("thumbPanel").style.display = "block";
}

function renderAudioPanel(probe) {
  const audio = probe.streams.find((s) => s.codec_type === "audio");
  if (!audio) return;
  const kv = $("audioKv");
  kv.innerHTML = "";
  for (const [k, v] of [
    ["音频流", `#${audio.index} · ${audio.codec_name}`],
    ["参数", `${audio.sample_rate} Hz · ${audio.channels} ch`],
  ]) {
    const kd = document.createElement("div"); kd.className = "k"; kd.textContent = k;
    const vd = document.createElement("div"); vd.textContent = v;
    kv.append(kd, vd);
  }
  $("audioPanel").style.display = "block";
}

// ---- 文件处理 ----
async function handleFile(file) {
  if (!wasm || !current) return;
  clearError();
  hidePanels();
  if (file.size > 64 * 1024 * 1024) {
    setStatus(`文件 ${file.name}（${(file.size / 1048576).toFixed(1)} MB）超过 64 MB，浏览器内解码可能较慢`, "err");
  } else {
    setStatus(`读取 ${file.name}（${(file.size / 1024).toFixed(1)} KiB）…`);
  }
  const buf = new Uint8Array(await file.arrayBuffer());
  current = { name: file.name, encoded: encodeBin(buf) };
  const t0 = performance.now();
  let probe;
  try {
    probe = call(wasm.ff_probe, current.encoded).probe;
  } catch (e) {
    setStatus("");
    showError(e.code, e.message);
    return;
  }
  renderMeta(probe, file.name);
  setStatus(`元数据就绪（${(performance.now() - t0).toFixed(0)} ms）`);
  // 缩略图/封面与音频面板并行渲染
  try { await renderThumb(current.encoded); } catch (e) { /* 无视频流等：面板保持隐藏 */ }
  renderAudioPanel(probe);
}

async function downloadWav() {
  if (!current) return;
  const btn = $("wavBtn");
  const rate = parseInt($("rateSel").value, 10) | 0;
  btn.disabled = true;
  const label = btn.textContent;
  btn.innerHTML = '<span class="spin"></span>解码中…';
  const t0 = performance.now();
  try {
    const env = call(wasm.ff_decode_audio, current.encoded, rate);
    const u8 = new Uint8Array(env.wav.length);
    decodeBin(env.wav, u8);
    const blob = new Blob([u8], { type: "audio/wav" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = current.name.replace(/\.[^.]+$/, "") + ".wav";
    a.click();
    setStatus(
      `WAV 已生成：${env.sample_rate} Hz · ${env.channels} ch · ` +
      `${env.duration_seconds != null ? env.duration_seconds.toFixed(2) + " s" : "未知时长"} · ` +
      `${u8.length.toLocaleString()} B（${(performance.now() - t0).toFixed(0)} ms）`,
      "ok",
    );
  } catch (e) {
    showError(e.code, e.message);
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
}

// ---- 初始化 ----
const drop = $("drop");
drop.addEventListener("click", () => $("picker").click());
$("picker").addEventListener("change", (e) => {
  if (e.target.files[0]) handleFile(e.target.files[0]);
  e.target.value = "";
});
for (const ev of ["dragenter", "dragover"]) {
  drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add("hover"); });
}
for (const ev of ["dragleave", "drop"]) {
  drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove("hover"); });
}
drop.addEventListener("drop", (e) => {
  const f = e.dataTransfer.files[0];
  if (f) handleFile(f);
});
$("wavBtn").addEventListener("click", downloadWav);

loadWasm().then((exports) => {
  wasm = exports;
  current = { name: "", encoded: "" };
  setStatus("wasm 就绪——拖入一个媒体文件开始");
}).catch((e) => {
  setStatus(e.message, "err");
});
