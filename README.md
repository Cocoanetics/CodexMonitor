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
[Project]	yyyy-MM-dd HH:mm->HH:mm (count)	Title	Originator
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
swift run codex-sessions show <session-id> --ranges 1...3,25...28
```

Outputs messages as markdown with headers and strips `<INSTRUCTIONS>` blocks.

Header format:

```
──── User · 09:14 · #12 ────
```

Pretty JSON export:

```sh
swift run codex-sessions show <session-id> --json
swift run codex-sessions show <session-id> --json --ranges 1...3,25...28
```

Includes a `summary` block (when available) plus all messages with timestamps.

### Watch sessions

```sh
swift run codex-sessions watch
swift run codex-sessions watch --session <session-id>
```

Prints the list-style line for each new or updated `.jsonl` session file under the sessions root.

## Notes

- Session lookup is filename-based for speed (the session ID must appear in the `.jsonl` filename).
