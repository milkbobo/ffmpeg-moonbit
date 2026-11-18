# H.264 B 线正确性收口（§405-§409）——交接文档

接续 AGENT_HANDOFF_2026-11-12_H264_PROMOTE.md（其使命——六开关转正及
正确性收口——已完成，本文是其收官总结 + 下一片入口）。工作树干净，
全部已提交。

## 当前仓库状态（2026-11-13，master，全部已提交）

```
416c570 fix: H.409 Bug C——decide 试价污染运行 QP 链（CAVLC prev_qp / CABAC
         mirror.qscale+last_qscale_diff），快照还原扩展至四状态
2c1bc8a docs: 409 交接——Bug C 已修，B 线正确性收口
68eb200 docs: Bug C 深挖——根因收窄到 B1 MC 输入差异
535e64a fix: H.407 补验——dqp_mbs 污染修复 + ffmpeg 逐钉复核 9 流全 MATCH
         + 遗漏五族补钉
c5d7961 feat: H.406 六开关默认转正（B 线+8x8DCT+CABAC 计价全开为默认）
0a49bbc fix: H.408 AQ×CABAC 双 bug（IDR I8 mb_qp + B mirror qps_arr[e]）
280363e feat: H.402 --stream native 分块宿主 I/O + ASan 探针
100addf feat: H.403 B 线组合正确性 + x264 帧级 C 仲裁探针
544cd75 feat: H.404 收尾三件（EncStats B-intra 口径等）
```

origin 落后本地若干提交（**未 push**，push 需用户点名）。

## 六开关现状（§406 起）

`b_slices` / `b_parts` / `intra_in_b` / `intra4x4_in_b` / `dct8x8` /
`cabac_rd` 在三个入口（`h264_encode_frames` / `h264_encode_frames_cabac` /
`H264StreamEncoder::open`）**默认全部 true**。配套语义：

- 单帧序列：`b_slices` 自动降级为 I-only（原「needs 2 frames」报错删）。
- 无 CABAC：`cabac_rd` 静默 no-op（原报错删）。
- 流式子旗标随 `b_slices=false` 降级（原三条 requires 报错删）。
- CLI：正向旧拼法保留为 no-op，七枚 `--no-*` 反开关；`--stream`×码控
  互斥保留。
- B 序列 SPS 在 VBV 下写 VUI/HRD（§406 补的既有缺口）。

## 正确性收口的全貌（§405-§409 修掉的五个真 bug）

统一模式：**decide 试价的 dry-run 写出会推进一切「真实写出才该推进」
的编码器状态**。`decide_b_mb` 现在快照/还原四状态：

1. `stats.dqp_mbs`（§407，AQ 下 22→77 膨胀）
2. `self.prev_qp`（§409，CAVLC：B_Direct+cbp=0 不写 dqp，试价基准
   泄漏 → 解码器 dequant QP 链 51→51→57 回绕 5）
3. `mirror.qscale`（§409，CABAC 同类）
4. `mirror.last_qscale_diff`（§409）

外加真实写出前的三字段预清（§405/§408：`chroma_mode` /
`transform_8x8` / `intra4x4`——mirror infos 跨 P/B 图复用，试价残留
污染 ctx-64/ctx-399 邻居推导），以及两个非试价 bug：

- Bug A（§408）：`H264CabacIEnc::encode_luma_i8` 用 `self.p.qp` 而非
  AQ 后的 `self.mb_qp`（每 AQ 调整的 I8x8 宏块重建 ±1）。
- Bug B（§408）：`h264_b_mirror_new` 收基础 `qp~` 而非 `qps_arr[e]`
  （ABR/VBV 下 B 图 AQ dqp 基准错位）。

## 验证状态

- **wasm 全族 143 + CLI 16 全绿**（族清单与命令见 doc/agent.md §2——
  wasm-only 约定：不主动跑 docker native/x264/ffref）。
- `moon check --target wasm --deny-warn` 干净；`moon info` 无 .mbti
  变化。
- ffmpeg 逐钉复核：§406 重钉的 7 条流 36 帧 + i4p 双流经
  `ffmpeg -f framemd5` 全 MATCH（§407）。
- **docker native / x264(38) / ffref 未跑**（Docker Desktop 本机反复
  500；上次成功 native 记录 = §407 前的 65/65 + x264 38/38，此后仅
  MoonBit 改动）。用户点名时按小批 + timeout 跑。

## 已钉死的测试资产

- `h264_enc_combo_test.mbt`：28 组合矩阵 + BParts(5) 回归
  （bi8 夹具）。
- `h264_enc_b_test.mbt`：all-on cabac recon 不变式（扫盒夹具）。
- `h264_enc_rc_test.mbt` / `h264_enc_vbv_test.mbt`：qp51×strength6×
  双熵 recon 不变式（§409 回归）。
- ffmpeg 仲裁钉值全部经 framemd5 复核；dump 路由（ARB22/ARBCABAC/
  ARBB/RCARB/RCCARB/ARBBRC/I4ARB/I4CARB）保留在测试内可复跑。

## 方法论沉淀（本线最重要的可复用资产）

1. **试价污染模式**：每加一个候选/工具，先问「这个写出路径动了哪些
   真实写出才该动的状态」——快照/还原或预清。B 线五个 bug 里三个
   （§407 dqp_mbs、§409 prev_qp、§409 mirror.qscale）都是它。
2. **bin 级对拍规程**：编码 `H264CabacEnc::decision`/`bypass` 与解码
   `CabacContext::get_cabac`/`get_cabac_bypass_sign` 全部打点（漏
   bypass_sign 会假分歧）；(ctx,bit) 全量对拍而非 ctx 序列；干跑计价
   混入用包级门控标志剔除。
3. **探针比对域 = 断言域**：luma-only vs yuvp md5、源像素冒充 recon
   都坑过；先看断言在比什么，探针就比什么。
4. **普查规程**：`moon test -f` 匹配测试名不是文件名——先
   `grep -hoE '^test "[^"]+"'` 枚举 stem 再逐族跑（§406 漏了五族）。
5. **自动重钉循环**：必须限定 diff 形态（md5/整数）+ 目标文件，否则
   会把 QP 换进无关文件（§407 曾误伤三文件回滚重做）。
6. rm-guard 误伤含独立 "rd"/"RD" 子串的 heredoc（cabac_rd/RD/
   reorder）——用 Edit 工具或拆词绕开。

## 下一片候选（无正确性欠账）

1. **统一播放门面**：`VideoDecoder`/`playback` 已有 H264/HEVC/VP9/AV1
   分发（§312-§313），编码器侧未接入门面——补 `VideoEncoder` 抽象与
   CLI 整合。
2. **更多 profile 与位深**：High 之外（High10 及以上、4:2:2/4:4:4
   编码、CQM）。编码器当前 8-bit 4:2:0 + High/Main/Baseline。
3. **加权预测 B**（`weighted_bipred_idc`）：compensate 已有 explicit/
   implicit 分支骨架，编码器侧未暴露。
4. **码控深化**：mb-tree/lookahead 类（现 ABR/VBV 是逐图反馈）。
5. 清理：`.scratch/promote_wip.diff` 已被 §406 超越可删；
   `doc/handoff/AGENT_HANDOFF_2026-11-12_H264_PROMOTE.md` 十五节收口后可归档。

## 复现命令（wasm-only）

```sh
moon check --target wasm --deny-warn --no-render
# 全族（按名字 glob，勿整包）：
for f in "h264 enc *" "h264 enc b:*" "h264 enc bi4*" "h264 enc bi8*" \
  "h264 enc bintra*" "h264 enc bparts*" "h264 enc combo*" "h264 rc:*" \
  "h264 aud:*" "h264 vbv:*" "h264 stream:*" "h264 brc:*" "probe:*" \
  "h264 cabac *" "h264 aq:*" "h264 aq strength*" "h264 i4p:*"; do
  moon test --target wasm -p milkbobo/ffmpeg-moonbit/libavcodec -f "$f" --no-render
done
moon test --target wasm cmd/encode-h264 --no-render
```

docker native（点名时）：nine-x264 镜像，命令模板见
`doc/handoff/AGENT_HANDOFF_2026-11-12_H264_PROMOTE.md` §407 段。
