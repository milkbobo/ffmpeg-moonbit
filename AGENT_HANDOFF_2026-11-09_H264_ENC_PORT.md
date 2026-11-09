# H.264 纯 MoonBit 编码器——切片状态（§376 I 帧 + §377 P 帧，已完成）

## 状态

用户指令：**不能用 C FFI，把编码功能整体移植成纯 MoonBit**。§375 的 libx264
绑定降级为对拍 oracle。已交付两个切片（均已提交）：

- **§376 I 帧**：IDR、单 slice、CAVLC、Baseline 4:2:0 8-bit、平 QP，
  I_PCM/I16/I4x4。
- **§377 P 帧**：P_Skip + P_L0_16x16、单参考（前帧重建）、±16 整素 SAD +
  MC 四分素精化的 ME、inter 残差（矩阵 3/4/5）、mb_skip_run。

## 验证矩阵（全绿）

| 验证 | 口径 |
| --- | --- |
| CAVLC 残差性质测试 | 3000 随机模式写→读逐值相等 + 钉向量 |
| 重建不变量 | 编码器本地重建 == 自家解码器（跳滤波），96×64 全平面逐字节 |
| **外部仲裁** | docker ffmpeg（nine-x264）零告警；I 帧 `f638094d…`、I+P 四帧 `e454d8…/a8a44b…/970f51…/87806a…` 与自家解码器逐帧一致（MD5 钉死） |
| PCM 无损 / 静态场景纯 skip / 确定性 / QP 阶梯 / 裁剪 | 全绿 |
| 全量 | wasm **1727/1727**、`--deny-warn` 干净 |

## 文件

| 文件 | 内容 |
| --- | --- |
| `h264_enc_bitstream.mbt` | RBSP 位写入器（ue/se/trailing/防竞争；`finish_raw_of`） |
| `h264_enc_ps.mbt` | SPS/PPS 序列化（raw RBSP 回读；裁剪序 L/R/T/B） |
| `h264_enc_dct.mbt` | 无移位 fdct + Hadamard + 量化（3 类 MF = 2^17/init、AC 21+qp/6）+ `h264_enc_dequant_level`（解码器镜像填充） |
| `h264_enc_cavlc.mbt` | `h264_enc_write_residual` + pub 自检 `h264_enc_residual_roundtrip` |
| `h264_encode.mbt` | I 帧主体（I_PCM/I16/I4x4、SAD 选模、本地重建镜像） |
| `h264_encode_p.mbt` | P 帧（`h264_encode_frames` GOP、pskip/pred_motion 镜像、ME、skip_run、inter 残差/重建） |
| `h264_encode_test.mbt` / `h264_encode_p_test.mbt` | 黑盒 8 + 5 测 |
| `h264_shadow_wbtest.mbt` | 调试工具：逐 MB 语法影子解析（native 门控） |

## 关键语义（续做前必读）

1. **量化刻度**：MF = 3 类 `2^17/dequant4_init`（13107 族）；AC shift
   21+qp/6、luma DC 17+qp/6、chroma DC 21+qp/6；mb 填充 =
   `(level*qmul+32)>>6`（`h264_enc_dequant_level`）。重建不变量测不出刻度
   错误（自洽），必须看质量度量。
2. **CAVLC levels** 先抽非零序列再反向；escape prefix=15 是 12 位窗口
   [30,4125)；trailing ones 按非零序列数；scan 用转置系 `h264_zigzag_scan_t`。
3. **I16 语法**：mb_type 模式序 V/H/DC/P；cbp 分组 [0,16,32,15,31,47]
   （k0..2 无 luma AC）。
4. **P 帧**：pskip/pred_motion 镜像含 match-count 中值与 pskip 早退；
   mb_skip_run 片尾残留**必须写出**；inter cbp 48 表反查；单参考
   ref_idx 不编码。
5. **ME 零 MV 偏置**：平移不变内容（梯度/平坦）大量 MV 并列，先测 (0,0)、
   严格更优才替换。
6. **状态数组别名**：`Array::make(n, new_state())` 共享实例——逐个 push。

## 工具链坑

- **黑盒测试文件里 `b''` 字面量触发 moonc ICE**
  （`Invalid_argument("Moonc.Basic_ba_int.get")`）——用重载字面量
  `let mid : Byte = 128`。
- 白盒 wasm 可执行体 V8 init 局部数上限贴边——测试放黑盒、私有自检做
  pub 函数、顶层表改 match 常量、调试文件 native 门控。
- `Int32 == Int`：表读取的 `.to_int()`/`.reinterpret_as_int32()` 多余；
  C 式 for 循环变量不能用 `_`；String 索引 `.to_string()` 是十进制数字。

## 后续切片

1. **P_8x8 / 16x8 / 8x16 分割** + sub_mb_type（语法骨架已在解码器侧）。
2. **率失真选模**（当前 SAD 启发式 + I4x4 顺序贪心）。
3. **CABAC**（High profile + 8x8dct）。
4. **码率控制**（QP 决策、CBP 折衷、B 帧）。

## 运行

```sh
moon test --target wasm libavcodec/h264_encode_test.mbt     # 8 测
moon test --target wasm libavcodec/h264_encode_p_test.mbt   # 5 测
moon test --target wasm --no-render                          # 1727/1727
```
