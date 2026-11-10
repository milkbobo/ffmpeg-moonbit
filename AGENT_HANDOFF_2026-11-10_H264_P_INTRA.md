# AGENT_HANDOFF_2026-11-10 — H.264 CAVLC P 切片 Intra16x16（§383）全绿

## 本片结论

接手工作树里编译不过的 WIP（P 帧 intra 半成品），收口成 **CAVLC P slice
的 Intra16x16 完整分支**：决策 → 预测重放 → Hadamard DC/AC 残差 → 语法 →
重建 → 状态提交 → 双重外部仲裁。做成 **opt-in**（`intra_in_p=true`），默认
关闭，既有钉值与 CABAC 链逐字节不变。

| 检查门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn --no-render` | 零警告 |
| `moon check --target native libavcodec/x264` | 干净 |
| 新黑盒 `libavcodec/h264_encode_p_intra_test.mbt` | **3/3** |
| 旧 CAVLC `h264_encode_p_test.mbt` / CABAC `h264_enc_cabac_test.mbt` | **8/8** / **10/10** |
| 全量 `moon test --target wasm-gc` | **1726/1726** |
| docker ffmpeg 9.0.2（`nine-x264`） | 零告警，framemd5 三帧与自家解码器逐帧一致 |
| x264 native oracle（docker，`-p .../libavcodec/x264`） | **10/10**（7 旧 + 3 新） |
| ASan runner | **不适用**（见下，非代码问题） |

## 定位过程（下次失步照抄）

1. 先判读准则：**`recon ≠ 源` 不是病，`recon ≠ enc.recon` 才是**。初值
   `mean_abs=27` 曾把方向误导到量化误差。用 `recon=` 把编码重建打包成
   `yuvp()` 等价 `Bytes`，与 **unfiltered** 解码
   （`h264_decode_annexb_frames(stream, true)`）逐帧 MD5 对拍；带滤波输出
   会制造假差异（ffmpeg framemd5 是带滤波的，那个只用于外部仲裁）。
2. 逐 MB 差异分布定位到「最后一行 6 个 MB」，前 18 个全 0 —— 典型的
   状态/上下文不同步，不是整体算法错。
3. 写端 `write_mb_syntax` / 读端 `h264_decode_mb_cavlc_intra` 加临时
   `println` 做逐 MB zip：`mb_type / pred16 / chroma_mode / cbp` 全对齐，
   只有 **DC 残差 nC** 一列分叉：W `nc0=1/13/3`、R 恒 `0`。
4. 真因：CAVLC 解码器 intra 路径从清零的 `non_zero_count` 起，I16 且
   `cbp&15==0` 时一个 luma 计数都不写；编码器按 inter 习惯继承上一帧 I 帧
   nz 种子。nc 决定 VLC 表，`nc0=13` 那处码长变化 → 位流错位，后续 6 个 MB
   被读成 P_Skip（症状是「解码成功、ffmpeg 零告警、只有最后一行画面是上一帧」）。
   **修法**：I16 的 `cur_nz` 从 0 起，只在解码器同样会写的槽位回填
   （`cbp&15` 的 16 个 luma、`cbp&0x20` 的 8 个色度 AC）；inter 种子不动。
5. 探针用完删干净（W/R println、临时 `zz_i16_probe_test.mbt` 已按铁律
   `mv` 进 `.trash/2026-11-10/libavcodec/`）。

## 两条容易再踩的语义差异

- **反量化矩阵按宏块类型分叉**：intra 用 0/1/2，inter 用 3/4/5；I16 的
  `qmul_y[0]` 还要喂 `h264_luma_dc_dequant_idct`。
- **色度 AC 未编码时的 nz**：inter 解码器 `fill_rectangle(...,0,1)` 清零，
  intra 解码器保留上一帧值。两条路径分别处理，不能共用一条分支。
- **I16 AC 的 fdct 必须跑完整残差再丢 `levels[0]`**（§382 教训），清零
  (0,0) 再变换会污染每个 AC 块。
- **P slice intra mb_type 是 I slice 表 +5**：`5 + 1 + spec_mode + 4*group`，
  cbp 由 mb_type 组导出（不写 cbp codeword），`mb_qp_delta` 无条件写。
- `mc_plan` 对 I16 要**重放预测**：`eval_plan` 干跑与 `write_coded_mb` 各调
  一次 `code_mb_residuals`，前一次留在 `rec_*` 的重建必须被覆盖。

## 复现命令

```sh
# 黑盒（宿主 wasm）
moon test --target wasm --no-render libavcodec/h264_encode_p_intra_test.mbt
moon test --target wasm --no-render libavcodec/h264_encode_p_test.mbt
moon test --target wasm --no-render libavcodec/h264_enc_cabac_test.mbt

# 全量（wasm-gc，避开非 gc 后端 V8 局部数上限）
moon test --target wasm-gc < /dev/null

# x264 C oracle（docker native，10/10）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native \
   -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"

# 外部仲裁：测试打印的 I16ARB 行 → .264 → framemd5
python -c "import re,pathlib; s=pathlib.Path('.scratch/i16test.log').read_text(); m=re.search(r'I16ARB:([0-9,]+)',s); pathlib.Path('.scratch/i16_cut.264').write_bytes(bytes(int(x) for x in m.group(1).strip(',').split(',')))"
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "ffmpeg -y -v warning -i /work/.scratch/i16_cut.264 \
   -f framemd5 -c:v rawvideo /work/.scratch/i16_cut.md5"
```

钉值 `57c00c8ae52173ab0283e20006e5a6ec / 80fe0f660ef17d69b35e6a335553d209 /
80fe0f660ef17d69b35e6a335553d209`（已进黑盒 `inspect`）。

## C binding 技能落地清单（moonbit-c-binding + make-moonbit-c-bindings）

| 技能要求 | 本片动作 |
| --- | --- |
| 类型映射 / 私有 extern / `#borrow` `#owned` | 复核 `ffi.mbt`：非基本参数全部 `#borrow`，C 侧不留存 MoonBit 指针；无需 `#owned` |
| external object + finalizer | 复核 `X264EncHandle` 仍是 `moonbit_make_external_object` + `x264enc_destroy`；失败句柄模式（可选返回失效坑）保持 |
| `moon.pkg` native-stub / targets / link flags | 逐项核对未改；`supported_targets = "native"` 与 `targets` 文件门控保持 |
| C wrapper 负责 ABI 归一化、输出拷贝、释放 C 内存 | `x264dec_annexb` 补 NULL blob 防御、`INT32_MAX` 输出长度上限、`av_parser_close` NULL 保护；AVParser 切 AU + `av_new_packet` 拷贝 + `free(sink.pay)` 原有逻辑不变 |
| 安全层形状校验 | `x264_decode_annexb` 在进 extern 前拒绝 <8 字节流；blob 头/长度校验保持；新增短流回归 |
| native 测试 | docker `nine-x264` 跑 10/10，含 I16 流、混合 intra/inter 流双解码逐像素 |
| ASan | runner 只支持 `moon test --target native -v` **全模块**，本项目 native 验证走单包 `-p`；镜像内触发 `moonbitlang/x` 依赖解析失败（runner 已 finally 恢复 `moon.pkg` 与 `libmoonbitrun.o`）。记为不适用，不是代码失败。内存边界由 C stub 复核 + native oracle + ffmpeg 仲裁覆盖 |
| vendoring / prepare.py | 该包不 vendor 上游源码（链接镜像内 FFmpeg 静态库 + libx264），无 prepare 脚本，故无幂等门 |

## 可选后续片

1. **CABAC P slice intra 分支**：`decode_cabac_intra_mb_type` 的
   ctx_base=17 / intra_slice=0 表（b1/b2 都 @19、b3/b4 同 @20，与 I slice
   的 6..10 不是一套数字），写端 `write_cabac_mb_syntax` 目前对 I16 直接
   `return`，CABAC 入口固定 `allow_intra=false`；两端要一起接。
2. transform_8x8 的 I16/I8x8 组合。
3. 码率控制 / I16 转默认策略（当前 opt-in 保基线；若要转正需重钉全部
   CAVLC 仲裁钉值与质量门）。
4. 把 `H264EncStats` 用到 CABAC 编码器上（字段已接，CABAC 入口也接受
   `stats=`，但当前无测试断言）。

## 权威文件

- `libavcodec/h264_encode_p.mbt` — I16 plan / 残差 / 语法 / 状态提交 /
  `H264EncStats` / `recon=` 打包
- `libavcodec/h264_enc_cabac.mbt` — CABAC 入口 `allow_intra=false` 与 I16 门
- `libavcodec/h264_decode.mbt` — `h264_decode_mb_cavlc_intra` / `h264_block0_nc`
- `libavcodec/h264_encode_p_intra_test.mbt` — 3 项黑盒（含 ffmpeg 钉值）
- `libavcodec/x264/{ffi.mbt,x264.mbt,libx264_stub.c,x264_wbtest.mbt}` — C 绑定
- `PORTING_HISTORY.md` §383 — 完整记录
