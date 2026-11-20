# AV1 编码器多参考交接 —— §463

日期：2026-11-20
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游：§462（RD×skip 联合决策，已提交 e9d04f7）

## 结果

让 inter 帧可以指定**参考槽位**与**参考索引**，不再固定「上一帧 + LAST」：

- `av1_enc_write_me_res420_inter_frame_obu` 增 `ref_slot~`（0..7）与
  `ref_idx~`（dav1d 0..6）：
  - `ref_slot` 决定帧头七个 `ref_frame_idx` 全部指向哪个槽，同时
    `prepare_frame` 的 ref_slots 也按它 gather —— 两者一致，保证块级参考
    解析到的就是该槽的画面；
  - `ref_idx` 决定块级 ref 树写哪条路径（LAST/LAST2/LAST3/GOLDEN/
    BWDREF/ALTREF2/ALTREF）。
- `av1_enc_inter_skip_block` 增 `ref_idx~`，把 ref 树、`rstate.find` 的
  `ref0+1`、`splat_single` 的 ref 索引、邻居状态 `ref0` 四处统一参数化。
- `av1_enc_write_me_res_tile` 增 `ref_idx~` 透传。
- 默认 `ref_slot=0, ref_idx=0` → 与 §446b..§462 的 LAST-only 行为完全一致。

## ref 树写端（镜像 av1_inter_read_refs 的单参考分支）

```
bit0=0, bit2=0, bit3=b  → ref0 = b        (LAST / LAST2)
bit0=0, bit2=1, bit4=b  → ref0 = 2 + b    (LAST3 / GOLDEN)
bit0=1, bit1=0, bit5=b  → ref0 = 4 + b    (BWDREF / ALTREF2)
bit0=1, bit1=1          → ref0 = 6        (ALTREF)
```

每位的 ctx 都走 `av1_inter_ref_tree_ctx(top, left, ctx_row)`，与解码端
`av1_inter_read_refs` 的 ctx_row 编号逐位对应。

## 验证

- 新黑盒 **4/4**（`av1_enc_multiref_test.mbt`）：
  - **七个参考索引 0..6 全部逐像素 decode==expected**（三平面）；
  - **ref 树真的写了不同位**：LAST 与 ALTREF 的包字节内容不同（长度相同
    但内容必须不同，否则说明索引没进码流）—— 这是防「参数被静默忽略」
    的关键断言；
  - 默认路径（slot 0 / LAST）确定性与既有行为不变；
  - `ref_slot=8`、`ref_idx=7` 被拒收。
- 回归全绿：encoder 8/8、RD 4/4、skip 5/5、NEARMV 2/2、RD×skip 4/4、
  inter 24/24、tile 12/12、frame 7/7（共 70）。
- `moon check --target wasm --deny-warn` 零警告；fmt/info 已跑。

## 边界与下一步

- **本片只做了「单参考 + 可任意选索引/槽」**，还没有：多参考候选选择
  （同一帧内不同块用不同参考）、复合预测（双参考）、参考帧环形缓冲的
  session 层管理（`Av1Encoder` 仍只保留上一帧重建）。
- 帧头 `ref_frame_idx` 七项全指向同一槽，因此跨索引的 MV 预测器候选
  （refmvs 按 ref 索引区分）尚未被真正利用——要发挥多参考收益，下一步
  应让 session 保留 N 帧重建并做 per-frame 参考选择。
- 再往后：复合预测（需要 `reference_select=1` + comp ref 树 + 加权平均）、
  以及分区树/变换尺寸（压缩收益最大但工程量也最大）。
- **§461 帧内模式选择的教训仍有效**：WIP 在
  `.trash/2026-11-20-av1-s461-wip/`，重做前应先写单块 V_PRED 对拍 wbtest。

## 交接给下个会话

本片改动**尚未提交**。提交信息避开 "del"/"rd" 子串（用 `git commit -F`）。
