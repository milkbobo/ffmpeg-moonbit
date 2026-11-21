export const MAX_MEDIA_BYTES = 64 * 1024 * 1024;
const MAX_BATCH_BYTES = 96 * 1024 * 1024;
export const MAX_CLIPS = 8;
export const PLAYBACK_TIMEOUT = 20_000;

export function checkMediaFiles(primary, extras = []) {
  if (extras.length >= MAX_CLIPS) throw new Error("一次最多处理 8 个片段。");
  let total = 0;
  for (const file of [primary, ...extras]) {
    if (!file || !Number.isSafeInteger(file.size) || file.size <= 0) {
      throw new Error("请选择非空媒体文件。");
    }
    if (file.size > MAX_MEDIA_BYTES) throw new Error("单个媒体文件不能超过 64 MiB。");
    total += file.size;
    if (total > MAX_BATCH_BYTES) throw new Error("同一任务的输入总量不能超过 96 MiB。");
  }
}

export function runMediaTask(action, options = {}, signal) {
  return new Promise((resolve, reject) => {
    signal?.throwIfAborted();
    const worker = new Worker("./worker.js", { type: "module" });
    const timeout = action === "transcode" ? 120_000 : ["probe", "init"].includes(action) ? 20_000 : 60_000;
    const timer = setTimeout(() => finish(new Error("处理超时，已停止后台任务。")), timeout);
    let finished = false;
    function finish(error, result) {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      worker.terminate();
      if (error) reject(error);
      else resolve(result);
    }
    function abort() {
      finish(signal.reason || new DOMException("已取消处理。", "AbortError"));
    }
    signal?.addEventListener("abort", abort, { once: true });
    worker.onerror = () => finish(new Error("媒体处理线程异常退出。"));
    worker.onmessageerror = () => finish(new Error("媒体处理结果无法读取。"));
    worker.onmessage = ({ data }) => {
      if (data.type === "unavailable" || data.error) finish(new Error(data.error));
      else if (data.type === "ready" && action === "init") finish();
      else if (data.id === 1) finish(null, data.result);
    };
    if (action !== "init") {
      try {
        worker.postMessage({ id: 1, action, ...options });
      } catch (error) {
        finish(error);
      }
    }
  });
}
