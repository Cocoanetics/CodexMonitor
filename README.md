# CodexMonitor

Tools for **listing, inspecting, and watching local OpenAI Codex sessions** stored in `~/.codex/sessions`.

Works with sessions created from:
- the **Codex CLI** (`codex exec …`, `codex exec resume …`)
- the **VS Code Codex extension**

## What’s included

- **CodexMonitor-CLI**: list/show/watch Codex sessions
- **CodexMonitor-App**: macOS menu bar app showing recent/active sessions and letting you view session messages

## Build

```sh
swift build
```

## CodexMonitor-CLI

### List sessions

```sh
swift run CodexMonitor-CLI list 2026/01/08
swift run CodexMonitor-CLI list 2026/01
swift run CodexMonitor-CLI list 2026
```

Output format:

```
<id>\t<start->end>\t<cwd>\t<title>
```

(Exact formatting may evolve, but the intent is: **session id**, **time range**, **project path**, **title/origin**.)

Title heuristics:
- Uses the first user message (skipping AGENTS and `<environment_context>`).
- If the message contains a `## My request for Codex:` section, only that section is used.
- Removes local file paths like `/Users/.../File.swift:12:3`.
- Newlines are replaced with spaces and the result is truncated.

### Show a session

```sh
swift run CodexMonitor-CLI show <session-id>
swift run CodexMonitor-CLI show <session-id> --ranges 1...3,25...28
```

Outputs messages as markdown with headers and strips `<INSTRUCTIONS>` blocks.

Pretty JSON export:

```sh
swift run CodexMonitor-CLI show <session-id> --json
swift run CodexMonitor-CLI show <session-id> --json --ranges 1...3,25...28
```

### Watch sessions

```sh
swift run CodexMonitor-CLI watch
swift run CodexMonitor-CLI watch --session <session-id>
```

Prints a line for each new or updated `.jsonl` session file.

## CodexMonitor-App (Menu Bar)

```sh
swift run CodexMonitor-App
```

The menu bar app:
- shows the **most recent sessions** (and indicates which ones are currently active)
- lets you **open a session** and **view the session messages** in a window

## Learnings / Notes

### Where Codex stores sessions

Codex sessions are stored as JSONL files under:

```
~/.codex/sessions/YYYY/MM/DD/
```

### Resuming sessions by id

Codex can append to an existing session by id:

```sh
codex exec resume <SESSION_ID> "message"
```

Key behavior:
- resume **does not** create a new session
- resume **does not** move the session file to “today” — it stays in its original `YYYY/MM/DD` folder (only mtime changes)

### VS Code refresh behavior

When you append to a session (e.g. via `codex exec resume …`), VS Code may **not** immediately show the new messages.
A restart of VS Code reliably refreshes the session view.

## Notes

- Session lookup is filename-based for speed (the session id must appear in the `.jsonl` filename).
