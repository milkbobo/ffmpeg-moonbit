# H.264 4:4:4 CABAC P 帧及流式 I/P

接续 STREAM_C444。批量 `h264_encode_frames_cabac` 和
`H264StreamEncoder` 支持 `chroma_format=3, b_slices=false`。
4:4:4 B 调度仍在入口拒收。

- inter CBP 不编码 chroma bins，三个平面共享四位 CBP。
- 三平面残差使用 cat 2/8/12，块索引为 `16*p+i`；编码来源为
  `H264PMbCode.planes_444`，与 CAVLC 共用量化及重建。
- 4:4:4 inter transform flag 写 0，三平面 8x8 DCT 仍待实现。
- CABAC 批量路径的色度 stride、加载、分配、recon 打包支持全分辨率。
- weighted prediction 拟合使用完整的 4:4:4 色度高度。
- 修正已有单 IDR 测试：batch recon 只含 inter 图片，不能读取 recon[0]；
  改用 intra 单帧入口取得重建，保留已有滤波后 FFmpeg MD5 锚点。

验证：

- `h264_enc_c444_cabac_test.mbt` 2/2，含重复平坦帧、RD 开关、
  多参考、AQ、dct8x8 开关、流式/batch 字节一致及逐像素重建。
- 组合回归初次 42 项中 41 项通过，唯一失败是上述已有 IDR 测试越界；
  修正后单独重跑该测试通过。
- native `x264/stream_c444_wbtest.mbt`：CAVLC/CABAC 四帧均被 FFmpeg 接受，
  零 warning/error，逐帧 FNV 像素摘要与本地默认滤波解码一致。
  C ABI / 借用与释放规则均未改动，未新增 C 分配，无新增 ASan 运行。
- `moon fmt` / `moon check --target wasm --deny-warn` / `moon info --target wasm`。

下一步：4:4:4 B 帧双向 MC 和 CABAC B 语法、三平面 8x8 DCT。
