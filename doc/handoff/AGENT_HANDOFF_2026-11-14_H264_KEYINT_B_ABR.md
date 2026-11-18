# 周期 B GOP 的全序列 ABR

本轮在纯 MoonBit H.264 编码中开放 keyint 与 B 帧、target_bytes 的批式
组合。继续使用 moonbit-c-binding、make-moonbit-c-bindings 指导的现有
FFmpeg native FFI 做独立仲裁，未修改 C 层或增加编码 FFI。

## 实现与契约

`video_encode_periodic_qps` 新增 B 分支，复用已有
`h264_encode_frames_b`：把全局显示顺序 QP 数组按 GOP 切片，B 核心负责
在每个 GOP 内输出 I、P2、B1 等编码顺序，末尾没有未来参考的图片按 P
帧编码。B_parts、帧内候选、8x8 变换、CABAC-RD、加权 P、AQ、AUD 和
位深均透传。不改既有 B 核心，也不改变 P-only 分支。

全序列只运行一次 h264_rc_solve。每个候选的成本为完整拼接码流字节数，
包含每个 IDR、重复 SPS/PPS 和 AUD。没有给各 GOP 各自一份完整预算。
B 核心沿用既有 PPS 行为：每个 GOP 的 PPS 以该 IDR 的实际 QP 为基准，
后续片头用 delta 表示本图像 QP。P-only PPS 仍以配置基础 QP 为基准。
单 GOP 周期 B ABR 与普通 B ABR 逐字节相同；过小预算沿用全 QP51
最佳努力输出，不承诺满足不可行的任意字节数。

B 核心已经把每个 GOP 的 QP 按显示顺序追加进 stats.frame_qps，因此
ABR 外层只给 P-only 路径追加，避免重复统计。最终 frame_qps 每个输入
一项，recon 排除每个 GOP 的 IDR、其余图片按编码顺序排列。探测使用
独立 stats/recon，全部平面形状在探测前验证。

CLI 已接受默认 B 配置下 `--keyint N --target-bytes B`。周期 B × VBV
仍在 facade、CLI 和共享逐 QP helper 明确拒收，不能把显示顺序 QP 与
解码顺序 CPB 直接混用。流式 ABR/VBV、B × multi_ref>1 仍拒收。

## 验证

- 新周期 B ABR 专项3/3：8/9/10-bit × CAVLC/CABAC × keyint3/4，
  七帧、多 GOP，目标位于 QP20 与 QP51 的完整输出大小之间。
  检查实际总字节预算、混合 QP 覆盖、编码确定性、QP51 不可行预算回退，
  B 宏块统计恰为两帧八个宏块（无探测统计泄漏），最终 recon 一致。
- 直接使用公开 SPS/PPS/片头解析器，按每个 GOP 的局部 POC 将图片映射
  回全局显示位置，核对每个片头的实际扩展 QP 与 frame_qps，检查 I/P/B
  类型及每个显示位置只出现一次。不是只比较编码器自身的统计数组。
- 边界覆盖 keyint1 全 IDR、keyint2 仅尾 P、keyint20 单 GOP；后者与
  原 B ABR 逐字节相同。错误平面保持调用者预先写入的 QP/recon 不变；
  streaming open 继续拒收 ABR。
- 原周期 P ABR3、周期 P VBV4、IDR5 共12/12；统一接口7、固定 QP
  周期 B3 共10/10；CLI24/24。加上新专项，本轮 wasm 合计49/49。
- native oracle1/1：8/9/10-bit × 双熵 × keyint3/4，共12条七帧
  码流（84帧），完整输出均在目标预算内；18条独立 IDR 尾流（48帧
  重复对拍）均可独立解码。纯解码与 FFmpeg 显示顺序逐像素一致，
  FFmpeg warning/error 均0，native 的最终 QP 与 B 宏块统计亦正确。
  native 编译的既有 derive 语法弃用警告未改，上面的零警告指解码诊断。
- 严格 wasm check、moon info、git diff --check 和定向格式化通过。未新增公开字段或函数，
  未改 C，无需重复 ASan；未运行全仓库测试，未创建提交。

```text
moon test --target wasm --release libavcodec/h264_enc_periodic_brc_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_periodic_rc_test.mbt libavcodec/h264_enc_periodic_vbv_test.mbt libavcodec/h264_enc_idr_test.mbt --no-render
moon test --target wasm --release libavcodec/video_encoder_test.mbt libavcodec/h264_enc_periodic_b_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild --filter '*periodic B ABR budgets*'
moon check --target wasm --deny-warn
moon info --target wasm
git diff --check
```

native 镜像为 ffmpeg-moonbit-ffref:nine-x264，原有未提交改动、旧交接记录
及 h417_dbg_wbtest.mbt 均保留。下一步为周期 B 的连续 VBV，需要明确
逐 GOP 的解码顺序、pic_timing、输出延迟及 IDR 缓冲周期，不能仅把当前
B 分支传入 VBV 即开放。
