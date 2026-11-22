# Silica Workbench

Silica is a native, read-only code viewer for macOS with one agent panel for Codex or Claude Code.
Open a project, ask the agent to make a change, and read the result in the same
window. The file tree and open tabs follow changes on disk.

![Swift source shown beside the Silica file tree](.github/assets/screenshot.jpg)

## Reading a project

- Browse and filter the file tree, pin parent folders while scrolling, or jump to
  a file with Quick Open. Find text in a file or across the project.
- Select and copy source text with syntax highlighting, line numbers, indent
  guides, a minimap and word wrap. Highlighting covers 25 languages. Adjust the
  font and tab width, or choose from nine light and dark color themes.
- Preview Markdown with highlighted code blocks. Double-click a block to see its source.
- Open files and folders from Finder. The welcome window lists recent projects,
  and reopening a project can restore its tabs and reading positions.

## Working with an agent

Install the adapter for each agent you want to use. The scripts install pinned
npm runtimes under `~/Library/Application Support/Silica Workbench/`.

| Agent | Install from the checkout | Sign in from Terminal |
|---|---|---|
| Codex | `bash scripts/install-codex-acp.sh` (adapter 2.6.0, requires Node.js) | Run `codex login`. |
| Claude Code | `bash scripts/install-claude-acp.sh` (adapter 0.109.0, requires Node.js 22+) | Run `claude` and log in. |

Press **⌘R** in a project and choose **Codex** or **Claude Code** at the top of
the panel. Sending a message connects with that agent’s existing login. Switch
agents while idle to start a fresh chat in this window. New windows remember the
last selection. Connection settings show the adapter version, login instructions
and a separate executable override for each agent. If your login expires, sign
in again in Terminal and reconnect.

The panel shows the backend's model,
reasoning and workspace permission choices, streams command output, and asks
for tool permissions. **Stop** cancels a task. **End Connection** becomes
available if cancellation stalls. A running task holds a lease across windows
that open the same project or a parent or child folder.

Under each turn, **Edited by agent** links to the current files reported by ACP
edit, delete and move tools. Changes made through shell commands are not listed.
Each turn lists up to 500 distinct project paths. A chat holds up to 100 turns
in its window. Start a new chat or close the window to clear that history.
Reconnecting within the window uses ACP session loading.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘P | Quick Open |
| ⇧⌘F | Find in Project |
| ⌥⌘J | Filter files in the tree |
| ⌘L | Go to Line |
| ⇧⌘V | Toggle Markdown preview |
| ⌘B or ⌃⌘S | Show or hide the sidebar |
| ⌘R or ⇧⌘A | Show or hide the selected agent’s chat (opening focuses the message input) |
| ⌘F | Find in file |
| ⇧⌘R | Refresh the file tree and open files |
| ⌃Tab / ⌃⇧Tab | Next / previous tab |
| ⇧⌘] / ⇧⌘[ | Next / previous tab |
| ⌘W / ⇧⌘W | Close tab / close window |
| ⌥Z | Word wrap |
| ⌘+ / ⌘− / ⌘0 | Increase, decrease or reset the font size |

## Building from source

This development fork of upstream Silica requires Xcode 27 or later and runs on macOS 26 or later. [Upstream project](https://github.com/dqhieu/Silica)

1. Clone the repository and open `Silica.xcodeproj`.
2. In the Silica target's Signing & Capabilities, choose your own team (or "Sign to
   Run Locally"). Please don't commit that change.
3. Press ⌘R. Xcode fetches the Swift packages on the first build.

After the first build, run both offline suites. The workspace suite builds the app
in `.derivedData` and exercises its viewer and agent session with a local fixture.

```sh
bash scripts/test-agent.sh
bash scripts/test-agent-workspace.sh
```

The optional live smoke test uses the selected agent’s account and a disposable
project. Set `RUN_LIVE_AGENT_TESTS=1` and `AGENT=codex` (default) or
`AGENT=claude` when running `bash scripts/test-agent-live.sh`.

[Viewer design](docs/design/agent-viewer.md) · [Codex integration](docs/design/codex-acp-integration.md) · [Claude Code integration](docs/design/claude-acp-integration.md)

## Contributing

Bug reports, ideas and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before you start on a change.

## License

Silica is released under the [MIT License](LICENSE). It includes
[swift-markdown](https://github.com/swiftlang/swift-markdown),
[swift-cmark](https://github.com/swiftlang/swift-cmark) and
[Sparkle](https://sparkle-project.org), whose licenses are in
`Silica/Resources/Licenses` and in Settings › About.
