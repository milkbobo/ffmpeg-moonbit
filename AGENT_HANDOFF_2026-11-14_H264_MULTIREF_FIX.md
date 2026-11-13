# H.264 §416 多参考正确性收口——交接文档

接续 `AGENT_HANDOFF_2026-11-14_H264_MULTIREF.md`（§415 语法层已交付，recon
不变式留为已知限制）。本片位级重诊该限制，**推翻"槽位错位"假设**，修复五个
连环真 bug，CAVLC 多参考达到全验证状态；CABAC×multi_ref 明确拒收。

## 五个真 bug（全部修复）

| # | 症状 | 根因 | 修法 |
| --- | --- | --- | --- |
| 1 | ref=0 的 skip MB recon 破 | `decide_plan` 探针已换指 `self.ref_y`→ref1，RD 选 Skip 后 `commit_skip` 读错平面（P_Skip 语法恒 ref 0） | `commit_skip` 开头指回 `refs_y[0]` + `cur_ref_mb = 0` |
| 2 | ref1 coded MB 纯 chroma 全 MB ±1/±2 恒差 | `mc_into_rec` weight_rect 的 **offset** 恒 `[0]`（§415 只改了 weight） | 两处 offset `[cur_ref_mb]` |
| 3 | 流式 mr=2 流无效 | `stream_idr` 漏传 `multi_ref~` → 流式 SPS/PPS 说 1、P 片写 ref_idx | 两熵 I 帧入口传 `self.nrefs` |
| 4 | CABAC 批式无多参考 | `cabac_qps` 无 refs 轮换 + PE/params 双字面量 `nrefs: 1` | 补 insert/truncate + 改 `multi_ref`/`refs_y.length()` |
| 5 | P1 的 PWT entry1 写出权重 1 | 中性填充界 `self.nrefs`（历史长度）且 CABAC 入口无填充 | 两熵以 `p.nrefs`（语法计数）为界补中性 |

诊断利器（复用）：前缀解码 + `dec.refs` 对编码 recon 逐像素（历史内容一致
性）；逐 MB diff + 解码镜像 `infos[mb].ref_idx`（失败 MB 定性）；AU 尺寸表
+ 交字节 dump（批/流式分叉定位）。

## 交付状态

- **CAVLC mr=2 全绿**：recon 不变式逐帧 md5、流式==批式逐字节、toggle 场景
  2115B vs 2750B（−23%，多参考设计场景的正向验证）、High 10 组合。
- **ffmpeg 仲裁**：移动 + toggle 双流 framemd5 **14/14 帧 MATCH**（滑动窗口
  "Missing reference" 提示同 §415，输出正确；产物 `.scratch/repin415/`）。
- **CABAC×multi_ref 拒收**：残差解析 EINVAL 与 wp/rd 无关——ref_idx 的
  CABAC 写/读 bin 级失步（表面逐行核对未现差异，需 bin trace 专项）。批式
  + 流式入口 `Err("...does not support CABAC yet")`。
- wasm 全族+CLI **166/166**；ffref native **78/78**（mr=1 字节不变）。

## 下一片候选

1. **CABAC ref_idx bin trace**：写/读两侧各打印前 N 个 MB 的 bin 序列
   （ctx 索引 + bit 值）对拍——`h264_cabac_put_ref` vs
   `h264_cabac_mb_ref`。修好后解除两入口拒收。
2. multi-ref 决策深化：best-ref 探针含 chroma SAD / RD 计价（现纯 luma
   16x16 SAD + 25% 门）。
3. B 切片多参考（需 B 的 ref list 管理接入编码器）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_multiref_test.mbt --no-render
$env:MSYS_NO_PATHCONV='1'
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit/.scratch/repin415:/data" ffmpeg-moonbit-ffref:nine-x264 -c "ffmpeg -y -hide_banner -nostdin -f h264 -i /data/MR3T.264 -f framemd5 /data/t.md5"
```
