# Codex Session Viewer

Browse Codex session logs from `~/.codex/sessions`.

## Build

```sh
swift build
```

## Commands

### List sessions

```sh
swift run codex-sessions list 2026/01/08
swift run codex-sessions list 2026/01
swift run codex-sessions list 2026
```

Output format:

```
[Project]	HH:mm->HH:mm [count]	Title	Originator
```

- `Project` is the last path component of the session `cwd`.
- `count` is the number of message records in the session.
- `Originator` is shortened (e.g. `VSCode`, `CLI`).

Title rules:
- Uses the first user message (skipping AGENTS and `<environment_context>`).
- If the message contains a `## My request for Codex:` section, only that section is used.
- Removes local file paths like `/Users/.../File.swift:12:3`.
- Newlines are replaced with spaces and the result is truncated to 60 characters.

### Show a session

```sh
swift run codex-sessions show <session-id>
```

Prints each message with a timestamp and role.

### Markdown export

```sh
swift run codex-sessions markdown <session-id>
swift run codex-sessions markdown <session-id> --ranges 1...3,25...28
```

- Outputs raw message text as markdown.
- `--ranges` selects 1-based message indices (single values or `start...end`).
- Always strips `<INSTRUCTIONS>...</INSTRUCTIONS>` blocks.
- Each message is prefixed with a header like:

```
──── User · 09:14 · #12 ────
```

## Notes

- Session lookup is filename-based for speed (the session ID must appear in the `.jsonl` filename).
