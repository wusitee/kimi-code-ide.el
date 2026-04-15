# KIMI.md

This file provides guidance when working with code in this repository.

## Architecture and File Structure

This package integrates Kimi Code CLI with Emacs via the Agent Client Protocol (ACP).

**Core Files:**
- `kimi-code-ide.el` - Main entry: user commands, session management, UI buffer
- `kimi-code-ide-acp.el` - ACP client management, JSON-RPC handling, session lifecycle
- `kimi-code-ide-handlers.el` - Client method handlers (fs, terminal, permission) and diff viewing

**Support Files:**
- `kimi-code-ide-tools-server.el` - HTTP-based MCP tools server framework
- `kimi-code-ide-tools-http.el` - HTTP transport implementation
- `kimi-code-ide-tools.el` - Emacs tools: xref, project info, imenu, treesit
- `kimi-code-ide-diagnostics.el` - Flycheck/Flymake integration
- `kimi-code-ide-transient.el` - Transient menu interface
- `kimi-code-ide-debug.el` - Debug logging utilities
- `kimi-code-ide-tests.el` - ERT test suite

## Commands

### Running Tests

```bash
# Run all tests in batch mode
emacs -batch -L . -l ert -l kimi-code-ide-tests.el -f ert-run-tests-batch-and-exit

# Run tests interactively
M-x ert-run-tests-interactively
```

## Development Guidelines

- Keep changes minimal and focused
- Follow the coding style of existing files
- Write tests for new logic
- Update this file if you find any instructions that are incorrect or outdated

## Important Notes

- **ACP Transport**: We use `acp.el` (by xenodium) for the ACP JSON-RPC protocol. Do not reimplement the protocol layer.
- **Agent Launch**: Kimi is launched via `kimi acp` as a subprocess.
- **UI Buffer**: The main interaction happens in a custom buffer (`kimi-code-ide-mode`), not a terminal emulator, because `kimi acp` speaks JSON-RPC over stdio.
- **Terminal Tool Calls**: When the agent requests `terminal/create`, we spawn real processes using `make-process`.
- **MCP Tools**: The Emacs MCP tools server uses HTTP transport and is passed to Kimi during `session/new` via the `mcpServers` parameter.
