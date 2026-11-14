# H.264 §418 B 调度多参考收口

接续 §417 最后一项拒收「B × multi_ref>1」。本轮完成 B 片 ref_idx 全链
（搜索/语法/镜像/参数集）、五个真 bug 修复与全族钉值债清偿，B×multi_ref
三处拒收全部解除。两个 C 绑定技能（moonbit-c-binding /
make-moonbit-c-bindings）按惯例用于复用现有 FFmpeg 参考解码器仲裁链
（docker ffmpeg-moonbit-ffref:nine-x264），无新增 C FFI。

## 实现契约

- B 计划枚举携带 list 0 参考索引：BL0x16(x,y,rf)、BBi16(...,rf,...)、
  BParts(kind,subs,mvs,refs)；B_8x8 组级 refs（组内共享，walk 序数组 +
  group_refs 映射）。list 1 永远单条未来参考，不编 ref_idx。
- 搜索：`me_b_l0_multi` 逐参考完整 ME + 运动补偿色度 SAD 计价（替换旧
  luma-only `me_b_l0`，单参考决策也变——本轮钉值债主因）；预测器全部带
  等参考测试。
- 语法：CAVLC `h264_enc_put_ref_idx`（rc==2 单反码位）、CABAC
  `h264_cabac_put_ref`（B 片按 `h264_b_direct_neighbor` 排除 direct 邻居）。
- 镜像：`h264_b_mirror_new` 收 `pasts : Array[H264RefPic]`，
  `ref_count0 = pasts.length()`。
- 列表构造：B 的 list 0 = 参考历史**去头**（头是刚编码的未来 P）；历史容量
  B 调度下 `nrefs+1`（`ref_history_cap`，封 16），P 搜索仍钳 `min(len,nrefs)`；
  参考 POC 按显示位距推导（GOP 相对序）。批式 `h264_encode_frames_b` 同构。
- B 片头 override 双列表计数（l1 恒 0）；SPS `max_num_ref_frames=nrefs+1`；
  IDR intra 入口透传 multi_ref（参数集声明容量）。

## 真 bug（前三个为接线笔误，第四个为潜伏期 bug）

1. 批式 IDR 自带参数集未声明容量（intra multi_ref 未透传）→ 解码参考错位。
2. 流式 P 搜索未钳制（B 调度历史加格后 P 多搜一条 → 流式≠批式）。
3. stream_b 首版 pasts 构造重复/含未来 P。
4. **kind-22 preamble**：B_8x8 组在列表 L 无分区时，编码镜像参考缓存写 0、
   解码器写 -1；`h264_b_compensate` 据此把纯 L1 组双向预测 → 编码重建≠解码。
   触发形态罕见（9/10-bit 周期 GOP 第二组首个 B 的全 L1 B_8x8 宏块），旧
   测试未覆盖。修复：preamble 按解码器 `refs[list][group]` 语义，无分区组
   写 -1。

## 仲裁（可复现）

1. 全套重跑收集 13 处钉值差分 + ARB*/VBV*/RCARB/FLAT* 转储（转储前移/
   新增至钉值前——assert_eq 失败即中止测试）。
2. `.scratch/arb418/arbitrate.py`（折行感知 + ARBBRC 双流单行特判）提取
   18 条 .264；docker `-v warning -threads 1 -f framemd5` 全部退出 0、
   stderr 空。
3. FFmpeg framemd5 与本仓解码器逐帧核对全等（B 流按 coding↔display 映射）
   后重钉；平铺流（FLATARB/FLATACARB）补永久转储后同流程。
4. 新 oracle：ARBMR2/ARBMR3（toggle 场景 9 帧，CAVLC nrefs=2 / CABAC
   nrefs=3）FFmpeg 逐帧一致，钉进 h264_enc_b_multiref_test.mbt。

## 验证

- 新专项 9 项全绿（h264_enc_b_multiref_test.mbt）；idr/stream_vbv 配置
  测试更新为新合法组合；multiref 拒收断言改为正面 round-trip。
- 全族 28 个编码器测试文件 + CLI 25/25；`moon check --target wasm
  --deny-warn`、`moon fmt`、git diff --check 通过。
- 仍拒收：流式 ABR（未知输入长度契约未定）。

```text
moon test --target wasm --release libavcodec/h264_enc*_test.mbt libavcodec/h264_encode*_test.mbt --no-render
moon test --target wasm --release -p cmd/encode-h264 --no-render
moon check --target wasm --deny-warn
```
