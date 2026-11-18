# 周期 B GOP 的连续 VBV/CBR

本轮开放纯 MoonBit H.264 的周期 B × 批式 VBV。继续按
moonbit-c-binding、make-moonbit-c-bindings 使用现有 FFmpeg native
FFI 独立仲裁；未新增编码 FFI，未修改 C 边界，未创建提交。

## 顺序、搜索和缓冲

新增私有 h264_b_coding_order，生成解码顺序 AU 索引到全局显示位置的
映射；支持单 GOP、周期 GOP 和无未来参考的尾 P。h264_vbv_solve 新增
私有可选 coding_order：仍按真实 AU 大小回放 CPB，但提高的是该 AU
对应显示位置的 QP。旧实现直接使用 AU 索引，I0/P2/B1 的第二次移除
溢出时会错误地提高 B1 的 QP。

普通 CAVLC/CABAC B VBV 与周期 B VBV 都传入此映射。逐帧 QP 统计仍
按显示顺序，recon 仍排除 IDR、按编码顺序。B 核心已记录 QP，周期 VBV
外层不再重复追加。探测使用独立输出，先完整验证输入平面。

周期 B 复用已有连续 CPB helper，所有 GOP 使用一次全局 VBV 搜索，
每帧 filler 计入实际 AU。后续 buffering_period 根据前序 AU（含
filler）消耗后的真实余量写出，IDR 不重获初始90%容量。普通 B 核心
的 filler 索引也修正为解码顺序，原先误按显示位置取值。

## HRD 与 SPS 修正

- 所有 B 图像的 CPB removal delay 按解码位置递增；周期 IDR 的值
  仍相对前一个 AU 中最近的 BP，因此为前一 GOP 长度*2，之后从当前
  BP 计算。计数保留16位模语义。
- 选择一帧固定输出滞后。推导 output_delay=2*(display+1-decode)，
  因而 IDR为2、提前解码的P参考为4、B为0、尾P为2。跨 GOP 显示时刻
  连续。P-only 默认输出延迟0，码流行为保持原状。
- B SPS 的 VUI 声明 max_num_reorder_frames=1、max_dec_frame_buffering=2。
- 修正 B intra 分支漏传 vbv：原先内部 PS 有 HRD，实际写出的 B SPS
  却没有 VUI。现在 CAVLC/CABAC 实际输出均携带配置的 HRD/VUI。
- CAVLC B SPS 写出原先没有防起始码转义，加入 HRD 后在64x48旧样本中
  被 FFmpeg 检出 Truncated VUI。现在统一对 RBSP 做 h264_enc_escape。

依据：[ITU-T H.264 (08/2024), D.2.2 / Annex C](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.264-202408-I%21%21PDF-E&lang=e&type=items)。
cpb_removal_delay 相对 preceding AU 中最近的 buffering period，
dpb_output_delay 描述 CPB 移除到 DPB 输出的时钟间隔。上面的固定一帧
滞后是针对本编码器单层 B 调度的实现选择。仍沿用既有逐帧整数到达量
CPB 模型，没有进行完整 HRD 认证。

## 验证

- 新黑盒周期 B VBV3/3：8/9/10-bit × 双熵 × keyint3/4，八帧，
  初始QP10、64kbit/s、4000bit缓冲、25fps；实际 AU 全局 CPB 上下界，
  每个 BP 的余量、每个 pic_timing 的移除与输出时刻、VUI、片头 QP、
  filler统计、B宏块统计、未滤波 recon 均正确。边界另含keyint1/2/20、
  filler、普通单 GOP 字节兼容、失败不污染调用者输出。
- 新白盒 solver1/1：只让编码顺序第二个 AU（显示位置2）变大，验证
  仅该图片提高QP，显示位置1的QP保持不变；覆盖具体错配风险。
- 原周期 P VBV4、IDR5、统一接口7，共16/16；周期P/B ABR共6/6；
  CLI25/25；普通B码控4项中行为测试3项通过，1项历史黄金值由下面的
  C参考独立重算后更新，专项重跑通过。本轮 wasm 合计55项通过。
- native 三项均通过（优化构建）：
  1. 8/9/10-bit × 双熵 × keyint3/4，共12条八帧流（96帧）；
     初始QP26，64kbit/s、4000bit缓冲。FFmpeg独立 AU 大小回放 CPB
     通过。18条独立IDR尾流（66帧重复对拍）均可解码。
  2. 普通/全IDR/短GOP/单GOP × 双熵，8条六帧 filler 流（48帧）。
  3. 64x48旧 checkerboard/box 样本，ABR4000和VBV90000/18000/30，
     两条六帧流（12帧），独立参考 MD5 与更新后的黄金值相同。
  共156个完整流帧，纯解码与FFmpeg显示顺序逐像素一致，所有完整流与
  尾流解码 warning/error 均0。
- 初始native调试构建搜索耗时过长，主动终止后使用优化构建完成验证。
  native编译保留既有derive语法弃用警告；零警告指FFmpeg解码诊断。
- 严格wasm check、native包check、moon info、定向格式化、diff检查通过。
  无新增公开API。没有更改C，不重复ASan；未跑全仓库测试。

历史ABR黄金值变化来自先前共享P路径修正；本轮B VBV修正也改变实际
头部和搜索成本。两组均先以C解码核对全部像素，再更新pins；新增
"legacy B rate-control snapshots"保留独立输入及C参考MD5复现路径。

```text
moon test --target wasm --release libavcodec/h264_enc_periodic_bvbv_test.mbt libavcodec/h264_enc_vbv_order_wbtest.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_periodic_vbv_test.mbt libavcodec/h264_enc_idr_test.mbt libavcodec/video_encoder_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_periodic_brc_test.mbt libavcodec/h264_enc_periodic_rc_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_brc_test.mbt --no-render
moon test --target wasm --release cmd/encode-h264 --no-render
moon test --release --target native -p libavcodec/x264 --filter '*periodic B VBV keeps*'
moon test --release --target native -p libavcodec/x264 --filter '*B VBV filler works*'
moon test --release --target native -p libavcodec/x264 --filter '*legacy B rate-control snapshots*'
```

native镜像仍为ffmpeg-moonbit-ffref:nine-x264。CLI已开放周期B批式VBV，
文档同步。流式ABR/VBV和B × multi_ref>1仍拒收。保留已有工作区修改、
旧交接文档与h417_dbg_wbtest.mbt，不覆盖先前工作。
