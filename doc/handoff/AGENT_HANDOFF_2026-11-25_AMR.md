# AMR-NB / AMR-WB 接手（2026-11-25）

## 最新接手状态

本会话（「继续迁移常用音频格式」第三片）完成 AMR-WB 解码器移植，并把 AMR-NB / AMR-WB
接入统一播放 API、MP4/3GP 映射与 CLI / demo。**工作区改动尚未提交**（仓库约定：
仅在用户明确要求时提交）。记录见 `doc/PORTING_HISTORY.md` §514–§515。第四片（ADPCM）
见 `AGENT_HANDOFF_2026-11-25_ADPCM.md`，同样未提交。

### 已完成

- `libavcodec/amrwb.mbt` / `amrwb_frame.mbt` / `amrwb_tables.mbt`：移植 `amrwbdec.c`
  全部路径（9 个模式），表由 `scripts/gen_amrwb_tables.py` 生成（重排表按
  `AMRWBFrame` 的 uint16 布局展开 `AMR_BIT` / `AMR_OF`）。
- `libavcodec/amr.mbt`：新增 `amr_f32`（binary32 舍入）；`ff_amr_set_fixed_gain`
  结果、激励能量、激励截断前的乘加按 float 舍入——修掉了 AMR-NB 既有的
  4.75k / 7.4k 对 FATE 偏 29 / 11 LSB 的问题（现在八个模式 ≤ 2）。
- `libavformat/rawaudio.mbt`：`av_amr_open` 识别 `#!AMR-WB`，codec 名改为
  `amrnb` / `amrwb`，多声道签名报错；`mov.mbt` 对 `samr` / `sawb` 强制单声道
  与 8000 / 16000 Hz；`codec_tags.mbt` 映射 `samr` / `sawb`。
- `playback.mbt`：`Source::Amr`，`AudioDec::AmrNb` / `AmrWb`，open / next_packet /
  duration / dump 时基 / decode 全部接通。
- `scripts/amr_c_ref/`：本机 gcc 编译的 C 参照程序（Docker 起不来时的替代）；
  `scripts/gen_amr_fixtures.py` 生成 `libavformat/amrwb_realdata_test.mbt`、
  `amrwb_realdata_2_test.mbt`、`amrnb_realdata_test.mbt`（19 项，含 `samr` 3GP
  与裸 WB 流），wasm 与 wasm-gc 双后端通过；`amr_realdata_wbtest.mbt` 同步更新。
- README（能力表加 AMR 行、demo 导入说明）、`doc/PORTING_HISTORY.md` §514–§515、
  `doc/agent.md` §6（C 参照程序、float 边界、黑盒测试文件命名、stash pop 的
  CRLF）、体积探针重新生成（666 个公开函数）、demo 分流正则加 `amr|awb`。

### 验证与接续

```powershell
moon check --no-render
moon test libavformat/amrwb_realdata_test.mbt --target wasm --no-render
moon test libavformat/amrwb_realdata_2_test.mbt --target wasm --no-render
moon test libavformat/amrnb_realdata_test.mbt --target wasm --no-render
moon test libavformat/amr_realdata_wbtest.mbt --target wasm --no-render
moon test libavformat/sipr_realdata_test.mbt --target wasm --no-render
python scripts/generate_wasm_size_probe.py
```

重新生成夹具（需要 gcc 与上级 FFmpeg 源码树）：`python -I scripts/gen_amr_fixtures.py libavformat`。

1. 对 FATE 的口径：AMR-NB 八个模式 ≤ 2 LSB；AMR-WB 六个模式 ≤ 1，6k60 / 19k85 /
   23k05 / 23k85 不超过 C 解码器自身的偏差（13 / 22 / 38 / 22）。MoonBit 对 C 参照
   六个模式 ≤ 1.4 LSB，其余在个别帧的截断边界后到 4.5–26 LSB；再往 float 仿真
   的方向走不会收敛（§514）。
2. 候选后续：WAV 里的 ADPCM（MS / IMA，常用且 C 为定点可位级对拍）、Speex（上一轮
   盘点的候选，需 Ogg Speex 头与 speexdec.c 约 1600 行浮点）、WMA Pro / Lossless。
3. Docker 本会话始终没起来；需要 docker 参照时（如 `linuxserver/ffmpeg` 的整链
   输出）先 `Start-Process` Docker Desktop 再轮询 `docker info`，或继续用
   `scripts/amr_c_ref/` 的做法给新解码器搭 C 参照。
4. 提交分片建议：(1) AMR-WB 解码器 + 表 + 表脚本；(2) 裸流 / MP4 映射 / 播放 API
   接线 + `amr_f32` + 测试 + 夹具脚本 + C 参照程序；(3) 文档 + 探针 + demo。
   `libavcodec/av1_decode3.mbt` / `av1_decode4.mbt` / `av1_enc_key_tile.mbt` 与一批
   `git status` 幻影 M（`git diff` 为空）不纳入。
