# Agent Instructions for `kimi-code-ide.el`

## GPG Signing Policy

Every commit in this repository **must be GPG signed**. The signing key is managed by a password manager that requires manual unlock.

**Rule for agents:**
- **Do not** run `git commit` or `git push` without explicit user approval.
- If the user says "yes" (or otherwise approves), you may commit and push as normal.
- If the user has not approved, stop and ask: *"Commits require GPG signing via your password manager. May I commit and push?"*

This applies to all branches, including force-pushes and squashes.

## Autoload Policy

All `interactive` commands that are exposed via transient menus, keybindings, or meant to be called directly by users **must** keep their `;;;###autoload` cookie intact.

**Rule for agents:**
- Never remove `;;;###autoload` from existing commands such as `kimi-code-ide-resume`, `kimi-code-ide`, `kimi-code-ide-send-prompt`, etc.
- When adding a new user-facing interactive command, add `;;;###autoload` directly above the `defun`.
- When moving or refactoring code, ensure the `;;;###autoload` cookie travels with the function definition.
