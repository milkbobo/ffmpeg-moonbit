# H.264 CABAC 编码器交接（§381 已收口，全部完成）

更新：2026-11-10（收口版）。本文接续 `AGENT_HANDOFF_2026-11-09_H264_ENC_PORT.md`
（§376–§380 纯 MoonBit CAVLC 编码器），记录 CABAC 熵编码切片的最终交付。
**§381 已全部完成，无未竟事项**；细节见 `PORTING_HISTORY.md` §381 与
`README.md` 的 H.264 行。

## 最终状态（全部验证过）

| 项 | 状态 |
| --- | --- |
| `moon check --target wasm --deny-warn --no-render` | 干净 |
| wasm 全量测试 | **1736/1736**（1729 + CABAC 7） |
| 黑盒 7 测（`h264_enc_cabac_test.mbt`） | **7/7**（含 ffmpeg 仲裁 PIN 已回填） |
| bin 级 zip 探针（已删除，一次性工具） | 26271/26271 逐 bin 对齐 |
| docker ffmpeg 仲裁（六帧 96×64×6/QP24） | 零告警，framemd5 逐帧 == 自家解码器（`e454d8…/a6814a…/74ecad…/791ea2…/aa4569…/884043…`） |
| x264 oracle（docker native `-p libavcodec/x264`） | **7/7**（含新增 CABAC 流双解码用例） |
| 临时调试 | **已全部删除**（dbg singleton、双侧 emit、探针文件、moon.pkg 门控） |

## P 失步根因（一段话版）

**残差电平 escape（level≥15）的数据位写法错**：旧实现按 `k=3` 起的
前缀梯写 `k` 位数据；解码器语义是 `jj` 个 1 前缀 + 0 + `jj` 位数据
（值 = 14 + [2^jj, 2^(jj+1))）。QP 26 电平不达 15 从未触发，QP 24 即
显形。交接文档建议的第一刀（skip 分支四位 `mb_type_bits` +
`h264_write_back_part` 写 mvd=0）已在代码中且正确。

## 留给后续切片的要点

1. 排查 CABAC 类失步时，**bin 级 zip 探针**（两侧引擎全量 emit 逐行比）
   是终局工具；MB 级/块级对比会被「值碰巧相同」的对齐假象拖延。
2. 探针自身的 emit 要当真嫌疑对待：本轮三次假警报全是探针 bug
   （`bypass_sign` 的 mask 语义读反、`get_cabac_bypass` 的 patch 覆盖、
   emit 位置不对称）。
3. 算术引擎可用随机往返（200 轮 QP 10-49 混合 decision/bypass/terminate
   写→读）快速排除——本轮引擎提前洗清了嫌疑，节省了大量误向。
4. 静态场景测试前提：CABAC 无 PCM，I 帧有损，P 帧必然带 coded MB；
   漂移断言无意义，用解码成功 + 流尺寸门。
5. 未来片（未变）：I16x16 CABAC 分支、RD 换 CABAC 位定价、High profile
   8x8dct、码率控制。

## 运行速查

```sh
# 黑盒（宿主 wasm）
moon test --target wasm --no-render libavcodec/h264_enc_cabac_test.mbt

# x264 oracle（docker nine-x264）
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work \
  ffmpeg-moonbit-ffref:nine-x264 -c \
  "/root/.moon/bin/moon update >/dev/null 2>&1; \
   /root/.moon/bin/moon test --target native -p milkbobo/ffmpeg-moonbit/libavcodec/x264 --target-dir /tmp/mbuild"

# ffmpeg 仲裁（流 dump → bin → framemd5）
python .scratch/rd_dump_to_bin.py <dump> x.264
docker … ffmpeg -y -v warning -i x.264 -f framemd5 -c:v rawvideo x.md5
```
