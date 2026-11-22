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
| Shutdown | Track descendant identities while connected; close stdin, allow the supervisor to drain, then TERM/KILL and verify known survivors. Keep the project lease until cleanup completes or the user explicitly releases surviving processes. Blocked stdin cannot block escalation; pipe errors cannot terminate the app |

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

## Project tasks and edited files

Before sending a prompt, acquire a lease across windows with overlapping canonical
project roots. A prompt response can arrive before a terminal exits. The turn
waits for that exit, including for tools omitted from the visible timeline.
Stopping or disconnecting also waits for owned writers to exit. If processes
survive cleanup, Release Project or Close Anyway can release the lease explicitly.

Each turn collects paths from ACP `tool_call` and `tool_call_update` events for
edit, delete and move tools. Locations and structured diff content supply paths.
The panel lists the first 500 unique project-relative paths in arrival order.
Selecting one opens its current contents in the read-only viewer. Shell commands
can change files without reporting paths. Disk notifications refresh the viewer
and tree independently of these events.

A window keeps up to 100 turns in memory. Starting a new chat or closing the
window clears the conversation.

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

- `bash scripts/test-agent.sh` exercises framing, RPC, permissions, tool state,
  edited-file extraction and process cleanup using local fixtures.
- `bash scripts/test-agent-workspace.sh` builds the app and checks read-only
  text, disk reload, project leases, cancellation, forced disconnect and
  terminal exits after the prompt response or beyond the visible timeline.
- `RUN_LIVE_CODEX_TESTS=1 bash scripts/test-agent-live.sh` opts in to a real
  Codex account. It checks file effects on disk, cancellation, reconnect and
  permission handling in a disposable project.
