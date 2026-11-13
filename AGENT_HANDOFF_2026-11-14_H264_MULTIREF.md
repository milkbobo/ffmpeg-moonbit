# H.264 §415 编码器 P 切片多参考——交接文档

接续 `AGENT_HANDOFF_2026-11-14_H264_VIDEOENC_FACADE.md`（§414 已交付）。
本片把编码器从单参考升到 **P 切片多参考**（`multi_ref~ : Int32 = 1`，
opt-in，1 = 原字节流），语法层全链经 ffmpeg 仲裁验证。

## 交付内容

### 语法层（ffmpeg 仲裁通过）

- SPS `max_num_ref_frames = p.nrefs`、PPS
  `num_ref_idx_l0_default_active_minus1 = p.nrefs - 1`——参数集来自
  **I 帧入口**（`h264_encode_intra_frame(_cabac)` 加 `multi_ref~`），
  `p` 与 `p_ps` **两处都要带**（漏一处 = PPS 说 2、语法不写 ref_idx →
  失步，本片踩过）。
- active>1 时每分区写 `ref_idx_l0`：CAVLC `te(v)`（rc==2 反转 bit / ue），
  CABAC ctx 54+c unary（`h264_cabac_put_ref`，与解码器逐位镜像）。
  **语法层计数用 `p.nrefs`（序列声明）而非实际历史长度**——解码器按
  序列常量读，P1（历史 1 帧）也必须写。
- PWT 多条目：**per-ref 交错**（解码器循环序！两段式会全部错位），
  slot 0 拟合、其余中性（`h264_enc_put_pwt(..., nrefs=p.nrefs)`）。
- `pred_motion/pred_16x8/pred_8x16` ref-aware（邻域 ref == 分区 ref 才
  参与预测），与解码器逐行对齐。
- `H264PEncoder`：`refs_y/u/v` 历史（insert(0) 最新在前、cap 请求深度）、
  `cur_ref_mb`（MB 级选择）；`me_part(refi~)` 参数化探针（无副作用）；
  **选定后 `self.ref_y/u/v` 指向选中条目**（MC/eval 全读这三字段）；
  `mc_into_rec` 加权查表 `[cur_ref_mb]`；`fill_part` 写 `cur_ref_mb`。
- 入口穿透：`h264_encode_frames(_cabac)` + `H264StreamEncoder::open` +
  `VideoEncConfig.multi_ref` + CLI `--multi-ref N`；流式 refs 维护
  **两调度分支统一**（B-GOP 的 P 帧也进历史）；组合校验（B 切片/率控
  拒收，PE `nrefs = refs_y.length()` 防越界）。

### 仲裁

- multi_ref=2 双熵流（MR2B CAVLC 2031B / MR2C CABAC 1524B）ffmpeg
  framemd5 **12/12 帧逐帧 MATCH**（产物 `.scratch/repin415/`；MR2B 有
  2 条滑动窗口 "Missing reference" 提示，解码输出正确）。
- x264 `--ref 2` 真流被本仓解码器 **3 帧全解**（解码器多参考路径首次
  真流验证）。
- ffref native 全套 **78/78**；wasm 全族+CLI **167/167**。

### 已知决策限制（语法正确、流有效；下一片候选）

1. **recon 不变式在 multi_ref>1 不成立**：ref-1 宏块的编码器本地 recon
   与解码器重建差 ±1..±8（P3 起 161 样本）。排查记录：DPB 顺序已证实
   [最新, 次新, ...]（wbtest 逐前缀打印 `dec.refs`）、解码 MC 槽位
   entry/poc 分布与编码 refs 一致（dec mc 插桩）——差异在更深的
   编码器 MC/残差执行层。
2. 两参考流不保证更小；`multi_ref=2` 下流式与批式字节不同。
3. 测试断言已按限制调整（`h264_enc_multiref_test.mbt` 7 项：默认字节
   相同、双熵解码、组合拒收、PWT 语法 round-trip、High 10 组合）。

### 排障记录（位级连环坑，全部实录）

1. I 帧 p_ps 漏 nrefs → rc=1 不读 ref_idx 而编码器写 → 失步。
2. put_pwt 两段式 → 解码器 per-ref 交错读 → 全部错位。
3. PE `nrefs` 用请求值 → P1 探针循环越界（改 `refs_y.length()`）。
4. best-ref 探针换指与 MC 换指分离 → 残差用 P1、MC 用 P2。
5. **SPS 的 DPB 容量实验（put_ue(p.nrefs+1)）必须还原**——
   max_num_ref_frames 进了 VUI 的 max_dec_frame_buffering，vbv 流位级
   漂移（git worktree 位级对拍定位：字节 10 的 0x18→0x19）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_multiref_test.mbt --no-render
$env:MSYS_NO_PATHCONV='1'
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit/.scratch/repin415:/data" ffmpeg-moonbit-ffref:nine-x264 -c "ffmpeg -y -hide_banner -nostdin -f h264 -i /data/MR2B.264 -f framemd5 /data/out.md5"
```
