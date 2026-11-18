# H.264 编码：可配置 AQ 强度

四个公开编码入口增加 `aq_strength~ : Int32 = 1`，合法范围 0..6。
CLI 增加 `--aq-strength N`，JSON 摘要输出 `aq_strength`。
参数仅在 `aq=true` / `--aq` 时改变量化，但无论 AQ 开关都验证范围。

行为契约：活动度高于均值 125% 时 +strength、低于 75% 时 -strength，
中间不变；均值为零时不调整。宏块最终 QP 裁剪到 0..51。
默认 1 保持既有字节输出，0 等价于关闭 AQ。此选项是整数 QP 幅度，
不是 x264 浮点 aq-strength 算法的数值对等实现。

实现贯通 I/P、CAVLC/CABAC、ABR 探测/最终编码、VBV 探测/最终编码，
避免码率搜索和最终编码使用不同强度。宏块 delta 继续相对运行 QP
编码，重建与色度量化同步更新。

```sh
moon run cmd/encode-h264 -- input.yuv --width 640 --height 480 --output out.264 --cabac --aq --aq-strength 3
```

## 验证

- 最大强度测试：两种熵编码 × QP 0/26/51，编码侧重建与无滤波解码
  逐字节一致；默认等于显式 1、0 等于关闭、关闭时强度 6 无影响。
- 参数越界 -1/7/Int32.max 被拒绝，CLI 数字和范围错误被拒绝。
- 强 AQ + ABR/VBV 四组合：预算、CPB、stats.vbv_bits、重建均通过。
- CLI 定向回归 5/5。
- 完整 `h264_enc_rc_test.mbt` 回归 14/14（含原有 RC/AQ/I4P 钉值）。
- docker nine-x264 最大强度 native 仲裁 1/1（内部覆盖双熵和三种 QP），
  C 探针零告警、三帧，FFmpeg/MoonBit 双解码逐像素一致。
- `moon check --target wasm --deny-warn --no-render`、`moon fmt`、
  `moon info --target wasm` 已完成，接口摘要包含四个新参数。
- `moon check --target all --no-render` 退出 0，只有既有 v128 未使用导入警告。

沿用用户指定的 moonbit-c-binding / make-moonbit-c-bindings：复核
native oracle 的私有 extern、借用流字节与 C 输出复制边界，并通过
真实 C parser/decoder 验证新流。本轮没有修改 C ABI、分配或生命周期，
未重跑 ASan；上一轮 CLI 已运行该绑定的定向 ASan。
自动修改使用 mbtx，临时转换脚本完成后移除。

工作树保留前两轮 AUD、CLI 未提交改动，本轮亦未提交。
后续缺口仍有 CABAC 专用位定价、B 帧、流式编码。
