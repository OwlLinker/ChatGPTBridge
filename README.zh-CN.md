# ChatGPTBridge 中文说明

**[English](./README.md) · 简体中文**

**项目仓库：** [OwlLinker/ChatGPTBridge](https://github.com/OwlLinker/ChatGPTBridge)

## ChatGPT Web 写代码的痛点

当你使用 Chat 为本地项目编码时，对话和电脑上的项目文件是分开的，因此会遇到这些问题：

- Chat 不知道项目当前的最新状态；
- 需要在 Chat 和本地项目之间反复手工复制内容；
- 使用旧版本源码；
- 漏复制某一行；
- 修改后留下语法错误、不完整代码，或者重复应用同一份修改；
- 想继续使用 Chat 服务，却不想自己开发 API 集成，也不想换成其他编码工具。

## ChatGPTBridge 的作用

> 用最简单的方法使用 Chat 进行编码。

ChatGPTBridge 把 Chat 对话和本地 Git 项目连接起来：你在 Chat 中提出修改要求，把当前项目快照提供给 Chat，再通过本地安全检查，把一份完整回答应用回项目。

Chat 负责提问、讨论设计和生成代码。ChatGPTBridge 只负责连接 Chat 对话和本地项目文件，不需要 API、不需要专门的 Coding Agent，也不需要另一个编码订阅。

Bridge 本身不设置调用次数、Token 或 Patch 限额。因此，你可以在 Chat 账号和套餐允许的范围内持续使用 Chat 编码；Chat 服务本身的限制仍然适用。

ChatGPTBridge 把它变成固定流程：

~~~text
在 Chat 中提出修改要求
        ↓
生成当前项目快照
        ↓
把快照提供给 Chat
        ↓
Chat 返回一个完整 Patch
        ↓
在本地检查并应用 Patch
        ↓
查看、测试，决定是否提交
~~~

## 快速开始

### 新手安装：安装并完成第一次修改

ChatGPTBridge 会把工具安装到一个已经存在的 Git 项目中；它不会替你创建项目，也不会在安装时向 Chat 发送内容。以下步骤都在 Terminal（终端）中操作。请把示例项目路径替换成你 Mac 上的真实路径。

1. **检查电脑和项目。** 需要 macOS、Git，以及一个已经是 Git 仓库的项目。运行：

   ~~~bash
   git --version
   git -C "$HOME/Projects/MyProject" status
   ~~~

   如果第二条命令提示不是 Git 仓库，请停止并确认项目路径；除非你确实要创建新仓库，否则不要运行 `git init`。原生监控和部分 Swift 工具需要 Apple 命令行工具；如果尚未安装，运行 `xcode-select --install` 并按系统提示完成安装。

2. **下载 ChatGPTBridge。** 选择一个保存工具本身的位置。以下示例把它放在用户目录下：

   ~~~bash
   git clone https://github.com/OwlLinker/ChatGPTBridge.git "$HOME/ChatGPTBridge"
   ~~~

3. **安装到你的项目。** 目标项目必须已经存在，并且是 Git 仓库：

   ~~~bash
   "$HOME/ChatGPTBridge/tools/chat-bridge-install.sh" "$HOME/Projects/MyProject"
   cd "$HOME/Projects/MyProject"
   ~~~

   每个项目都要单独安装一次，可以重复使用刚才下载的 ChatGPTBridge。如果安装器提示某个 Bridge 文件已存在，不要直接覆盖；只有确实要更新项目里的 ChatGPTBridge 文件时才使用 `--force`。安装不会自动提交或推送代码。

4. **添加项目专属的排除规则。** 工具会自动排除常见私密文件，但它不是秘密扫描器。生成快照前，请把不应分享的项目文件和目录加入排除列表：

   ~~~bash
   mkdir -p .chatgpt
   touch .chatgpt/ignore
   open -e .chatgpt/ignore
   ~~~

   每行写一个忽略规则，保存后生成并打开快照检查：

   ~~~bash
   ./tools/chat-context.sh full
   open -e .chatgpt/project-context.md
   ~~~

   确认快照只包含你愿意提供给 Chat 的内容。检查无误后复制：

   ~~~bash
   pbcopy < .chatgpt/project-context.md
   ~~~

5. **把快照发给 Chat。** 打开普通 Chat 对话（不是 Work），按 **Command+V** 粘贴并发送快照，然后描述你要修改什么。例如：“请以我提供的项目快照作为当前源码基线，实现以下修改：……请只在一个代码块中返回一份完整 unified Diff，不要省略上下文，也不要只返回部分 Patch。”如果项目快照太大，Chat 可能会要求你提供更小的相关上下文，或使用后面的增量快照方式。

6. **应用 Chat 返回的修改。** 复制 Chat 回复中完整的 Diff 代码块，回到该项目对应的 Terminal 窗口，运行：

   ~~~bash
   ./tools/chat-apply-shell.sh
   ~~~

   工具会从剪贴板读取 Patch，检查它是否匹配当前项目，并且只有通过安全检查后才会应用。若失败，请先查看 `.chatgpt/patch-error.txt`，不要反复应用同一份失败 Patch。成功后检查 `git diff`、运行项目测试，再由你自己决定是否提交。ChatGPTBridge 不会替你提交或推送。

之后开始新一轮工作时，如果要以项目当前状态为准，请重新生成 `full` 快照。`./tools/chat-context.sh diff` 会生成相对于 Git `HEAD` 的变更快照 `.chatgpt/project-diff.md`；分享前要先检查它，并且只有在 Chat 已有对应上下文、该上下文也基于同一个 `HEAD` 时才使用。如果之前的完整快照包含尚未提交的修改，请重新生成完整快照，不要默认增量 Diff 可以安全替代。想自动监控并应用回复，请继续阅读下文“不使用 Hammerspoon，自动监控并应用已完成的 Diff”一节；Hammerspoon 是可选项。

### 不使用 Hammerspoon，自动应用完成的 Diff

这是 ChatGPTBridge 自带的 macOS 功能，不需要安装 Hammerspoon。

1. 在目标项目中安装 ChatGPTBridge。
2. 在终端进入该项目并启动：

   ~~~bash
   cd "/你的项目绝对路径"
   ./tools/chat-monitor.sh start
   ./tools/chat-monitor.sh status
   ~~~

   启动脚本会把监控器编译到 `.chatgpt/chat-monitor`，并设置执行权限（`755`）。首次启动时会请求 `chat-monitor` 自身的辅助功能权限；请在“系统设置 → 隐私与安全性 → 辅助功能”中允许该程序，然后再次运行 `start`。原生监控不需要给 Terminal 或 iTerm 辅助功能权限，这两者的授权也不能代替 `chat-monitor` 的授权。监控器不会在登录时自动启动。
3. 在支持的 Codex macOS 应用或 ChatGPT 浏览器标签页中打开普通 Chat 对话，不能是 Work、Codex 工作区、设置页或空白 New chat。发送一条要求 Chat 输出完整 Diff 的请求，并等回复结束。ChatGPTBridge 会读取最后的 Diff，通过本地检查后应用到该项目。
4. 用完后停止监控：

   ~~~bash
   ./tools/chat-monitor.sh stop
   ~~~

监控器不会发送普通提示词，也不会提交或推送 Git。启动时已经存在的 Diff，以及打开旧会话时的历史 Diff，都不会自动应用；这类 Diff 请手动复制并运行 `./tools/chat-apply-shell.sh`。

### 圆环颜色说明

- **金色、闪动：** 监控已开启，或刚提交了新请求；表示等待回复，不代表 Patch 已成功。
- **绿色、静止：** Patch 已成功应用。Hammerspoon 也会把已应用过的重复 Patch 视为成功。
- **红色、静止：** Patch 应用失败。检查 `.chatgpt/patch-error.txt` 和 `.chatgpt/failed.patch`。

圆环描边位于 Chat 发送按钮外侧。只有被监控的 Chat 窗口在前台时才显示；应用在后台时仍可继续监控。提交新请求后回到金色。当前没有单独的黄色重复状态：原生监控会跳过重复 Patch 并保留当时颜色；Hammerspoon 会将已应用过的重复 Patch 显示为绿色。看不到圆环时，可能是监控未开启，也可能是 Work/新建会话等页面不受支持，或 Chat 窗口不在前台。

## 它能做什么？

- 继续使用 Chat 普通对话界面编码；
- 一次性把当前项目状态提供给 Chat；
- 用内置规则和 .chatgpt/ignore 排除私密或无关文件；
- 用一个命令应用 Chat 生成的完整修改；
- 拒绝基于旧项目版本生成的 Patch；
- 识别重复应用；
- 检查失败时自动回滚；
- 撤销最近一次成功修改；
- 支持 ChatGPT/Codex macOS 应用、Safari、Chrome 和其他 Chromium 浏览器。

## 安全风险与账号安全

### 先说结论

ChatGPTBridge 不能承诺账号绝对不会收到警告、限制或停用。你如何使用 Chat，仍然受当前的 [OpenAI 使用条款](https://openai.com/policies/terms-of-use/) 和[使用政策](https://openai.com/policies/usage-policies/)约束。

ChatGPTBridge 是非官方的第三方本地工具，与 OpenAI 没有隶属或背书关系。

需要区分以下几件事：

- ChatGPTBridge 不使用 API Key、Chat 私有接口、反向代理，也不提供绕过 Chat 限额的方法；
- 手工复制和应用的方式，自动化程度最低，因此规则上的不确定性也最低；
- 从应用或浏览器自动读取 Diff，以及使用 Hammerspoon，都会以程序方式读取界面内容。这些功能只是为了方便，但由于当前 OpenAI 条款涉及自动或程序化提取，因此存在额外的规则不确定性；
- ChatGPTBridge 不提供无限 Chat 配额，也不能保证账号永远不会受到限制。

### 使用 ChatGPTBridge 会不会导致封号？

没有人可以诚实地保证“绝对不会”。ChatGPTBridge 的设计目标是让用户继续操作普通 Chat 界面，并不是绕过限额或隐藏使用行为；但是，自动读取界面仍然属于第三方自动化，OpenAI 会自行判断当前条款和安全措施如何适用。因此，应把自动读取和 Hammerspoon 视为可选的便利功能，而不是 OpenAI 官方批准的集成。

### ChatGPTBridge 会做什么，不会做什么

ChatGPTBridge 在本地运行，连接的是你已经在使用的 Chat 界面。它不会：

- 索取或保存 Chat 密码、登录 Cookie、API Key 或私有 Token；
- 默认不会自己向 Chat 自动发送提示词或请求；只有显式开启失败诊断自动发送后才会发送；
- 切换账号、规避验证码、绕过速率限制或隐藏使用行为；
- 自动提交或推送 Git。

它可以读取你选择提供的项目快照或 Diff；在你开启自动读取时，读取 macOS 辅助功能界面内容；然后把 Patch 应用到本地 Git 项目。你粘贴或发送给 Chat 的内容，仍然适用 Chat 正常的数据处理规则和账号规则。

### 小白更安全的使用方式

1. 只使用自己的账号，并且只把获准提供给 Chat 的项目发送出去。
2. 发送前检查 `.chatgpt/project-context.md`，不要把密码、私钥、Token、环境文件或客户数据放进快照。
3. 先使用手工复制和应用的方式。理解自动化风险后，再启用自动读取或 Hammerspoon。
4. 一次只执行一个请求。不要运行无人值守循环、定时批量任务、多账号并行，或任何为了规避服务限额的操作。
5. 如果 Chat 出现警告、验证码、异常登录验证或账号限制，立即停止自动化，按服务提示处理。不要用另一个账号或另一种自动化方式绕过限制。

如果你最担心账号安全，建议使用手工流程，并亲自检查每份快照和 Patch。这样可以减少本地自动化层，但仍不能代表 OpenAI 已批准或保证任何第三方工具。

## 第 1 步：检查电脑环境

必须有：

- macOS；
- 一个 Git 项目；
- Terminal 或 iTerm；
- Git、zsh、Bash、Python 3。

根据修改的文件，可选安装以下检查依赖：

- 检查 JavaScript 需要 Node.js；
- 检查 HTML 需要 HTML Tidy。

检查：

~~~bash
git --version
zsh --version
python3 --version
~~~

自动读取应用或浏览器还需要 swiftc 和辅助功能权限。如果没有 swiftc：

~~~bash
xcode-select --install
~~~

如果系统没有自动找到 HTML Tidy，可以安装后指定路径：

~~~bash
CHAT_BRIDGE_TIDY_BIN=/path/to/tidy ./tools/chat-apply-shell.sh
~~~

如果需要指定 Node.js，也可以设置 `CHAT_BRIDGE_NODE_BIN`。

## 第 2 步：打开项目

把示例路径替换成要让 ChatGPT 帮忙修改的项目：

~~~bash
cd /path/to/your-project
git status
~~~

如果不是正确的 Git 项目，先进入正确目录。除非你明确想创建新仓库，否则不要执行 git init。

## 第 3 步：安装 ChatGPTBridge

先下载或克隆本项目，再把下面的 `/path/to/ChatGPTBridge` 替换成你保存本项目的实际文件夹。

替换下面两个示例路径。首次安装时不要加 `--force`：

~~~bash
/path/to/ChatGPTBridge/tools/chat-bridge-install.sh \
  /path/to/your-project
~~~

安装器会复制工具并给 Shell 脚本增加可执行权限；写入前会检查目标文件，不会提交或推送代码。更新已经安装的版本时，执行：

~~~bash
/path/to/ChatGPTBridge/tools/chat-bridge-install.sh --force /path/to/your-project
~~~

这会用当前仓库的版本替换项目里已安装的 Bridge 脚本和说明。

### 支持多个项目

每个 Git 项目都要单独安装 ChatGPTBridge，并从该项目运行自己的 `tools/chat-context.sh` 生成快照；这会登记项目根目录，供 Hammerspoon 路由 Patch 使用。Hammerspoon 执行 Patch 文件时，会先检查已登记的项目中哪个能通过该 Patch 的只读校验；如果 Patch 因源码上下文不匹配而无法通过，则按 Patch 文件路径唯一确定所属项目。目标路径缺失、不可读或仍有歧义时会拒绝应用，不会猜测旧的“最近活动项目”。

在 Terminal 手动应用时，进入目标项目目录并运行该项目的 `./tools/chat-apply-shell.sh`。多项目自动路由适用于 Hammerspoon 通过 `--patch-file` 传入 Patch 文件的情况。

## 第 4 步：配置私密文件排除规则

ChatGPTBridge 默认排除常见的 `.env`、私钥、凭据、云端凭据目录、`.git`、依赖目录、构建产物和缓存目录。但这只是按路径排除，不是秘密扫描器；发送前仍必须检查每份快照，并补充项目自己的忽略规则。

为当前项目增加规则：

~~~bash
cd /path/to/your-project
mkdir -p .chatgpt
touch .chatgpt/ignore
open -e .chatgpt/ignore
~~~

每行写一个规则：

~~~gitignore
fixtures/
*.sqlite
local-notes.md
reports/
*.log
~~~

保存并关闭编辑器。它只影响发送给 ChatGPT 的快照，不会阻止 Patch 修改文件。

临时指定其他忽略文件：

~~~bash
CHAT_BRIDGE_IGNORE_FILE=/path/to/project.ignore \
  ./tools/chat-context.sh full
~~~

## 第 5 步：生成并检查项目快照

在项目根目录执行：

~~~bash
./tools/chat-context.sh full
~~~

生成：

~~~text
.chatgpt/project-context.md
~~~

快照会优先完整收录识别到的逻辑实现文件（包括 Objective-C/C/C++ 源文件），再收录说明等辅助材料。默认的单文件 512 KB、总计约 12 MB 限制只作用于辅助材料。内置排除规则、符号链接保护和 `.chatgpt/ignore` 仍然生效。

发送前先检查：

~~~bash
open -e .chatgpt/project-context.md
~~~

确认 ChatGPT 需要的文件都在里面，并且没有密码、私钥、Token 或其他不应外发的信息。

## 第 6 步：把快照提供给 ChatGPT

可以打开文件、全选、复制，再粘贴到 ChatGPT。也可以执行：

~~~bash
pbcopy < .chatgpt/project-context.md
~~~

粘贴后发送：

~~~text
这是当前项目快照，请以它作为当前源码依据。
请完成我的修改要求。
完成后只输出一个完整的 unified diff 代码块。
路径必须使用项目根目录相对路径。
不要使用“...”省略代码，也不要在 diff 中加入解释文字。
~~~

要求 ChatGPT 只输出一个完整 Patch，例如：

~~~diff
diff --git a/path/to/file b/path/to/file
--- a/path/to/file
+++ b/path/to/file
~~~

不要应用不完整的回答，也不要使用旧快照生成的 Patch。

## 第 7 步：应用 Patch

第一次建议复制 ChatGPT 返回的完整 Diff，然后执行：

~~~bash
cd /path/to/your-project
./tools/chat-apply-shell.sh
~~~

也可以把完整 Patch 保存成文件后执行：

~~~bash
./tools/chat-apply-shell.sh --patch-file /path/to/change.patch
~~~

ChatGPTBridge 会检查 Patch、应用修改、检查常见文件、识别重复应用，并在失败时生成诊断。

查看结果：

~~~bash
git diff --check
git status --short
git diff
~~~

然后按照项目说明运行测试或启动命令。Patch 有效不代表功能一定正确。

## 可选：自动读取最后一个 Diff

确保 ChatGPT 对话在原生应用、Safari 或支持的 Chromium 浏览器中打开。首次运行会请求 `chat-read-last-diff` 程序的辅助功能权限；按系统提示允许该程序：

~~~text
系统设置 → 隐私与安全性 → 辅助功能
~~~

执行：

~~~bash
./tools/chat-read-last-diff.sh
~~~

可以指定来源：

~~~bash
CHATGPT_SOURCE=native ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=chrome ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=safari ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=auto ./tools/chat-read-last-diff.sh
~~~

支持 ChatGPT/Codex macOS 应用、Safari、Chrome（含 Beta/Canary/Dev）、Chromium、Edge、Brave、Vivaldi 和 Arc。需要指定应用 Bundle ID 时，可设置 `CHATGPT_BUNDLE_ID`。

自动读取不到 Diff 时，改用复制后应用的方式。

## 可选：不使用 Hammerspoon，自动监控并应用已完成的 Diff

ChatGPTBridge 自带 macOS 原生监控器。它监控 Codex macOS 应用（`com.openai.codex`）、Safari 或支持的 Chromium 浏览器中的普通 Chat；当提交按钮从“生成中”恢复为可提交状态时，调用现有本地 Patch 检查流程。它不会发送普通提示词，也不会提交或推送 Git。

### 首次使用

1. 在你希望接收修改的 Git 项目中安装 ChatGPTBridge。
2. 在终端进入该项目并启动监控：

   ~~~bash
   ./tools/chat-monitor.sh start
   ./tools/chat-monitor.sh status
   ~~~

   启动脚本会把监控器编译到 `.chatgpt/chat-monitor`，并设置执行权限（`755`）。首次启动时会请求 `chat-monitor` 自身的辅助功能权限；请在系统设置中允许该程序，然后再次运行 `start`。原生监控不需要给 Terminal 或 iTerm 辅助功能权限，这两者的授权也不能代替 `chat-monitor` 的授权。它不会在登录时自动启动。
4. 打开普通 Chat 对话（不是 Work、Codex 工作区、设置页或空白 New chat），照常使用 Chat。只有最后一个 Diff 可读、完整、稳定且不超过 8 MiB 时才会尝试应用。超大或不完整内容会被跳过，不会截断后应用。
   启动监控或进入已完成的旧对话，不会自动应用历史 Diff。请发送新请求并等待回复结束；已有 Diff 可使用手动复制和应用命令。
5. 停止监控时运行 `./tools/chat-monitor.sh stop`。需要排查时查看 `.chatgpt/chat-monitor.log`。

支持的应用在后台时监控仍会继续；状态圆环只在被监控的同一 Chat 窗口位于前台时显示。监控每秒检查已缓存的提交/停止按钮状态，并合并辅助功能通知、低频扫描完整界面树。浏览器兜底扫描在生成期间至少间隔 30 秒，空闲时至少间隔 60 秒。这是降低性能开销的保护措施，不代表已测得固定 CPU 上限。若辅助功能无法读取按钮标签，完成检测可能延迟或跳过。

失败诊断自动提交默认关闭。只有在项目本地 `.chatgpt/chat-monitor.json` 显式设置 `{"autoSendFailureReport": true}` 才会启用。即使启用，监控器也不会覆盖已有草稿；无法确认仍是原普通 Chat 且输出已完成时，不会发送。开启后会把本地失败诊断发送到 Chat，请确认接受后再启用。

## 可选：使用 Hammerspoon 自动执行

Hammerspoon 是可选的快捷键自动化工具。配置完成后，你可以用一个快捷键完成本地落地步骤：

1. 从当前 Chat 窗口读取最后一个完整 Diff；
2. 将 Diff 保存为临时 Patch；
3. 调用 `tools/chat-apply-hammerspoon.sh`；
4. 执行同样的校验、应用、语法检查和失败保护；
5. 显示简短的执行结果；
6. 只有确认修改成功后，才执行可选的 Hammerspoon 配置重载。

ChatGPTBridge 核心不包含 Lua 快捷键集成。Lua 部分属于你的 Hammerspoon 配置；这里介绍的是可选的 `OwlLinkerHS.spoon`、`ChatGPTApplyPatch.lua` 和 `Tab+A` 集成。ChatGPTBridge 提供本地执行器和安全检查。

### 小白配置步骤

1. 安装并打开 Hammerspoon。
2. 在 macOS 中，前往 `系统设置 → 隐私与安全性 → 辅助功能`，允许 Hammerspoon 控制电脑。Terminal 或 iTerm 只用于运行命令，本集成不需要给它们辅助功能权限。
3. 添加或启用 Hammerspoon 的 Lua 集成。它需要读取当前 Chat 的 Diff，创建唯一的临时 Patch 文件，并使用项目的绝对路径调用脚本：

   ~~~bash
   /path/to/ChatGPTBridge/tools/chat-apply-hammerspoon.sh --patch-file /tmp/你的临时文件.patch
   ~~~

   把 `/path/to/ChatGPTBridge` 替换成你保存本项目的实际文件夹。

4. 重载 Hammerspoon 配置。
5. 在受支持的 ChatGPT/Codex 应用或浏览器中打开普通 Chat 对话（不能是 Work 或 Codex 工作区），按一次 `Tab+A` 开启持久监控，再发送一条要求输出完整 Diff 的新请求。开启后，可以把应用切到后台。
6. 正常发送请求，等待助手回复完成。
7. 等监控应用完整 Diff 后查看通知。首次开启时，已经完成的历史 Diff 不会应用；`HMReloadConfig` 重载后，没有成功/失败记录的待处理 Diff 可能继续处理。应用成功可能触发 Hammerspoon 重载，但监控会继续保持开启。

如果自动执行失败，不要用同一个 Patch 反复按快捷键。先查看 Hammerspoon 控制台和 `.chatgpt/patch-error.txt`，然后改用复制后应用的方式，或让 Chat 重新生成 Patch。

### 可选：回复完成后自动执行与 Tab+A 相同的动作

当前的 `OwlLinkerHS.spoon` 集成在按 `Tab+A` 开启后，可以监控受支持的 ChatGPT/Codex 应用或浏览器，即使它在后台运行，也会在观察到一次“发送 → 回复完成”后执行本地 Patch 流程。未按快捷键开启时不监控。

1. 先重载 Hammerspoon，确保监控处于关闭状态。
2. 按一次 `Tab+A` 开启持久监控。
3. 正常发送请求，等待 Chat 回复完成。
4. Patch 成功后，`HMReloadConfig` 会重载 Hammerspoon，但监控会自动继续。

启动监控时，当前窗口必须是普通 Chat 而非 Work，并且助手最后一条回复中必须有可识别的 Diff 标识。完整 Patch 可立即处理；Diff 仍在生成或读取时，监控会等待并重试。监控会把发送/生成周期与一次已完成且内容稳定的 Diff 对应起来，避免并行运行多个 Patch，并且同一份 Diff 只处理一次。再次按 `Tab+A` 可关闭监控；它不会发送普通提示词，也不会点击发送按钮；失败报告自动提交由下文的独立设置控制。由于它仍会程序化读取 Chat 界面，如果你最重视账号安全，建议保持关闭。

监控不会绑定到单个对话标题。标题仅在可读取时用于恢复各对话自己的圆环状态；切换普通 Chat 对话不需要关闭再开启监控。Work、Codex 工作区、设置页和其他非 Chat 窗口不会处理 Patch；回到普通 Chat 后监控会继续。监控开关状态会在 `HMReloadConfig` 后保留。

自动应用只支持普通 Chat 对话。Codex 工作区、设置页面和其他非 Chat 窗口会被忽略，不会应用 Patch。

监控开启且 ChatGPT/Codex 在前台时，发送按钮周围会显示金黄色描边作为状态提示。监控在后台仍会继续；切换到其他应用时隐藏标记，回到 ChatGPT/Codex 后会重新显示。

颜色含义：金色表示监控中或新请求提交后；绿色表示 Patch 成功应用；红色表示应用失败。Patch 成功或失败的状态会保持到下一次提交请求，届时恢复金色。当前没有黄色重复状态：Hammerspoon 将已经应用过的 Patch 保持为绿色；原生监控跳过重复 Patch 并保留当时的颜色。圆环是显示在 Chat 提交按钮外侧的描边，不会修改应用按钮本身。

当 Hammerspoon 配置中的 `autoSendFailureReport` 为 `true` 时，应用失败后会读取 `.chatgpt/patch-error.txt` 和 `.chatgpt/failed.patch`，通过粘贴方式填入普通 Chat 输入框并自动提交诊断。此设置属于外部 Hammerspoon 集成，不由 ChatGPTBridge 安装器控制；开启监控前请先检查它的值。成功应用或重复应用不会触发该操作，Work 和其他非 Chat 窗口也不会提交诊断。

只有确认可以把失败 Patch 和本地诊断发送给 Chat 后，才将它设置为 `true`：

~~~json
{ "autoSendFailureReport": true }
~~~

如需关闭此功能，将 Hammerspoon 配置中的 `config/chatGPTPatchMonitor.json` 的 `autoSendFailureReport` 改为 `false`。

## 撤销或恢复

只有应用 Patch 后没有继续修改项目时，才能撤销：

~~~bash
./tools/chat-apply-shell.sh --undo
~~~

如果失败，不要重复应用同一个 Patch。先读取：

~~~text
.chatgpt/failed.patch
.chatgpt/patch-error.txt
~~~

把诊断和失败 Patch 提供给 ChatGPT，要求它基于最后一个成功版本重新生成完整 Patch。

## 检查安装

~~~bash
for f in tools/chat-apply-shell.sh tools/chat-apply-hammerspoon.sh \
  tools/chat-read-last-diff.sh tools/chat-bridge-install.sh; do
  zsh -n "$f" || exit 1
done
bash -n tools/chat-context.sh
swiftc -parse tools/chat-read-last-diff.swift
~~~

ChatGPTBridge 不会自动提交或推送。每次发送前检查快照，提交前查看并测试修改。

## 更多

- [English guide](./README.md)
- [许可证](./LICENSE)
