# Agent 交接：AV1 纯 MoonBit 编码器排障过程记录（2026-11-17/18）

> **本文件已被 `doc/handoff/AV1_ENC_HANDOFF_2026-11-18.md` 取代**（§442 收口后的
> 权威交接）。保留本文件作为 §442 四轮排障的过程档案：根因链、探针
> 方法论、失败实验记录（od_ec 重写等）都在这里有完整细节。

# （原）Agent 交接：AV1 纯 MoonBit 编码器 §438a 收口（2026-11-18）

用户指令：继续迁移 AV1 编码器，wasm-only（纯 MoonBit 自研路线，H.264
§376-§437 同款；FFmpeg n9.0.2 树内无 AV1 软件编码器，且 wasm-only 决定
排除 C 绑定——libaom/dav1d 只作算法参照）。

---

## 0. 一句话状态

**§438a（msac 熵编码器）完成**：5/5 全绿（bool/symbol+CDF 轨迹/
bools+uniform/单 bool/2000 符号双适应模式压力）。根因只有一个——
`carry_out` 的进位传播（只有 b≥0x100 才 bump 前字节、0xFF 链循环回退）；
区间算术/CDF 镜像/全精度 done 一次到位。未提交。

## 1. 已完成

- 调研：解码端 43 个 av1*.mbt；`av1_msac.mbt`（dav1d msac 移植，287
  行）= 写端镜像目标；`av1_parse_sequence_header`/`_payload` 位序已读
  （§438b 序列头写端的镜像源）。
- `libavcodec/av1_enc_msac.mbt`（新，~250 行）：
  - `Av1MsacEnc`（precarry/low/rng/cnt/allow_update_cdf）+ init(-9)
  - `encode_bool_equi`/`encode_bool`：split `v=(((rng>>8)*(f>>6))>>1)+4`，
    bit=1→[0,v) bit=0→low+=v, rng-=v（从解码器第一性逆推）
  - `encode_symbol_adapt`：`F(i)=((r>>8)*(cdf[i]>>6))>>1+4*(n-i)`，
    F(-1)=rng，s→[F(s),F(s-1))；CDF 更新逐行镜像 decode_symbol_adapt
  - `encode_bool_adapt`/`encode_bools`/`encode_uniform` 同构镜像
  - `carry_out`（od_ec 进位链：0xFF 传播）+ `renormalize`（c==0 吐字节）
- `libavcodec/av1_enc_msac_test.mbt`（4 用例）：bool_equi/bool 序列、
  symbol_adapt（含 CDF 轨迹逐槽恒等断言）、bools/uniform、单 bool。

## 2. 验证现状

- 编译干净（libavcodec check 过）。
- 单 bool=1 ✓；单 bool=0 ✗；512-bit 序列第 14 个破（前 13 个幸存）；
  symbol 第 4 个破（写 3 读 0）；bools 第 0 个破。

## 3. 校准线索（下会话从这里继续）

1. **首号嫌疑：`done()` 的 flush 位数**。dav1d 解码 init `cnt=-15` ⇒
   流首字节落在 dif 的 **bit55**（非 56），比自然 16 位窗口低 1 位——
   od_ec_enc 的 done 有经典的 1 位补偿（`c = -cnt - 2` 风格）。当前
   实现是 `-c-1` + 三段凑数 carry_out，手算单 bool=0 例子：输出流
   [0xBF,0xFF,0xFB,0xFF]，dif 顶 16 位 = 0x5FFF < vw=0x4004<<48 需要的
   ≥0x4004 —— 差在终止字节的选择/移位。
2. **od_ec_enc_done 真实结构**（可从 libaom entenc… od_ec_enc.c 直读，
   本仓无源码——`.scratch/ffref/ffmpeg-src` 也没有 aom；需 WebFetch
   aom 源或继续黑盒）：输出「足以消歧的最短前缀」+ 依赖解码端越界
   refill 的**低位全 1 填充**（dav1d refill 越界分支 dif|=…全1）。因
   此 done 可以：flush `low` 的剩余位到字节边界（补 -cnt-1 或 -cnt-2
   位），追加区间内一点（low+rng-1 的低位），后续交给 1 填充——只要
   `low|111.. < low+rng`（即填充后仍在区间）即可，不满足时多 flush
   一字节。
3. **校准捷径**：先写「全精度 done」——flush 后直接输出 8 字节定长
   （V=low+rng-1 零填充），解码器 refill 读满不越界——正确性与区间
   算术解耦，先让 4 个 round-trip 用例全绿，再把 done 换成最短终止
   （省 4-6 字节/tile）作为优化切片。**推荐先走这步**。
4. 若全精度 done 仍红 ⇒ 嫌疑转到 carry_out/renorm 的进位语义（od_ec
   的 cnt 语义："low 中已知稳定/可能进位的位数"，-9 起步对应 17 位
   窗口）或 bit=0 方向（可用单 bool=0 + 手算 dif 直接验证——见线索
   1 的手算已确认方向，基本可排除）。
5. symbol 第 4 个破（写 3 读 0）：与 bool 同源（流早期错位）概率大；
   bool 修复后大概率连带绿。

## 4. §438 后续切片规划

| # | 切片 | 要点 |
|---|---|---|
| §438a | msac 编码器收口 | 线索 §3；全绿后补 disable_cdf_update/多 CDF 形态/1000+ 符号压力 |
| ~~§438b~~ 完成 | 序列头 OBU 写端 | `av1_enc_seq.mbt` 5/5（mono 位恒写教训入档）；验收=自家解析器字段级 round-trip |
| ~~§439~~ 完成 | 帧头写端（key frame + OBU_FRAME） | `av1_enc_frame.mbt` 4/4；教训：reduced 头无 sc 位、tile_offsets 绝对偏移 |
| ~~§440a~~ 完成 | 最小 tile（64x64 单块 DC+skip） | `av1_enc_tile.mbt`——**第一个像素 round-trip**；CDF 轨迹=复用 av1_cdf_copy_defaults 镜像 |
| ~~§440b~~ 完成 | dc 残差写端（skip=0 路径） | 同文件 +1 fn 3/3——带系数 round-trip；教训：512/1024 桶 base=chroma*16（布局 [2][16] 非联合索引）、get_skip_ctx 传真实 bs、itx 四步链是 dav1d 正确语义勿动 |
| ~~§441~~ 完成 | SPLIT 多块 + directional 模式 | split_tile/directional_tile 各 1/1（tile 套件 5/5）；分区 ctx SPLIT 不写回；方向空邻居=127 非 128 |
| ~~§442~~ 完成 | AC tile 结构里程碑 | 4×32x32 + 双 mirror（partition/tx ctx）+ 块 0 Y dc 残差 → **6/6 全绿**（编码全量 20/20）；根因：txsz tctx 逐块推导（tx ctx mirror，l-index=by4）+ 系数 ctx 初值 0x40 非 0 + skip 块继承邻居残差；AC token 是下一切片 |
| 后续 | 逐工具扩展 | directional pred / inter / CDEF 关 / multi-tile ……（H.264 §376-§437 节奏） |

## 5. 工具链注意

- UInt 转换：Int64→UInt32 用 `.to_int().reinterpret_as_uint()`（Int64
  无 reinterpret_as_uint）；UInt 移位量用 Int（`v >> i`）。
- 测试循环别用 `for _i = 0; i = _i; ...` 阴影写法（解析炸）；标准
  `for i in 0..<n` + 预生成数组重放（解码端需要 call-site 概率/CDF）。
