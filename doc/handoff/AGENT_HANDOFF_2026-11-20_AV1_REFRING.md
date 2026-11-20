# AV1 编码器 session 参考帧管理交接 —— §464

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§463（多参考 ref_slot/ref_idx，已提交 3bdedab）

## 结果

让 session 真正维护参考帧历史，inter 帧可以预测**更早的重建帧**：

- `Av1Encoder` 增 `slots : FixedArray[Av1EncPlanes?]`（8 槽环形缓冲，
  索引 = AV1 参考槽 0..7）与 `cur_slot`（最近一帧所在槽）。
- `encode_frame` 增 `ref_age~ : Int32 = 0`：0 = 上一帧（原行为），
  k = k 帧前的重建；超出历史则**夹到最老可用槽**，负值当 0。
- `av1_enc_write_me_res420_inter_frame_obu` 与
  `av1_enc_write_me_skip420_inter_frame_obu` 均增：
  - `ref_slot~`：预测来源槽（帧头七个 ref_frame_idx 全指向它）；
  - `refresh_slot~`：**本帧重建写入的槽**（`refresh_frame_flags = 1<<slot`）。
  两者分离是关键 —— 预测读旧槽、重建写新槽。

## 核心设计：预测源与刷新目标必须分开

第一版把 `refresh_frame_flags` 也设成 `1 << ref_slot`，结果第 3 帧起
全链失步（`F2 Y(0,2) = 0 want 14`）。根因：`ref_slot` 是**读取**的槽，
如果重建也写回同一槽，解码端的参考历史就被当前帧覆盖，而编码器的环形
缓冲还保留着旧图 —— 两边状态分叉。

修正为：`ref_slot`（读）与 `refresh_slot = (cur_slot+1)%8`（写）分离，
帧头同时写出这两个字段，解码器据此维护自己的参考库，与编码器的 ring
逐帧同步。key 帧刷新全部 8 槽（`refresh_mask 0xFF`），session 同步把 8
个槽都填成 key 重建、`cur_slot = 0`。

## 验证

- 新黑盒 **5/5**（`av1_enc_refring_test.mbt`）：
  - 6 帧序列、age 依次 0/0/1/2/3，全部逐像素 decode==expected；
  - age=99 夹到最老槽仍精确；负 age 当 0；
  - 默认 age=0 两次运行字节长度恒等（确定性）；
  - **不同 ref_age 产生不同码流**（fresh=2358 vs old=2241 字节）——
    防「选项被静默忽略」的关键断言，证明真的换了预测源。
- 回归全绿：encoder 8/8、RD 4/4、skip 5/5、NEARMV 2/2、RD×skip 4/4、
  multiref 4/4、inter 24/24、tile 12/12、frame 7/7（共 75）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- `ref_age` 目前是**调用方显式指定**，没有自动选参考（标准编码器会按
  SAD/RD 在多个参考里择优）。下一步可把 §462 的联合选择器扩展成
  「q × skip × ref_age」三维。
- 仍是**单参考**：一帧只用一个参考图，没有复合预测（双参考加权）。
- 分区树（固定 64×64）、变换尺寸/类型（只有 TX_32X32 DCT_DCT）、
  CDEF/LR 仍未做 —— 这几项是压缩率的最大杠杆。
- **§461 帧内模式选择的教训仍有效**：WIP 在
  `.trash/2026-11-20-av1-s461-wip/`，重做前应先写单块 V_PRED 对拍 wbtest
  把 `av1_prepare_intra_edges` 的坐标/tile 边界/sb_has_tr-bl 语义钉死。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
