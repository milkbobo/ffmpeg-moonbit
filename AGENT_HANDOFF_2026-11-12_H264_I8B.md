# H.264 I8x8-in-B 收口（§400）——b_slices × dct8x8 解禁

接续 BI8 基础设施轮，本轮解除 `b_slices × dct8x8` 互斥并把 B 线最后一项
组合收口。**真因不在 B 写端，而在 B 序列的 P 编码器**——上一轮交接的
归因（「CABAC 的 B 帧 8x8DCT 上下文与 ffmpeg 分歧」）是症状不是根因。

## 根因

`h264_encode_frames_b` 的 `new_p_encoder` 把 `dct8x8` 硬编码为 `false`，
注释声称「B 序列 P 帧保持 4x4 变换，故写端不发 inter flag 位」。但
`dct8x8_allowed` 是**解码端从 PPS 的 `transform_8x8_mode` 推导**的
（FFmpeg `h264_cabac.c:2347`：`dct8x8_allowed && (cbp&15) && !IS_INTRA`），
与写端字段无关。PPS 说 1，解码器就在 cbp bins 与 mb_qp_delta 之间读
`transform_size_8x8_flag`，写端却不发 → **从第一个 P 图像 MB0 起整片
失步**（本地解码器报 CABAC bytestream overread，ffmpeg 报 MB 4 1 /
MB 5 2 bytestream 负值）。

修复 = 透传真实 `dct8x8`。P 帧遂走 §385/§387 已验证的完整 8x8DCT 路径
（inter 8x8 残差 + I8x8-in-P 候选），无需新写任何残差逻辑。

教训：**给写端加「条件位」时，发射条件必须逐字对齐解码端的读取条件，
而解码端的条件往往来自参数集而非写端的局部开关。** 上一轮 BI8 交接已
记录过同型教训（inter flag 发射门漏了 PPS 开关），这次是同一纪律在
**跨图像构造点**上的复发：B 序列里 P 编码器的构造参数必须与序列级
PPS 一致，不能按「这条路径用不到」就地写死。

## 定位手段（bin 级 zip，可复用）

临时在 CABAC 读写两侧原语打点，zip 首个分歧 bin：

- 读侧 `libavcodec/cabac.mbt`：`get_cabac`（ctx）、`get_cabac_bypass`
  （-1）、`get_cabac_bypass_sign`（-1）、`get_cabac_terminate`（-3）。
- 写侧 `libavcodec/h264_enc_cabac.mbt`：`H264CabacEnc::decision`（ctx）、
  `bypass`（-1）、`terminate`（-3）。
- 每 MB 标记：读侧 `h264_decode_mb_cabac` 入口、写侧 I/P/B 三个 MB 循环。
- 格式 `W ctx=N bit=B` / `R ctx=N bit=B` / `M W mb=… st=… fn=…`，
  比较时**剥掉 W/R 前缀**再逐 bin 对齐。

**坑：`bypass_sign` 的 mask 与 bin 值极性相反。**
`mask = low >> 31`，mask=-1 对应 bin **0**、mask=0 对应 bin **1**
（因为 `get_cabac_bypass` 是 `low < range → 0`，而 bypass_sign 先减
range 再取符号）。打点须写 `if mask == 0 { 1 } else { 0 }`，否则每个
符号位都假分歧（本轮第一次 zip 即在 bin 67 撞上这个假阳性）。

修复后 76182/76182 bins 逐 bin 对齐、本地解码零 overread。收口后全部
钩子移除（热路径不留调试分支）。

## 其余改动

- **BI8 候选解禁**：`decide_b_mb` 末尾去掉 `&& !self.cabac_on` 门
  （CABAC 写端 `write_b_mb_i8_syntax_cabac` 与 `price_b_bits` 定价链
  上一轮已备齐）；清除该写端遗留的调试 `println("I8ENC-C …")`。
- **`cabac_on` 字段删除**：解禁后无读取点，按「无兼容包袱」原则整字段
  删除，7 处构造点同步（h264_encode_p/b、h264_enc_cabac、h264_enc_stream）。
- **流式透传**：`H264StreamEncoder` 增 `dct8x8` 字段与
  `open(dct8x8~=false)`；SPS 选择镜像批式（b_slices → `h264_enc_sps_rbsp_b`
  的 dct8x8 变体；cabac → high/main；否则 `h264_enc_sps_rbsp(dct8x8~)`），
  PPS 两侧透传；`stream_idr`/`stream_p`/`stream_b` 三处构造点接
  `self.dct8x8`。
- **CLI**：`encode-h264` 增 `--dct8x8`（批式双熵 + 流式全打通），
  usage 与 README 选项表补行。
- 删除两处过时的「组合必须被拒绝」断言（`h264_enc_b_test.mbt` /
  `h264_enc_bintra_test.mbt`）。

## 验证

- 新增 `libavcodec/h264_enc_bi8_test.mbt` **6/6**：三模式
  （CAVLC/CABAC/CABAC-RD）重建不变式 + `i8p_mbs>0` + 滤波解码；流式与
  批式三模式逐字节相等；确定性双跑 + opt-in 门控（关时
  `i8_mbs==i8p_mbs==0` 且流长变化）；ffmpeg 钉值。
- **docker ffmpeg 9.0.2（nine-x264 镜像）零告警**，三模式 × display 序
  六帧 framemd5 全部钉值（ARBBI8V/ARBBI8C/ARBBI8R 路由），18 帧经
  `scripts/check_md5.mbtx` 与 docker 输出逐帧核对一致。CABAC 流
  6766 → 5972 B（BI8 胜出，48/48 B MB 选 I8x8）。
- CLI 新增 `--dct8x8` 双熵 × b_slices 四组合流式/批式逐字节 + High
  profile SPS `profile_idc=100` 断言，CLI **11/11**。
- B 线回归 38/38、其余编码器套件 77/77；libavcodec blackbox 六批
  **206/206**、whitebox 十批 **545/545**；libavformat 693/693
  （含 whitebox 五批 448）、libavutil 61/61、libswscale 48/48、
  libswresample 19/19、CLI 11/11。**已跑合计 1583 项全绿**。
- `moon check --target all` 0 错误（仅既有 v128 unused_package 警告）；
  `moon fmt` 干净。

## 本轮未做完（按用户指示停止）

1. **libavcodec 各向量/内核子包的 wasm 扫尾**（`aac_*_vectors`、
   `av1_*_vectors`、`lf_kernel`、`lr_kernel`、`itx_probe` 等约 37 个
   子包）跑到一半被叫停。这些包与本轮改动（H.264 编码器）无交集，
   但**未留下全绿证据**，下轮补跑：
   `for D in libavcodec/*/; do ... moon test --target wasm-gc "$D"; done`
   （排除 native-only 的 `x264/`）。
2. **docker native oracle 未重跑**：`libavcodec/x264`（上轮 34/34）与
   `ffref`（上轮 42/42）。本轮未改 C ABI，预期不变，但需实跑确认。
3. **未提交、未 push**。工作区含本轮 §400 改动**与前序未提交的
   §395–§399 + BI8 基础设施**（同一批文件交织，难以拆分提交）。
   建议一次性提交为「B 线收口 §395–§400」，或先按文件核对 §395–§399
   的完整性再决定。`git status` 另有前序遗留的 `.scratch_*`、`*.md5`
   等散落产物，**勿 `git add -A`**，按精确路径添加。
4. PORTING_HISTORY 已补 §395–§400（§395–§399 为前序增量的追记，
   内容取自各自交接文档）、README H.264 行已补 B 线收口段、
   `cmd/encode-h264/README.md` 已补 `--dct8x8` 行。

## 工具面（新增，可复用）

- `scripts/extract_dump.mbtx LOG TAG OUT`：测试日志的 `TAG:逗号字节`
  dump → 裸流文件。
- `scripts/check_md5.mbtx LOG TAG FFMD5`：本地 `TAGMD5:` 行 vs docker
  framemd5 逐帧核对。

两者把「dump → 外部仲裁 → 钉值」闭环脚本化，取代以往的一次性 python
one-liner。

## 宿主限制（既有，非本轮引入）

- libavcodec blackbox **整包一次 spawn 超 Windows 命令行上限**
  （os error 206），按文件分批跑（blackbox 11 文件/批、whitebox
  20 文件/批均验证可行）。
- `moonbitlang/async@0.22.7` 与本机 core 不兼容
  （`Cannot find import 'moonbitlang/core/async'`），**既有 async
  `.mbtx` 脚本同样无法运行**，故本轮编排用直接分批命令而非 async 脚本。
  写自动化脚本前先确认 async 可用，否则用同步 `.mbtx`（仅 `@fs`/`@env`）
  或直接命令。

## 剩余

1. 流式宿主分块读（WASM 文件系统无分块读，输入缓冲仍整文件）。
2. x264 HRD 逐字段对拍（B 流的 pic_timing/HRD 语义已在 AU 层落地）。
3. B 线各 opt-in 转正（`b_slices`/`b_parts`/`intra_in_b`/
   `intra4x4_in_b`/`dct8x8`/`cabac_rd`）——需重钉全部仲裁钉值与
   PSNR/字节门。
4. `H264EncStats` 的 B-intra 计数口径：BI4→`i4p_mbs`、BI8→`i8p_mbs`
   沿用 P-slice 计数器（字段文档写的是「inside P slices」），语义上
   宜另立 B 侧计数或改文档；本轮未动以免破坏既有钉值。

## 权威文件

- `libavcodec/h264_encode_b.mbt` — `new_p_encoder` 的 dct8x8 透传（根修）、
  `decide_b_mb` 的 BI8 候选门、`write_b_mb_i8_syntax_cabac`
- `libavcodec/h264_enc_stream.mbt` — `H264StreamEncoder` 的 dct8x8 全链
- `libavcodec/h264_encode_p.mbt` / `h264_enc_cabac.mbt` — 互斥删除、
  `cabac_on` 字段删除
- `cmd/encode-h264/options.mbt` / `main.mbt` / `README.md` — `--dct8x8`
- `libavcodec/h264_enc_bi8_test.mbt` — 6 项黑盒
- `PORTING_HISTORY.md` §395–§400 / `README.md` H.264 行