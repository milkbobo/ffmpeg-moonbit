# H.264 多参考 VBV/CBR

接续平均字节预算与 RC 重新仲裁工作，开放纯 MoonBit CAVLC/CABAC
P-only 序列的 multi_ref + VBV/CBR。两个 C 绑定技能用于独立参考解码验证，
本轮没有增加 C 编码 FFI。

## 实现

两个 VBV 包装函数原来没有接收 multi_ref，因此其 QP 搜索和最终带
filler 编码都会隐式回到默认单参考。本轮新增私有可选参数（默认 1），
从公开入口经包装层传至两次 qps 编码调用，并解除原多参考 VBV 拒收。
SPS/PPS 参考容量、逐帧参考历史、活动数量预热和权重表沿用已有实现。

调用设置 b_slices=false、multi_ref=3、vbv_maxrate、vbv_bufsize、fps。
统一 VideoEncConfig 批式入口也已验证。target_bytes 与 VBV 仍互斥，
参数组仍必须完整，B 切片多参考及流式码率控制仍不支持。

## 验证

- 多参考完整专项 12/12。
- 新增八组合：CAVLC/CABAC × 8/10-bit × 宽松/紧 CPB。
  宽松 200000 bit/s、32000 bit CPB；紧 12000 bit/s、4000 bit CPB；
  均 25fps、90% 初始满度、六帧 32×32。按实际 AU 大小（含 filler）
  回放 CPB，逐帧无上下溢；宽松场景确有 filler，紧场景确有 QP 提升。
  验证最终 frame_qps、recon 数量和总比特统计，没有把探测计入结果。
- 新测试解析实际 SPS 并断言 ref_frame_count=3，防止静默单参考回退。
  P 重建逐帧与本地解码一致。
- 不可行 CPB（64 bit/s、256 bit、25fps）两种熵编码均在达到 QP51
  后返回 vbv underflow，不输出违反模型的码流。
- 统一编码接口 VBV 转发 1/1，双熵均与直接调用逐字节一致。
- 既有 VBV 参数验证专项 1/1。
- native FFmpeg oracle 八组合共 48 帧逐像素一致且无解码 warning/error。
  该 fixture 纹理更复杂，原紧配置在 QP51 仍不足，正确返回下溢；独立
  像素对拍改用可行的 32000 bit/s、8000 bit CPB 紧配置，其余不变。
- moon check --target wasm --deny-warn、moon info --target wasm、
  git diff --check 通过；私有参数扩展没有增加公开接口。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt --filter '*multiref VBV*' --no-render
moon test --target wasm --release libavcodec/h264_enc_vbv_test.mbt --filter '*parameter validation*' --no-render
moon test --target native -p libavcodec/x264 --filter '*multiref VBV*'
```

native 环境为 ffmpeg-moonbit-ffref:nine-x264。本轮未跑整个仓库或整个
旧 VBV 测试文件。没有修改 C 包装代码，不重复 ASan；所有先前工作区
未提交内容均保留，未创建 Git 提交。

## 后续：长序列与旧 VBV 回归

新增 35 帧、32×32 的 VBV 环绕测试，覆盖 3/16 个参考帧和两种熵编码。
200000 bit/s、32000 bit CPB、25fps 下，跨 frame_num 两次 15→0，
每个实际 AU（含 filler）均通过 CPB 回放，35 项最终 QP 和 34 个 P
重建数量正确、像素与本地解码一致，确认参考淘汰与 filler 长期组合有效。
native 参考测试四条流共 140 帧逐像素一致，且解码 warning/error 均为零。

完整旧 h264_enc_vbv_test.mbt 初跑 4/9，五个失败全部定位为色度 RD
修正后遗留的固定大小、QP 或哈希预期。重新导出 flat、tight、arbitration
各两种熵编码，共六条流、30 帧，真实 FFmpeg -v warning -threads 1
全部成功且 stderr 为空。按新实际编码结果更新固定字节/位数/QP，按
FFmpeg framemd5 更新图像哈希；RC/B 调度的哈希按 coding order 重排。
外部哈希使用 assert_eq，不再使用自动快照更新表达式。

复跑整个旧 VBV 文件 9/9 通过。没有放宽 CPB 约束、目标码率范围、
QP 提升、filler 满度或 recon 一致性条件。临时导出测试已经移除；证据在
.scratch/vbv_{flat,tight,arb}_{c,k}.264/.md5，辅助为 vbv_repin.mbtx。
新增环绕测试后，多参考完整专项 13/13 通过，两份完整专项合计 22/22。

本次只添加测试和重新仲裁预期，没有修改编码算法或新增编码 FFI。
moon check 严格检查、moon info、git diff --check 通过；未跑全仓库测试。
