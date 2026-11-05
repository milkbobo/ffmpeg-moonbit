# AGENT HANDOFF — 2026-11-05 AAC 强度立体声与 M/S（§290 → §300）

> 更新（同日）：§2b 第 1 项的「编码器接线」已由 §302 闭环，并做成 opt-in
> （`AacEncodeConfig.perceptual_short`）。实测数据与下一步见
> `AGENT_HANDOFF_2026-11-05_AAC_SHORT_WINDOW.md`。以下 §2b 是 §301 时点的快照。

这条线到这里，感知路径的三个工具（twoloop/PNS、`search_for_is`、`search_for_ms`）
都已经与 FFmpeg 9.0.2 **逐位对拍**并接进了编码器：顺序、判据、成本量值、以及
M/S 改写后的标度因子与带类型终值。§297–§299 又把码率重试循环的四处顺序/状态偏差
（`analyze`、TNS、`adjust_frame_information`、以及首帧 TNS 的零初始化）全部对齐，
所以感知路径现在与 `aacenc.c` 同构；§300 又把 3GPP psy 的八短窗形态补齐（编码器还没接）。默认（简化）路径保持原样，只在它自己的
频率门 + 能量掩码上跑。剩下的事列在 §2b。以下把"已经落地的"和
"下一次要怎么做的"分清楚。

## 1. 本轮交付了什么

- 配置：`AacEncodeConfig.is_stereo`（默认 false）+
  `aac_encode_config_with_is(config)`。它与 `perceptual` 无依赖——简化判据只需要
  带能量，所以默认路径也吃这个开关。（§290 当时还让 `is_stereo` 与 `pns` 互斥、
  两侧配置函数互相清对方，**§294 已拆掉这条**，现在两者可同时开。）
- 决策：`aac_encode_is_search`（`libavcodec/aac_encode.mbt:994`）——
  FFmpeg 频率门 + 带内互相关 `|rho| >= 0.95` + 相位取互相关符号 +
  强度位置 `round(2*log2(ener0/ener1))`，先裁到 `[-155,100]` 再裁到相对上一条
  IS 位置的 `±60`。
- 变换：`aac_encode_apply_is`，与 `apply_intensity_stereo` 逐式一致
  （`L' = (L + p·R) · sqrt(ener0/ener01)`，`R' = 0`）。
- 码流：`aac_encode_write_scalefactors` 的第三条独立差分链 `off_is`（起点 0），
  `aac_encode_write_spectral` 与 `aac_encode_band_has_data` 跳过 14/15，
  `aac_encode_global_gain` 跳过 14/15（也跳过噪声带）。
- 测试：`aac_encode_vectors` 14/14，其中三条是本轮新增
  （`aac_lc_is_config` / `aac_lc_intensity_stereo_round_trip` /
  `aac_lc_intensity_stereo_skips_uncorrelated`）。全量 1399/1399。

实测数字（44.1 kHz / 128 kbps / 2ch，感知路径，4 帧 + 1 收尾帧；§291 换了顺序之后
重测）：

| 夹具 | IS 带 | 码长 | R 的 9 kHz 电平 | 往返 SNR |
|---|---|---|---|---|
| 高音共享（L 440 + R 550 低音不同） | 10 | 1744 → 1711 B | −0.03 dB | 22.92 → 22.35 dB |
| 高音不共享（L 9 kHz / R 11.7 kHz） | 0 | 1773 = 1773 B | — | — |

（§290 当时的数是 1831 → 1802 B、+0.38 dB、18.60 → 18.54 dB；顺序改成与
FFmpeg 同序后 SNR 涨了 4 dB 多、音调重建电平几乎无偏。）

外部对拍：同一条 8 帧 IS 流（3102 字节），`linuxserver/ffmpeg:9.0.2` 报
`9 frames decoded; 0 decode errors`；ffmpeg 的 PCM 与本解码器的 PCM
最大差 `1.49e-7`、RMS `2.43e-8`、相对 SNR `138.92 dB`。

## 2. §292 已完成：真成本判据逐位对拍并接线

顺序（§291）和判据（§292）都到位了。感知路径现在跑的是 FFmpeg 的
`aac_is_encoding_err` 成本比较，`libavcodec/aac_is.mbt`，逐位对拍在
`libavcodec/aac_is_vectors/`：4 帧 × 49 带的 `is_mask` / `ms_mask` /
右声道 `band_type` / `is_ener0` / `is_ener1` / 两相位 `pass` / `is_mode`
**完全相等**（64 个强度带）。默认路径仍用 §290 的频率门 + `|rho| >= 0.95`
（它没有 twoloop 的 `sf/band_type/阈值` 可定价），那条门的误差式子仍写在
`aac_encode_is_search` 的 docstring 里。

参考链路（全部可复现）：

```
bash _ref/aacenc/build.sh                 # 现在会编译 aacenc_is_patched.c
moon test --target wasm libavcodec/aac_is_vectors   # 1/1
python scripts/gen_aac_is_vectors.py .scratch/is_dump/enc.log   # 再生成夹具
```

**再生成夹具需要临时把探针加回来**（本轮已摘干净）。做法：在 `AacEncoder` 上加
`mut dbg_frame_no : Int32`（并在 `aac_encoder_new` 里初始化），在感知路径 λ 循环里
`st = ...` 之前插一段

```
if self.config.channels == 2 && its == 0 && use_is {
  打印 "ISDUMP-FRAME <n>"、每个声道一行 "ISDUMP-SPEC0/1" 后跟 1024 行
  "ISDUMP-V <值>"、"ISDUMP-ALLOC <alloc>"、49 行
  "ISDUMP-PSYBAND0/1 <g> <energy> <threshold> <spread> <bits>"、49 行
  "ISDUMP-SF0/1 <g> <twos[ch].sf[g]> <cbs[ch][g]> <zeros[ch][g]>"、最后 "ISDUMP-END"
}
```

然后 `moon test --target wasm libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log`，
跑上面的生成脚本，最后 `grep -c ISDUMP libavcodec/aac_encode.mbt` 必须归零。
脚本会把值按 C 实际消费的 **float** 存（`%.9e` 足以无损往返 float）——这一点必须
保持，否则"完全相等"的断言会假失败。

### 剩下的事（按建议顺序）

1. ~~**`dist1/dist2` 量值的 ulp 二分**~~ —— **§293 已闭环**，而且根因不在 IS：
   escape 码本（cb 11）的 `quantized = c*cbrtf(c)*IQ` 原先按「double `cbrt`
   再舍到 f32」建模，而本机工具链的单精度 `cbrtf` 在 `c = 0..8191` 里有
   **2196 个值与它差 1 ulp**（c=11：C 2.223979949951172 对 2.223980188369751）。
   修法是 `dump_tables.c` 新增 `CBRT` 记录 → `aac_twoloop_cbrt_prod` 零转录 →
   `aac_two_band_cost` 查表；`aac_is_vectors` 现在把 6 个成本量值也断言成
   **精确相等**（`worst cost gap = 0`）。二分用的探针留在 harness 里：
   `ISD1L` 行 = 只加完**左带**成本的 `dist1`。以后遇到「决策逐位对、量值差一点」
   的成本类对拍，先照这个拆法按调用边界二分，别去怀疑求和顺序。
2. ~~**打开 IS 与 PNS 的组合**~~ —— **§294 已做完**，而且是白捡的：
   `aac_encode_stereo_psy` 交给 `aac_is_search` 的 `cb`/`zeroes` 就是 PNS 终值，
   上游 `search_for_is` 的门（两声道 `band_type != NOISE_BT && !zeroes`）本来就把
   噪声带排除在外。实测同一噪声夹具的噪声带数开不开 IS 都是 81/78，IS 另加 14 个
   强度带、再省 3.3% 码；混合流经 ffmpeg 9.0.2 解码 0 errors，PCM 与本解码器最大差
   4.47e-8。回归在 `aac_lc_pns_with_intensity_stereo`，配置叠加两个方向都测
   （`aac_lc_is_config`）。§288 那条结论仍然成立：噪声带写的是 `noise_sfi`。
3. ~~**`search_for_ms` 的完整形态**~~ —— **§295 已做完并逐位对拍**
   （`libavcodec/aac_ms.mbt`，向量在 `aac_is_vectors/` 第二支）。踩到的两条已经
   写进 §295 与 `agent.md`：C 的 `float` 字面量要按 f32 值存（`bmax` 差 1 ulp
   就是这么来的），以及 `ms_mask` 是**读改写**——`search_for_is` 把 flip 位寄生
   在那里，上游只对 `!is_mask` 的带写 0，重算整个掩码会清掉它。
   简化路径仍用能量掩码（没有 twoloop 的 `sf/cb/阈值` 可定价）。

## 2b. §300 之后剩下什么（按建议顺序）

1. **短窗感知路径的剩下两层**。前两层已闭环：**§300** 给出 3GPP psy 的八短窗形态
   （8×128 带计划、逐窗阈值链、短窗 `bit_demand` / 孔避免阈值，560 条
   `psy_bands[w*16+g]` 逐位对上 `bits`/`alloc`/`fill_level`），**§301** 把 twoloop
   量化器做成按窗分组（`AacTwoShape`、15 处 `w += group_len[w]` 外层、组内共享一条
   `sf_idx` 与码本、`minsf` 写组内每窗槽位、`ff_pns_bits` 按 `(w<<4)+g-1` 回看，
   266 条 `sf/cb/zeroes` 逐位一致）。还缺的是把这条链**接进编码器**：
   - **窗分组计划与码流**：`window_grouping[]`（`aacpsy.c:398`）的展开——移植自己的
     攻击检测要产出 `group_len[8]`，`scale_factor_grouping` 的 `bs_packet_loss_free`
     之后的 7 位分组字段按 `group_len` 写（写侧现在只在 `window_sequence == 2`
     时写死一组），`channel_data_psy` / `write_scalefactors` 要吃逐窗组的
     `sf_idx`/`band_type`/`zeroes`；
   - **多窗工具与 adjust**：`aac_ms_search` / `aac_is_search` 仍只有单长窗形态
     （C 的 `w`/`w2` 外层还在，接进去是纯结构性工作；`search_for_ms` 里 mid/side 的
     `Mmax/Smax` 是整窗组共用的）；§299 那三条里，窗口组 zeroes 归并只有多窗才不是
     恒等、`msc == max_sfb * num_windows` 的 `num_windows` 也第一次真的等于 8；
     TNS 的多窗形态（`aac_encode.mbt` 的 `search_tns` 已按 `num_windows` 出
     `n_filt`，但带范围与 `tns_max_bands_128` 还没接）。
   两条都在 §301 的向量里有参照：`_ref/aacenc/aac_ref.exe --short` 已经能跑 psy +
   twoloop 并打印 `SHORTGRP`，加开关就是多窗 IS/M-S 的黄金数据。注意 §300/§301 都
   没动编码器：`use_psy = perceptual && seq != aac_eight_short` 这条门还在，短窗帧
   仍走简化模型，所以接上编码器的窗分组才会第一次改变端到端码流。
2. **短窗 IS 夹具**：结构上 `num_windows` 与每窗带内偏移都参数化了，缺的只是一组
   8 短窗的真夹具。
3. ~~**f32 字面量的同类残留**~~ —— **§296 已清**（量化器 / `zspread` / PNS 三条
   链，外加 `frame_bit_rate *= 1.15f` 的整数→单精度→截回整数，和
   `options.pns || options.intensity_stereo` 这条带宽条件），而且实测
   **一条码都没变**：`qmaxval = (int)(maxval*Q34 + 0.4054f)` 这类分歧的窗口只有
   8e-9 宽（≈1/15 个 f32 ulp），现有与构造的采样点都进不去。**唯一剩下的同类
   欠账是 `aac_psy.mbt`**：那批从 C 抄来的十进制常量（`1.3219281`、
   `-0.46666667`、`0.00076`、`3.64`…）确实该按 f32 重存，但那个模块的口径本来
   就是「整数决策逐位、浮点相对误差 ≤5e-4」，动它之前要先决定要不要把 psy 也
   做成逐位模型（那会重写 energy/threshold/PE 整条链，并移动所有感知指标）。
   `aac_encode.mbt` 里 TNS 与简化路径的 `1.4/1.16/0.405/0.95` 不是 C 的操作数，
   是简化模型自己的常量，不用管。
4. ~~**§289 偏差 2**~~ —— **§297 已闭环**：λ 重试每一轮重跑 `analyze`（第 0 轮沿用
   帧首那次）。口径是**ABR 分支的恢复语义 + 严格分支的 λ 规则**——C 的严格分支
   `continue` 前不 `memcpy(coeffs, pcoeffs)`，字面照搬会把 IS/MS 混合每重试一次
   就再乘一遍，这条取舍写在 §297 里，别改回去。
   ~~偏差 4~~ 由 **§298** 闭环：`search_for_tns` 现在在 twoloop 之后、PNS 之前，
   每轮在 `coefs[ch].copy()` 上滤波，`coefs` 不再被污染（`AacEncFrame.tns` 字段
   取消，改成 `build_frame`/`assemble_frame` 的入参）。
   **偏差 3 由 §299 闭环**：`max_sfb` 现在每轮由 `adjust_frame_information` 从量化
   结果反推（`cmaxsfb` = 最后一个 `!zeroes` 的带；窗口组 zeroes 归并在单长窗是
   恒等所以没搬；CPE 两声道取 max），`ms_mode` 补上第三种取值 **2**（全带标记，
   此时 `encode_ms_info` 不写掩码位），TNS 的带范围改读上一轮/上一帧的
   `ics.max_sfb`（新增 `AacEncoder.last_max_sfb`，零初始化 → 首帧不发滤波器）。
   §289 的四条顺序/状态偏差 1-4 至此全部关掉，感知路径与 `aacenc.c` 的 element
   循环同构。三条规则在现有夹具上都不改输出（三个码率的 `max_sfb` 与 §298 相同：
   19/33/43），所以回归写成了**性质断言**而不是指标：`highest <= max_sfb`、
   `ms_mode == 2` 时不读掩码位、帧 0 无 TNS 而后续帧有。短窗进来时这两条要跟着
   走：窗口组 zeroes 归并只有多窗才不是恒等，`msc == max_sfb * num_windows` 的
   `num_windows` 也会第一次变成大于 1。
5. `set_special_band_scalefactors` 上游是一轮里同时管 IS 位置和噪声
   `3+ceil(log2(pns_ener)*2)`，我们的噪声仍取 `search_for_pns` 的 `noise_sfi`
   （§288 的结论，别说改回去）。

## 3. 本轮踩到的坑（下一轮直接用）

- **`sf[b] >= 0` 这个哨兵只对真标度因子成立**。IS 位置可以为负，写侧必须先按
  `cb` 判 14/15；`aac_encode_global_gain` 同理。
- **让 ffmpeg 解我们的码流**这条验证路径值得保留，做法（本轮实测可用）：
  1. 建一个临时 main 包（`import` 写在 `moon.pkg`，源码里再写一遍会报
     `[3001] Invalid import declaration`）；
  2. `moon run <dir>`，**目录不能以 `.` 开头**（moon 跳过点目录，
     `.scratch/xxx` 会报 "does not match any known package"），本轮用的是
     根下的 `zz_is_dump/`，用完移进 `.trash/2026-11-05/`；
  3. `moon run` 走 wasm 目标（这台 Windows 的 native 目标要求 MSVC `cl.exe`，
     本机没有），所以不能写文件——把 ADTS 用 `println("BYTES \{...}")` 打出来
     （`Byte::to_string()` 打的是 `b'\xFF'`，Python `ast.literal_eval`
     直接还原），PCM 一行一个样本；
  4. Python 落成 `out.adts` 后
     `docker run --rm -e MSYS_NO_PATHCONV=1 --entrypoint ffmpeg
     linuxserver/ffmpeg:9.0.2 -v debug -i out.adts -c:a pcm_f32le -f f32le
     ref.f32`，再和本解码器的 PCM 比。
- **IS 的相位/带类型别记反**：`INTENSITY_BT2 = 14` 是**反相**，
  `INTENSITY_BT = 15` 是**同相**（`libavcodec/aac.h:74`）；编解码两侧的
  `p = -1 + 2*(bt - 14)` 必须同式。
- MoonBit 不把 `a = x` 换行 `+ y` 当续行（多行算术要拆 `let` 或加括号）。
- **临时 main 包会被整模块测试图收进去**：`zz_*` 这种放在模块根的 scratch 包会
  被 `moon test --target wasm` 一起编译；本轮在测试运行中途把它 `mv` 走，构建图
  立刻报 `input ...\zz_is_pns\main.mbt missing`，那一次全量测试等于白跑。顺序要
  改成「先清 scratch，再起全量测试」，或者等测试跑完再清。
- **`MSYS_NO_PATHCONV=1` 必须是 shell 前缀**，写成 `docker run -e MSYS_NO_PATHCONV=1`
  对 Git Bash 的路径转换没有任何作用——本轮 `-v "$PWD":/w` 被转成
  `.../ms_dump;W:\`，docker 直接报 `destination can't be '/'`。正确写法：
  `MSYS_NO_PATHCONV=1 docker run --rm -v "$PWD":/w --entrypoint ffmpeg ...`。
- **要"改了判据之后指标怎么动"的诚实对照，就把同一套测试在 HEAD 上重跑一次**：
  `git worktree add --detach .scratch/head_wt HEAD` → 在那个工作树里跑
  `moon test --target wasm libavcodec/aac_encode_vectors` → `git worktree remove
  .scratch/head_wt --force`。比翻文档里的旧数字可靠（§291/§292 的打印口径并不
  完全一致）。工作树放在 `.scratch/` 里就不会污染 `git status`，也不会被 moon
  当成包（点目录被跳过）。更硬的一档：把 scratch 的 dump 程序在两个提交上各跑
  一遍，直接 `cmp` 两条 ADTS——§296 就是这样证明"保真清扫一条码都没变"的，
  上一轮的 ffmpeg 外部对拍结论也因此原样适用、不必重跑（scratch 包要 `cp`
  进工作树，`moon run` 不吃点目录）。
- **给码流写"只有这个工具能造出来"的签名断言**，比再加一条聚合指标有用：
  M/S 命中后两声道的标度因子只差 `3*boost`（0/3/6 步），于是
  `aac_encode_test_tool_bands` 把掩码位读进来就能直接验。注意它只对
  `ONLY_LONG` 帧成立——短窗帧走简化路径的能量掩码，第一版没加这个限定，
  报了 10 个"违例"，其实那 10 个是 10 个过渡帧。
- **改测试辅助函数的统计口径会重画既有结论**：同一支 helper 里加
  `if window_sequence != 0 { continue }` 会让 §294 那条"噪声带数开不开 IS 都是
  81/78"变成 51/46。限定要贴在真正需要它的那几行上（这里只有 M/S 计数），
  别一把盖住整个循环。
- **docker ffmpeg 不会覆盖已有输出**：`-f f32le /w/a_ref.f32` 撞到旧文件时它会问
  `Overwrite? [y/N]`，非交互下直接**不写并退出**，而 docker 的退出码仍是 0 ——
  于是你拿旧参考去比对新流，看到「差 0.07」还以为解码错了。`-y` 要放在
  **ffmpeg 那一侧**（`docker run … --entrypoint ffmpeg … -y -i …`），写成
  `docker run --rm -y …` 是非法 flag。同理：比对前先 `ls -la *_ref.f32` 看时间戳。
- **回归夹具的选帧要用数据，不要用手工下标**：`gen_aac_is_vectors.py` 里
  `TAKE = (0, 1, 4, 5)` 在 §295 加了新测试之后指到了别的帧，强度带覆盖从 64 掉到
  9，**而所有测试仍然全绿**——指标被无声稀释。现在 `choose()` 读参考侧的
  `ISBAND`/`MSBAND` 计数，挑「强度带最多 + M/S 最富」的四帧，并把选中的块号印出来。
- **临时探针的收尾三步**（§297 又走了一遍）：`moon test --target wasm
  libavcodec/aac_encode_vectors > .scratch/is_dump/enc.log` →
  `python scripts/gen_aac_is_vectors.py <log>` → 摘探针后
  `grep -c ISDUMP libavcodec/aac_encode.mbt` **必须归零**；再加一条硬度：
  把 scratch dump 程序在摘探针前后各跑一次，`cmp` 两条 ADTS 必须相同，
  这样外部对拍结论才落在要提交的实现上。
- **顺序类改动要先确认"这个夹具上到底会不会触发它"**：§298 把 TNS 挪进循环之后，
  四音/PNS/IS 四条夹具的打印指标**逐字符不变**——不是改动没生效，而是那些内容上
  TNS 根本不点火（长音 + 高码率下预测增益判据不过）。有效证据是换个夹具：8 帧
  共享高音只有一帧变（366 → 369 B、SNR 22.147 → 21.013），而那正是码流里
  带 TNS 的唯一一帧。所以这类改动的回归应该是**"工具是否还发出来"的断言**
  （新测试 `aac_lc_perceptual_path_emits_tns` 数解码侧的 `AacTns`），不是平均值。
- **给旧提交补一个临时测试来取基线**很便宜：`git worktree add --detach
  .scratch/head_297 8743b8b` → 用 Python 往那棵树里的测试文件**追加**一个只打印
  的测试（`assert s.count(anchor) == 1` 再替换）→ 在那棵树跑 → 拿到
  `bytes/per-frame/snr`。注意旧树的 helper 元数可能不同（§297 的
  `tool_bands` 只回 5 个值），临时测试里就别用新字段。
- **Windows 上 `git worktree remove --force` 可能只注销不删目录**：报
  `Permission denied`（moon 的构建缓存还握着文件句柄），但工作树其实已经注销，
  `git worktree list` 干净。别以为没清就去重跑 remove（第二次会报
  `not a working tree`），直接 `rm -rf .scratch/head_xxx` 收尾即可。
- 其余照旧：`moon fmt` 禁跑、heredoc 禁用（往 C 源里写含 `"\n"` 的行会被 Python
  吃一层转义，写完必须 `grep` 验证）、清理走 `.trash/<日期>/`、
  每条 bash 显式 `cd`、`libavcodec` 包**不要再加白盒测试**（wasm init 的
  local count 已接近上限，§288 记过）、提交消息里含 `remove`/`rm` 子串会被钩子
  拦，用 `git commit -F <file>`。
