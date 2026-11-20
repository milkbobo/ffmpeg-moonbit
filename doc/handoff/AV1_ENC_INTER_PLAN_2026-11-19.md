# AV1 编码器 inter 开工方案 —— §446 切片计划（2026-11-19 调研）

> 基于 `AV1_ENC_HANDOFF_2026-11-18.md`（§438a-§445 已完成、已提交
> 5ca3b4b + 90252b6 后续）的后续切片规划。本文件是 §446 的精确入口，
> 供下个会话直接开工。

## 现状

- §438a-§445：key frame 全链（msac/seq/frame 头/多 tile/SPLIT/角度/
  AC tokens/13 kfym 模式/四 ctx mirror）31/31 绿。
- 工作树的 av1_enc_* M 文件是 **fmt 格式漂移**（调用换行重排），无逻辑
  改动，随 §446 首次提交带走即可。
- HEVC 编码器线的经验直接映射（§449 P 帧/§450 分数 ME 是同构先例）。

## 解码端 inter 生态地图（写端镜像对象）

| 模块 | 规模 | 内容 |
|---|---|---|
| `av1_inter_block.mbt` | 418 行 | `av1_inter_read_block`：inter 块符号序核心（返回 MV/邻居状态） |
| `av1_inter_motion.mbt` | 158 行 | `av1_inter_read_block_motion`：mode/MV 读取 |
| `av1_inter_syntax.mbt` / `av1_inter_ctx.mbt` | — | 符号 ctx / intra_inter/skip ctx |
| `av1_inter_residual.mbt` | — | inter 残差（§443 tokens 链可复用） |
| `av1_refmvs_refs/_state.mbt` | — | 参考 slot/DPB/order hint；project/refmv 候选推导 |
| `av1_recon_inter.mbt` + `av1_mc_core/` | — | MC 重建（8tap 内核，编码端 MC 直接调用——HEVC 同款） |
| `av1_ref_header.mbt` | — | 参考帧头相关 |
| 帧头 inter 分支 | av1_decode2/3 | uncompressed header 的 INTER 段 |

`decode_inter_block`（av1_decode_inter.mbt）把 40+ 配置项打包进
`av1_inter_read_block` 的结构体参数——**写端镜像时同一结构体照抄**，
seq/帧头全关的开关项（masked/jnt/dual_filter/warp/interintra/
reference_select）让解码器不读那些符号，写端也不用写。

## 切片计划

### §446a 帧头 inter 最小分支

`av1_enc_frame.mbt` 扩展 `frame_type=INTER`：show_frame、ref_frame
（单 LAST slot）、order hint、loop filter/CDEF/LR 全关位、tx_mode、
reference_select=0、skip_mode_allowed=0、segmentation 关、
allow_warped_motion=0。逐位镜像解码端帧头 INTER 读取路径（先写测试：
写→parse 字段恒等，key frame 测试不动）。**先决**：读透
av1_decode2/3 的 inter 帧头分支（比 key 头多 ~1.5 倍位）。

### §446b 参考管理 + 全 GLOBALMV 帧（最小合法 inter 流）

- 编码端参考帧存储：一张参考图的平面 + 复用解码端 prepared refs
  结构（或最小镜像）。
- tile 级 inter 块写端：镜像 `av1_inter_read_block` 的**单参考
  GLOBALMV（零 MV）路径**——is_inter/ref_frame/GLOBALMV 选择符，无
  MV 编码、无 comp/interintra/warp（帧头全关 → 解码器不读 → 不写）。
  残差走 §443 `av1_enc_txb_tokens`。MC = 块拷贝（零 MV）。
- 测试：key 帧后跟一帧全 GLOBALMV inter（静止序列）→ 像素 round-trip
  == 参考帧；平移序列 → 残差链承载差异。

### §447 NEWMV + 整像素 ME

MV 编码写端（NEWMV joint→class→bits，镜像 av1_mvres 相关读取）+
整像素 SAD 搜索（HEVC §449 同款菱形/全搜）。is_inter=0 的 intra 块
走 §445 已有 intra 写端（inter 帧里的 intra 路径）。

### §448 分数 MV

1/8 pel ME + 8tap MC（调 `av1_mc_core` 解码内核——重建一致性 by
construction）。switchable_filter 关（帧头定 EIGHTTAP）。

### 之后（按需）

compound 双参考 / interintra / warped / obmc / delta_q / CDEF / LR。

## 风险与先例

- **最小路径策略**：只镜像「帧头全关 + 单参考 GLOBALMV/NEWMV」的
  符号序，复杂分支全部不进流——HEVC §449 的成功模式。
- **CDF mirror 既有基建**（§440a 定音）：inter 符号同样
  `av1_cdf_copy_defaults` + 同一 FixedArray 喂 encode_symbol_adapt。
- 帧头 inter 分支的位序是最大未知数——§446a 先行独立成片、写读
  恒等测试铺路。
- 排障方法论照搬 §443 档案（Err sink / 双侧 trace / CDF 槽 dump）。
- 工具链坑见 2026-11-18 交接 §6（as 保留字 / UInt 移位 / wbtest=wasm-gc）。

## 建议首片验证目标

§446a+§446b 合并为一个会话可完成的切片：
「key frame + 全 GLOBALMV inter 帧」两条 OBU 流，解码端像素级
round-trip（静止帧 inter 输出 == key 帧重建），31+2 测试全绿。
