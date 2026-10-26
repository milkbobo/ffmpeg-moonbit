# AV1 整帧入口：状态基础接续（2026-10-26）

> 后续实现见 [INTER_SESSION](AGENT_HANDOFF_2026-10-26_INTER_SESSION.md)
> 和 PORTING_HISTORY §96：inter 主体、会话、GM warp 与真实流 MD5 已接入。
> 以下保留本阶段历史状态，不再代表当前待办。

本轮从 `8cd7860` 接续。改动保留在工作区，未提交、未推送；`agent.md` §3
要求用户明确授权才提交。本报告补充 FRAME_ENTRY，不代表整帧已可解码。

## 已完成与验证

- G1 前置：`Av1InterTileState::set_block` 接收绝对坐标，写入 `&31`
  上下文；`reset_left` 只清 left。回归使用 x4=36/68、y4=66，验证
  上下 bank 独立、共享 left 的重置和 top 跨行保留。96 组既有 inter
  block C 对拍仍通过。帧级 top bank 数组尚未创建。
- G3 语法：新增 `av1_segment.mbt`，三个分支统一为 `read_id`：
  不更新 map、temporal 预测、空间预测（含 postskip skip 不读符号）。
  `decode_b` 已改用该读取器，发布真实 seg_pred，只在 update_map 时写
  cur_segmap；旧 map 已在 skip 前选定时，其 segment feature 也参与 skip。
  **当前帧入口仍只解 keyframe，`prev_segmap` 初始化为 None。** 后续会话
  必须按 coded-grid 匹配选 primary ref segmap，不能把此语法测试当端到端验证。
- G3 帧头：保留 segmentation_update_map / temporal_update / update_data。
  `av1_ref_slot_state_from_header` 保存独立 feature 数组和 GM 数据；
  update_data=false 从 `refs[ref_frame_idx[primary_ref]]` 逐字段继承
  mask/ALT_Q/ALT_LF/ref/skip/globalmv/preskip/last_active，重新派生 qidx/lossless。
  缺 primary header 时返回错误。旧 geometry-only 构造器仍可用于不需继承的帧。
- G4 前置：`Av1CdfCtx::copy` 深拷贝全部 **82** 个表。测试逐表逐元素
  改写源、快照，确认第三份 tile 快照完全隔离。尚未接 frame-end CDF
  选择和槽位刷新；copy 本身不执行 dav1d_cdf_thread_update 的计数/padding 处理。

96 组新增分段 C 对拍：从 dav1d 1.5.1 decode.c 提取原文 helper 和两段
decode_b 分支，链接其 msac/cdf；比较 id、seg_pred、rng、dif 高32位及
seg_pred/seg_id 全表。覆盖 preskip/postskip、skip、缺旧 map、tile 边可用性、
last_active=0..7、CDF 更新开关与末行最小值。

注意原交接的 `get_prev_frame_segid` 描述错误：上游遍历 w4×h4 取最小值，
遇到零才提前结束；不是首单元一致性检查。C unsigned 的 neg_deinterleave
结果在 MoonBit 中也要把负数夹成零。

## 再生与检查

新自动化均为 `.mbtx`：

1. `moon run scripts/emit_av1_cdf_copy.mbtx`
2. `moon run scripts/emit_av1_segment_oracle.mbtx`（本机 Temp/dav1d-src）
3. 用现有 Temp/mvres-tar.tar 的 config.h/dav1d 源，在 vpxdev-img 中编译
   `.scratch/av1/segment_reference.c`，链接 src/msac.c、cdf.c、ref.c、tables.c，
   stdout 写 `.scratch/av1/segment_reference.txt`。
4. `moon run scripts/emit_av1_segment_vectors.mbtx`
5. 头部 fixture 来源：ffmpeg `testsrc2=size=160x120:rate=5`，8帧，
   libaom-av1、cpu-used=6、crf=30、aq-mode=1、lag-in-frames=0、g=30；
   输出 `.scratch/av1/seg_inter.ivf` 后运行
   `moon run scripts/emit_av1_segment_header_fixture.mbtx`。

头部回归先在真实 P2 header 中插入完整 feature syntax，再分别读取三种
update_data=false 的 map/temporal 组合。P2 primary_ref=0，但 refidx[0]=1，
只有 slot 1 保存特征，验证间接索引与双向数组隔离。帧头 fixture 仅保留
32字节前缀，不能当成像素解码向量。所有新大向量置独立 av1_segment_vectors 包；
主包 wbtest 的 Wasm init 局部变量已经接近上限。

最终验证：`moon check --target wasm --deny-warn --no-render` 零警告；
Wasm 全量 **960/960**；`moon info --target wasm` 已运行，生成接口按原约定不提交。

## 下一步

继续 FRAME_ENTRY 的 G1：inter/intra 标志、inter 帧内 intra 的 y_mode CDF、
inter 分支 vartx/recon/LF/上下文回写，新增帧级 top bank 和 rstate。
随后 G4 会话槽位与 sbrow×tile 主循环，先让单 key+2P MD5 收敛。
参考头还需接 loop-filter mode/ref delta 的 primary 继承（已保存所需数组）；
目前 parser 仍使用默认 delta，这不是本轮已完成项。
G2 GM warp、G5 superres、G6 多格式真实 inter 流仍未完成。
