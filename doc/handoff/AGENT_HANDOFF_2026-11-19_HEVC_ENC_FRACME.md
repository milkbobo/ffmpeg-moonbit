# HEVC 编码器分数像素 ME（2026-11-19）

接续 [§449 P 帧切片](AGENT_HANDOFF_2026-11-19_HEVC_ENC_P.md)，本切片把 P 帧
运动搜索从整数位置扩到 1/4 像素。纯 MoonBit/wasm；条目见
`doc/PORTING_HISTORY.md` §450。

## 实现

- `hevc_enc_inter.mbt::hevc_enc_me_search`：整数全搜索后，在最佳整数 MV
  的 4x4 分数邻域（`(mx+fx, my+fy)`，`fx,fy ∈ [0,3]`）精修。每个候选调
  `hevc_luma_mc_uni` 在临时 `HevcPicture` 上生成预测，用最终重建样本的
  SAD 评价——评价域与解码器完全一致，无独立的插值/舍入模型。
- 仅当严格更优时替换整数 MV，静态块仍稳定落在 MV 0。MVD 语法不变
  （本来就是 1/4 像素单位），无新增 bin、无公开 API 变化。

## 验证

- 黑盒 `hevc_enc_p_test.mbt` 钉值更新为 FFmpeg 9.0.2 对纯 MoonBit I+P
  码流的新 framemd5（4 帧 64x64 qp26）：
  `1f82a62968f60a66d45a21fd7994f5d9` /
  `ad2ddfb5a6afc335a86b3e9e7a38c02b` /
  `0e87898da61774a5f0a133226625749d` /
  `4abf3a6a3473037c5887ae2c18617885`。
  FFmpeg 零告警解码，四帧与自家解码器逐字节一致。
- 白盒新增 `quarter-pel MV round-trip`（用解码器 MC 核构造四种真实 1/4
  像素位移）与 `half-pel MV round-trip at qp extremes`（qp 10/42）；
  HEVC 编码器白盒 31/31、黑盒 2/2 全绿。
- `moon check --target wasm --deny-warn --no-render` 零警告；改动文件
  格式化且幂等。

## 边界与后续

分数 ME 只作用于 luma（chroma 由解码器从 luma MV 派生），未做多参考、
分数像素层间的进一步分级（如 1/8 精度）、B 片、RD 选模。下一步建议：
带 intra 候选的 RD 选模 → B 片 → 高色度/高位深 → 码控 → 流式/CLI。
