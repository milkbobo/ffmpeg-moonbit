# H.264 流式 CABAC 位定价

本轮继续迁移编码组合能力，保持编码本体为纯 MoonBit。

- `H264StreamEncoder::open(cabac=true, cabac_rd=true)` 将真实 CABAC 候选计价接入流式 P 帧，与批式逐字节相等；支持 AQ/AUD。
- CLI 新增 `--cabac-rd`，批式和流式均透传；拒绝未开 CABAC 或与 B 帧组合。
- 修复批式 CLI 接受 `--b-slices` 却未向编码器传递的问题，双熵均覆盖。
- 流式 CLI 明确拒绝 ABR/VBV，避免静默忽略参数。

验证：Wasm 流式及 CABAC RD 14/14，CLI 9/9，严格 check、fmt、info、diff check 通过。已有 Docker x264 原生回归 33/33，定向 ASan 使用现有 harness 和 VBVARB 素材通过。容器有旧 derive 语法弃用警告。

补充验收：新增流式 CABAC RD 的 C parser 与双解码器像素对拍 1/1；B 帧/GOP/ABR/VBV 回归 34/34。C parser 无警告、无错误，三帧重建一致。

技能：已查阅所有 MoonBit 技能；moonbit-c-binding 和 make-moonbit-c-bindings 用于复核私有 extern 的借用边界、调用期间复制、释放路径及原生/ASan 验证。没有新增 C ABI 或 vendoring。契约测试采用现有实现的黑盒测试，未引入重复声明或未经验证的证明；无 OCaml 输入。

限制：CABAC RD 仍不支持 B 帧；流式宿主仍整文件读取并收集输出。本轮未修改已有的 ffref/ffref_test.mbt、libavcodec/h264_inter.mbt、libavformat/playback_streaming.mbt 工作区改动。
