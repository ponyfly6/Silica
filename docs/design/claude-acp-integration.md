# Claude Code over ACP

Silica pins `@agentclientprotocol/claude-agent-acp@0.109.0` in `Tools/ClaudeACP`.
The `claude-agent-acp` executable runs `dist/index.js` and requires Node.js 22+.
Its locked dependency `@anthropic-ai/claude-agent-sdk@0.3.328` supplies the CLI
through optional platform packages. The installer includes those dependencies.
The adapter honors an existing `CLAUDE_CODE_EXECUTABLE` override. By default it
locates the CLI itself.

## Session contract

- The adapter supports ACP v1 and v2. `CLAUDE_AGENT_ACP_PROTOCOL` defaults to
  `auto`, and Silica requests v1 on the shared stdio transport.
- The adapter reuses the user’s Claude Code login. Silica advertises no terminal
  authentication, so the adapter returns an empty `authMethods` list. To sign
  in, run `claude` in Terminal and log in, then reconnect.
- Silica displays the `mode`, `model` and `thought_level` config categories.
  Claude starts in `auto` when available, otherwise `default`, subject to the
  user’s Claude settings. Silica preserves either mode plus `acceptEdits`,
  `plan` and `dontAsk`. For `bypassPermissions` or an unknown mode it requests
  the first offered value in the order `auto`, `acceptEdits`, `default`. The
  connection requires confirmation of the replacement. The picker and outgoing
  configuration requests use the same allowlist.
- With Silica’s advertised terminal-output extensions, Bash announces a display
  terminal through `content` and `_meta.terminal_info` even with the client
  terminal capability disabled. The adapter reports
  stdout in `_meta.claudeCode.toolResponse` and delivers the same text in
  `_meta.terminal_output_delta.data`. The timeline displays the delta once and
  uses the exit code from `_meta.terminal_exit`. Text-only tools use structured
  content and finish without waiting for a terminal. For tools with `kind: "edit"`,
  the shared timeline collects paths from `locations` and `type: "diff"`
  content under **Edited by agent**.

## Verification

The generated npm lock records the adapter, SDK and optional CLI packages.
Local Swift tests cover executable discovery, mode selection, diff paths and
text-only shell completion. The workspace fixture checks the actual ACP request
that replaces `bypassPermissions` with `auto`, rejects a picker request for
`bypassPermissions`, and starts a fresh session after switching agents.

The opt-in Claude smoke test passed with the existing login in a disposable
project. It checked Bash output, edits across two turns, cancellation with a
partial file, reconnect via `session/load`, and a rejected Edit request in
`default` mode that preserved the original file. Run it with `AGENT=claude`
and `RUN_LIVE_AGENT_TESTS=1`.
