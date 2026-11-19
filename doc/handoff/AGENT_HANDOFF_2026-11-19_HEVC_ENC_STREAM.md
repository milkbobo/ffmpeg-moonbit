# HEVC 流式编码器 + CLI 交接 —— §459

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§458（CRF 码控）

## 结果

HEVC 编码器新增**流式逐帧推送**（`HevcStreamEncoder`）与 **CLI**
（`cmd/encode-hevc`），并修复批式 B 片**奇数长序列的 RPS delta bug**
（设计流式调度时发现、探针实证、FFmpeg 仲裁）。纯 MoonBit、wasm-only。

验证：HEVC 编码器测试 wasm-gc **94/94**、黑盒 wasm 12/12；流式 5 帧 CRF
流 FFmpeg 9.0.2 `-xerror` 零告警仲裁钉黑盒；CLI e2e 输出与仲裁流 SHA-256
一致。

## 先说 bug：批式 B 片奇数长 RPS（§459 修复）

- **根因**：`hevc_encode_sequence` 的
  `has_following_b = is_b_interleaved && i%2==0 && i+1<n`。P 锚的 L0 在
  2 个 display 步之前（display i-1 的 B 夹在中间——锚点存在该 B 必
  存在），但条件看的 `i+1<n` 是序列尾。奇数长（n=3/5）最后一个偶锚点
  错写 `rps_delta=-1`。
- **症状**：本仓解码器 `hevc: duplicate POC in a sequence`；n=4 恰好
  避开（既有测试全用 n=4，从未暴露）。
- **修复**：`anchor_gap_two = is_b_interleaved && i%2 == 0`。偶数长流
  字节不变（88/88 既有钉值原样通过）；n=5 修复流 FFmpeg 零告警 5 帧。
- **教训**：调度类逻辑的测试长度要覆盖奇偶两端；`i+1<n` 这类"向后看"
  条件要对着参考链真实间隙核。

## 流式 API（`libavcodec/hevc_enc_stream.mbt`）

```moonbit
HevcStreamEncoder::open(width~, height~, qp~=26, crf~=-1.0,
  inter~=true, b_slices~=false, bit_depth~=8, chroma_format_idc~=1)
enc.push_frame(y, u, v) -> Result[Unit, String]   // 显示序进
enc.finish() -> Result[Array[Bytes], String]       // 尾 P flush
enc.drain() -> Array[Bytes]                        // 编码序出，消费式
```

- **契约：drain 拼接 == 批式 annexb 字节恒等**（平直 QP/CRF × b_slices
  on/off × n=1..6 全矩阵钉死）。CRF 逐 push 递推即批式公式——§458 的
  display-causal 设计正是为此铺路。
- 调度镜像批式：首 push IDR 带参数集；奇数位 park pending（帧拷贝 +
  该帧 CRF QP 暂存）；偶数位出 P（delta=-2）+pending B（L0=prev_anchor，
  L1=ref_pic）；偶数长尾奇数位在 finish 落尾 P（delta=-1），奇数长
  finish 无输出。`inter=false` 每 push IDR（仅首帧带 PS）。
- 参考链旋转镜像批式（锚点编码后旧 L0 → prev_anchor）。
- `push_frame` 错误不推进状态；空流 `finish` 报 `hevc enc: no frames`。

## CLI（`cmd/encode-hevc`）

```
encode-hevc input.yuv --width W --height H --output out.265
  [--qp 0..51] [--crf 0..51] [--chroma 420|422|444]
  [--bit-depth 8|10|12] [--b-slices] [--all-intra]
```

planar YUV（8-bit u8、10/12-bit 16-bit LE），整文件缓冲、逐帧推送、
JSON summary（encode-h264 词汇表子集；其 --stream 分块宿主 IO 未镜像）。
e2e：python 复现黑盒帧 → CLI `--crf 28 --b-slices` → 输出与仲裁流
SHA-256 一致（`5d6d5777…41aa40`）。

## 测试与仲裁

- 白盒 `hevc_enc_stream_wbtest.mbt` **5/5**：24 组合恒等矩阵、
  all-intra/10-bit/422 恒等、逐 push 节奏、n=3/5 解码 POC、错误路径。
- 黑盒 `hevc_enc_stream_test.mbt` **1/1** 双目标：流式 crf28_ipb5_stream
  （5517 字节，POC 0/2/1/4/3）MD5：前三帧同 4 帧钉值流，P4
  `d38ddbc3685d721f7bbc0286ed75002c`、B3
  `7e6eceb2ac22ce95fe7b9a74f6ab2028`。
- 生成器 `cmd/generate-hevc-crf` 扩展写流式 n=5 流并自证 == 批式；
  4 帧钉值流 SHA 不变。
- CLI options **2/2**（默认/尺寸公式、十种拒绝）。

## 本轮踩到的坑

1. `.mbtx` 脚本引不到本模块包（`Value not found in package`）——探针
   一律用 cmd 包（生成器模式）。
2. `frames[:n]` 是 ArrayView，批式入口要 Array——手动重建子数组。
3. `try?` 已移除：`try { … true } catch { _ => false }`。
4. pub struct 字段若不再赋值不要 `mut`（`crf_rc` 只改内部）；labeled
   可选参数不能按位置传（guard_frame 的 bit_depth=）。
5. `for n, want in [(…tuple…)]` 是 index/value 迭代——解构要
   `for (n, want) in`。
6. all-IDR 多帧流仍不能整段解（§458 坑，重申）；422 测试数据要
   (w/2)×h 色度平面。

## 检查状态

`moon fmt`/`moon info` 已跑（encode-hevc/pkg.generated.mbti 生成）；
全仓 `moon check --target wasm` 0 错误；定向 wasm-gc 仅既有 v128 警告。

## 边界与下一步

- 流式无 VBV/ABR/scenecut/keyint/pict_type/SEI（H.264 流式已有，HEVC
  侧未移植）；CLI 整文件缓冲。
- 其余边界不变：单色、色度 SAO、B 片加权/时间 MVP/多参考、多 slice/tile。
- 路线：**VBV/ABR 码率控制 → 或收尾项（单色/色度 SAO）**。VBV 可参照
  H.264 流式的 `vbv_trial/commit` 事务模式（§422 系列）。
