import { PLAYBACK_TIMEOUT } from "./media-task.js";

export class WasmPlayer {
  constructor(file, fileId, canvas, controls, callbacks) {
    this.canvas = canvas;
    this.controls = controls;
    this.callbacks = callbacks;
    this.fileId = fileId;
    this.sound = new Audio();
    this.sound.addEventListener("loadeddata", () => {
      if (!this.closed && this.sound.src) {
        this.controls.mute.disabled = false;
        this.syncSound();
      }
    }, { once: true });
    this.sound.addEventListener("error", () => {
      if (!this.closed) this.callbacks.audioUnavailable();
    });
    this.position = 0;
    this.seekVersion = 0;
    this.soundVersion = 0;
    this.pending = new Map();
    this.requestId = 0;
    this.worker = new Worker("./worker.js", { type: "module" });
    this.worker.onmessage = ({ data }) => {
      if (data.type === "unavailable") this.fail(data.error);
      const request = this.pending.get(data.id);
      if (!request) return;
      this.pending.delete(data.id);
      clearTimeout(request.timer);
      if (data.error) request.reject(new Error(data.error));
      else request.resolve(data.result);
    };
    this.worker.onerror = () => this.fail("Wasm 播放线程无法启动。");
    this.worker.onmessageerror = () => this.fail("无法读取播放线程返回的画面。");
    this.load(file);
  }

  send(action, options) {
    if (this.closed || this.error) return Promise.reject(new Error(this.error || "播放器已关闭。"));
    const id = ++this.requestId;
    return new Promise((resolve, reject) => {
      this.worker.postMessage({ id, fileId: this.fileId, action, ...options });
      const timer = setTimeout(() => this.fail("视频解码超时，已停止播放线程。"), PLAYBACK_TIMEOUT);
      this.pending.set(id, { resolve, reject, timer });
    });
  }

  async load(file) {
    try {
      const { duration } = await this.send("playerOpen", { file });
      const first = await this.send("playerFrame", { target: 0 });
      if (this.closed) return;
      if (first.eof) throw new Error("没有可解码的视频帧。");
      this.duration = duration;
      this.controls.seek.max = duration ?? 0;
      this.draw(first);
      if (!this.seeking) {
        this.updateTime(0);
        this.updateButtons();
        this.prefetch();
      }
    } catch (error) {
      this.fail(error.message);
    }
  }

  setAudio(blob) {
    if (this.closed) return;
    this.soundUrl = URL.createObjectURL(blob);
    this.sound.src = this.soundUrl;
  }

  syncSound() {
    const sound = this.sound;
    if (!sound.src || sound.readyState < 2 || !this.playing || this.buffering) return;
    const position = this.clock();
    if (position < sound.duration) {
      sound.currentTime = position;
      const version = ++this.soundVersion;
      sound.play().catch(() => {
        if (!this.closed && version === this.soundVersion) this.callbacks.audioUnavailable();
      });
    }
  }

  toggleMute() {
    this.sound.muted = !this.sound.muted;
    this.controls.mute.textContent = this.sound.muted ? "取消静音" : "静音";
    this.controls.mute.setAttribute("aria-pressed", String(this.sound.muted));
  }

  clock() {
    if (!this.playing || this.buffering) return this.position;
    return Math.min((performance.now() - this.startTime) / 1000, this.frame.end);
  }

  updateTime(time) {
    if (this.scrubbing) return;
    this.controls.seek.value = time;
    this.showTime(time);
  }

  showTime(time) {
    const minutes = Math.floor(time / 60);
    const seconds = String(Math.floor(time % 60)).padStart(2, "0");
    this.controls.time.textContent = `${minutes}:${seconds}`;
    this.callbacks.timeChanged?.(time);
  }

  previewSeek(time) {
    this.scrubbing = true;
    this.showTime(time);
  }

  cancelPreviewSeek() {
    this.scrubbing = false;
    this.updateTime(this.seeking ? this.seekTarget : this.clock());
  }

  draw(frame) {
    const canvas = this.canvas;
    if (canvas.width !== frame.width || canvas.height !== frame.height) {
      canvas.width = frame.width;
      canvas.height = frame.height;
    }
    canvas.getContext("2d").putImageData(new ImageData(frame.rgba, frame.width, frame.height), 0, 0);
    const first = !this.frame;
    this.frame = { start: frame.start, end: frame.end };
    if (first) this.callbacks.ready(frame.width, frame.height, this.duration);
  }

  updateButtons() {
    this.controls.play.disabled = !this.frame || this.seeking || !!this.error;
    this.controls.play.textContent = this.playing ? "暂停" : this.ended ? "重播" : "播放";
    this.controls.start.hidden = this.controls.play.disabled || !!this.playing;
    this.controls.start.textContent = this.ended ? "重播视频" : "播放视频";
    this.controls.seek.disabled = !this.duration || !this.frame || !!this.error;
  }

  play() {
    if (this.ended) {
      this.seek(0, true);
      return;
    }
    this.startTime = performance.now() - this.position * 1000;
    this.playing = true;
    this.syncSound();
    this.updateButtons();
    this.tick();
  }

  pause() {
    if (!this.playing) return;
    this.position = this.clock();
    this.playing = false;
    this.stopSound();
    clearTimeout(this.timer);
    this.setBuffering(false);
    this.updateTime(this.position);
    this.updateButtons();
  }

  stopSound() {
    this.soundVersion++;
    this.sound.pause();
  }

  setBuffering(buffering) {
    if (!!this.buffering === buffering) return;
    this.buffering = buffering;
    this.callbacks.buffering(buffering);
  }

  async prefetch() {
    const version = this.seekVersion;
    try {
      // Keep one decoded frame ready. Decoding to a wall-clock target can
      // skip increasingly large batches when the decoder is running slowly.
      const frame = await this.send("playerFrame", { target: -1 });
      if (this.closed || version !== this.seekVersion) return;
      this.nextFrame = frame;
      if (this.buffering) this.tick();
    } catch (error) {
      if (version === this.seekVersion) this.fail(error.message);
    }
  }

  tick() {
    if (!this.playing || this.closed) return;
    const position = this.clock();
    this.updateTime(position);
    if (position >= this.frame.end - 0.001) {
      if (!this.nextFrame) {
        this.position = this.frame.end;
        this.setBuffering(true);
        this.stopSound();
        return;
      }
      if (this.nextFrame.eof) {
        this.pause();
        this.ended = true;
        this.updateButtons();
        return;
      }
      const stalled = this.buffering;
      this.draw(this.nextFrame);
      this.nextFrame = null;
      if (stalled) {
        this.startTime = performance.now() - this.frame.start * 1000;
        this.setBuffering(false);
        this.syncSound();
      }
      this.prefetch();
    }
    const delay = (this.frame.end - this.clock()) * 1000;
    this.timer = setTimeout(() => this.tick(), Math.max(4, Math.min(delay, 50)));
  }

  async seek(target, resume = this.playing || this.resumeAfterSeek) {
    this.pause();
    const version = ++this.seekVersion;
    this.nextFrame = null;
    this.scrubbing = false;
    this.seeking = true;
    this.resumeAfterSeek = resume;
    this.updateButtons();
    const time = Math.min(target, Math.max(0, (this.duration ?? target) - 0.001));
    this.seekTarget = time;
    this.updateTime(time);
    this.callbacks.seeking(time);
    try {
      let frame = await this.send("playerSeek", { target: time });
      while (!this.closed && version === this.seekVersion && Number.isFinite(frame.progress)) {
        this.callbacks.seeking(time, frame.progress);
        frame = await this.send("playerLocate", { target: time });
      }
      if (this.closed || version !== this.seekVersion) return;
      if (frame.eof) throw new Error("没有可解码的视频帧。");
      this.draw(frame);
      this.position = Math.min(time, frame.end);
      this.ended = false;
      this.seeking = false;
      this.resumeAfterSeek = false;
      this.updateTime(this.position);
      this.updateButtons();
      this.callbacks.seeked();
      this.prefetch();
      if (resume) this.play();
    } catch (error) {
      if (version === this.seekVersion) this.fail(error.message);
    }
  }

  fail(message) {
    if (this.closed || this.error) return;
    this.error = message;
    this.stopWorker(message);
    this.pause();
    this.updateButtons();
    this.callbacks.error(message);
  }

  close() {
    this.pause();
    this.closed = true;
    this.stopWorker("播放器已关闭。");
    this.sound.removeAttribute("src");
    this.sound.load();
    if (this.soundUrl) URL.revokeObjectURL(this.soundUrl);
  }

  stopWorker(message) {
    this.worker.terminate();
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error(message));
    }
    this.pending.clear();
  }
}
