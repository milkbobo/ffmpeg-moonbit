# H.264 B 帧 CABAC 位定价

接续 STREAM_RD，本轮支持 `cabac_rd=true` 与 `b_slices=true`，批式、流式、CLI 均已打通。默认关闭，原有码流保持不变。

`H264PEncoder::price_b_bits` 对 Direct/L0/L1/Bi 的非 skip 候选提交临时运动状态，经真实 CABAC skip/type/mvd/cbp/dqp/residual 写端定价，随后回滚算术引擎、上下文、运动与 direct 标志、nz/cbp/qp、active_list 和 dqp 计数。B skip 仍沿用原来的精确预测判定。

验证：Wasm 流式/B 帧 15/15，CABAC RD/GOP/CABAC 20/20，CLI 9/9。新原生定向用例 1/1，含 P 与 B 两种调度，C parser 无警告/错误，FFmpeg 与 MoonBit 显示序重建像素一致。Wasm 严格 check、fmt、info、diff check 通过。原生编译仍有既有 derive 语法弃用告警。

沿用已读取的全部 MoonBit 技能，两个 C 绑定技能用于原生 oracle 的私有借用接口与对拍验证。本轮未修改 C ABI，无需重新 vendoring；ASan 继承上一轮同一 C stub 的通过记录，本轮未重跑。

后续可继续 B 分割模式、intra-in-B、B 与 VBV/ABR。原有工作区 ffref、h264_inter、playback_streaming 改动保留。STREAM_RD 文档记录的是上轮限制，CABAC RD 不支持 B 的限制已由本轮解除。
