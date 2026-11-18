# H.264 编码续迁移：AUD

两个序列入口 `h264_encode_frames` / `h264_encode_frames_cabac`
增加 `aud~ : Bool = false`。开启后每个 AU 首部输出六字节 AUD，
首帧在 SPS/PPS 之前；首帧 primary_pic_type=0（I），后续=1（I/P），
nal_ref_idc=0，RBSP 含停止位。默认关闭，既有输出不变。

AUD 在内部 qps 序列构建时加入，因此 ABR 真编码搜索、VBV 探测、
最终带 filler 的编码和 stats.vbv_bits 都包含其成本。

## 技能应用

已读取 MoonBit 技能目录，沿用 agent-guide 的 mbtx 自动化、包边界和
格式/接口检查；按 orientation 使用本地实现与工具链验证；按
refactoring 保持默认行为，按 spec/test 指导固定有效输入、边界与回归契约。
本轮没有 OCaml 输入，也没有引入 Why3 证明或声明式空实现。

指定的 moonbit-c-binding 和 make-moonbit-c-bindings 用于现有 x264
oracle：复核 native 门控、私有 extern、#borrow(stream)、C 侧拷贝及
MoonBit 领域结果；新增 native 测试通过该 FFI 验证 AUD 清单、AU
大小总和、三个 AU/帧、零告警，并执行 FFmpeg/MoonBit 双解码逐像素对拍。
没有修改 C ABI、内存所有权或引入新 C 依赖，本轮未重跑 ASan。

## 验证

- `moon test --target wasm --no-render libavcodec/h264_enc_vbv_test.mbt`：8/8。
  新测试覆盖双熵 × flat/VBV，去除 AUD 后与默认流逐字节相同，
  每帧重建一致、实际 AU CPB 不变量和 stats 位数一致。
- docker nine-x264 native AUD 仲裁：1/1（内部覆盖 CAVLC/CABAC）。
- docker nine-x264 完整 native 绑定回归：32/32。
- `moon check --target wasm --deny-warn --no-render`：退出 0，无警告。
- `moon check --target all --warn-list +73 --no-render`：退出 0，
  有仓库既有冗余类型标注警告。
- `moon fmt`、`moon info --target wasm` 完成，生成接口含 aud 参数。

下一步仍可选 CABAC 位定价、B 帧、AQ 可配置或 CLI 接入。
工作区原有三个行尾状态文件未改动语义；本轮未提交。
