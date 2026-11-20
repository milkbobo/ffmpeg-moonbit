# AV1 编码器去块收口交接 —— §468d

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§468c（inter 帧去块，已提交 4abab39）

## 结果

1. **skip 混合路径接上环路去块**：`av1_enc_write_me_skip420_inter_frame_obu`
   增 `loop_filter_level0~` / `loop_filter_level1~` / `loop_filter_sharpness~`，
   把该帧真实的 `skips` 数组传给 `av1_enc_deblock_frame_inter`；session 的
   skip 分支透传。
2. **修掉 §468c 的一个多 SB 真 bug**（见下）——之前只测 64×64 单 SB
   所以没暴露。

## 核心 bug：mask 与滤波循环按「128 宽区域」组织，不是按 64×64 SB

这是本轮最重要的发现，也是之前多 SB 帧 decode≠expected 的根因。

解码器即使 `use_128x128_superblock = 0`，`lf_mask` 仍按 **128×128 区域**
索引：

```
f.lf_mask[(by >> 5) * f.sb128w + (bx >> 5)]     // >>5 = 128px 单位
```

也就是说**一个 128 宽区域内的两个 64×64 SB 共享同一个 mask 对象**，滤波
循环也以 `sb128w` 为列数、以 `x * 128` 像素步进。

我第一版按 64×64 SB 数分配 mask、按 SB 列号循环，单 SB 帧恰好正确，
一旦帧宽超过 64（两个 SB 同行）就失配——表现为 Y 差 110 个像素。

修正为：
- `masks` 按 `sb128w * sb128h` 分配；
- 构造时索引 `(by >> 5) * sb128w + (bx >> 5)`；
- 滤波循环用 `sb128w` 列、`x * 128` 步进。

**教训：dav1d 的 lf_mask / cdef_idx 是「128 区域」粒度，不是 SB 粒度；
即便用 64×64 SB 也必须按 128 区域组织，且单元测试必须覆盖多 SB 帧
（单 SB 会掩盖这类错误）。**

## 另外两处 skip 相关的修正

skip 块的 mask 与残差块不同：

| | 残差 SB | skip SB |
|---|---|---|
| var-tx | SPLIT 四叶 TX_32X32 → `tx_masks = [1,0]` | 不写 var-tx 符号，整块 TX_64X64 → `tx_masks = [0,0]` |
| level 选择 | ref=LAST 且非 global → 索引 `(0+1)*2+1 = 3` | GLOBALMV（global）→ 索引 `(0+1)*2+0 = 2` |

两者都必须**按 SB 分别选择**，不能整帧用一套。

## 验证

- 新白盒 **5/5**（`av1_enc_deblock_skip_wbtest.mbt`）：
  - skip 混合帧 lf = 8 / 32 / 63 三档 `decode == expected` 均 `Y=0 UV=0`；
  - **基线 lf=0 本就精确**（先证明这一点，才能把 lf 的差异归因于滤波）；
  - 探针确认解码器对该帧确实滤波（126 像素变化）；
  - 默认 lf=0 与显式 lf=0 码流逐字节相同。
- `av1_enc_deblock_inter_wbtest.mbt` 扩到 **4/4**，新增**多 SB（128×64）**
  用例（lf=16/48 均精确）——正是这个用例抓出了上面的 128 区域 bug。
- 回归全绿 **99 个测试**：encoder 8/8、refring 5/5、RD 三维 5/5、RD 4/4、
  skip 5/5、NEARMV 2/2、RD×skip 4/4、multiref 4/4、ME 复用 4/4、
  loop-filter 3/3、deblock-intra 3/3、deblock-inter 4/4、deblock-skip 5/5、
  inter 24/24、tile 12/12、frame 7/7。

`moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 现在的覆盖范围

编码器侧环路去块**已覆盖全部当前形态**：

- 帧类型：intra key 帧 + inter 帧
- inter 两条路径：全残差（§468c）+ skip 混合（本片）
- 任意 SB 网格（含多 SB）
- 4:2:0、8-bit

## 剩余缺口

- **tile 边界强度修正**（解码端 `lf_sbrow_cols` 里 `tile_cols > 1` 的分支）
  未做；当前编码器按 SB 分 tile，多 tile 时需要补。
- **CDEF**、**LR** 未做。CDEF 可照 §468 的模式：解码端 `av1_cdef` 已有，
  复用内核 + 自写帧级驱动。
- 高位深 / 其它色度格式未接。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
