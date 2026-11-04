# 关于 heredoc 命令在 Windows / Git Bash 执行层挂起与内容改写的问题报告

> **提交对象**：MoonBit 工具链 / 执行环境负责人
> **提出方**：FFmpeg n9.0.2 → MoonBit 移植项目（`moonbit/`，约 10 万行 MoonBit、1385 个 wasm 测试）
> **日期**：2026-11-04
> **性质**：现象复核 + 归因咨询，**不是缺陷指控**

---

## 0. 一页结论

我们项目里长期有一条约定：「禁用 heredoc，一律用编辑工具写文件」。这条约定把**两类不同现象**混记成了「heredoc 会挂死」。复核后结论如下：

| 现象 | 我们的归因 | 是否 MoonBit 侧 |
|---|---|---|
| ① heredoc 里的 `\n` / 引号 / NUL 被改写，写出损坏文件 | 命令字符串在传给 shell 前的转义处理层 | **否** |
| ② heredoc 命令永久挂起、直到超时 | shell 从 stdin 读脚本 + 结束符失配 + stdin 不给 EOF | **否**（`moon` CLI 已用实验排除） |
| ③ `moon test` 全量偶发卡在 `moonc` 编译（仅 1 次） | 未定位 | **待确认**，见 §6 |

**一句话**：前两类都发生在 shell 解析 / 命令传输阶段，`moon` 进程根本还没启动，不是 MoonBit 编译器或 CLI 的缺陷。之所以来问 MoonBit 侧，是因为症状常表现为「跑 `moon fmt` / `moon test` 时卡住」，容易被误判成工具链问题，且我们想确认 `moon` 的 stdin 行为是否有已知约定。

**最希望得到回答的是 §5 的 4 个问题**，尤其是第 1 条（命令到底是 `bash -c` 还是 `bash -s`）。

---

## 1. 背景

本项目需要频繁用脚本生成夹具、给 FFmpeg 的 C 源码打调试补丁、批量转换向量表。早期大量使用：

```bash
python - <<'EOF'
... 往 C 源里注入 printf("\n") ...
EOF
```

结果反复出现文件损坏与命令无返回，于是形成了「绝对不能用 heredoc」的约定。但历次交接文档对机理的描述不一致（有的写「转义改写」，有的写「挂死」，有的写「rm-guard 拦截」），这次做了隔离实验，想把准确机理固定下来，也顺便确认是否该向 MoonBit 侧反馈。

---

## 2. 现象一：内容被改写（写出损坏文件）

项目内可查的记录：

| 出处 | 记录内容 |
|---|---|
| `agent.md` §6 | 「heredoc 内含 `\n`、`\\n`、引号或 NUL 转义的内容会被反复改写/截断，已三次写入损坏文件（Python `SyntaxError: unterminated string literal`、源文件里出现真实换行甚至 NUL 字节）」 |
| `AGENT_HANDOFF_2026-10-27_AAC_PS.md` §「已解决的关键坑」1 | 本轮三次把 `\n`/引号/NUL 写坏文件 |
| `AGENT_HANDOFF_2026-11-04_OPUS_ENC.md` §5 | `build_ref.sh` 的 `python - <<'EOF'` 往 C 源注入 `printf("\n")` 时，`\n` 被 Python 当转义变成真换行，生成非法 C 字符串；必须写成 `\\n` |
| `AGENT_HANDOFF_2026-10-26_INTER.md` §7 / `AGENT_HANDOFF_2026-10-25_AV1_LR.md` | 「bash heredoc 写含 `\n` 的 C/Python 字符串会断行」「heredoc 会把 `\\n` 变成真换行、破坏 printf」 |

**典型症状**：C 源码里的 `printf("\n")` 变成跨两行的字符串字面量；Python 脚本报 `unterminated string literal`；文件里出现 NUL 字节。

**诚实说明**：本轮**没有主动复现**这一类（项目已全面改用编辑工具写文件，不再走 heredoc）。上表是历史记录，不是本次实跑结果。我们想确认的是：转义处理发生在哪一层、能否提供 raw 透传模式（§5 第 2 条）。

---

## 3. 现象二：命令永久挂起

### 3.1 最小复现（不依赖本项目、不需要 MoonBit 源码）

在任何 Git Bash 里执行，用 `timeout` 保护：

```bash
# 对照组：结束符顶格 + 末尾 exit，stdin 故意保持打开 6 秒
{ printf 'cat <<"EOF"\nhello\nEOF\nexit\n'; sleep 6; } | timeout 3 bash -s
# 实测：输出 hello，exit=0，立即返回

# 实验组：结束符前多了两个空格，其余完全相同
{ printf 'cat <<"EOF"\nhello\n  EOF\nexit\n'; sleep 6; } | timeout 3 bash -s
# 实测：exit=124（被 timeout 杀掉），无任何输出，进程卡住
```

`bash -s` 用来模拟「命令经 stdin 喂给 shell」的执行方式；`sleep 6` 模拟「命令执行期间 stdin 不关闭」。

### 3.2 实测矩阵（2026-11-04，环境见 §8）

| 编号 | 结束符 | shell 模式 | stdin | 结果 |
|---|---|---|---|---|
| A | 正确 | `bash -s` | 管道立即 EOF | `exit=0`，输出 `hello` |
| C | 前带 2 空格 | `bash -s` | 管道立即 EOF | `exit=0`，仅 warning：`here-document at line 1 delimited by end-of-file (wanted 'EOF')` |
| G | 正确（末尾有 `exit`） | `bash -s` | 保持打开 6s | `exit=0`，立即返回 |
| **H** | **前带 2 空格（末尾有 `exit`）** | **`bash -s`** | **保持打开 6s** | **`exit=124`，永久挂起** |
| I | `EOF\r`（CRLF） | `bash -s` | 保持打开 6s | `exit=0`，正常 |
| J | 前带 2 空格 | `bash -c` | 保持打开 6s | `exit=0`，仅 warning |
| K | — | `moon version` | 保持打开 6s | `exit=0`，正常输出版本 |
| L | — | `moon check --target wasm --deny-warn` | 保持打开 6s | `exit=0`，`no work to do` |

### 3.3 根因：三个条件必须同时成立

1. **命令通过 stdin 喂给 shell**（`bash -s` 语义），而不是作为 `-c` 的参数；
2. **heredoc 结束符没被识别**——缩进、被引号/转义改写、正文里提前出现或丢失 `EOF` 都会导致；
3. **stdin 不发送 EOF**——发起命令的工具持有管道不关闭。

bash 读 heredoc 匹配不到结束符时，会把后面所有行都当成正文（连 `exit` 也吞掉），然后继续从 stdin 读、永远等不到 EOF，进程不返回，直到外层超时。

反过来：

- 只要 stdin 会 EOF（A/C），bash 报个 warning 就退出，**不挂**；
- 只要命令是 `bash -c`（J），heredoc 正文在命令字符串里、不从 stdin 取，**不挂**；
- 只要结束符正确（G），**不挂**。

### 3.4 几个反直觉的点

- **CRLF 不是元凶**：`EOF\r` 在本机 Git Bash（cygwin 文本模式）下 `\r` 被吃掉，照常匹配（I）。真正容易失配的是缩进或内容被转义层改写。
- **`bash -s` 本身就会读到 stdin EOF**：第一版实验里连「结束符正确」也超时了，因为 `bash -s` 执行完脚本还会等下一条命令。必须在脚本末尾加 `exit` 才能把变量隔离开。这一点很容易把「shell 固有行为」误记成「heredoc bug」。
- **`moon` CLI 不背这个锅**：K/L 显示 `moon version` 与 `moon check` 在 stdin 保持打开时都立即返回，不读 stdin、不因此挂起。挂起发生在 shell 解析阶段，此时 `moon` 进程尚未启动。

### 3.5 两类现象的级联关系

内容被改写（现象一）**不一定**导致挂起，但经常级联：`\n` 被改成真换行或引号被截断 → 结束符或引号结构被破坏 → 触发 §3.3 的三个条件 → 挂死。这解释了为什么历史记录里两者总是同时出现、被笼统记成「heredoc 会挂死」。

---

## 4. 与 MoonBit 侧的关系：已经排除了什么

| 检查 | 结论 |
|---|---|
| `moon` / `moonc` / `moonrun` 是否从 stdin 读取或等待 | K/L 实测：`moon version`、`moon check` 在 stdin 打开时立即返回，**不等待** |
| 挂起时 `moon` 是否已启动 | 否。挂起在 shell 读 heredoc 阶段，`moon` 尚未 exec |
| 是否需要 MoonBit 编译器 / CLI 改动 | **不需要**。我们判断这是命令执行层（IDE 内 Agent 的 Bash 工具，非交互、无 TTY）的行为 |

**为什么还是要问 MoonBit 侧**：当出问题的 heredoc 里包的是 `moon fmt` / `moon test` 这类命令时，用户看到的是「跑 moon 卡住」，很容易归因到工具链。我们希望把这个误判排除掉，并确认 `moon` 对 stdin 没有隐含约定（例如未来版本是否会从 stdin 读配置 / 交互式确认）。另外 §6 有一个**真正可能属于 MoonBit 侧**的独立现象，想请一并看一下。

---

## 5. 希望确认的问题（请逐条回复）

1. **命令执行方式**：IDE / Agent 的 Bash 工具执行一条命令时，实际是 `bash -c '<command>'`，还是把命令经 stdin 喂给 `bash -s`？命令执行期间 stdin 是否保持打开、结束后是否发送 EOF？
   —— 这一条决定 §3.3 的条件 ①③ 在真实环境里是否成立。我们只能用 `bash -s` 复现出挂起，**没有抓到工具实际使用的命令行**，所以不把 §3.3 断言为已证实的真实根因。
2. **转义处理层**：命令字符串在传给 shell 之前，是否经过模板 / 转义处理（`\n` → 真换行、引号规范化、NUL）？发生在哪一层？有没有 raw 透传模式（例如按字节传命令、或提供"上传脚本文件再执行"的官方通道）？
3. **超时与非交互保证**：命令执行是否有默认超时、以及 stdin 为 `/dev/null` 或立即 EOF 的保证？我们能否依赖，还是必须在每条可能出问题的命令外自己套 `timeout`？
4. **反馈渠道**：若确认属于 IDE 执行层而非 MoonBit 工具链，请帮忙指到正确的反馈对象；若属于 MoonBit 侧，我们可补一份带 `moonc` 日志的最小仓库。

---

## 6. 附：另一个独立的偶发挂起（供参考，尚未定位）

这一条**与 heredoc 无关**，但可能是真正值得 MoonBit 侧看的现象，单独记录：

- 2026-11-04 15:21，执行 `moon test --target wasm`（全量 1385 个测试），第一次运行**卡在编译阶段**：
  - 命令行从进程表读到：`moonc.exe build-package ... libavcodec/opus_hybrid_pcm_vectors/pcm_vectors.mbt -o ... opus_hybrid_pcm_vectors.core -target wasm -g -O0`。
  - `moon`(PID 51700) 与 `moonc`(PID 84868) 两个进程约 20 分钟 **CPU 时间均为 0**，`moonc` 常驻内存约 15 MB，目标 `.core` 没有更新，也没有任何测试输出。
  - 该包源码 115 KB，产物目录里只有 15:21:41–43 生成的 `internal_test.core` / `.wasm`，此后无任何新文件。
- 终止后：单独跑 `moon test --target wasm libavcodec/opus_hybrid_pcm_vectors` **13 秒通过**（1/1）；重跑全量 **2m47s 完成 1385/1385**。
- 只出现过 **1 次**，未抓到堆栈或 `moonc` 日志，**不作为 bug 报告**，仅作为观察记录。若后续复现，我们会补进程栈、`moon` 的 verbose 日志与该包的构建产物快照。

想请教：`moonc build-package` 在这种大向量包（单个 115 KB 的 `pcm_vectors.mbt`，含大数组字面量）上有没有已知的偶发等待（例如文件锁、并行构建的任务队列、缓存索引）？是否有推荐的诊断开关？

---

## 7. 我们目前的规避约定

1. 生成 / 修改任何脚本或源码，**一律用编辑工具（Write / Edit）写完整文件**，不经过 shell 拼接。
2. 必须在 shell 里内联 Python 时，只允许**无反斜杠转义的单行 `python -c`**（实测基线：`python -c 'print(repr("printf(\"\\n\")"))'` 输出 `'printf("\\n")'`，正常）。
3. 确实要用 heredoc 时：结束符**顶格**、用 `<<'EOF'` 防止变量展开、脚本末尾显式 `exit`、外层套 `timeout N`；避免让 stdin 成为脚本来源。
4. 全量测试输出**重定向到日志文件**再查看，不用 `... | tail -N`：管道缓冲会让人完全看不到进度，无法区分「慢」和「挂住」。
5. `moon fmt` 在本项目禁止全包运行（会格式化整个包），只对改动过的单文件格式化。

---

## 8. 环境信息

| 项 | 值 |
|---|---|
| OS | Microsoft Windows 10 Pro，26H2，build 26300（NT 10.0.26300.0） |
| Shell | GNU bash 5.3.15(1)-release (`x86_64-pc-cygwin`)，MINGW64_NT-10.0-26300 / MSYS 3.6.9 |
| Git | 2.55.0.windows.3 |
| MoonBit CLI | `moon 0.1.20261016 (1af328f 2026-10-16)`，feature flags: `rr_moon_mod, rr_moon_pkg` |
| 可执行文件 | `/c/Users/milkb/.moon/bin/moon`、`moonc`、`moonrun` |
| 构建目标 | `wasm`（项目 wasm-first 约定） |
| 命令发起方式 | IDE 内 Agent 的 Bash 工具，非交互、无 TTY（**具体是 `bash -c` 还是 `bash -s` 未确认**，见 §5.1） |
| 项目规模 | MoonBit 源文件约 10 万行；全量 `moon test --target wasm` = 1385 项 |

---

## 9. 可整段运行的复核脚本

把下面内容保存为 `.sh` 后用 `bash probe.sh` 运行（**本身不要用 heredoc 创建这个文件**）。
G/H/I/J 四行只需要 bash + coreutils；**K 行需要安装 `moon` CLI**，未安装时 K 非 0 属正常，不影响前四项结论。整套脚本在本环境实跑输出为 `G 0 / H 124 / I 0 / J 0 / K 0`。

```bash
#!/usr/bin/env bash
set -u
run() {
  local label="$1" script="$2"
  { printf '%b' "$script"; sleep 6; } | timeout 3 bash -s >/dev/null 2>&1
  printf '%-4s exit=%s\n' "$label" "$?"
}
echo "结束符是否正确 | stdin 保持打开 | 预期"
run G 'cat <<"EOF"\nhello\nEOF\nexit\n'          # 0   正常
run H 'cat <<"EOF"\nhello\n  EOF\nexit\n'        # 124 挂死
run I 'cat <<"EOF"\nhello\nEOF\r\nexit\n'        # 0   CR 被吞
echo "--- bash -c 对照 ---"
timeout 3 bash -c 'cat <<"EOF"
hello
  EOF
' < <(sleep 6) >/dev/null 2>&1
printf '%-4s exit=%s  (仅 warning，不挂)\n' J "$?"
echo "--- moon CLI 对照 ---"
timeout 3 moon version < <(sleep 6) >/dev/null 2>&1
printf '%-4s exit=%s  (不等 stdin)\n' K "$?"
```

预期输出：`G 0 / H 124 / I 0 / J 0 / K 0`。若 H 不是 124，说明该环境的 stdin 会 EOF 或执行方式不是 `bash -s`，§3.3 的条件不成立——这本身就是我们想确认的信息。

---

## 10. 项目内参考文档

| 文件 | 相关段落 |
|---|---|
| `agent.md` | §6「绝对不能用 heredoc」；wasm `__moonbit__init` 局部变量上限 |
| `AGENT_HANDOFF_2026-10-27_AAC_PS.md` | 「已解决的关键坑」1（三次写坏文件） |
| `AGENT_HANDOFF_2026-11-04_OPUS_ENC.md` | §5（`printf("\n")` 被改成真换行）、§9（工具坑累计） |
| `AGENT_HANDOFF_2026-10-26_INTER.md` | §7（heredoc 写含 `\n` 的 C/Python 字符串会断行） |
| `AV1_AGENT_HANDOFF.md` | §8（heredoc 不稳，复杂补丁写 `.py` 再执行） |
| `AGENT_HANDOFF_2026-11-04_AAC_PSY.md` | §4（本轮已把含糊的「会挂死」改写为精确条件） |

> 说明：上表路径均为本项目仓库内文件，供内部追溯；§3 的最小复现与 §9 的脚本不依赖本仓库即可运行（§9 的 K 行另需 `moon` CLI）。
