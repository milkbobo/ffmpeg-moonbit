# H.264 §417 收口：全族钉值债清偿

接续 §417 系列十七轮交接。本轮对整个 H.264 编码器测试族做完整重跑，
发现并清偿系列期间从未重跑的七个文件共 15 处旧黄金值（决策变更遗留，
非编码器缺陷），全部经真实 FFmpeg 仲裁后重钉，随后统一提交。

## 钉值债成因

§417 各轮的门是定向文件（当轮新增 + 邻近回归），以下文件在色度 RD /
共享路径修正改决策后从未重跑：bi8（mode0/1/2）、bintra（bintra+bi4）、
bparts（CAVLC/CABAC）、cabacrd（4 项：流 md5×3 + 尺寸 + 帧钉）、
weightp、dct8（4 项）、vbv（CABAC tight P4/B3）。vbv 的钉虽在
MULTIREF_VBV 轮重钉过，但后续轮次（周期/在线线）的时序与决策修正
再次改变了 CABAC tight 流的 P4/B3 两帧。

## 仲裁流程（可复现）

1. 两批 29 个编码器测试文件 + CLI 全量 release 跑，收集 expect-test
   差分（实际值）与 `ARB*:`/`VBV*:`/`WPARB:` 转储行。
2. 转储写 .264（.scratch/arb417），docker ffmpeg-moonbit-ffref:nine-x264
   `-v warning -threads 1 -f framemd5` 逐条解码：18 条流全部退出 0、
   stderr 空（零告警）。
3. FFmpeg framemd5 与本仓解码器打印值逐帧核对全等（B 流按
   coding↔display 序映射：coding=[0,2,1,4,3,(5)]）后才重钉；钉值一律
   取 FFmpeg 输出，不取本地解码快照。
4. cabacrd 三条无转储流补永久转储打印（ARBCRDALLON/ARBCRDOFF/
   ARBCRDCOMBO）；weightp 的 WPARB 转储打印移到钉值循环之前，使
   转储在钉值失败时仍然可得。流级 md5 钉（cabacrd）与文件字节 md5
   交叉验证一致。

## 定性说明

- cabacrd :12 用 fixture(96,64,4)（非 6 帧）——4 帧流 4 个图像 NAL，
  ffmpeg 4 帧 CLEAN；早期「只有 3 图像 NAL」是自制 annexb 扫描器在
  4 字节起始码处漏计，以 ffmpeg 为准。
- cabacrd :263 与 cabac_test:464 是同参数流（§406 后 cabac_rd 默认开），
  两文件钉值序列已一致，互为独立佐证。
- bi8 mode1（CABAC）与 mode0（CAVLC）流字节不同但解码帧 md5 逐帧
  相同（同决策不同熵编码）；mode2（rd）B 帧确有不同决策——三者分别
  仲裁。

## 验证

- 最终门：两批 29 文件 + vbv_order_wbtest + video_encoder + CLI 25/25
  全绿（数字见 doc/PORTING_HISTORY §417）。
- moon check --target wasm --deny-warn、git diff --check 通过。
- 本轮无编码器算法改动；仅测试钉值、两处转储打印增补/前移。

```text
moon test --target wasm --release <两批 29 文件> --no-render
moon test --target wasm --release -p cmd/encode-h264 --no-render
moon check --target wasm --deny-warn
```
