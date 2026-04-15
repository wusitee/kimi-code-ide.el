# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

`kimi-code-ide.el` is an Emacs package that integrates Kimi Code CLI with Emacs via the Agent Client Protocol (ACP). It creates a bidirectional bridge: Kimi speaks ACP (JSON-RPC over stdio) to Emacs, and Emacs exposes its capabilities (LSP via xref, tree-sitter, imenu, project info) through an HTTP-based MCP tools server.

> **Note:** The codebase refers to this as the **Agent Client Protocol (ACP)**; Kimi's CLI documentation sometimes uses **Agent Collaboration Protocol**. They are the same protocol.

## Architecture

The package is split into several layers:

- **`kimi-code-ide.el`** — Main entry point. Manages the UI (conversation buffer in `kimi-code-ide-mode`, input buffer in `kimi-code-ide-input-mode`), window display, session commands, and resume from Kimi's native `context.jsonl` session files. Resume parses `context.jsonl` from `~/.kimi/sessions/MD5/`, filters out Kimi system noise (`<system>`, `<current_focus>`, etc.), and injects formatted history into the next prompt.
- **`kimi-code-ide-acp.el`** — ACP integration layer. Wraps `acp.el` to manage the `kimi acp` subprocess, handles the `initialize` → `session/new` handshake, sends `session/cancel` notifications, and routes agent notifications and requests. Agent `session/update` notifications drive the UI via `agent_message_chunk`, `tool_call`, `plan`, and `diff` sub-types. Also handles `session/request_permission` with `completing-read` prompts.
- **`kimi-code-ide-handlers.el`** — Client method handlers and diff viewing. `kimi-code-ide-handlers-open-diff` launches `ediff` after temporarily deleting Kimi side windows and restores window configuration variables on exit.
- **`kimi-code-ide-tools-server.el`** / **`kimi-code-ide-tools-http.el`** — HTTP-based MCP tools server framework and transport (requires the `web-server` package). Registers Emacs functions as MCP tools via `kimi-code-ide-tools-server-make-tool` and exposes them over HTTP. The config passed to Kimi during `session/new` uses the shape `((mcpServers . ((emacs-tools . ((type . "http") (url . "..."))))))`.
- **`kimi-code-ide-tools.el`** — Emacs tool definitions: `xref-find-references`, `xref-find-apropos`, `project-info`, `imenu-list-symbols`, `treesit-info`.
- **`kimi-code-ide-diagnostics.el`** — Flycheck/Flymake integration that exposes a `getDiagnostics` MCP tool. Returns LSP-style JSON arrays of `range`/`severity`/`message`/`source` objects per file.
- **`kimi-code-ide-transient.el`** — Transient menu interface (`kimi-code-ide-menu`) with dynamic descriptions based on live session state.
- **`kimi-code-ide-debug.el`** — Debug logging utilities (`kimi-code-ide-debug`, `kimi-code-ide-log`) with a dedicated buffer.
- **`kimi-code-ide-tests.el`** — ERT test suite.

Key design points:
- The ACP client runs `kimi acp` as a subprocess. The UI buffer is a custom Org-mode buffer, not a terminal emulator, because the transport is JSON-RPC over stdio.
- **ACP notification flow:** `session/update` notifications from the agent drive UI updates. Sub-types include `agent_message_chunk` (streaming text), `tool_call` (tool execution status), `plan` (step-by-step plan entries), and `diff` (file change suggestions rendered via `ediff`).
- Terminal tool calls (`terminal/create`) spawn real processes with a backend priority of **`vterm` > `eat` > plain `make-process` fallback**.
- The MCP tools server is started over HTTP (requires the `web-server` package) and passed to Kimi during `session/new` via the `mcpServers` parameter.
- **Diagnostics tool:** `kimi-code-ide-diagnostics.el` exposes `getDiagnostics` as an MCP tool, returning structured LSP-style JSON per file when queried.
- **Window management:** When opening an `ediff` diff, the code temporarily deletes Kimi side windows to avoid layout conflicts, then restores `ediff-window-setup-function` and `ediff-split-window-function` afterward.
- **Additional UX:** `kimi-code-ide-toggle-recent` switches the most recent Kimi window across sessions. Both the conversation and input buffers auto-enter Evil insert state when `evil-mode` is active.
- Sessions are keyed by project directory (`project.el` root or `default-directory`). Each project gets its own Kimi instance and buffer (e.g. `*kimi-code[project-name]*`).

## Commands

### Run all tests

```bash
emacs -batch -L . -l ert -l kimi-code-ide-tests.el -f ert-run-tests-batch-and-exit
```

### Byte-compile a file (syntax check)

```bash
emacs -Q --batch -f batch-byte-compile <file>
```

There is no Makefile, Cask, or package build system. Development is done directly against the `.el` files.

## Project Insights

Before modifying resume, session management, ACP lifecycle, or path-handling code, read **`INSIGHTS.md`**. It contains hard-won debugging lessons (path normalization, native-comp caching, process sentinel behavior, JSONL parsing edge cases, etc.).

> **If a conversation reveals a new subtle behavior or hidden invariant, update `INSIGHTS.md` before declaring the task complete.**

## Dependencies

The package declares the following dependencies in `kimi-code-ide.el`:

- `emacs "28.1"`
- `acp "0.11.0"` (ACP protocol layer by xenodium)
- `transient "0.9.0"`
- `web-server "0.1.2"` (required for the MCP tools HTTP server)

Optional runtime dependencies:
- `vterm` — preferred terminal backend for `terminal/create`
- `eat` — secondary terminal backend
- `flycheck` or `flymake` — for diagnostics collection
- `evil` — auto-insert-state in conversation/input buffers

## Agent Policies (from `AGENTS.md`)

- **GPG Signing**: Every commit must be GPG signed. Do not run `git commit` or `git push` without explicit user approval.
- **Autoload Cookies**: All `interactive` commands exposed via transient menus or keybindings must keep their `;;;###autoload` cookie intact. Never remove them from existing commands; add them to new user-facing interactive commands.
- **Syntax Check & Review**: Before declaring any editing task complete, byte-compile modified files and review every changed line for missing parentheses, unbalanced quotes, incorrect function names, missing `require` forms, and accidentally deleted code (including `;;;###autoload` cookies).
