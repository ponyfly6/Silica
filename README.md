# Silica Workbench

This development fork of [dqhieu/Silica](https://github.com/dqhieu/Silica) is building
a native agent workbench. It uses a separate app identity and does not check the
upstream Sparkle feed. Codex connects through the pinned ACP adapter.

## Codex tasks and turn review

Install Node.js and sign in with `codex login`, then install the pinned adapter:

```sh
bash scripts/install-codex-acp.sh
```

Open a project in the development app and press **⇧⌘A**. Send a question or task;
the panel connects automatically using your existing Codex login. Model, reasoning
effort and workspace/read-only mode come from the backend. Commands show their
output and exit status; permission requests require an explicit choice. **Stop**
cancels the task; **End Connection** becomes available if cancellation stalls.

Each task captures project files before and after execution. Click a file under
**Observed this turn** to open its frozen native diff. **Open File** opens today's
version so you can edit, save and continue in the same chat. Previous turn diffs
stay unchanged. Existing disk edits are part of the baseline, not attributed to
the next task. Unsaved project buffers must be saved before execution, and editing
is protected across overlapping project windows while the task runs.

This preview retains chat and review history in the window only (20 turns / 100 MiB
of retained review contents). Closing the window or starting a new chat clears it.
Disconnect/reconnect within the window uses ACP `session/load`. There are no
automatic retries, full-access mode, or whole-turn revert actions.

Capture covers tracked and non-ignored untracked files, with a non-Git fallback.
External symlink contents and ignored files are excluded; text retention is limited
to 1 MiB per file and 50 MiB per snapshot. Binary/oversized files show limitations.
Concurrent external edits can appear in the observed changes. Discovery is bounded
to 20,000 files and fails explicitly when a reliable baseline cannot be captured.
The app does not retain credentials; the adapter manages its own login and sandbox.

## Native file review

Open a text file, edit it, then press **⇧⌘D** or click the comparison button in the
tab bar. File Review shows a read-only, selectable AppKit diff with old/new line
numbers, additions/deletions, and three lines of context. **Open File** returns to
the editor; **Refresh** compares the latest editor contents, including unsaved edits.

The baseline is captured when a file is opened. Saving or external disk refreshes
do not replace it. **Reset Baseline** (also Editor › Set File Review Baseline) uses
the current editor version instead. Baselines live for the open tab only; these
are separate from the frozen project snapshots attached to Codex turns.

Comparison uses an installed Git executable with `diff --no-index`, even outside a
Git repository. Each text version is limited to 1 MiB, the displayed patch to
20,000 rows / 8 MiB, and computation to five seconds. Oversized or failed comparisons
show an error rather than a partial diff. No files are reverted or staged.

Build with the existing Silica scheme. Core diff checks run with:

```sh
bash scripts/test-review.sh
bash scripts/test-agent.sh
# Optional: uses your Codex account on disposable synthetic projects.
RUN_LIVE_CODEX_TESTS=1 bash scripts/test-agent-live.sh
```

The adapter is pinned to `@agentclientprotocol/codex-acp@2.6.0` in
`Tools/CodexACP/package-lock.json`; development validation used Codex 0.166.0.
Protocol decisions and the Zed references are recorded in
[the integration notes](docs/design/codex-acp-integration.md).

Design and implementation milestones are in [docs/design](docs/design/agent-workbench-v1.md).
The description below documents the upstream editor foundation. Upstream downloads
and releases do not include this fork's workbench features.

---

## Upstream Silica

A lightweight code editor for macOS, made of glass. Open a folder, find files fast,
and edit with syntax highlighting, a minimap and a Markdown preview, all in a native
SwiftUI and AppKit app.

![Silica editing a Swift project, with the file tree on the left and the editor on a glass card](.github/assets/screenshot.jpg)

## Download

Get the latest DMG from [Releases](https://github.com/dqhieu/Silica/releases/latest),
open it and drag Silica to Applications. Silica checks for updates once a day and
installs them for you; you can turn that off in Settings › General.

Silica needs macOS 26 or later.

## Features

- **Projects.** Open a folder to get a window with a file tree. Files and folders
  your `.gitignore` excludes are dimmed, and the tree updates as files change on disk.
  Create, rename and move files to the Trash right in the tree, and filter it as you type.
- **Quick Open and project search.** Jump to any file with fuzzy matching, or search
  the text of every file in the project.
- **Syntax highlighting** for 25 languages, including Swift, JavaScript, TypeScript,
  Python, Go, Rust, C, C++, Java, Kotlin, HTML, CSS, JSON, YAML and Markdown.
- **Nine color themes**, each with a light and a dark palette: Atom One, GitHub,
  Xcode, Solarized, Catppuccin, Gruvbox, Tokyo Night, Rosé Pine and Dracula.
- **Markdown preview**, with highlighted code blocks.
- **Editing tools.** Tabs, line numbers, indent guides, a minimap, word wrap, go to
  line, toggle comment, and moving or duplicating lines.
- **Picks up where you left off.** Projects reopen their tabs, and recent projects
  are on the welcome window.
- **Works with Finder.** Use Open With, drop files on the Dock icon, or run
  `open -a Silica <path>`.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘P | Quick Open |
| ⇧⌘F | Find in Project |
| ⌥⌘J | Filter files in the tree |
| ⌘L | Go to Line |
| ⇧⌘V | Toggle Markdown preview |
| ⌃⌘S | Show or hide the sidebar |
| ⌘/ | Toggle comment |
| ⌥↑ / ⌥↓ | Move lines up or down |
| ⇧⌥↑ / ⇧⌥↓ | Duplicate lines up or down |
| ⌥Z | Word wrap |
| ⌘+ / ⌘− / ⌘0 | Increase, decrease or reset the font size |

## Building from source

You need Xcode 27 or later.

1. Clone the repository and open `Silica.xcodeproj`.
2. In the Silica target's Signing & Capabilities, choose your own team (or "Sign to
   Run Locally"). Please don't commit that change.
3. Press ⌘R. Xcode fetches the Swift packages on the first build.

## Contributing

Bug reports, ideas and pull requests are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) before you start on a change.

## License

Silica is released under the [MIT License](LICENSE). It includes
[swift-markdown](https://github.com/swiftlang/swift-markdown),
[swift-cmark](https://github.com/swiftlang/swift-cmark) and
[Sparkle](https://sparkle-project.org), whose licenses are in
`Silica/Resources/Licenses` and in Settings › About.
