# 只读代码查看器与 Agent

用户在侧栏向 Agent 描述任务，在主窗口打开文件、查找并复制代码。文件树和已打开的标签页跟随磁盘更新。Markdown 预览、语法高亮、行号、小地图和阅读位置恢复继续服务于阅读。

所有项目修改都由 Agent 执行，因此移除了新建、保存、重命名、删除、输入设置和未保存提示。用户直接阅读当前文件，也就无需维护差异视图、基线和每轮项目快照。窗口之间只保留任务租约，同一项目或上下级目录同时只能运行一个任务。停止任务时先清理子进程，再释放租约。仍有进程存活时由用户决定是否释放。

每轮从 ACP 的 edit、delete、move 工具事件中收集项目内路径，按首次出现顺序列出最多 500 个。点击路径打开当前文件。通过 shell 命令做出的更改不会列入清单，仍会通过磁盘通知刷新。每个窗口的一次对话最多保留 100 轮。

## Agent 选择与权限模式

窗口共用同一套 ACP v1 传输、会话和时间线实现。面板顶部可以选择 Codex 或 Claude Code，连接或执行任务期间锁定选择。空闲时切换会断开连接并清空本窗口的对话。新窗口沿用上次选择，两个适配器各自保存可执行文件路径。

Codex 固定使用 `@agentclientprotocol/codex-acp@2.6.0`。启动时设置 `INITIAL_AGENT_MODE=workspace-write`，允许保留 `workspace-write` 或 `read-only`。如果当前模式不在允许范围内，则请求切换至适配器提供的 `workspace-write`。

### Claude Code

`@agentclientprotocol/claude-agent-acp@0.109.0` 需要 Node.js 22 或更高版本，通过 Claude Agent SDK 0.3.328 使用平台对应的 CLI。适配器复用 Claude Code 登录状态，登录过期时在终端运行 `claude` 并登录，再重新连接。

Claude 保留会话已有的 `auto`、`default`、`acceptEdits`、`plan` 或 `dontAsk` 模式。遇到 `bypassPermissions` 或未知模式时，按 `auto`、`acceptEdits`、`default` 的顺序选择适配器提供的第一项。Claude 必须报告当前模式。Codex 会话未提供模式选项时沿用启动时设置的权限。没有合适的回退选项或模式切换未获确认时，连接失败。面板只显示当前 Agent 允许的模式。

在 Silica 启用终端输出扩展时，Claude 的 Bash 工具通过 `terminal_output_delta` 发送输出，并通过 `terminal_exit` 报告退出状态。仅包含文本的工具无需等待终端退出事件。文件编辑沿用同一套工具位置和 diff 路径提取逻辑。[Claude Code 集成记录](claude-acp-integration.md)

## 面板宽度与模型选择

拖动面板左边缘可以调整宽度（300–820 pt），双击恢复默认的 360 pt。窗口变窄时，面板临时收窄，为编辑器保留至少 420 pt；窗口变宽后恢复保存的宽度。

打开面板、在面板中切换 Agent 或新建对话时自动连接。发送按钮旁的菜单显示适配器提供的模型、推理档位和允许的权限模式。模型和档位经适配器确认后按 Agent 分别保存。新建或加载会话时先协商权限，再恢复模型，并根据更新后的选项恢复档位。已下架的选项会跳过，恢复偏好失败时在面板中提示，仍可继续对话。

## 离线验证

```sh
bash scripts/test-agent.sh
bash scripts/test-agent-workspace.sh
```

第一条验证协议、工具事件和进程清理。第二条构建应用，使用本地适配器验证只读文本、磁盘同步、租约及会话生命周期。
