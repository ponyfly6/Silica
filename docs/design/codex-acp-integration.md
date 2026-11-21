# Codex / ACP integration

Validated on 2026-11-16 with macOS 27.2.1, Xcode 27.2, Swift 6.4.2,
`@agentclientprotocol/codex-acp@2.6.0`, and its locked Codex 0.166.0 runtime.
The npm lockfile is committed; the runtime itself stays outside the application
sources. The managed installation lives under the user's Application Support.

## Implemented contract

| Area | Contract |
| --- | --- |
| Transport | JSON-RPC over UTF-8 NDJSON stdio; one ordered ingress stream, ID-matched responses, bidirectional requests, timeouts, cancellation and EOF handling |
| Session | ACP v1 `initialize`, `session/new`, `session/prompt`, `session/load`, `session/set_config_option`, `session/cancel` |
| Configuration | Backend-provided model and reasoning choices; read-only or workspace-write mode; existing Codex login, no credential copies |
| Tools | ID-based partial updates; omitted fields retain their prior values; optional raw command and cwd |
| Output | Advertise `_meta.terminal_output` and `_meta.terminal_output_delta`; append either channel, never replace prior chunks |
| Completion | A display terminal is identified by `terminal_info` or terminal content; `terminal_exit` is separate from tool completion. Read/search/list deltas have no terminal and require no exit event |
| Permissions | `session/request_permission`; preserve backend option IDs, explicit allow/reject choices, cancel unanswered requests on stop/disconnect |
| Files / terminals | Client filesystem and terminal capabilities are false. Codex's own workspace-scoped tools execute and emit output; this app does not provide a PTY |
| Shutdown | Track descendant identities while connected; close stdin, allow the supervisor to drain, then TERM/KILL and verify known survivors. Keep the lease until shutdown completes, before capturing cancelled changes. If known processes survive KILL, only an explicit user release ends protection, and that turn's review is marked provisional. Blocked stdin cannot block escalation; pipe errors cannot terminate the app |

Session loading replays backend history, but replay does not append to an active
turn. There is no automatic prompt retry. Unexpected methods not advertised by the
client receive an error. Diagnostics on stderr are drained separately from JSON
and are not persisted or displayed as assistant text.

Timeline details retain up to 500 entries, with an explicit omission notice.
Additional tools retain bounded lifecycle metadata (up to 20,000 omitted tools),
including terminal exits and failure counts; exhausting this bound stops the turn.
Assistant text (256 KiB) and tool output (1 MiB) truncation are marked. Cancelled or
disconnected turns settle pending tool cards without inventing exit codes.
Process cleanup verifies known descendants using PID and start time, including
reparented children observed while connected; independently detached processes
that escaped observation remain outside this guarantee.

## Turn snapshots

Acquire a lease shared across windows with overlapping canonical project roots.
Save dirty project buffers with the user's explicit choice, protect editing and
file mutations, then capture the baseline before sending the prompt. At task end,
capture again and compare byte fingerprints. Include previously observed paths so
an ignore-rule change cannot masquerade as a deletion. Native file review compares
immutable before/after text via Git histogram; opening a file returns to its live
version. A later turn receives a fresh baseline including manual edits.

Protection checks actual canonical write targets as well as project roots.
Unrelated windows with external tabs or symlink aliases into the running project
also become read-only. Before a task, each window saves only its edited files inside
that project. Save As, create, rename, duplicate and delete recheck their
targets; buffer writes have a final guard. Save panels do not create directories,
because their folder-creation action bypasses the application's mutation guard.

Git discovery includes tracked files even if ignored, and non-ignored untracked
files. Non-Git discovery applies nested ignore rules and normalizes macOS `/var`
and `/private/var` aliases before computing relative paths. External symlink
contents are never retained. Binary/unsupported text and files over the capture
budget keep a limitation marker. Metadata-only changes to captured text files are
not a complete filesystem audit. External edits during a task may also be observed.

Limits: 20 turns, 100 MiB retained changed-file contents, 50 MiB per snapshot,
1 MiB text per file, 20,000 discovered files, bounded discovery/capture time.
Limits and failures are visible. No automatic rollback or staging is provided.
History is in memory for this window; persistence, attachments and cross-restart
chat restoration remain future work. The panel is currently a fixed 360 pt wide.

## Zed reference

Read the local `~/Code/opensource/zed` checkout at
`053d91cb14b5fd138f221ec02bd76efb15e7b2af`. The relevant implementation is
[`crates/agent_servers/src/acp/v1.rs`](https://github.com/zed-industries/zed/blob/053d91cb14b5fd138f221ec02bd76efb15e7b2af/crates/agent_servers/src/acp/v1.rs):
`client_builder` forwards ingress to one foreground queue; the tool update handler
creates display-only terminals from metadata and handles output and exit
independently. `crates/acp_thread/src/acp_thread.rs` separates conversation and
terminal state. These informed the Swift implementation; Zed code and its IDE
subsystems were not copied into Silica.

Protocol references: [ACP v1](https://agentclientprotocol.com/protocol/v1/initialization),
[Codex adapter](https://github.com/agentclientprotocol/codex-acp).

## Verification

- `bash scripts/test-review.sh`: 25 Git/diff/parser/isolation/cancellation checks.
- `bash scripts/test-agent.sh`: framing, ordered RPC, permission responses, EOF,
  timeout recovery, tool patches, terminal-vs-read output, Git/non-Git snapshots,
  ignore rules, frozen history, storage bounds, path containment.
- `bash scripts/test-agent-workspace.sh`: offline build, then the actual app's
  workspace/coordinator/session implementation in an isolated test process:
  cross-project Save As, symlink/external-tab editing, retargeted symlinks, nested
  leases, cancellation, disconnect, missing exit after prompt completion, hidden
  terminal exit and stable final snapshots after stubborn writers stop.
- Process fixtures also cover TERM-resistant children, parent EOF/reparenting,
  children created during shutdown and a full stdin pipe. They use disposable
  files and never connect to an account.
- `RUN_LIVE_CODEX_TESTS=1 bash scripts/test-agent-live.sh`: disposable synthetic
  project only; two actual Codex turns with commands and exits, added/modified/
  deleted files, manual edits, immutable first review, cancellation and partial
  changes, reconnect/load, real permission rejection without a file write.
- Native app verification uses an independent development app identity and a
  disposable Python project: unsaved-file Save and Continue, protected editing,
  streamed text with native inline Markdown, expandable test output/exit status,
  two naturally completed turns (including a read tool), one-file diffs, the
  unchanged first-turn diff after round two, and Open File back to the editor.
  The panel layout was also checked in light appearance using a separate QA copy.
  No user repository is sent to the smoke test.
