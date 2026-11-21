# Agent Workbench v1 implementation plan

设计依据：[agent-workbench-v1.md](agent-workbench-v1.md)。

2026-11-16 进度：已完成首条 Codex/ACP 执行链路：固定适配器 2.6.0（Codex 0.166.0）、原生面板、权限响应、命令输出／退出码、停止／断连、重连续接、跨重叠窗口的任务租约、发送前保存和执行期间编辑保护。每轮在任务前后捕获项目快照，变更列表打开冻结的 AppKit diff。此前文件级 ⇧⌘D 比较仍独立保留。

验证包括 25 项 diff 检查、52 项协议／快照／进程检查、47 项真实工作区与会话生命周期检查，以及真实 Codex 集成：连续两轮、手工改动保留、新增／删除／修改、取消后的部分变化、session/load 与拒绝权限。非 Git 快照覆盖 macOS 路径别名；read/search/list 输出不误判为等待终端退出。完整记录见 [接入说明](codex-acp-integration.md)。

当前是可运行预览：面板固定 360pt、窗口内最多 20 轮和 100 MiB 已留存差异；未实现附件、持久历史与跨重启恢复。开发版从独立 `build/Silica Workbench.app` 启动。

## M0：先证明运行链路

- [x] 隔离 fork 的 bundle ID、显示名、偏好命名空间和 Sparkle 启动／菜单入口；保留版权和 license。
- [x] 将本地 `.derivedData/` 加入适当 ignore，避免提交构建产物。
- [x] 编译应用：Xcode 27.2、macOS 27.2.1、Silica scheme，Debug + 本地 ad hoc 签名；执行 `xcodebuild -scheme Silica -project Silica.xcodeproj -configuration Debug -derivedDataPath .derivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build`。
- [x] 显式安装候选 `codex-acp@2.6.0` 到开发工具目录，记录完整 lockfile、适配器和实际 Codex 版本。保留用户已有 Codex 配置。
- [x] 建最小 stdio 探针：initialize → session/new → 无写入 prompt → session/update；不在日志中导出认证或用户代码。
- [x] 在独立 fixture 项目验证：受控文件修改、shell 输出和 exit code、拒绝权限、session/cancel、session/load、断连后的部分事件。
- [x] 核验 terminal=false 时后端 shell 事件是否足够；不足则补客户端命令桥，不发布无结果可见性的执行功能。
- [x] 将捕获的数据改成合成 fixture；固定 schema 支持表，明确必需 capability 和降级行为。

完成条件：能够列出实际使用版本和已跑通的协议方法；任何登录／权限／事件缺口有明确结论，才开始写入型 UI。

## M1：把一次写入任务做完整

- [x] 新建 Agent/Protocol、Agent/Models、Agent/Support、Agent/Views 分组，遵循项目现有组织方式。
- [x] 完成 ACPTransport 的独立隔离、分帧、request/response、stderr、EOF、超时和有序关闭。
- [x] 完成协议 client 与 capability negotiation（当前集成在 AgentSessionModel 中）；权限请求响应采用原始 optionId。
- [x] 建 AgentSessionModel：连接状态与 turn 状态独立，按 ID patch 工具记录，保留停止／失败的输出。
- [x] 接 WorkspaceModel 和 WorkspaceWindow.close 生命周期；同根和嵌套根共享协调，运行时编辑及文件操作统一保护。
- [x] 实现发送前保存／冲突处理，以及首轮 TurnCheckpoint。不能先上线写盘聊天框再补数据保护。
- [x] 实现右侧 AgentPanelView，至少具备连接、输入、流式消息、工具、命令结果、权限与停止。
- [x] 确认失败不会触发自动重发，第二个窗口不会启动重叠写入任务。

完成条件：真实执行一项小改动，成功／拒绝／停止／断连四种路径都有可解释的结束状态。

## M2：审阅、手工修改、继续

- [ ] 实现附件 builder 和 UTF-16 选区转换；显式附件、发送快照、删除附件、大小限制。
- [x] checkpoint 枚举 tracked / untracked / non-Git 文件，记录覆盖与不稳定读取，任务后捕获新增／删除／修改。
- [x] 按 [diff 选型](diff-engine-evaluation.md) 用 Git histogram 比较快照，处理 0 / 1 退出码、配置隔离、输出限额、超时和可执行路径诊断。
- [ ] 实现 AppKit 原生统一 diff（可选中文本、前后行号、增删背景、3 行上下文），加文件来源标记、不可捕获文件占位及“原有修改／本轮变化”区分；另测真实布局与滚动。
- [ ] 增加 WorkspaceModel.refresh / EditorBuffer 的即时冲突可见性；不破坏编码、换行、undo 与 scroll。
- [ ] 打开变更文件，手工修改保存，再在同一 session 发下一轮；上一轮 diff 固定且标记当前文件已变化。
- [x] 取消或异常退出也计算可取得的部分差异，不标记为成功；不加入危险的整轮撤销捷径。

完成条件：在已有未提交修改的项目上连续完成两轮；审阅者能准确说出本轮开始前和结束后的区别。

## M3：完成日常使用

- [ ] 持久化 transcript / checkpoint / metadata，与 ProjectSessionStore 和凭据隔离。
- [ ] 按 capability 续接 session，回放去重；能力缺失时提供只读历史和新建入口。
- [ ] 限制内存／磁盘日志，提示截断、捕获缺口与配额耗尽；可删除历史，保护活动与未审阅记录。
- [ ] 连接失败、登录过期、适配器缺失、版本不兼容、文件权限错误均给出可执行下一步。
- [ ] 主线程响应、窗口缩放、深浅主题、键盘操作、VoiceOver、关闭窗口时任务处理。
- [ ] 在一个 Web 项目和一个 Swift／脚本项目中实用，记录首轮耗时、输出延迟、checkpoint 耗时和内存峰值。

## 必要验证矩阵

| 范围 | 需要覆盖的故障 / 边界 |
| --- | --- |
| Transport | UTF-8 跨包、半行、多行合包、CRLF、坏 JSON、超大帧、错序 response、EOF |
| Tool reducer | 增量 patch、省略和 null、未知字段、重复 ID、取消后的尾部事件 |
| Permission | allow / reject / cancel、并发请求、只响应一次、窗口关闭、无自动扩大权限 |
| Files | 脏 buffer、外部修改、emoji 选区、CRLF、非 UTF-8、symlink 外跳、删除、新增、非 Git |
| Checkpoint | 已有未提交内容、tracked 但 ignored、体积上限、捕获中变化、历史 diff 不随新编辑漂移 |
| Lifecycle | 同根多窗口、父子项目、进程退出、后台子进程、恢复回放、失效 session、配额耗尽 |

协议和文件状态用有意义的自动化 fixture 测试；视觉布局和真实登录／权限另用本机手测。文档与界面草图不作为已完成这些验证的证据。
