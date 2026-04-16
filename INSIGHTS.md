# Project Insights — `kimi-code-ide.el`

This file captures hard-won lessons from debugging and evolving the package. Future agents (Claude, Kimi, or otherwise) should **read this file before making changes** to resume, session management, ACP lifecycle, or path-handling code. If a conversation reveals a new subtle behavior, **update this file** before declaring the task done.

---

## Resume & Session Restoration

### 1. Path normalization must match Kimi CLI exactly
**What happened:** `kimi-code-ide--get-working-directory` returned `/home/wste/dotfile/` (with trailing slash), but Kimi CLI computes the session-directory MD5 from `/home/wste/dotfile` (without trailing slash). The hashes differed, so resume searched an empty `~/.kimi/sessions/` subdirectory and found no `context.jsonl`.

**Fix:** Wrap the result of `kimi-code-ide--get-working-directory` with `directory-file-name` to strip the trailing slash.

**Lesson:** Any feature that correlates Emacs state with Kimi CLI disk state must use *identical* path normalization before hashing or comparing paths.

---

### 2. Kimi CLI creates a new empty session on every `session/new`
**What happened:** `kimi-code-ide--latest-kimi-context-file` sorted `context.jsonl` files by mtime and picked the newest one. Because Kimi creates a fresh session directory for every `session/new`, the newest file often contained only the `_system_prompt` and zero conversation turns. Resume then appeared to "load nothing."

**Fix:** Sort by mtime, but return the **first file that actually yields parsed turns** (`(kimi-code-ide--parse-context-jsonl file)` returns non-nil).

**Lesson:** Newest-on-disk is not the same as "most recent conversation." Always validate that a candidate file contains meaningful history.

---

### 3. Intentional `stop` must not trigger buffer-killing cleanup
**What happened:** `kimi-code-ide-acp-stop` called `acp-shutdown`, which fired the process sentinel. The sentinel unconditionally called `kimi-code-ide--cleanup-on-exit`, killing the conversation buffer even though the user explicitly chose to keep it for resume.

**Fix:** Clear the process sentinel (`set-process-sentinel process nil`) inside `kimi-code-ide-acp-stop` *before* calling `acp-shutdown`.

**Lesson:** Process sentinels are a common source of race-condition bugs during intentional teardown. Distinguish "user asked to stop" from "process crashed."

---

### 4. Buffer-empty check is the wrong signal for "already has history"
**What happened:** `kimi-code-ide-resume` only rendered disk history when the buffer was physically empty. If the buffer contained just the welcome message (`* Kimi Code IDE — project\n\n`), the history was skipped and the user saw no previous conversation.

**Fix:** Replace the empty-buffer check with `kimi-code-ide--buffer-has-history-p`, which looks for actual conversation headings (`* You`) rather than checking `point-min == point-max`.

**Lesson:** Static boilerplate (welcome messages, headers) should not be treated as user-facing content when deciding whether to inject history.

---

## Emacs Native Compilation Caching

### 5. Stale `.eln` files cause "works in tests but not in Emacs"
**What happened:** After editing `kimi-code-ide.el` source, batch tests passed but the live Emacs process still behaved like the old code. Emacs 30 native compilation stores `.eln` binaries in `~/.config/emacs/.local/cache/eln/`, and these can outlive `.elc` rebuilds from Straight.

**Fix:** When iterating on this package, delete stale `kimi-code-ide-*.eln` files from the native-comp cache after syncing source to the Straight repo.

**Lesson:** If source edits don't seem to take effect in a running Doom/Emacs 30 setup, suspect the `.eln` cache before suspecting the logic.

---

## Pending Resume History

### 6. Global pending history causes cross-project contamination
**What happened:** `kimi-code-ide--pending-resume-history` was a single global string. Resuming project A would inject A's conversation into project B's next prompt.

**Fix:** Convert it to a hash table keyed by `working-dir` (`:test 'equal`). Use `puthash`/`gethash`/`remhash` in `kimi-code-ide-resume` and `kimi-code-ide-send-prompt`.

**Lesson:** Any transient state that lives across command invocations must be scoped to the project/session key, not stored globally.

---

## JSONL Parsing

### 7. `context.jsonl` parsing must survive multi-line JSON objects
**What happened:** `kimi-code-ide--parse-context-jsonl` used `(forward-line 1)` after each `json-parse-buffer`, assuming single-line JSON. If Kimi ever writes pretty-printed or multi-line objects, parsing would skip or corrupt subsequent objects.

**Fix:** Replace `(forward-line 1)` with `(skip-chars-forward " \t\n\r")` and let `json-parse-buffer` advance point naturally. On parse error, jump to `(point-max)` to avoid infinite loops.

**Lesson:** JSONL is "one object per line" by convention, but not guaranteed. Defensive parsing should tolerate whitespace and recover from malformed objects.

---

## CI & Batch Testing Stubs

### 8. Test-file stubs must stay in sync with CI stubs
**What happened:** `kimi-code-ide-tests.el` contained an `eval-and-compile` stub for the `acp` package so tests could run in CI without the real dependency. The CI workflow (`ci.yml`) also generated an inline `ci-stub.el` with the same functions. Over time, the test file stub drifted: it was missing `acp-make-session-request-permission-response`, which had been added to the CI stub and was actively used in `kimi-code-ide-acp.el`. This meant local batch test runs (without `ci-stub.el` loaded) could fail with a `void-function` error.

**Fix:** Add the missing `acp-make-session-request-permission-response` definition to the test file stub, keeping it identical in coverage to the CI stub.

**Lesson:** Whenever a new `acp` function is introduced in the codebase, update *both* the test file stub (`kimi-code-ide-tests.el`) and the CI stub (`.github/workflows/ci.yml`) in the same commit. Treat them as a matched pair.
