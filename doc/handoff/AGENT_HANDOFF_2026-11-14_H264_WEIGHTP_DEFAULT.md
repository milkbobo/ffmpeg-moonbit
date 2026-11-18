# H.264 §413 weightp 转正默认 + 收益门——交接文档

接续 `doc/handoff/AGENT_HANDOFF_2026-11-13_H264_HIGH10.md`（§412 High 10 已交付）。
本片把 `§410` 的 opt-in `weightp` 转正为默认，并在转正压力测试中修掉
**两个「全局拟合噪声」真 bug**。

## 这一片做了什么

### 1. 转正（§406 同款路数）

- 公开三入口翻默认：`h264_encode_frames`（h264_encode_p.mbt:283）、
  `h264_encode_frames_cabac`（h264_enc_cabac.mbt:2944）、
  `H264StreamEncoder::open`（h264_enc_stream.mbt:110）→ `weightp = true`。
  单帧 intra 入口与 PPS 写出辅助保持 false（dct8x8 的 §406 先例）。
- CLI：默认开；`--weightp` 变 no-op；`--no-weightp` 退出；usage 行更新。

### 2. 两个真 bug（转正压力测试的产出）

**Bug 1（luma 噪声拟合）**：移动方块内容最小二乘拟出 `w=29/o=13`（中性
32/0），加权后 SAD = 直接预测的 164%，RD PSNR 43.5→35.2 dB、round-trip
MAD 超阈、率控单调性破。第一版修法：整数化权重必须严格减小可见区 SAD。

**Bug 2（chroma 边缘收益 × skip 精确匹配）**：严格门修完后 rc fixture 的
P 帧 ~400B→~900B（2.2x）。机理：chroma 梯度半像素平移在零 MV 全图拟合下
`o=+1/+2` 有微小 SAD 收益（过了严格门），但真实 MC 里静止块是精确匹配
（残差 0），offset 平白造 ±1 残差 → skip 崩。**门的域错了**（零 MV 拟合域
≠ 实际 MV 预测域）。最终修法：显著性阈值 `sad_weighted*4 < sad_plain*3`
（改善 >25%）；只有真全局 fade/增益/色度渐变能过。moving fixture 的
chroma 逐帧 +1/+2 是精确全局增益 → 保留（i16_cut 场景切换 inter 腿省
339B 是真实收益）。

### 3. 重钉（收益门后）

- weightp 自测 5 项：对照腿显式 `weightp=false`；opt-in 测试改写为
  default-on 语义。
- vbv：flat/AU-bits/tight-buffer 钉值重钉（QP 轨迹不变）；ffmpeg 仲裁
  pins1/pins2 重钉（该测试按**解码序**遍历——显示序映射 slot=[0,2,1,4,3]
  逆排回填）。
- p_intra 比值门 1.8x→1.6x（chroma 加权使 inter 基线 2356→2017）。
- 六帧仲裁钉族（b/bi8/bintra×2/brc/cabac×2/cabacrd/rc×3/dct8×4/p×2，
  共 ~23 处 md5 + 3 处数值）：自动重钉循环（限 diff 形态+目标文件的
  §411 方法）。

### 4. 仲裁

- V413A（CAVLC 200000/60000/30）/V413K（CABAC 60000/12000/30）流 +
  显示序逐帧 md5（tmp_probe repo 根 native 包）；docker ffmpeg framemd5
  **10/10 MATCH 零告警**（产物 `.scratch/repin413/`）。
- ffref native 全套 **78/78**（10-bit 默认流带 PWT 与 oracle 一致）。

## 已知坑（新增）

- moon 输出两类失败行：`fail()` 类带 `FAILED:`、`inspect` 类只带
  `expect test failed`——**只 grep 前者会漏看大批 inspect 失败**（本片
  曾因此误判「只剩 5 个失败」实为 31 腿）。
- `moon test --update` 对变量 `content=pins[i]` 是**破坏性改写**（循环变
  单值字面量 + 多余空行）——本片复现 §411 记录，已回滚改用自动循环重钉。

## 验证矩阵

| 项 | 命令 | 结果 |
| --- | --- | --- |
| wasm 类型检查 | `moon check --target wasm --deny-warn --no-render` | exit 0 干净 |
| wasm 全族+CLI | 18 个 h264* 测试文件 + `cmd/encode-h264` | **153/153** |
| 白盒 | `moon test --target wasm-gc libavcodec/h264_enc_weight_wbtest.mbt` | 4/4（勿用纯 wasm——既有崩溃） |
| docker ffref | image 内 `moon test -p ffref` | **78/78** |
| ffmpeg CLI framemd5 | V413A/V413K | **10/10 帧 MATCH** 零告警 |

六帧仲裁钉族最终重钉面（自动循环 + 4 处手工点）：b（2 处流 md5）、
bi8（3 模式×3 帧变化）、bintra×2、brc（9 处）、cabac×2（8 处）、cabacrd
（off/rd 计数 1993→1919 + 5 处）、rc（ABR QP 序列 2 组 + i4p 计数/字节 +
AQ 仲裁 4 处 + dqp_mbs 22→21）、dct8（4 处，双熵 P-slice I8 新值分叉）、
p（4 处）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_weightp_test.mbt libavcodec/h264_enc_vbv_test.mbt --no-render
# docker 仲裁（产物在 .scratch/repin413/）
$env:MSYS_NO_PATHCONV='1'
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work ffmpeg-moonbit-ffref:nine-x264 -c "/root/.moon/bin/moon update >/dev/null 2>&1; /root/.moon/bin/moon test --target native -p ffref --target-dir /tmp/mbuild"
```
