# H.264 §412 High 10 位深全链——交接文档

接续 `doc/handoff/AGENT_HANDOFF_2026-11-13_H264_REPIN.md`（§411 重钉已交付，wasm
145+16 绿）。本片把工作区里的 §412 WIP（位深管线 + High10 测试）收口：
CLI 接线、ffref C 绑定扩展、ffmpeg 双路仲裁、文档与提交。用户指定的
两个技能（moonbit-c-binding / make-moonbit-c-bindings）全程用于 ffref
FFI 扩展（survey→stub→安全包装→docker 验证）。

## 这一片做了什么

### 1. 位深管线（WIP 已有，本片复核）

- `libavcodec/h264_enc_depth.mbt`：`qp_ext = qp + 6*(bd-8)`、
  `max_sample`、`bit_depth_ok`（8/9/10；4:4:4 profile 出 4:2:0 范围外拒收）、
  `profile_idc`（>8 → 110）、`load_plane`/`pack_plane`（>8 位平面小端
  16-bit）。
- SPS/PPS：High 族 body 带 `bit_depth_luma/chroma_minus8`；
  `pic_init_qp_minus26` 写用户态差值（FFmpeg 解析端自加 `qp_bd_offset`，
  双加会错）；High 族 PPS 尾即使 8x8 关也写全（漏写会把 stop bit 误读
  为 `transform_8x8_mode_flag`）。
- 编码器全部公开入口（`h264_encode_intra_frame(_cabac)`、
  `h264_encode_frames(_cabac)`、`H264StreamEncoder::open` 等）带
  `bit_depth? : Int32 = 8`，默认字节不变。

### 2. CLI `--bit-depth 8|9|10`（本片新增）

`cmd/encode-h264`：`Options.bit_depth`（非法值 7/11/0/abc 拒收）、
`sample_bytes`/`raw_frame_size`（>8 位帧尺寸 ×2）、`pixel_format_name`
（`yuv420p9le`/`yuv420p10le` 报文与错误信息）、批式/流式/`open_stream_encoder`
三路透传、usage 行与 summary JSON（`pixel_format` + `bit_depth` 字段）、
wbtest 新增 1 项（双位深腿：流式==批式逐字节、SPS profile 110、解码
round-trip、8-bit 尺寸截断拒收）。

### 3. ffref C 绑定扩展 9/10-bit（两个指定技能的落点）

- `ffref_stub.c` `frame_kind`：`AV_PIX_FMT_YUV420P9LE → 6`、
  `YUV420P10LE → 7`（blob `chroma_mode` 语义扩展，头布局不变）。
- `append_frame`：kind≥6 平面小端 16-bit 逐行 verbatim 拷贝
  （LE 内存序=字节序），帧长 `2*(w*h + 2*cw*ch)`。
- `ffref.mbt`：`FFRefVideo::bit_depth()` 新公开方法；`ffref_decode_video`
  文档更新（9/10-bit 4:2:0 支持）；`ffref_video_frame_len` kind≥6 腿。
- `ffref/ffref_high10_test.mbt`（native-only，登记进 moon.pkg targets）：
  - 主测试 11 腿：9/10-bit × CAVLC/CABAC × {I 单帧, 3 帧 P 链} +
    weightp 3 腿（9 CAVLC / 10 双熵）——oracle 报 kind 6/7、宽度高度、
    与本仓解码器（**skip_lf=false，含去块**）逐样本比对。
  - B-GOP 4 腿：默认 B 序列（解码序 I0,P2,B1,P4,B3,P5），oracle 显示序
    vs 我们解码槽经 §411 映射 `[0,2,1,4,3,5]` 重排后逐字节比对。

### 4. 排障记录（本片最有价值的教训）

首版 ffref 测试用 `skip_lf=true` 对 oracle → 9/10-bit qp26 全帧 ±1..±10
差异、**双熵逐值相同**（熵编码不改系数量值）。三步定位：

1. **qp 极值 + PCM bracket**：qp0 腿 ndiff=0、PCM 腿 ndiff=0、qp26/51
   大面积差异、dct8 腿与普通腿逐字节同构 ⇒ 差异=环内去块滤波，不是
   编码器/变换 bug。
2. **判别实验**：docker 内 x264 产 High10 真流（testsrc2 96x64 3 帧
   qp26 CAVLC），本仓解码器与 ffref oracle 交叉解码 **3 帧 ndiff=0** ⇒
   解码器在真流上与 FFmpeg 逐样本一致。
3. **修正**：ffref 测试统一 `skip_lf=false`（oracle 是全解码含 LF）。
   wasm round-trip 侧维持 `skip_lf=true`（编码器本地 recon 是 pre-LF，
   两套约定各有其对照域，不能混）。

副产品：**解码器 9/10-bit 去块路径首次获得 ffmpeg 仲裁覆盖**（此前
decoder 测试从未提及 bit_depth）。

### 5. ffmpeg CLI framemd5 仲裁（§411 风格外部位）

repo 根 `tmp_probe/`（跑完已删，回收站可取）native 产两条 10-bit B-GOP
流：H10B.264（CAVLC，2727 B）/ H10C.264（CABAC，2018 B）+ 我们显示序
逐帧 md5。docker `ffmpeg -f h264 -i X.264 -f framemd5` **12/12 帧
MATCH 零告警**。产物存 `.scratch/repin412/`（gitignored）。

## 验证矩阵

| 项 | 命令 | 结果 |
| --- | --- | --- |
| wasm 类型检查 | `moon check --target wasm --deny-warn --no-render` | exit 0 干净 |
| native ffref 检查 | `moon check --target native -p ffref --deny-warn --no-render` | exit 0 干净 |
| wasm 全族+CLI | 18 个 h264* 测试文件 + `cmd/encode-h264` | **153/153** |
| docker ffref native 全套 | image 内 `moon test -p ffref` | **78/78**（原 77 + B-GOP 1） |
| ffmpeg CLI framemd5 | H10B/H10C | **12/12 帧 MATCH** 零告警 |
| 接口 | `moon info --target wasm` | 无需提交变化（mbti 为本地生成物） |

## 遗留与下一片候选

1. **x264 native oracle 8 项**继续冻结（native-only 约定不变）。
2. `weightp` 转正默认（需重钉全部 `h264*` 快照，§411 交接同款欠账）。
3. High 4:2:2 / 4:4:4 profile（422/444 色度 + 12/14-bit）——当前 4:2:0
   架构下属大改，未排期。
4. 统一播放门面 / 码控深化。

## 工具坑（新增入档）

- MoonBit `for c = 0; c < pw { }` 漏更新子句 = 死循环；E0052「loop
  variable never updated」警告必须当错误处理（本次挂掉 docker 容器
  45 分钟，104% CPU）。
- docker 内 `moon test -f` **全名匹配**（含 `ffref: ` 前缀），不可重复
  传 `-f`；多测试跑全套或分次容器。
- 探针包必须放 repo 根（`.scratch/` 不参与包发现）；`moon.pkg` 用仓库
  s-表达式语法（JSON 花括号解析报错）；`is-main` 用
  `pkgtype(kind: "executable")`；`fn main` 调 raise 函数须 `fn main raise`。
- `moon run` 的可执行文件 CWD = 包目录，`@fs.write_bytes_to_file` 相对
  路径落在包目录下（挂载映射要算对）。

## 复现命令

```sh
moon check --target wasm --deny-warn --no-render
moon test --target wasm libavcodec/h264_enc_high10_test.mbt --no-render
moon test --target wasm cmd/encode-h264 --no-render
# docker ffref 全套
$env:MSYS_NO_PATHCONV='1'
docker run --rm --entrypoint /bin/sh -v "D:/project/FFmpeg-n9.0.2/moonbit:/work" -w /work ffmpeg-moonbit-ffref:nine-x264 -c "/root/.moon/bin/moon update >/dev/null 2>&1; /root/.moon/bin/moon test --target native -p ffref --target-dir /tmp/mbuild"
# framemd5 仲裁（产物在 .scratch/repin412/）
docker run --rm -v "D:/project/FFmpeg-n9.0.2/moonbit/.scratch/repin412:/data" --entrypoint /bin/sh ffmpeg-moonbit-ffref:nine-x264 -c "ffmpeg -hide_banner -nostdin -f h264 -i /data/H10B.264 -f framemd5 /data/H10B_ff.md5"
```
