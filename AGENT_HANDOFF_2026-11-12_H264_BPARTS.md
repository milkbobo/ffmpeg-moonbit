# H.264 B 帧子分割（b_parts）

接续 B_RD/STREAM_RD，本轮 `b_parts~` opt-in 支持 B 宏块子分割 kinds 4..22：
16x8/8x16 双分割（九种 list 组合 × 两朝向全枚举）与 B_8x8（逐 8x8 组在
direct/L0/L1/Bi × 8x8/8x4/4x8/4x4 中共 13 种 sub 类型按 SAD+λ 位估计决策）。
批式（CAVLC/CABAC/CABAC RD）、流式、CLI（`--b-parts`，要求 `--b-slices`）全打通。
默认关闭，原有码流逐字节不变（B/GOP/CABACRD 钉值全过）。

核心机制（与 P 端「macroblock-entry 重置 + fill_part 回写」同纪律，但作用在
真 H264DecCtx 镜像上）：

- `h264_b_slot_reset` 把当前 MB 槽位重置为解码器逐图新 infos 的入口态
  （mv/mvd=0、ref=-1、direct=false）；子分割写端在它之上**按解码序回放**：
  b_direct(direct 组) → kind22 右侧组 2/10 号块 ref 隐藏(-2) → refs 写回
  （kind<22 逐 list 逐 part；kind22 只在 CABAC 走逐组 cache dance）→
  `h264_b_mvd_walk`（逐组 preamble：direct 组从兄弟块恢复隐藏 ref、inter 组
  写 2x2 ref；kinds 4..21 用 `pred_16x8/8x16`、kind 22 用 `pred_motion`，
  与 `h264_decode_b_mb` 的读序逐分支一致）→ 每部分 pred 后发 mvd 并
  `h264_write_back_part`。回放使每个 mvd 预测恰好看到解码器读时刻的邻居
  ——包括后继分割「未写回」槽位的 stale 值（median 里的 C/D 回退全一致）。
- mvd 可达域：commit 回放对每个 mvd 夹取 ±70 并把计划 MV 数组（BParts 的
  mvs）同步改为 pred+clip——镜像、码流、重建三方同一决策；CAVLC/CABAC
  两写端与 commit 走同一 walk，预测必然相同。
- CABAC 写端新增 `h264_cabacw_b_parts_type`（4-bin 后缀 + kinds 12..21 的
  第 5 bin，bits 映射 3..10→k-3、11→14、22→15、12..21→(k+4)>>1±1）与
  `h264_cabacw_b_sub_type`（ctx 36/37/38/39 的 13 分支树），均从解码端
  `h264_b_cabac_type`/`h264_b_sub_type` 逐分支转写。
- 决策：`eval_b_parts` = commit→`h264_b_compensate`→残差→CAVLC 干跑 +
  CABAC 定价（`price_b_bits` 对子分割分支免运动快照——写端自含回放，仅
  回滚 nz/cbp/qp/引擎）。B_8x8 逐组 ME（9 矩形 × 双 list）+ Bi 逐块 SAD。

验证：bparts 套件 7/7（CAVLC/CABAC/CABAC-RD 重建逐像素相等；流式逐字节
相等；确定性 + opt-in 门控；ffmpeg 仲裁钉值）；既有 B 7/7、GOP 4/4、
CABAC RD 6/6、CLI 10/10；P/stream/RC/VBV/DCT8 全绿；docker x264 native
oracle 34/34；ffref 42/42。**ffmpeg 9.0.2（nine-x264 镜像）零告警解码
CAVLC 与 CABAC 两条 b_parts 流，display 序 framemd5 六帧逐帧一致**
（ARBBPARTS/ARBBPARTSCABAC dump 路由钉值）。统计：两半滑动 fixture
19/48、四象限 fixture 43/48 的 B MB 走子分割，kind 22 (B_8x8) 真实选中
（stats.bpart_mbs/b8x8_mbs 断言 >0）。

沿用全部 MoonBit 技能；moonbit-c-binding 与 make-moonbit-c-bindings 用于
x264/ffref 原生 oracle 的容器化重跑边界复核。本轮未改 C ABI、未新增
vendoring；ASan 继承上一轮同一 C stub 记录。

既有宿主限制（与本轮无关，基线复现已确认）：`h264_enc_quant_wbtest` 触发
wasm "local count too large"（whitebox 包过大），blackbox 整包一次 spawn
超 Windows 命令行上限（os error 206）——均按文件分跑；native 套件在本机
需 MSVC，仍在容器内跑。

后续可继续：intra-in-B（kinds 23..48，框架同构）、B×VBV/ABR、流式宿主
分块读、子分割候选剪枝（现每 B MB 约 23 次候选评估）。
