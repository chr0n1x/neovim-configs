# Harness adapter interface

The generic modules (`watcher`, `jsonl-parser`) are harness-agnostic.
They load the adapter for `NVIM_LLM_HARNESS` (default `claude`) and call only
the functions below. Implementations: `claude/init.lua`, `maki/init.lua`.

## Required

| Function | Returns | Purpose |
|---|---|---|
| `projects_dir()` | `string?` | Directory to watch for session JSONLs. |
| `session_ownership(nvim_cwd, lines, jsonl_path)` | `"match" \| "mismatch" \| "unknown"` | Decide whether a JSONL belongs to this nvim instance. `"unknown"` means no evidence yet; the watcher retries on the next write. |
| `find_reset_command(lines)` | `string?` | Return the reset command text (`"/clear"`, `"/new"`, ...) if any line is one, else nil. Stub: return nil. |
| `is_same_file_reset(cmd)` | `boolean` | True when the reset keeps the same JSONL (only history wiped), false when the session switches files. |
| `parse_tool_result(line, line_number)` | `table?` | Normalize one JSONL line into a change event: `{ file_path, operation, starting_line?, delta?, dedup_key?, source_line?, event_uuid?, event_timestamp?, event_id? }`. Return nil for non-edit lines. Stub: return nil. |

## Optional

| Function | Purpose |
|---|---|
| `flat_sessions_dir = true` (field) | Session JSONLs live at the top level of `projects_dir()`; fswatch watches that dir non-recursively instead of its subdirs. |
| `extract_cwd(lines)` | Dialect-specific cwd extraction, used by `session_ownership`. |

## Normalized change event fields

- `file_path` (string): absolute path of the edited file. Required.
- `operation` (string): `"Edit"` or `"Create"`.
- `starting_line` (number?): 1-based line of the edit; nil for early events that lack line info.
- `dedup_key` (string?): deduplicates repeated autocmds for the same logical edit.
- `delta`, `source_line`, `event_uuid`, `event_timestamp`, `event_id`: optional, harness-specific extras stored in the edit history.

## Invariants the watcher relies on

- Baseline: on first encounter of a JSONL the watcher pins (if ownership is
  `"match"`) and starts reading from the current file size, so preexisting
  content is never replayed.
- Shrinking files are skipped (`file_size <= prev.byte_pos`); an adapter that
  rewrites its own JSONL in place must surface that via `find_reset_command`.
