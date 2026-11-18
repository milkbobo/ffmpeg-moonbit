# Agent 交接：AV1 纯 MoonBit 编码器 §438a–§445 全线完成（2026-11-18）

> 取代 `doc/handoff/AV1_ENC_HANDOFF_2026-11-17.md`（该文件保留为排障过程的历史
> 记录；本文件是当前权威交接）。用户指令：继续迁移 AV1 编码器，
> **wasm-only**（纯 MoonBit 自研路线——FFmpeg 树内无 AV1 软件编码器，
> C 绑定被 §437a wasm-only 决定排除；dav1d/libaom 只作算法参照）。

---

## 0. 一句话状态

**§438a–§445 十片全部完成且全绿**：msac 熵编码器 → 序列头 → 帧头/
OBU_FRAME → 最小 tile（skip=1）→ dc 残差（skip=0）→ SPLIT 多块 +
directional → AC tile 结构（4×32x32 + 双 ctx mirror）→ AC token
全系数链（base_tok/br_tok/golomb + levels 演化 → 非均匀残差）→
**多 tile 帧（uniform tile_info + 独立 per-tile msac/CDF + 尺寸前缀
交错）**。AV1 编码四套件 **28/28**（msac 7 + seq 5 + frame 7 + tile 9）；
解码端真实流全绿；全模块 wasm `moon check --deny-warn` 0/0。**未提交**。

## 1. 交付物清单（全部未提交，同树）

| 文件 | 内容 |
|---|---|
| `libavcodec/av1_enc_msac.mbt` | §438a+§443 熵编码器：encode_bool/bool_equi/symbol_adapt/bool_adapt/bools/uniform/**encode_hi_tok**（四层嵌套 escape=3）/**encode_golomb** + od_ec 进位链 carry_out + renormalize + done（全精度 4 字节 flush） |
| `libavcodec/av1_enc_msac_test.mbt` | round-trip 7 用例（含 2000 符号 × 双适应模式压力 + CDF 轨迹逐槽恒等 + hi_tok 全 escape 层 + golomb） |
| `libavcodec/av1_enc_seq.mbt` | §438b 序列头 OBU 写端（Av1SeqEncConfig + leb128 + OBU 封装 + TD） |
| `libavcodec/av1_enc_seq_test.mbt` | 写→parse 字段恒等 5 用例 |
| `libavcodec/av1_enc_frame.mbt` | §439+§444 key frame 帧头 + OBU_FRAME 写端（Av1KeyFrameEncConfig + tile_info sb 几何推导；§444：tiles 数组 + tile_cols/rows + uniform 增量位 + context_update/tile_size_bytes + tg 头 + 尺寸前缀交错） |
| `libavcodec/av1_enc_frame_test.mbt` | 帧头/tile group round-trip 7 用例（§444：2x1 水平 + 1x2 垂直多 tile 像素解码 + 六例非法配置） |
| `libavcodec/av1_enc_tile.mbt` | §440a/b + §441-§445 tile 写端：minimal / residual / split / directional / ac_tile / **av1_enc_txb_tokens**（通用系数写端）+ av1_enc_write_ac_token_tile + **av1_enc_write_modes_tile**（13 kfym 模式 + 角度增量 Y/UV + kfym 模式 mirror + skip ctx mirror） |
| `libavcodec/av1_enc_tile_test.mbt` | 像素 round-trip 12 用例（§443：非均匀残差 + 反对称 ±2 + br/golomb；§445：常量传播双帧 + 13 模式扫 + 六 delta 字节差异） |
| `doc/PORTING_HISTORY.md` | §438a/§438b/§439/§440a/§440b/§441/§442/§443/§444/§445 十节 |

## 2. 编码器架构（写端镜像自家解码器）

```
帧 → OBU_TD + OBU_SEQUENCE_HEADER + OBU_FRAME
                                    ├─ 未压缩帧头（H264Rbsp 位写入 + trailing bits）
                                    └─ tile group（单 tile，无 tg 位）
                                        └─ msac 熵载荷（Av1MsacEnc）
                                            ├─ partition 递归（partition ctx mirror）
                                            ├─ 每块：skip（skip ctx mirror）/kfym（mode mirror）
                                            │         /angle delta/uv_mode/txsz（tx ctx mirror）
                                            └─ 每块残差：coef_skip × 3 平面 → eob/tokens/dc_sign
```

**CDF 轨迹镜像**（§440a 定音）：写端直接拿 `av1_cdf_copy_defaults(qidx)`
的解码端上下文，同一 `FixedArray` 喂 `encode_symbol_adapt`——语法序逐位
镜像解码器，轨迹天然同步。

**上下文 mirror 四件套**（§442 三件 + §445 第四件 skip）：
- **partition ctx mirror**：pm_above/pm_left 16 槽，`part_ctx` 读
  `((part[bx8]>>(4-bl))&1) + (((part[by8]>>(4-bl))&1)<<1)`，`part_write_back`
  写 `al_part_ctx` 表值 over `imin(hsz,16)` 槽（SPLIT 不写回、BL_8X8 恒写）。
- **tx ctx mirror**：ta/tl 32 槽（reset_keyframe 初值 **-1**），每块 txsz
  depth 的 base `((max-1)*3 + tctx)*4`，tctx = `(tl[by4]>=lh)+(ta[bx4]>=lw)`
  ——**l-index 是块的 by4（垂直位置），不是 0**。
- **系数 ctx 初值 = 0x40**：reset_keyframe 的 lcoef/ccoef 全 0x40
  （非 0）——chroma skip ctx 的 `!=0x40` 判定给 ca=cl=0 → sctx=7；
  dc_sign 的 `>>6` 求和需 0x40（0x40>>6=1）。

## 3. 全部根因/教训档案（§442 四轮排障沉淀）

| # | 根因 | 修复 |
|---|---|---|
| 1 | eob_bin 512/1024 桶 base 是 `chroma*16`（[2][16] 布局），非联合索引 | 写端对齐解码器公式 |
| 2 | `get_skip_ctx` 必须传真实 bs（按 av1_bdim 分派） | 调用点传 bs0/bs16 |
| 3 | itx dc shortcut 的四步 181/shift 链是 dav1d 正确语义 | 勿动（误改直加曾致真实流红） |
| 4 | done() 的 `while v!=0` 丢尾部 0x00 字节 | 固定 4 字节 flush |
| 5 | od_ec 真源码重写曾破坏 §438a 位流兼容 | 还原；§438a 逐位实现是正确自洽的 |
| 6 | txsz tctx 逐块推导（左邻 tx ≥ lh → +1） | tx ctx mirror |
| 7 | 系数 ctx 初值 0x40 非 0 | 数组 0x40-init |
| 8 | skip 块 DC 预测继承邻居残差（≠128 是正确行为） | 断言改块内均匀 |

**排障方法论**（复用价值最高）：
- **Err 消息 sink**：trap/abort 吞 stdout → helper 加 `log:Array[String]` +
  `return Err(...)` 逐步 dump（fail 消息存活于测试报告）。
- **双侧 (base, n, sym) trace**：写端 ENC + 解码端 DEC 逐符号打印，用
  特征序列（如连续 5 个 n=9 sym=3）锚定目标测试段（防多测试 trace 交错）。
- **CDF 槽 dump 对照原表**：判读前/读后与符号值。
- **wasm-gc 内联后栈行号不可靠**：OOM 归属错行，一切以 Err sink 为准。

## 4. 验证基线

| 项 | 结果 |
|---|---|
| `av1_enc_msac_test.mbt` | 7/7（含 2000 符号压力 + CDF 轨迹恒等 + hi_tok/golomb） |
| `av1_enc_seq_test.mbt` | 5/5 |
| `av1_enc_frame_test.mbt` | 7/7（§439 4 + §444 多 tile 3） |
| `av1_enc_tile_test.mbt` | **12/12**（minimal/residual/split/directional/ac 结构 + §443 三 + §445 三） |
| 解码端真实流（grain/kf/tiles/hbd/qm/intrabc） | 全绿（未受影响） |
| 全模块 wasm deny-warn | 0/0，插桩零残留 |

## 5. 后续切片

| # | 切片 | 要点 |
|---|---|---|
| §446 | inter 基础 | 参考 slot/帧间预测——需帧头 inter 分支 + 参考管理 |
| 备选 | qmatrix / delta_q / CDEF / LR | 帧头已写 disable 位，按需开 |
| §443 | ~~AC token~~ **已完成** | `av1_enc_txb_tokens`：br_tok escape 符号 = n（合法，F(n)=0）、golomb 扩展 levels 只记 15、符号链 = 非零 ac 扫描位置升序、dc br ctx 无 14/7 基座、itx 反对称断言容 ±2（两趟舍入） |
| §445 | ~~intra 模式扩展~~ **已完成** | **skip ctx mirror = 第四 mirror（sctx = a.skip+l.skip，skip=1 写回 1）**——§441 split tile 曾绿而错（常数边缘断言盲区）；left 填充 = mid+1=129 / top = mid−1=127（仅角点）；边缘滤波混 topleft → 块内 spread 1 合法；angle delta 6 符号 → −3..+2 |
| §444 | ~~多 tile~~ **已完成** | 增量位 `while lvl<max && read1()` 镜像；rows 起点 = max(min_log2_tiles−cols_log2,0)（cols 之后推导）；size_bytes 移位只到 24 位（`1<<32` 回绕成 1）；单 SB tile payload 与帧起点 SB 同形（tile 起点上下文全新鲜，§440a 最小 tile 可直接复用）；帧套件 7/7 |

## 6. 工具链坑（AV1 线累积）

- `Int64→UInt32` 用 `.to_int().reinterpret_as_uint()`（Int64 无 reinterpret）。
- UInt 移位量用 Int（`v >> i` 非 `v >> i.to_uint()`）。
- `as` 是保留字（变量名用 allsk 等）。
- String 索引给 UInt16（无 charcode_at；`digits[i]` 直接作 Char 需 cast）。
- 测试循环禁 `for _i = 0; i = _i; ...` 阴影写法；`for (a,b) in arr` 可解构。
- fail() 需含 raise 签名的函数；Result 函数加 `raise`。
- Array 插值 `\{arr}` 弃用（拼字符串）。
- **wbtest 目标 = wasm-gc**（白盒单元 wasm 撞 V8 init 上限，doc/agent.md §2）。
- moon fmt 的 autofix 会改旧文件（Int32/方法化），diff 前先 fmt。

## 7. 提交清单（用户点名时）

```
git add libavcodec/av1_enc_msac.mbt libavcodec/av1_enc_msac_test.mbt \
        libavcodec/av1_enc_seq.mbt libavcodec/av1_enc_seq_test.mbt \
        libavcodec/av1_enc_frame.mbt libavcodec/av1_enc_frame_test.mbt \
        libavcodec/av1_enc_tile.mbt libavcodec/av1_enc_tile_test.mbt \
        doc/PORTING_HISTORY.md AV1_ENC_HANDOFF_2026-11-18.md
```

提交信息建议：`feat: AV1 §438a-§442 纯 MoonBit 编码器七切片——msac/
序列头/帧头/tile 全链 + AC tile 结构 round-trip 20/20`
