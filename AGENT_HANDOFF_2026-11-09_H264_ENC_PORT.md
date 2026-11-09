# H.264 纯 MoonBit 编码器——第一切片（§376，已完成）

## 状态

用户指令：**不能用 C FFI，把编码功能整体移植成纯 MoonBit**。§375 的 libx264
绑定降级为对拍 oracle。本切片交付 **I 帧编码器（IDR、单 slice、CAVLC、
Baseline 4:2:0 8-bit、平 QP）**，全部验证绿，已提交。

## 验证矩阵（全绿）

| 验证 | 口径 |
| --- | --- |
| CAVLC 残差性质测试 | 3000 随机模式写→自家 `h264_decode_residual` 读回逐值相等（含 4 个手工钉向量回归） |
| 重建不变量 | 编码器本地重建 == 自家解码器（跳滤波）输出，96×64 全平面逐字节 |
| **外部仲裁** | docker ffmpeg 9.0.2（nine-x264）零告警解码；**其 framemd5 `92f60474…` == 自家解码器开滤波输出逐位一致**（MD5 钉死在 `h264_encode_test.mbt`）；全链 编码→C 解码→MoonBit 解码三方闭环 |
| PCM 无损 | I_PCM 路径解码 == 源逐字节 |
| 确定性 | 双跑逐字节一致 |
| QP 阶梯 | 18/30/42 码长单调 |
| 裁剪 | 66×34 奇尺寸 SPS 裁剪路径 + I_PCM 逐字节 |
| 全量 | wasm **1722/1722**、`--deny-warn` 干净 |

## 文件

| 文件 | 内容 |
| --- | --- |
| `libavcodec/h264_enc_bitstream.mbt` | RBSP 位写入器（ue/se/trailing/防竞争转义；`finish_raw_of` 给裸 RBSP 消费者） |
| `libavcodec/h264_enc_ps.mbt` | SPS/PPS 序列化（含 raw RBSP 出口回读验证；裁剪序 left/right/top/bottom） |
| `libavcodec/h264_enc_dct.mbt` | 无移位 fdct + Hadamard + 量化 |
| `libavcodec/h264_enc_cavlc.mbt` | `h264_enc_write_residual` + pub 自检 `h264_enc_residual_roundtrip` |
| `libavcodec/h264_encode.mbt` | 主体（I_PCM/I16/I4x4、SAD 选模、本地重建镜像、nC/模式预测镜像） |
| `libavcodec/h264_encode_test.mbt` | 黑盒 8 测 |
| `libavcodec/h264_shadow_wbtest.mbt` | 调试工具：逐 MB 语法影子解析（native-only 门控） |

## 本切片修掉的标准级 bug（按发现顺序）

1. **CAVLC levels 先抽非零序列再反向编码**——`levels[last_idx-k]` 把中间的
   零也当 level 写（性质测试抓获）。
2. **level escape prefix=15 是 12 位后缀窗口**（R∈[30,4125)，`over=R-30`）。
3. **scan 表必须用 `h264_zigzag_scan_t`（转置系）**——`h264_scan4` 默认返回
   转置变体；run/total_zeros 全错位。
4. **MB 状态数组别名**——`Array::make(n, new_state())` 把同一结构体填满所有
   槽位，宏块提交互相覆盖（nC 级联污染；对照 `Array::make(channels, [])` 同坑）。
5. **量化移位定标**：无移位 fdct 配本解码器反量化为 **AC 21+qp/6、luma DC
   17+qp/6、chroma DC 16+qp/6**（经验推导 + 重建不变量验证；MF=13107 族）。
6. **chroma AC 的存储位 0 是 DC 槽**——AC 量化不得触碰（DC/AC 槽位复用冲突）。
7. **chroma DC 槽存原始 level**（`chroma_dc_dequant_idct` 自己反量化）；
   **ccb<2 时 AC 残差不得进重建**（解码器根本看不到）。
8. **I16 mb_type 模式序 V/H/DC/Plane**（`h264_i16x16_pred=[2,1,0,3]`）、
   **cbp 分组 [0,16,32,15,31,47]**（k0..2 无 luma AC、k3..5 才有）。
9. **trailing ones 按非零序列数**（扫描位置的零不截断 run）。
10. **SPS 裁剪序 left/right/top/bottom**（我最初写成 right,left,bottom,top）。

## 最后一课：假阴性排查

性质测试 iter 85/150 的「写码器 bug」其实是**测试夹具 bug**：
`h264_enc_residual_roundtrip` 把 `r.finish()`（**防竞争转义后**）直接喂给
裸 RBSP 读取器——原始流的 `00 00 01` 被插 0x03 后位流错位。修复用
`finish_raw_of()`。教训：**转义是 NAL 传输层语义，裸 RBSP 工具链（自检、
影子解析）必须绕过**。位级对账时也要注意 `finish()` 出来的位串含 0x03
插入（'11' 对），别把转义字节当编码 bug。

## 后续切片（按依赖序）

1. **P 帧 + 整素/分素 ME**：复用 `h264_mc.mbt` 的 MC 做 SAD/SATD 成本，
   mvd 的 CAVLC 写码，ref_idx 信令。
2. **多 slice / I16 率失真选模**（当前 SAD×6/5 启发式）。
3. **CABAC**（`h264_cabac.mbt` 的编码器方向）+ High profile 8x8dct。
4. **码率控制**（QP 决策、CBP 折衷）。

## 运行

```sh
moon test --target wasm libavcodec/h264_encode_test.mbt   # 8 测全绿（wasm 可跑）
moon test --target wasm --no-render                        # 1722/1722
# 影子调试工具（native，镜像内）：
#   moon test --target native libavcodec/h264_shadow_wbtest.mbt
```
