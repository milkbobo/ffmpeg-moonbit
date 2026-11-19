# HEVC 编码器 SAO EO 交接 —— §461

日期：2026-11-19
工作目录：`D:\project\FFmpeg-n9.0.2\moonbit`
上游切片：§460（色度 SAO，未提交；§447-§459 已在 733d1f8/37223d7）

## 结果

HEVC 编码器 SAO 新增**边带偏移（EO）模式**（opt-in `sao_eo : Bool =
false`）：逐 CTB 与 band 候选竞争，四个 `eo_class` 方向择优，类别符号
约束（1/2 上、3/4 下，语法无 sign bins），对称 round-half-away 均值，
**平局选 EO**（bins 更省）。写端补 `sao_eo_class`（2 bypass bits MSB
先，镜像解码端）；Cr 无 class bin 继承 Cb。默认关闭，全部既有钉值流
字节不变。纯 MoonBit、wasm-only。

验证：HEVC 编码器测试 wasm-gc **105/105**；FFmpeg 9.0.2 `-xerror`
零告警仲裁；生成器复跑字节确定。

## 决策结构（hevc_enc_sao.mbt 重构）

- `HevcSaoCand`（**priv**）：gain/kind/aux/band_position 或 eo_class/
  4 offsets。band/EO 评估各产候选，`hevc_enc_sao_decide` 外层择优后
  `hevc_enc_sao_adopt` 一次写入（避免两模式覆盖 offset_val）。
- EO 评估 `hevc_enc_sao_eo_eval`：邻居对 pos 表 + `edge_idx=[1,2,0,3,4]`
  （与 `hevc_sao_apply` 共享语义）；`force_class>=0` 只评一个方向（Cr
  继承 Cb 的 class）；邻居出**平面**界回退自身（apply 同款）。
- **对称 round-half-away**：`(mag + c/2)/c` 再还原符号——朴素
  `(d+c/2)/c` 负均值向零截断偏 +0.5（振铃钉值 16≠24 抓出）。band
  公式保持 §453 原样（钉值流锁定）。
- 平局偏好 EO（等增益 bins 更少）；增益 0 两者皆 off。

## 参数面

三入口 + `HevcStreamEncoder::open` + CLI `--sao-eo`，与 `sao_chroma`
正交组合（Cr 继承 Cb 的 type **和** eo_class）。

## 测试与仲裁

- 白盒 `hevc_enc_eosao_wbtest.mbt` **4/4**：单元钉值（振铃构例
  band=0 / EO 垂直类 gain=24 / 类 2 偏移 +3；取反后类 3 偏移 -3；
  force_class）；条纹流双向合法 + 往返；组合与 10-bit；默认恒等；
  流式==批式（双旗标+CRF+B）。
- 黑盒 `hevc_enc_eosao_test.mbt` **1/1** 双目标：2 帧条纹流（282 字节）
  MD5 `47ed933777b48d814ee50c0713480c50` / `0978e4e361c2487d97fd36bff56060ea`。
- 生成器写 `eosao_seq.265`，SHA-256
  `37a6102a0e51dbcda997ae40dfeafbe4ceb734ec55ecf1cfb389c881e2936033`。

## 本轮踩的坑

1. **负均值整数舍入**（本切片唯一真 bug，单元钉值抓出）。
2. 自然流里 band 几乎总不劣于 EO（更自由的值映射）——别赌「EO 必然
   进流」的数据；流级钉双向合法 + 往返，位级靠单元钉值 + 写读镜像
   结构。条纹/阶跃/棋盘 × QP38-51 试遍 EO 都没自然胜出。
3. all-IDR 多帧整解 duplicate POC 坑再犯——多帧一律 sequence 入口。
4. `Int32>` 手写类型笔误（Write 大文件时 7 处）——批量 replace 修复，
   大文件写入后先 check 再继续。

## 检查状态

`moon fmt`/`moon info` 已跑；全仓 `moon check --target wasm` 0 错误；
定向 wasm-gc 仅既有 v128 警告；CLI 2/2。

## 边界与下一步

- SAO merge flag 未使用（始终显式参数）；决策无率项（SAD + 平局偏好）。
- 剩余：**VBV/ABR**（参照 H.264 vbv_trial/commit）→ 单色（cfidc=0）→
  B 片加权/时间 MVP/多参考、多 slice/tile。
- §460 + §461 均未提交（与 §447-§459 的 733d1f8/37223d7 衔接）。
