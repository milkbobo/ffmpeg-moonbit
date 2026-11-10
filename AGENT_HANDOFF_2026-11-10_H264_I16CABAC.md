# AGENT_HANDOFF_2026-11-10 — H.264 纯 MoonBit 编码器:I16x16 CABAC 分支(§382)全绿

## 本片结论

`h264_enc_cabac.mbt` 的 Intra16x16 分支完成并全绿:决策、redo、语法、
残差、提交。**编码器 CABAC 全部语法面现已走通 I 全 I4/I16 混合 +
P Skip/四分割**,QP22 六帧(含 I16 宏块)docker ffmpeg 零告警
framemd5 六帧与本仓自解码逐帧一致(钉值已进黑盒测试)。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn` | 零警告 |
| 黑盒 `libavcodec/h264_enc_cabac_test.mbt`(宿主 wasm) | **10/10** |
| 全量 Wasm(**--target wasm-gc**) | **1723/1723** |
| 非 gc Wasm 其余包(cmd/avutil/avformat/swr/swscale/wasm_probe) | **841/841** |
| x264 解码 oracle(docker native) | **7/7** |
| libavcodec whitebox 非 gc Wasm | **编译不过**(见下"V8 局部数上限") |

## 两个真因(都是"纸面对、实证杀")

1. **mb_type mode bins 的 +c 是错的**。`decode_cabac_intra_mb_type`
   I-slice 续段:首 bin `@3+c`(c=左/上是否 I16/PCM 的计数),
   **此后 `state += 2` 不含 c**——b0@6、b1@7、b2@8(仅 b1=1 才读)、
   b3@9、b4@10。FFmpeg C 源 `libavcodec/h264_cabac.c`
   `decode_cabac_intra_mb_type` 逐行证实(`&state[1]`…`&state[3+2*intra_slice]`)。
   症状特点:第 1 个 MB(c=0)六个 bin 恰好全对齐,失步从第 2 个 MB
   才开始;读端解出 pred=V 后第一行 MB-1 报 "unavailable top samples",
   或(单 MB)chroma 读到垃圾 DC。**教训:摘要/交接描述不算数,要么读
   本仓解码器真身、要么读 FFmpeg C 源;失步必须上 bin 级 zip 探针。**
2. **`luma_cbp` 无条件 OR**:I16 redo 的 AC 块循环需按
   `total != 0` 门控 `luma_cbp |= 1 << (i/4)`,否则平场全零也置 15,
   group 恒 ≥3,每 MB 多写一串零 cbf bins(可解但费码+形态错)。

## bin 级 zip 探针方法论(下次失步先做这个,~15 分钟)

1. 读引擎两端加包级门控 trace(默认 off,一条全局开关):
   - `cabac.mbt` 的 `get_cabac` / `get_cabac_terminate`:push
     `"R d{ctx}={bit}"` / `"R term={v}"`;
   - `h264_enc_cabac.mbt` 的 `H264CabacEnc::decision` / `terminate`:push
     `"W d{ctx}={bit}"` / `"W term={bit}"`。
   注意:顶层 mutable 需 `priv struct Ctl { mut on: Bool }` +
   包内 fn 设值,不然 moon 编译期报 unused_mut/未绑定。
2. 临时 wbtest(如 `h264_i16_probe_wbtest.mbt`):开 trace 编码
   (最小复现 fixture,平场 96×64 必触发 I16)、关 trace、清空数组、
   开 trace 用 `h264_decode_annexb_frames` 解码、关、zip 打印
   `i  W…  R…  <<<`。
3. 跑 docker native:`moon test --target native -p
   milkbobo/ffmpeg-moonbit/libavcodec -f 'zip probe*' --target-dir /tmp/mbuild`
   (`-f` 是**名字 glob**,不是文件路径;宿主上 `-f` 语义不同)。
4. 对齐从首个 bin 起;写=读逐行同值即收口。探针用完删干净
   (trace 钩子 + wbtest 文件)。
- 本次实证:96×64 平场 312 vs 312 bins 全对齐;24 个 MB 全部
  mb_type 7(cbp group1 + DC),~13 bins/MB,chroma DC 来自
  u/v=96 对边缺 DC pred=128 的 −32 残差(合法非零)。
- 引擎怕事先排除:平场首 MB 中流 `terminate(0)`(PCM reject)
  往返无损,已沉淀为 `cabac_wbtest.mbt`
  "cabac: mid-stream terminate(0) round-trips"(保留)。

## 判读准则(本次新钉)

- **recon ≠ 源 ≠ bug;recon ≠ enc.recon 才是 bug**。单 MB 16×16 平场
  的 "chroma recon 126" 是量化正常现象:首 MB 色度无邻边 → DC
  pred=128,u=96 的 DC 残差 −32(QP26)dequant 回 −2,128−2=126。
  黑盒断言一律与 `enc.recon_y/u/v` 对拍(既有 recon 不变式同法)。
- I16 决策规则:`use_i16 = i16_found && !(100*i4_cost < 94*i16_cost)`
  (I4 须便宜 >6%,平局选 I16)。
- CAVLC I16 分支教训同样适用于 CABAC:**AC 的 fdct 跑完整残差
  (含 (0,0))再丢 levels[0]**,不可清零 (0,0) 再 fdct。

## V8 局部数上限(新常态)

libavcodec 的 whitebox wasm 在非 gc 后端撞 V8 单函数局部数上限
(`__moonbit__init` local count too large)——本片代码增量成为最后一根
稻草(HEAD 下 676/676 过,加 I16 后编译不过)。**解法:全线改用
`--target wasm-gc` 跑全包套件**,同文件 673+黑盒全过。历史先例(把大
vectors 表拆分包)对本例不适用,whitebox 需同包 priv 访问。以后:
- 全包/全仓门:`moon test --target wasm-gc`;
- 单文件回归可继续 `moon test --target wasm --no-render <file>`;
- 文档/交接里把 whitebox wasm 门记 wasm-gc。

## 仲裁证据(重放命令)

QP22 六帧(95%+ MB 为 I16 at QP22 的 moving fixture)已钉:

```sh
# 1) ARB dump → Annex B
python .scratch/rd_dump_to_bin.py .scratch/arb22.txt .scratch/arb22.264
# 2) docker ffmpeg framemd5
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" \
  -w /work ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -y -v warning -i /work/.scratch/arb22.264 -f framemd5 -c:v rawvideo /work/.scratch/arb22.md5"
```

钉值 `e590592c…/7ad1fd5f…/5b307436…/bfaf8880…/a4332b24…/baa04a02…`
(黑盒内 "ffmpeg-arbitrated QP22 I16 frames")。QP24 旧钉值
`e454d8…/a6814a…/74ecad…/791ea2…/aa4569…/884043…` 未动——该 fixture
在 QP24 下 I4 仍胜 >6%,I16 未触发,流不变化(测试直通)。

## 运行速查

```sh
# 编码器黑盒(宿主 wasm)
moon test --target wasm --no-render libavcodec/h264_enc_cabac_test.mbt

# 全包套件(wasm-gc,避开 V8 局部数上限)
moon test --target wasm-gc

# x264 oracle / libavcodec native(docker nine-x264)
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" \
  -w /work ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"
```

## 可选后续片

1. P 帧内部分支 I16(CABAC ctx_base=17、intra_slice=0——注意
   `b2` 仅 b1=1 且 b1/b2 都 @19;b3/b4 同 @20;与 §382 的 I-slice
   表不是一套数字,写端同函数要按 intra_slice 分叉)。
2. CABAC 8x8dct(transform_8x8_mode 的 I16x16/I8x8 组合)。
3. 码率控制/广义 RD(lambda 已有 `h264_rd_lambda`,QP 恒定)。
4. x264 oracle 扩 I16 内容用例(现 7 个用例未专门构造 I16 密集流)。

## 权威文件

- `libavcodec/h264_enc_cabac.mbt` — 编码主文件(I16 分支 ~L1155-1440)
- `libavcodec/h264_cabac_mb.mbt` — 解码权威镜像
  (`h264_cabac_intra_mb_type` L410、`h264_decode_mb_cabac_intra` L973)
- `D:\project\FFmpeg-n9.0.2\libavcodec\h264_cabac.c` — FFmpeg C 源
  (本仓可直查;`decode_cabac_intra_mb_type` 语义已逐行证实)
- `libavcodec/h264_enc_cabac_test.mbt` — 10 项黑盒(含 QP22/QP24 双钉)
- `AGENT_HANDOFF_2026-11-10_CABAC_ENC.md` — 前一片(§381)交接
- `.scratch/rd_dump_to_bin.py` — ARB dump → Annex B 工具
