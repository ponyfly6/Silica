# Agent Workbench v1 implementation plan

设计依据：[agent-workbench-v1.md](agent-workbench-v1.md)。本轮只完成 fork、分支和设计，以下全部是待实施任务。

## M0：先证明运行链路

- [ ] 隔离 fork 的 bundle ID、显示名、数据目录和 Sparkle 启动／菜单入口；保留版权和 license。
- [ ] 将本地 `.derivedData/` 加入适当 ignore，避免提交构建产物。
- [ ] 编译现有应用，记录 Xcode、macOS、scheme 与构建命令；不为了 ACP 提前改造编辑器。
- [ ] 显式安装候选 `codex-acp@2.6.0` 到开发工具目录，记录完整 lockfile、适配器和实际 Codex 版本。保留用户已有 Codex 配置。
- [ ] 建最小 stdio 探针：initialize → session/new → 无写入 prompt → session/update；不在日志中导出认证或用户代码。
- [ ] 在独立 fixture 项目验证：受控文件修改、shell 输出和 exit code、拒绝权限、session/cancel、session/load、断连后的部分事件。
- [ ] 核验 terminal=false 时后端 shell 事件是否足够；不足则补客户端命令桥，不发布无结果可见性的执行功能。
- [ ] 将捕获的数据改成合成 fixture；固定 schema 支持表，明确必需 capability 和降级行为。

完成条件：能够列出实际使用版本和已跑通的协议方法；任何登录／权限／事件缺口有明确结论，才开始写入型 UI。

## M1：把一次写入任务做完整

- [ ] 新建 Agent/Protocol、Agent/Models、Agent/Support、Agent/Views 分组，遵循项目现有组织方式。
- [ ] 完成 ACPTransport 的独立隔离、分帧、request/response、stderr、EOF、超时和有序关闭。
- [ ] 完成 ACPClient 与 capability negotiation；权限请求响应采用原始 optionId。
- [ ] 建 AgentSessionModel：连接状态与 turn 状态独立，按 ID patch 工具记录，保留停止／失败的输出。
- [ ] 接 WorkspaceModel 和 WorkspaceWindow.close 生命周期；同根和嵌套根共享协调，运行时编辑及文件操作统一保护。
- [ ] 实现发送前保存／冲突处理，以及首轮 TurnCheckpoint。不能先上线写盘聊天框再补数据保护。
- [ ] 实现右侧 AgentPanelView，至少具备连接、输入、流式消息、工具、命令结果、权限与停止。
- [ ] 确认失败不会触发自动重发，第二个窗口不会启动重叠写入任务。

完成条件：真实执行一项小改动，成功／拒绝／停止／断连四种路径都有可解释的结束状态。

## M2：审阅、手工修改、继续

- [ ] 实现附件 builder 和 UTF-16 选区转换；显式附件、发送快照、删除附件、大小限制。
- [ ] checkpoint 枚举 tracked / untracked / non-Git 文件，记录覆盖与不稳定读取，任务后捕获新增／删除／修改。
- [ ] 实现统一 diff、文件来源标记、不可捕获文件占位及“原有修改／本轮变化”区分。
- [ ] 增加 WorkspaceModel.refresh / EditorBuffer 的即时冲突可见性；不破坏编码、换行、undo 与 scroll。
- [ ] 打开变更文件，手工修改保存，再在同一 session 发下一轮；上一轮 diff 固定且标记当前文件已变化。
- [ ] 取消或异常退出也计算可取得的部分差异，不标记为成功；不加入危险的整轮撤销捷径。

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
