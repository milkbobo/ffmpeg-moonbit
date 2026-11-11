# AGENT_HANDOFF_2026-11-11 — H.264 B 帧/CABAC 位定价/流式接口（§392–§394）

> **状态：已交付，全部验证绿。** 用户指令：使用 moonbit 全部 skills
> （必须 `moonbit-c-binding` + `make-moonbit-c-bindings`），继续迁移
> 「编码：H264」的 B 帧编码与帧重排、CABAC 专用位估价、流式编码
> 接口三项。接手 HEAD = `daaf04c`（§391 后补记）。
>
> C 绑定技能落点：本片**纯 MoonBit 编码本体零 FFI**（延续 §376 起
> 的纪律），两个技能用于 x264 native oracle 的回归验证（docker
> `nine-x264` **33/33**，含 §391 的 probe/ASan 基线延续）与 API
> 设计纪律（opt-in 契约、私有 extern 复核、安全层校验模式）。

---

## 一、交付概览

| 片 | 入口 opt-in | 内容 |
| --- | --- | --- |
| §392 CABAC 位定价 | `cabac_rd=`（CABAC 序列入口） | RD 决策换真 CABAC 引擎计价（快照/回放/回滚），默认关逐字节不变 |
| §393 B 帧与重排 | `b_slices=`（双熵序列入口 + CLI `--b-slices`） | 奇数 display 位编 B（编码序 I,P2,B1,P4,B3,…），POC type 0 重排，Direct/L0/L1/Bi 16x16 + skip，双熵写端 |
| §394 流式接口 | `H264StreamEncoder` + CLI `--stream` | 逐帧 push/drain 常数内存，契约 = 与批式逐字节相等 |

## 二、交付文件

| 文件 | 内容 |
| --- | --- |
| `libavcodec/h264_encode_p.mbt` | `H264PEncoder` 增 `cabac_rd`/`price_*` 字段；`eval_plan` 双熵分派；`eval_cabac_bits` 快照/回放/回滚计价核（含运动数组回滚根修）；`encode_p_frame` 增 `poc_lsb~`；`H264EncStats` 增 b_mbs/bi_mbs/bl1_mbs/bdirect_mbs |
| `libavcodec/h264_enc_cabac.mbt` | `encode_p_frame_cabac` 发布定价上下文 + `poc_lsb~`；`cabac_rd~` 透传全套（ABR/VBV/公开入口）；I 帧入口 `b_seq~` |
| `libavcodec/h264_encode.mbt` | CAVLC I 帧入口 `b_seq~`（B SPS + IDR poc lsb=0） |
| `libavcodec/h264_encode_b.mbt` | **新文件**：B SPS 写端、colocated 构造、B mirror（rec 平面共享）、`decide_b_mb` 四候选 RD、CAVLC/CABAC B 写端、B 序列编排核心 |
| `libavcodec/h264_enc_stream.mbt` | **新文件**：`H264StreamEncoder`（open/push_frame/drain/finish，past/fut 双参考） |
| `libavcodec/h264_enc_cabacrd_test.mbt` | §392 黑盒 6 测（含 ffmpeg 仲裁钉值） |
| `libavcodec/h264_enc_b_test.mbt` | §393 黑盒 7 测（含 display 序 ffmpeg 仲裁钉值） |
| `libavcodec/h264_enc_b_gop_test.mbt` | GOP 形状回归 4 测（n=2 骨架 / n=3 首 B / 双熵） |
| `libavcodec/h264_enc_stream_test.mbt` | §394 黑盒 6 测（三模式逐字节等于批式） |
| `cmd/encode-h264/{main,options,options_wbtest}.mbt` | `--stream`/`--b-slices` 选项 + 流式路径 + 6 测 |
| `PORTING_HISTORY.md` / `README.md` | §392–§394 节与 H.264 行 |

## 三、验证矩阵

| 门 | 结果 |
| --- | --- |
| `moon check --target wasm --deny-warn --no-render` | **EXIT=0**（112 tasks） |
| 编码器全套（11 文件，§376–§394 全钉值） | **86/86** |
| x264 native oracle（docker nine-x264） | **33/33** |
| docker ffmpeg 9.0.2 仲裁 | ARBCABACRD 六帧 / ARBB 六帧（display 序）/ CLI stream / CLI bstream 全部 **EXIT=0 零告警**，framemd5 与自家解码器逐字节一致并钉值 |
| CLI 实跑 | `--stream` 与批式同 md5（`66309d12…`）；`--stream --b-slices --cabac --aud` 113 B 三帧 |

## 四、§392 要点（CABAC 位定价）

1. **计价核 `eval_cabac_bits`**：候选经真 `write_cabac_mb_syntax`
   写入影子引擎，位数 = `enc.bits` 增量；随后回滚。
2. **回滚面**（本片核心资产，缺一即污染后续候选）：
   - 引擎标量 low/range/outstanding + `bits.truncate`；
   - `states` 全表副本；
   - mirror 当前 MB 的 mb_type_bits/cbp_all/chroma_mode/intra4x4/
     transform_8x8/qp 与 ctx 的 qscale/last_qscale_diff/cur_mb_is_intra；
   - `info.nz` 清零（解码器「每宏块完整覆写 nC 槽」）；
   - **六个运动数组** mv/mv1/ref_idx/ref_idx1/mvd/mvd1——子分区对角
     预测读「未写回的当前 MB 槽」，落选候选留值会改变后续候选的
     pred 与真写（根修：CAVLC 基线的 cur_mv/cur_ref 重置同语义，
     CABAC 定价直接写 mirror 数组必须显式回滚）。
3. **同候选回放自检**逐位相等（开发期探针，已撤）。
4. 坑：`h264_decode_annexb_frames(s, skip_lf)` 的 **true 才是跳过滤波**；
   把重建不变量挂在 `!skip`（去块后）上会制造假失败。

## 五、§393 要点（B 帧）与三个根因

**架构**：B 镜像 = 真 `H264DecCtx`（list0=过去参考、list1=未来参考、
colocated=未来 P 的运动态（`h264_b_colocated_from_states`）、rec 平面
与编码器共享）；direct/补偿/MV 预测全部直调解码器函数
（`h264_b_direct`/`h264_b_compensate`/`h264_pred_motion`/
`h264_write_back_*`）。候选 {Direct16, L0_16x16, L1_16x16, Bi_16x16}
以 `ssd·2^10 + λ·bits`（Int64）择优；direct 试验的 mirror 写有
快照回滚。**skip 判定 = direct SAD==0**（解码器 skip 分支跑同一
direct）。

**根因三则**（bin 级对齐 ≠ 语义对齐的又一课）：

1. **kind↔mask 映射反了**：`h264_b_partitions` 的 `mask: kind`
   （bit0=list0）⇒ kind1=L0、kind2=L1、kind3=Bi。写读两侧一致地错
   ⇒ 位流合法自洽但 MV 应用到错误参考列表（大面积重建差、解码零
   告警）。教训：**镜像对称的 bug 用「合法性验证」抓不到**，必须
   重建不变量或像素对比。
2. **CABAC mb_type kind3 的后缀**：4-bin（1×ctx31 + 3×ctx32）且
   `bits<8 → bits+3` 直接得 kind，**无继续 bin**（继续位只在
   bits≥8 且非 13/14/15 时读）。第一版多写了一个 ctx32。
3. **mvd 上下文按分量不按 list**：x 恒 40、y 恒 47（两 list 共享），
   amvd 由 `h264_mvd_fetch` 的 active_list 感知提供。

**其它**：B 的 ME 钳 |mvd|≤70（mvd 语法幅值上限）；B nz 镜像取
`cur_nz`（语法级、熵无关）；非参考 B 与后继 P 共享 frame_num；
poc_lsb = display*2 & 15（4 bit，8 帧后回绕，解码器 unwrap 已验证）。

**定位工具**（§381 bin zip 的再进化）：写端 `H264CabacEnc::decision`
与读端 `CabacContext::get_cabac` 全量打点 `(ctx, bit)`，两侧序列
diff 首分叉即真因；配合解码器 slice header/kind/MV 三级打点。
注意 bypass bins 不在 zip 内（mvd escape/sign 位），所以 zip 全对仍
可能有语义错——重建不变量才是终局门。

## 六、§394 要点（流式）

- `H264StreamEncoder`：push 即编码（I/P 模式每帧一 AU；B 模式偶数位
  出 P-B 对、奇数位缓冲、finish flush 尾帧为 P）。
- **B 调度双参考**：P 重建停 `fut_*`，B 用 (ref_*, fut_*)，B 编码后
  才交接——B 的过去参考不被刚编码的 P 覆盖。
- **契约 = 与批式逐字节相等**（三模式黑盒钉值）——流式正确性完全
  由批式的钉值体系背书，无需独立钉值。
- 两遍码控（VBV/ABR）需全序列，`open` 拒绝；WASM 宿主无分块文件
  读，CLI 输入缓冲仍整文件（已文档化），编码器侧不再持有帧数组。

## 七、复现命令

```sh
# 宿主（串行）
moon test --target wasm --no-render libavcodec/h264_enc_cabacrd_test.mbt \
  libavcodec/h264_enc_b_test.mbt libavcodec/h264_enc_b_gop_test.mbt \
  libavcodec/h264_enc_stream_test.mbt
moon test --target wasm --no-render -p cmd/encode-h264
moon check --target wasm --deny-warn --no-render

# CLI
moon run scripts/gen_h264_cli_fixture.mbtx
moon run cmd/encode-h264 -- .scratch/h264_cli_input.yuv --width 16 --height 16 \
  --output .scratch/s.264 --stream --b-slices --cabac --aud

# docker：x264 native oracle + ffmpeg 仲裁
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native -p libavcodec/x264 --target-dir /tmp/mbuild 2>&1 | tail -1"
# ARBB/ARBCABACRD dump 由黑盒测试 println 产出后走 framemd5
```

## 八、剩余 / 下一片候选

1. B 帧的 16x8/8x16/8x8 子分割与 intra-in-B（写端与决策框架已就绪，
   `h264_b_partitions` 的 kind 4..22）。
2. B 帧的 CABAC 位定价（`cabac_rd` 与 `b_slices` 目前互斥）。
3. B×VBV/ABR（B 是非参考帧，VBV 重放需把 B 的 AU 计入正确的 CPB 时
   序；display/编码序的码率分配）。
4. 流式 CLI 的宿主分块读（需要 x/fs 的流式 API 或自建 wasm bridge）。
5. x264 oracle 的 HRD/SPS 逐字段对拍（§391 遗留）。

## 九、坑（本片新增）

1. **bash -c 内嵌 python 字符串里的反引号会被 bash 展开**——多行
   文本写入一律走 `.scratch/*.py` 脚本文件，别走 `python -c`。
2. `moon test -u` 会把「当时错误实现的 actual」固化进 inspect 的
   content（含数组占位符场景），修复后必须人工核对 pins，别信 -u。
3. README 当前是 **LF**（记忆里的 CRLF 结论过时）；单行内追加不涉
   及行尾，别做全文件行尾「归一化」。
4. `h264_decode_annexb_frames` 的第二参 `skip_lf`：**true=跳过滤波**。
5. MoonBit `pub struct` 的字段可用 `priv` 修饰以引用 priv 类型
   （E4046 的解法）；Array 切片 `[...]` 是 view，跨界需 `to_owned()`。
