# H.264 RC/AQ/I4P 回归重新仲裁

接续 MULTIREF_RC 交接列出的 10 项失败。本轮只修改测试与说明，不修改
编码算法、不新增 FFI。按照两个 C 绑定技能的独立参考验证要求，使用
ffmpeg-moonbit-ffref:nine-x264 镜像中的真实 FFmpeg 仲裁。

## 核查结论

原失败来自 YUV 失真计价修正后的旧 QP/模式数量/码流哈希快照；本轮未
发现需要回退编码器的解码缺陷。保留所有预算、码率/质量单调性、QP
边界、AQ 非零增量、编码 recon 与解码像素一致等功能断言，没有放宽阈值。

- 小预算 CAVLC QP：[36,37,37,37,37]；大预算：[20,20,20,21,21]。
- CABAC 此目标可用全 QP38 满足，不强制声称每次都必须混合 QP。
- AQ 模式增量数量更新为 24。
- 普通 I4 场景 CAVLC/CABAC 均有两个 I4 获胜宏块；无 8×8 变换场景
  分别为 13/11。保留精确快照，同时新增“确有 I4 获胜”的功能断言。
- 混合场景继续要求 I4、I16、I8 都实际获胜。

## 独立参考

导出 RC、AQ、I4、有/无 8×8 变换的 CAVLC/CABAC 共八条流，FFmpeg
逐条以 -v warning -threads 1 解码，均返回成功且 stderr 为空，共 34 帧。
将 FFmpeg framemd5 按本地测试使用的帧序填入各数组（RC 五帧是
I0/P2/B1/P4/B3 解码顺序，其余 P-only 保持原序）。

固定的外部哈希断言由 inspect(content=pins[i]) 改为 assert_eq，避免
snapshot update 将循环中的动态期望误换为一个常量。帧哈希只从 FFmpeg
输出更新，不直接接受本地解码快照。临时导出测试/helper 已移除。

证据位于忽略目录：.scratch/rc_repin_{rc,aq,i4,no8}_{c,k}.264/.md5。
生成与重排辅助脚本为 .scratch/rc_repin.mbtx、rc_finish.mbtx。

## 验证范围

整个 h264_enc_rc_test.mbt 一次常规运行 14/15 通过，剩余大预算 QP
数组已按实际分配更新，随后定向验证该测试及其后续 recon 断言。
定向运行 1/1 通过，15 项均已完成通过验证（14 项完整运行 + 最后一项复验）。
本轮未跑全仓库测试。moon check --target wasm --deny-warn、
moon info --target wasm、git diff --check 通过；没有 API 接口变化。

```text
moon test --target wasm --release libavcodec/h264_enc_rc_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_rc_test.mbt --filter '*CAVLC lands under*' --no-render
```

这份记录更新 MULTIREF_RC 中“10 项未核查”的历史状态，不代表整个
仓库或所有视频编码组合已验证。工作区既有改动均保留，未创建提交。
