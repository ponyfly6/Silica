# Silica Agent Workbench v1

> 已被 [agent-viewer.md](agent-viewer.md) 取代。

日期：2026-11-13。状态：首版设计；已用固定适配器 2.6.0 验证核心链路，实际预览范围见 [接入说明](codex-acp-integration.md)，其余交互仍为目标设计。

## 产品决定

Silica 是以 AI 写代码为主要工作方式的原生轻量 macOS IDE。用户在项目里交代任务、看 AI 正在做什么、审阅结果，必要时直接改几行，再继续对话。新功能优先解决这段流程里的具体麻烦。Codex 优先，通过 ACP 接入。

用户成功场景：打开真实项目，选中一段代码，要求 Codex 修改功能并运行测试；能看见命令、输出和文件变化；任务结束后自己补两行，再在同一会话继续。全程不必为了理解执行结果而切换应用。

“轻量”意味着默认界面简单、依赖少、后台按需启动；不代表为实现 Agent 交互而牺牲文件正确性。第一版保留 Silica 的 SwiftUI / AppKit、文件树、Quick Open、搜索、高亮、Markdown 预览和编辑快捷键。

## 第一版范围

| 必须交付 | 具体行为 |
| --- | --- |
| Codex 连接 | 检测适配器、展示版本、连接错误和登录状态，按需启动本地子进程 |
| 项目会话 | 新建、连续多轮、本地历史、能力允许时恢复；同一项目一次执行一轮 |
| 显式上下文 | 添加当前文件、选区和文件树中的文件，发送前可移除；文本快照固定在发送时 |
| 执行时间线 | 流式文本、工具状态、命令与输出、权限请求、完成／失败／取消 |
| 本轮变更 | 文件列表、统一格式 diff、打开文件，区分已有修改与本轮观察到的变化 |
| 文件一致性 | 发任务前处理未保存内容；运行时保护本应用内的编辑；外部变化不静默覆盖 |
| 中断与恢复 | 停止、失联提示、重连、保留已产生的改动与历史，不自动重发任务 |

Claude、完整交互式终端、LSP、调试器、Git 提交与分支界面、多 Agent 并发、worktree 调度、图片附件和自动撤销，按真实 AI 开发任务遇到的具体需要评估。插件市场、模型 API 配置和 MCP 管理界面在首版范围之外。

## 窗口与使用流程

```text
┌ 项目名             文件标签                      Codex 开关 ┐
│ 文件树      │ 编辑器 / 当前文件的本轮 diff │ Codex            │
│             │                            │ 会话标题 / 历史   │
│             │                            │ 执行时间线        │
│             │                            │ 权限请求（出现时）│
│             │                            │ 本轮变更文件      │
│             │                            │ 附件 + 输入框     │
└─────────────┴────────────────────────────┴───────────────────┘
```

- 右侧一个可收起、可调宽的 Codex 面板，默认宽 380pt，范围 320–520pt；不放单选项的后端选择器。
- 中央复用编辑区；点变更文件进入只读统一 diff，明确标注“本轮开始 → 本轮结束”。“打开文件”回到可编辑文件。
- 宽度不足以容纳文件树、420pt 编辑区和 Codex 面板时，打开 Codex 临时收起文件树；更窄时 Codex 使用覆盖面板。收起后恢复原文件树偏好。
- 权限请求嵌入执行时间线，不用阻塞整个应用的模态弹窗；命令卡片可展开完整输出。
- 命令运行状态与任务状态分开：任务结束不等于后台命令退出，测试通过必须有真实执行证据。
- 运行期间输入框保留可编辑草稿，发送按钮禁用并显示停止操作；第一版不实现队列或中途 steering。
- ⌘B 收起或展开文件栏。⌘R 或 ⇧⌘A 收起或展开 Codex 面板，展开时聚焦输入框。选区引用与发送快捷键留到对应功能实现时验证。

首次连接：打开 Codex 面板 → 检测运行环境 → 若缺适配器，显示固定版本安装说明与“选择可执行文件” → 连接并完成后端要求的登录 → 创建项目会话。优先复用用户已有 Codex 登录，不读取或复制凭据到 Silica 存储。

每轮任务：处理未保存文件 → 获取项目执行租约 → 捕获本轮基线和附件 → 发送 → 观察／授权／停止 → 收束输出并计算本轮 diff → 释放编辑保护 → 用户查看、修改并继续下一轮。

审阅采用 **写入后审阅**。界面显示“已修改”，不提供容易误解为尚未落盘的“接受全部”按钮。“已查看”只记录审阅状态，不修改文件。

基础 diff 采用 **Git histogram 计算 + AppKit 原生只读显示**。先做统一格式、前后行号、增删背景色与 3 行上下文；保留选择和复制，不加入三方合并或逐块接受。`git diff --no-index` 比较任务前后快照，不要求项目本身受 Git 管理；诊断必须检查 Git 可执行文件。计算、解析与渲染分离，后续确有需要再评估内置 libgit2。候选审查、本机计时和适配边界见 [diff-engine-evaluation.md](diff-engine-evaluation.md)。

## Codex 接入决定

链路：`SwiftUI → AgentSessionModel → ACPClient → stdio codex-acp → Codex App Server`。

保留 ACP 的原因是后续接 Claude 时复用协议、时间线与文件桥接；v1 只实现 Codex 验证过的路径，不提前做通用插件平台。直接接 Codex App Server 是备选：只有固定版 ACP 确实缺失关键能力时才重新作决定，避免第一版维护两个后端。

- 候选固定版本：`@agentclientprotocol/codex-acp@2.6.0`，2026-11-13 从 npm 核验。npm 元数据声明 `@openai/codex: ^0.166.0`，因此只固定顶层版本仍不足以复现整个依赖树。开发环境先使用用户显式安装的适配器；准备分发时必须固定完整依赖锁和可执行文件校验信息。
- 本机已有 `/opt/homebrew/bin/codex`；检查时未发现 `codex-acp`。目前尚未安装适配器、验证登录或执行真实 Agent 任务。
- 先协商 ACP v1，按固定适配器实际返回的能力工作；不依赖 v2 draft 或 AIR 私有扩展。不硬编码模型名、mode ID 或权限 profile ID。
- 使用 Foundation `Process` 和独立 stdout / stderr 管道。设置 canonical 项目根为 cwd；可执行路径与参数数组分开，不经 shell 拼接。
- GUI 启动环境不能假定继承交互式 shell 的 PATH。设置中提供绝对路径；检测覆盖 Apple Silicon / Intel Homebrew 和用户配置路径；默认不执行用户 shell 初始化脚本。
- 日常连接不自动执行 `npx -y`、安装或升级软件。环境诊断只展示版本与错误，不打印完整环境或认证文件。
- 握手依次 initialize、必要的 authenticate、session/new 或受支持的 session/load；处理 auth_required。若登录需浏览器，明确展示目标地址并由用户触发。
- 模型及推理配置只展示后端宣告的选项，优先 session config options，按需兼容旧 modes。工作区写入模式必须与后端返回的权限／沙箱设置一致；不静默切到 unrestricted 模式。

### 协议最低实现与降级

| 接口 / 事件 | v1 决定 |
| --- | --- |
| initialize / authenticate | 协商能力并处理可操作错误；超时可重试连接 |
| session/new、session/load | new 必须；load 仅能力支持时使用，失败后历史仍可读 |
| session/prompt、session/update | 文本流、工具创建／patch、locations、diff、可见计划、可选 usage |
| session/cancel | 按固定版本 schema 取消 prompt，等待真实结束；通用请求取消另行处理 |
| session/request_permission | 使用请求中的 optionId 返回选择；不伪造“永久允许”选项 |
| fs/read_text_file | 根内文本文件，遵守范围参数；返回经一致性检查的磁盘版本 |
| fs/write_text_file | 原子写入、刷新文件树及 buffer；写前检查新出现的 dirty／外部冲突 |
| terminal capability | 初始为 false；通过兼容性验证后才决定是否需要客户端命令执行桥 |
| 未知事件 / 请求 | 通知保留兼容信息；未知请求返回标准 method-not-found，不挂起连接 |

Codex 自身运行命令，Silica 消费工具事件中的输出。关闭客户端 terminal capability 不意味着禁止后端 shell 工具。第一项兼容性验证必须确认：命令、输出和退出状态能否在这种配置下完整呈现。如果固定适配器无法提供，M1 必须补齐客户端命令桥后再开放命令任务；不以“执行中”占位冒充完成。完整 PTY 界面仍不在范围内。

权限卡片显示真实操作类型、完整路径或命令、cwd 及后端提供的选择。多个请求按 ID 排队且每个只响应一次；停止、断连、关闭窗口会取消未决请求。Silica 不自行记忆后端没有明确作用域的授权。ACP 文件方法的路径校验只约束这些方法，不能替代后端进程的实际沙箱。

## 文件正确性与变更归属

### 一个项目一个执行者

用解析符号链接后的项目根识别 workspace，进程内 `AgentWorkspaceCoordinator` 发放执行租约。同一路径的多个窗口共享租约；首次打开第二个窗口不能启动第二份写入任务。嵌套根也要做祖先／子路径冲突判断，避免父项目和子项目同时写同一文件。

第一版运行时本项目文件保持可浏览，Silica 内的文本编辑、新建、重命名、删除和保存入口受统一协调器保护；不能只把 NSTextView 改为只读而遗漏菜单、文件树或第二个窗口。任务结束或确认中断后再手工修改。外部工具仍可能修改文件，这个保护不是文件系统锁。

发送前，若本项目任意窗口存在未保存的有路径文件，展示“保存并继续 / 取消”；保存失败或外部冲突未解决时不发送。未命名文稿不自动保存；只有显式附加的选区／文本才作为快照发送。首次版本以磁盘为共同事实，暂不让 Agent 在多个未保存版本之间做选择。

执行期间收到外部更新：未修改的 buffer 沿用现有 `syncWithDisk()`，dirty buffer 保留用户版本并即时显示冲突；不等到下一次保存才让用户发现。没有证据时，不把外部更新归因给 Codex。

### 每轮比较基线

Git 工作区 diff 回答“相对 Git 基线变了什么”；本轮 diff 回答“相对本轮发出前变了什么”。二者是不同数据。

1. 发出 prompt 前创建不可变的 `TurnCheckpoint`，记录已存在的修改、文件清单、存在性、内容 hash 与可保存的原始字节。用户发任务即是主动选择将项目纳入本地比较；不自动向模型发送整个 checkpoint。
2. Git 项目以 NUL 分隔的 tracked + untracked/not-ignored 清单枚举；无 Git 项目复用文件遍历及 ignore 规则。`.git` 内容、构建产物、缓存和外链目标排除；tracked 文件不会只因后来匹配 ignore 就被漏掉。
3. 默认单文件文本上限 1 MiB、单轮内容上限 50 MiB。超限、二进制、不可读文件、符号链接只记录可取得的元数据并明确标记“未完整捕获”；总量上限先按稳定路径排序截取并展示覆盖报告。项目可以执行任务，但审阅页不能宣称完整覆盖或支持恢复。
4. 捕获时检查读取前后的文件属性，变化则重试一次；仍变化标记不稳定。它不是原子目录快照。出现覆盖缺口，在发送前就显示说明，任务后继续保留。
5. 任务结束再次枚举，比对新增、修改、删除；rename 第一版表现为删除 + 新增。diff 使用原始 checkpoint 字节解码，保留编码和换行信息；无法准确解码则只显示状态。
6. 工具事件用于关联“Codex 报告过此文件”，checkpoint 与磁盘事实用于计算实际变化。界面统一称“本轮观察到的变化”；并发外部变化标记归属不确定。
7. 若工具报告的文件未被基线覆盖，保留工具 diff 并标注来源，不能伪装成已独立核验的磁盘差异。ignored／二进制／外部路径的变更必须有清楚的缺口提示。

本轮结束快照固定，之后用户修改文件不会重写历史 diff；提示“文件在本轮后又有修改”，打开文件查看当前版本。历史中的“已查看”只适用于对应 snapshot hash。第一版不提供单文件恢复、整轮回滚或 `git reset/checkout/clean`，这些操作涉及后来修改与新文件，需要单独设计。

### 上下文附件

附件保存项目相对路径、发送时内容、起止行和内容 hash；选区从 NSTextView 的 UTF-16 range 安全转换，覆盖 emoji、CRLF 和空选区。附件总文本上限 128 KiB，超限提示用户缩小选区，不静默截断。使用协商支持的 resource 内容，缺失时降级为带路径／行号的 text block。除非用户添加，不自动附带当前文件、所有标签页或 checkpoint。

Agent 写盘与客户端写文件可能并存；所有可控客户端写入前再次检查路径 canonicalization、项目根、dirty 状态及预期 hash。拒绝 `.git` 元数据写入和指向项目外的 symlink 写入；不跟随软链接递归遍历。后端自行 shell 写盘则通过 watcher 和后端权限管理处理，不能声称客户端可以拦截所有写入。

## 状态、停止与历史

连接状态和每轮状态分开建模。

```text
连接：disconnected → connecting → authenticating? → ready → failed / disconnected
每轮：preparing → running ↔ awaitingPermission → finalizing → completed / failed / cancelled
                           ↓
                        cancelling → finalizing
```

- 初始化超时 15 秒，创建会话超时 30 秒；prompt 不设固定总时限。无输出只提示等待，不能推断失败或自动重试。
- 停止先发 session/cancel；仍接受该轮尾部输出，待 prompt 返回后 finalizing。5 秒未结束显示“终止连接”，由用户触发强制退出，并记录任务状态未知。
- 强制退出尽力结束本应用启动的进程树；退出窗口／应用先处理运行任务，再处理原有未保存文稿。已分离的后台进程不保证随连接结束；有未确认存活任务时明确显示，不假称测试停止或项目已稳定。
- 任务失败、取消或连接丢失都要保留部分输出、权限决定和现有文件变化；checkpoint 仍可审阅，状态不变成 completed。仍有已知写入进程存活时保持项目租约和编辑保护；状态未知时要求用户明确结束连接并确认检查外部进程后才解锁，不能根据短暂无文件事件就判定静止。此时产生的 diff 标记为暂定，后续磁盘变化有提示。
- 恢复先加载本地历史。支持 session/load 时使用后端 ID 续接；回放与本地历史替换／去重，不能重复追加。能力不支持或会话失效时显示“历史可读，新建会话继续”，不自动重放 prompt。
- 第一版不支持后台脱离窗口运行。关闭前可选择继续留在窗口或停止并关闭；不因普通窗口销毁丢失唯一执行进程引用。

存储置于 fork 独立的 `Application Support`，以 canonical root hash / local session UUID / turn UUID 分层。保存 schemaVersion、适配器版本、远端 sessionId、顺序事件、checkpoint 覆盖报告、变更快照；API key、token、完整环境和授权凭据不进入存储。

事件顺序使用本地递增序号。文本 delta 可合并，tool patch 按 ID 更新而非重复插入；省略字段保持原值，null 按 schema 处理。stdout 以字节缓冲按换行解析，覆盖 UTF-8 分包、多消息合包与 CRLF；单帧上限 16 MiB。stderr 单独收集诊断，不能与协议流混合。未知 JSON 字段可忽略，坏帧明确报错并保留已收事件。

日志和快照可能包含用户代码，保持本地；默认保留最近 20 个会话、历史总量 500 MiB、单命令显示日志 1 MiB（截断有标记）。配额不足不能静默清理进行中的会话或未审阅快照：停止捕获并展示覆盖缺口，用户可删除历史或查看只读记录后新建会话。任务进行中不自动做会话淘汰。持久化采用后台串行写入和原子替换，不在主线程写大文件。

## Swift 模块与现有接点

| 拟建类型 | 职责 / 现有接点 |
| --- | --- |
| `AgentSessionModel` | MainActor observable，会话和输入框状态；由 WorkspaceModel 持有 |
| `ACPTransport` | 独立并发隔离的字节读写、进程、request ID、timeout、EOF 与 shutdown |
| `ACPClient` | typed 协议 envelope、能力、session 方法、权限响应、标准错误 |
| `CodexAgentConfiguration` | 可执行路径、参数、实际版本和 capability；保持一个 Codex 实现 |
| `AgentWorkspaceCoordinator` | 进程级项目租约、嵌套根检测、菜单和编辑操作保护 |
| `AgentContextBuilder` | 从 activeBuffer / NSTextView 捕获显式附件 |
| `AgentFileBridge` | 路径、编码、hash 校验与 WorkspaceModel.refresh() / buffer 同步 |
| `TurnChangeStore` | 两次快照、内容 hash、覆盖报告、差异与来源关联；后台 I/O |
| `AgentSessionStore` | 与现有 ProjectSessionStore 分离的版本化历史，避免 UserDefaults 存大内容 |
| `AgentPanelView` | 右侧面板、composer、会话历史、timeline、permission 与 command 卡片 |
| `ChangeReviewView` | 中央只读 diff；workspace.open / reveal 跳回文件 |

项目默认 MainActor 隔离；transport、文件遍历和 diff 必须显式放在 actor／非主线程隔离边界。界面状态批量消费事件，流式刷新最多约每 50ms 一次，不能每 token 重算整个历史。对话与工具内容按不可信文本／Markdown 渲染，不执行原始 HTML、不自动加载远程图片、不执行输出里的链接或命令。

不直接把工具 raw JSON 塞到 WorkspaceModel，不修改现有 buffer 的 undo / encoding 语义，不为未来多后端提前增加复杂继承层。

## Fork 的开发隔离

- GitHub fork：`ponyfly6/Silica`；原仓库保留为 upstream；开发分支 `codex/agent-workbench-v1`。
- 首个可运行构建使用独立 bundle ID，例如 `dev.ponyfly6.SilicaWorkbench`，显示名 `Silica Workbench`。开发用本地签名，不提交个人开发团队凭据；保留原作者署名和许可证。
- 禁止开发版启动上游 Sparkle updater，也禁用手动检查入口；仅关闭自动检查还不足以防止手动安装上游版本。新发布源／签名体系后置，不能复用上游更新签名作为自己的发布能力。
- 不改上游 appcast、release 标签、版本号或发布流水线；本轮仅提交设计。已有 `.derivedData` 不纳入版本控制。

## 实施顺序与验收

详细执行清单见 [agent-workbench-v1-plan.md](agent-workbench-v1-plan.md)。

1. **M0 — 开发隔离与兼容性探针。** fork 身份与 updater 隔离；用固定适配器验证握手、认证、cwd、文本流、权限、命令结果、取消、恢复和文件事件，保存去敏感化 fixtures。若关键事件不足，先确定命令桥／协议调整。
2. **M1 — 一个项目完整执行一轮。** 原生右侧面板、连接状态、流式输出、权限、停止、项目租约与可控生命周期。checkpoint 和编辑保护必须在开放写入任务时一起到位。
3. **M2 — 能审阅并继续。** 文件／选区附件、变更列表、diff、外部修改提示、手工修改后第二轮、失败后的部分变更。
4. **M3 — 日常可用。** 历史与受支持的恢复、配额、窄窗口、键盘操作、故障说明；两个真实项目验证后再引入 Claude。

首版发布门槛：真实项目连续两轮成功；原有未提交修改保留；新增／删除／多文件修改可见；命令退出状态真实；权限拒绝和停止不挂 UI；崩溃后有部分历史；同根与嵌套根多窗口不能并发写入；不完整捕获不会被宣传为完整 diff。性能先实测：约 5,000 个小文本文件的基线捕获给出耗时、占用和 UI 响应记录，超 1 秒显示 preparing 进度，未测前不宣称“瞬开无损”。

## 资料与验证边界

下面是架构依据，不是兼容性测试报告。网页会变化，实际实现以固定版本 schema 和 fixture 为准。

- [ACP v1 initialization](https://agentclientprotocol.com/protocol/v1/initialization)
- [ACP tool calls 与权限](https://agentclientprotocol.com/protocol/v1/tool-calls)
- [ACP prompt turn](https://agentclientprotocol.com/protocol/v1/prompt-turn)
- [ACP filesystem](https://agentclientprotocol.com/protocol/v1/file-system)
- [ACP terminals](https://agentclientprotocol.com/protocol/v1/terminals)
- [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp)
- [OpenAI 官方 Codex App Server 文档](https://learn.chatgpt.com/docs/app-server)
- [固定 npm 版本](https://www.npmjs.com/package/@agentclientprotocol/codex-acp/v/2.6.0)
