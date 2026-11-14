# H.264 多参考列表预热：活动参考数量

接续 CABAC_MULTIREF 交接，修复 FFmpeg 在 DPB 未填满时报告的
Missing reference picture 提示。本轮改动纯 MoonBit 编码器；两个 C
绑定技能用于复用现有 FFmpeg 参考解码器，不新增 C 实现或编码 FFI。

## 实现契约

SPS/PPS 仍声明配置的参考历史容量，P slice 的实际活动数量使用编码器
已有 nrefs（当前重建历史长度）。新增私有 put_active_refs：当活动数量
不同于 PPS.ref_count_l0 时写 num_ref_idx_active_override_flag=1 及
num_ref_idx_l0_active_minus1。列表填满后恢复使用 PPS 默认数量。

CAVLC、CABAC 两条路径的 ref_idx 编码、权重表条目数量和中性权重初始化
同步使用活动数量，避免出现“header 声明一条但 payload 仍写多条”的失步。
单参考仍写 override_flag=0，不新增公开 API。批式、流式共享这一逻辑。

## 验证

- 多参考专项 8/8：原 2/3 参考深度矩阵扩展至 16，检查 recon 不变式、
  4×4/8×8 变换、批式/流式逐字节一致；保留 RD 与 High 10 组合。
- 流式专项 8/8。
- native FFmpeg oracle：深度 2/3/16 × CAVLC/CABAC × weightp 开关，
  12 条七帧码流，共 84 帧逐像素一致。每条流断言 warnings=0、errors=0、
  n_frames=7，修复前的参考缺失提示已消除（此矩阵范围内）。
- moon check --target wasm --deny-warn、moon info --target wasm、
  git diff --check 通过。仅用 moonfmt 格式化四个修改文件。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target wasm --release libavcodec/h264_enc_stream_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*multiref warm-up*'
```

native 命令在 ffmpeg-moonbit-ffref:nine-x264 容器执行，先 moon update。
容器编译仍有两条既有 derive 语法弃用警告，它们不是解码器告警。
没有改 C 代码或 FFI 所有权，因此本轮未重复 ASan。

## 边界

本轮不解决多参考 B 切片或码率控制限制，也未验证所有长序列/环绕组合。
上轮 CABAC_MULTIREF 交接中的早期参考列表提示说明被本轮结果更新。
工作区所有此前未提交内容均保留，未创建提交。

## 后续长序列验证

新增黑盒 `reference eviction survives two frame_num wraps`：35 帧 32×32
移动图案，跨 frame_num=15→0 两次，覆盖 3/16 参考深度与 CAVLC/CABAC。
每条流检查 34 个 P 帧编码 recon 与解码像素一致，且流式输出与批式逐字节
一致。多参考完整专项现为 9/9 通过。

新增 native oracle `multiref eviction across frame_num wraps is warning-free`：
相同规模四条码流，共 140 帧 FFmpeg/MoonBit 逐像素一致，且逐流断言
warnings=0、errors=0、n_frames=35。此次没有发现需要修改编码器的新缺陷，
仅增加正式回归；未新增编码 FFI。moon check 严格检查、moon info 和
git diff --check 通过，仅格式化两份测试文件。

```text
moon test --target wasm --release libavcodec/h264_enc_multiref_test.mbt --no-render
moon test --target native -p libavcodec/x264 --filter '*multiref eviction*'
```

以上不代表任意长度、全部 GOP 或所有像素格式已经验证。
