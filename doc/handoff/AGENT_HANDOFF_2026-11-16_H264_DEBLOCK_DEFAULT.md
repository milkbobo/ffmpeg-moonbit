# H.264 §424：编码环路去块默认开启交接（收口版）

日期：2026-11-16
上一阶段：`doc/handoff/AGENT_HANDOFF_2026-11-16_H264_DEBLOCK.md`（§423）
模块：`D:\project\FFmpeg-n9.0.2\moonbit`
执行环境：Windows，MoonBit `0.1.20261016 (1af328f 2026-10-16)`

> **状态：收口。** 49 文件回归 **241/241** 全绿（wasm-gc，每文件独立编译），
> CLI **30/30**（wasm），`moon check --target native` 0 警告。全部待仲裁流经
> 外部 FFmpeg 9.0.2（gyan essentials build）零告警解码并逐帧与自解码器一致。
> doc/PORTING_HISTORY §424 条目已入库。本文取代早前的执行中版本。

## 1. 公开契约（最终）

- `deblock` 默认 true：`h264_encode_intra_frame`、两个公开 IDR 入口、
  `h264_encode_frames`、`h264_encode_frames_cabac`、`H264StreamEncoder::open`、
  `VideoEncConfig::new`。
- CLI 默认开启；`--no-deblock` 关闭，`--deblock` 兼容保留。
- 重建承诺：开启时 `recon_*` 为滤波后解码重建；I_PCM 无损不滤波；
  显式 `deblock=false` 走旧路径。

## 2. 生产修复（全部落地并验证）

1. I_PCM 整图不滤波（无损承诺）。
2. B CAVLC/CABAC 写端显式 `info.transform_8x8=false`（陈旧标志清除）。
3. P/B 去块 QP 用码流实际 QP：P-CAVLC/Skip=`prev_qp`、P-CABAC=`mirror.qscale`、
   B 同理；`commit_plan_state`/`commit_skip` 带显式有效 QP。
4. P 有效 tf8：`coded.dct8 && (I8 || luma_cbp != 0)`。
5. （本轮）stream_abr helper `fps=25` 无条件传参修复——a4d8e6d 引入的
   HEAD 既有红（3 测试全挂于「fps requires VBV or target_bitrate」），
   平坦参照腿现在仅在有 VBV/ABR 时传 fps；顺带删除遗留 `if true` 诊断短路。

## 3. 重钉战役（外部 FFmpeg 9.0.2 仲裁，全部零告警 + 自解一致）

仲裁器：`...\ffmpeg-9.0.2-essentials_build\bin\ffmpeg.exe`（version 9.0.2-essentials，
Lavf 63.1.102）。工作流：测试日志 `TAG:十进制,流` dump → python 提取
（`.scratch/arb/extract_arb.py`）→ framemd5（行按 pts 排序 = 显示序；带 B 流
对解码序断言时按 pts [0,2,1,4,3] 重排）→ 与自打印 MD5 逐帧对 → 重钉
（`.scratch/arb/arb_all.py` 批量执行，结果在 `arb_results.txt`）。

已收口（测试全绿）：

- **ARBBI8C/R**：C 路解码像素现与 V 路完全相同（滤波参考消平熵间分歧），
  R 路尾部两帧 RD 分歧。三路六帧全部外部一致。
- **ARBMR2/3**（b_multiref 双腿）、**ARBC22D10/D12**（c422_depth 双腿）、
  **ARBB/ARBBAQ**（b 六帧 + 整流 MD5）、**ARBBRC A/V**（brc 双流，
  单行双流 dump 格式需定制解析）、**ARBCABACRD/ARBCRDALLON/COMBO/OFF**
  （cabacrd 四处）、**ARB3/ARB6**（p 双测试）、**DCT8ARB/CARB + I8PARB/CARB**
  （dct8 四处）、**RCARB/RCCARB**（rc 解码序重排）、**AQARB/AQCARB**、
  **I4P 双流 + stripe 双流**（rc 文件内三测试不打 dump——本轮用一次性探针
  复刻编码取流后仲裁，探针已删）。
- **绝对钉值**：VBV 布局总位 21712→21064、19456→18864；tight-buffer
  CAVLC QP [26,26,26,33,34]→[…,32,33]、流 2344/MD5→2342/`9e8d9441…`、
  CABAC 尾 QP 31→27；FLATACARB 2471→2428、`bd3b8b51…`→`2213f8b7…`；
  RC CAVLC small QP [36,37,…]→[37,38,…]（big 不变）、CABAC [37×5]→[38×5]；
  AQ dqp_mbs 25→23（双熵）；I4P/stripe 计数与长度（i4p 2→1、13→10、11→9、
  i16 14→13、长度 2479→2436/2241→2188/1162→1163/1055→1060）。
- 普遍规律：**IDR 帧逐字节不变，其后全部帧/轨迹重钉**——去块进参考的
  语义性连锁，非缺陷。

## 4. 质量口径决策（RC SAD 单调）

滤波域 SAD 被去块「去噪效应」翻转（QP 越高滤波越强）：小预算 743748 <
flat 767310；预滤波（skip_lf=true）域严格单调 796912 > 767963 > 764324。
`h264_rc_sad` 改测预滤波解码，断言保持严格，注释记录数据与机理。**此为
单方决策**（曾发起用户问询未获回复）：如需回到滤波域口径或区间放宽，
改动点就是 `h264_rc_sad` 的 skip_lf 参数与注释。

## 5. 最终门与证据

- 49 文件 wasm-gc：`Total tests: 241, passed: 241, failed: 0`
  （逐文件独立跑，`.scratch/h264_s424_finalrun.log`）。
- CLI：options_wbtest 24/24 + host_io_wbtest 5/5 + c444_online 1/1（wasm；
  wasm-gc 因 FrameWriter 目标门控不可用，属包结构而非回归）。
- `moon check --target native`：0 error / 0 warning（含 x264 绑定包）。

## 6. 同轮附带：x264 绑定 pict_type 强制（C 绑定切片，docker 门 3/3 绿）

按 moonbit-c-binding / make-moonbit-c-bindings 流程补 libx264.c
`X264_frame` 的 `frame->pict_type` 开关（libx264.c:515）：

- `X264PictType`（Auto/Keyframe/Idr/P/B）+ `send_frame(pict_type~)`；
  `force_idr~` 兼容保留且优先（镜像上游 I+forced-idr→IDR）。
- 桩：`base_forced_idr` 开机快照（av_opt_get_int 读回），**每个 I 请求
  显式重写 forced-idr**（Idr→1，Keyframe→base）——初版只在 base≠0 时还原，
  帧 0 的 IDR 请求把 forced-idr=1 泄漏给帧 4 的 Keyframe（open-gop 下仍出
  第三个 IDR）；用宿主 ffmpeg CLI `-force_key_frames` + `open-gop=1` 复现
  出权威语义（KEYFRAME→非 IDR I、不重发 SPS、解码器 key_frame=0）后定位。
- `pict_type_forcing_wbtest.mbt` 三测试 docker nine-x264 **3/3 绿**：
  ① 闭 GOP：Idr(0,7)+Keyframe(4)+P 钉制——x264 把非 IDR keyframe 升级为
  完整 IDR（SPS/type5 各 3），P 钉制消灭全部 B，Auto 对照腿有 B；
  ② open-gop=1：Keyframe(4) 保持非 IDR I（SPS/type5 各 2），包 keyframe
  标志仅两 IDR；
  ③ B 强制：bframes>0 是前提（bframes=0 时显式 B 被降级为 P）、且
  lookahead 以 bframes 封顶 B-run——先把 1..3 钉 P 腾出空间，4 钉 B 落位。
- 全包 93 测 82 过 + 本切片 3 绿；其余 9 红见 §7。

## 7. x264-oracle 族：已随 oracle 下线决定处置（用户决定 2026-11-16）

**用户决定：oracle 明确不做**（已写入 doc/agent.md §2——不修复、不扩展、不重跑，
失败不作为交付门）。本节原先记录的 9 个 §42x 链陈旧红**全部位于已注释的
oracle 测试族内**，随之失去效力，不再修复：

- `ffref/` 整包：7 个源文件逐行注释、`moon.pkg` 注释置空、`ffref_stub.c`
  加"未接线"头注。
- `libavcodec/x264/x264_wbtest.mbt`：55 个测试块（50 个 `x264 oracle:` +
  3 个 `pure H264 …` + 帧探针族）与 12 个孤儿 helper 逐行注释；保留 7 个
  绑定自测（forced-IDR、supports/deterministic/round-trip/avcC/10-bit）。
- 九个 pure-H264 wbtest 整文件注释（c444_bi16/bi8/binter8/online_depth/
  parts、chroma_crop、high_contrast、stream_c444）。
- `x264/moon.pkg` wbtest 的 libavutil import 注释（唯一使用方是 oracle
  测试；恢复 oracle 时一并还原）。
- **绑定本体与绑定自测保留**（lifecycle/输入格式/options/pict_type/
  round-trip——编码能力交付物，非 oracle）；`libavcodec/*.mbt` 的
  ffmpeg-arbitrated 黑盒钉值测试跑纯 wasm、不调用 C oracle，保留。

验证：`moon check --target native` 与 `moon check`（wasm）均 0 错 0 警；
wasm 回归抽查（deblock 族 9/9）不受影响。恢复 oracle = 逐文件取消注释 +
还原两处 moon.pkg（方法见 doc/agent.md §2 规则）。

## 8. 后续

- 全链未提交（按 doc/agent.md §3 用户点名才提交）。§421d–§424 与绑定切片同树。
- mooncakes 包若发布需 `moon info` 重生成（公共 API 新增 `X264PictType`
  与 `pict_type~` 参数）。
- 若上拟 SAD 口径决策被推翻：改 `h264_rc_sad` 一处即可。
- §7 的 oracle 族已按下线决定整体注释（2026-11-16），docker 门不再包含
  oracle 测试；绑定自测族保持全绿即可交付。
- **收官门（2026-11-17）**：x264 绑定包全量 docker nine-x264 **38/38** 全绿
  （oracle 注释后剩的绑定自测 + pict_type/SEI/ROI/stereo3d/mb_info 五个新切片
  一次通过）。根 README 的 libx264 绑定行已从 §375 时代表述更新为当前全貌
  （输入格式全家/色彩 VUI/pict_type/SEI×2/ROI/stereo3d/mb_info + oracle 下线）。
- 发布前事务（非阻塞，已定音为工具链限制）：`libavcodec/x264/pkg.generated.mbti`
  无法生成——`moon info` 的 canonical 输出只写模块 preferred backend（wasm），
  native-only 包直接被跳过（`Skipping package ... does not support target
  backend wasm`）；`preferred_target` 不是包级合法键（只存在于 moon.mod.json）。
  影响=包页无接口文档渲染，不阻塞发布本身。
