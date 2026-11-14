# 固定 QP 周期 B GOP 与手动 IDR

本轮继续纯 MoonBit H.264 编码迁移，开放固定 QP 下 B 序列的周期和
手动 IDR。按照 moonbit-c-binding、make-moonbit-c-bindings 使用现有
FFmpeg native FFI 独立仲裁，编码实现未转交给 libx264，C 边界未修改。

## 行为与实现

`H264StreamEncoder` 新增私有 `gop_start`，用于计算 GOP 内显示位置。
调度奇偶、POC、直接预测引用的时间位置都沿用已有单 GOP 算法，但输入
位置现在相对最新 IDR。`next_display` 保留整条序列的输入计数。

`force_idr=true` 先检查新输入平面，再将旧 GOP 中尚无未来参考帧的
pending 图片作为 P 帧编码（复用 finish 的尾帧行为），然后输出新 IDR。
新增私有 `flush_pending`，finish 与 IDR 共用。IDR 重置参考帧、宏块
镜像、frame_num、colocated、future planes 和 GOP 起点。无效平面不会
提前输出或丢失待编码帧，也不会重置周期。新 IDR 不被用作旧 GOP 的未来参考。

统一接口的 keyint 按显示帧距离判断，不再使用仅计参考帧的 fn_counter。
因此奇数、偶数 GOP 长度和手动 IDR 后的自动间隔均正确。一次 push
可能输出旧尾 P 和新 IDR 两个 AU；调用者仍按 drain 接收编码顺序输出。

批式 facade 复用同一流式调度，保留每个输入一项 frame_qps；recon 排除
所有 IDR，P/B recon 按编码顺序排列。支持 keyint1 的全 IDR 序列，以及
最后只有一帧的独立 GOP。CLI 固定 QP 也开放 --keyint 与默认 B 配置。

周期 B × ABR/VBV 仍在 facade 和 CLI 明确拒收，避免共享逐 QP helper
忽略 B 选项而静默生成 P 序列。P-only 周期 ABR/VBV 保留上一轮行为。
multi_ref>1 与 B 序列仍拒收。流式 ABR/VBV 仍未实现。

## 同时修复的高位深问题

新重建测试暴露已有 B 帧 Intra4x4/Intra8x8 helper 调用遗漏位深和
扩展 QP。9-bit CABAC、keyint3、移动方框样本第二 GOP 的 B 图片在
第一个右侧宏块（打包字节32）开始出现 encoder recon / decoder 差异；
相同 GOP 单独编码也复现，说明不是新 IDR 状态泄漏。

`h264_encode_b.mbt` 的四处选择／重放调用统一传入 p.qp_ext(qp) 与
bit_depth=p.bit_depth。现在预测、量化及重建均使用实际位深。
8-bit 参数取值保持相同；没有改变其它候选算法。

## 验证与黄金值

- 新周期 B 专项3/3：8/9/10-bit × 双熵 × keyint1/2/3/4/20；
  流式/批式逐字节相同，每个 GOP 与全新独立编码器逐字节相同，
  P/B recon 一致；测试无 AUD／有 AUD、单帧 GOP、POC wrap、待编码
  帧收尾、连续 IDR、手动间隔重启及失败不消耗输入。
- 原 IDR5、stream8、facade7、B8，共28项。首次执行其中两项历史
  黄金值不匹配；native 用相同96x64六帧样本独立验证后重新固定，
  两项分别重跑通过，其余26项首次通过。IDR5再跑亦通过。
- 周期 ABR3、周期 VBV4、高位深原测试8、CLI23，全部通过。
  本轮上述 wasm 专项与回归共69个测试。
- native 新增3个 oracle 测试，全部通过：
  1. 18条九帧周期 B 流（8/9/10-bit、双熵、keyint1/3/4），162帧；
     72条 IDR 尾流（306帧重复对拍），独立解码成功。
  2. 9/10-bit 移动方框纹理 × 双熵 × keyint0/3，8条流、72帧；
     真实 intra B 宏块覆盖，encoder recon 与未滤波纯解码一致，
     滤波后纯解码与 FFmpeg 每像素一致。
  3. 历史96x64六帧 B 样本，QP24，以及QP26+AQ+AUD两条流，12帧；
     FFmpeg输出与纯解码显示顺序逐像素一致。
  完整流合计246帧，以上所有流和尾流 FFmpeg 解码 warning/error均0。
- 黄金值独立记录：AQ+AUD流 MD5为146b72999e2a5ac5b0af9fa05975eacc；
  QP24 FFmpeg显示帧 MD5依次为4215ee3be54b5cf3f3a8ccf97cc7ee64、
  79cb6cd97cc795b5c41fb50ccd5db048、683deaf38ca7e61d3ae43498af9ac29b、
  3e8a91f312c23e1285933605fd084bfc、b59196a0d5e18e260f87add844c5a855、
  6853569a483390780d73ef9d826c7bf2。
  这些8-bit旧黄金值的差异来自先前共享 P 路径修正，本轮四处位深传参
  在8-bit时数值与旧调用相同。新增 oracle 保留复现输入和输出记录。
- 严格 wasm check、定向格式化、moon info、git diff --check通过。
  native 编译的旧 derive 语法警告未改；零警告指 FFmpeg 解码诊断。
  未改 C，未重复 ASan；未运行全仓库测试，未创建提交。

```text
moon test --target wasm --release libavcodec/h264_enc_periodic_b_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_idr_test.mbt libavcodec/h264_enc_stream_test.mbt libavcodec/video_encoder_test.mbt libavcodec/h264_enc_b_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_periodic_rc_test.mbt libavcodec/h264_enc_periodic_vbv_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_high10_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild --filter '*periodic B GOPs*'
moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild --filter '*high-depth B intra texture*'
moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild --filter '*legacy six-frame B snapshots*'
```

native 使用 ffmpeg-moonbit-ffref:nine-x264。保留此前未提交内容和
h417_dbg_wbtest.mbt。后续可迁移周期 B 的全序列 ABR，再处理解码顺序
CPB、跨 GOP timing 与 B 输出延迟，不能直接复用 P-only 的逐 QP helper。
