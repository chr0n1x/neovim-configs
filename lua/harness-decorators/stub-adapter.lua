-- Inert adapter defaults for harnesses with no edit following (projects_dir() nil).

---The interface every harness adapter (`harness-decorators.<harness>`) exposes. Adapters inherit
---from the stub below, which gives every field except title_color and the sidecar trio an inert
---default meaning "this harness does not do that".
---@class HarnessAdapter
---Directory to watch for session JSONLs; nil turns the watcher off.
---@field projects_dir fun(): string?
---Tri-state verdict on whether a session JSONL belongs to this nvim.
---@field session_ownership fun(nvim_cwd: string?, lines: string[], jsonl_path: string?): "match"|"mismatch"|"unknown"
---Session-resetting slash command found in the lines (e.g. "/clear"), or nil.
---@field find_reset_command fun(lines: string[]): string?
---True when a reset command keeps writing to the same JSONL.
---@field is_same_file_reset fun(cmd: string): boolean
---Normalized change_info for a JSONL line that records a file edit, or nil.
---@field parse_tool_result fun(line: string, line_number: integer?): table?
---Title fg color for the float title and picker row; matches tmux/scripts/tmux-agent-pick.sh (agent_color).
---@field title_color string
---Sidecar filename (without .jsonl) for a session; needed when projects_dir() returns a dir.
---@field sidecar_name? fun(session_id: string): string
---How much diff data a sidecar event holds (higher is richer); needed with sidecar_name.
---@field score_event? fun(ev: table): integer
---History-preview diff text for a sidecar event; needed with sidecar_name.
---@field extract_diff? fun(ev: table?): string
---Session id derived from the JSONL path, or nil for the filename stem (default: nil).
---@field session_id fun(jsonl_path: string?): string?
---Session id declared inside the JSONL lines, or nil (default: nil, so only a first-encounter
---ownership match pins, keyed by the path).
---@field session_id_from_lines fun(lines: string[]): string?
---Hook run when the watcher first pins a session; returns the byte offset to read from
---(default: file_size, so content written before the pin is not replayed).
---@field on_pin fun(jsonl_path: string, file_size: number): number
---inotifywait event list, or nil for the watcher's default set (default: nil).
---@field inotify_events fun(): string?
---Hook run when the harness becomes active (startup or switch).
---@field on_activate? fun()
---True when the harness pushes edits itself, so the filesystem watcher stays off (default: false).
---@field push_following boolean
---True when session JSONLs sit directly in projects_dir() (watched non-recursively; default: false).
---@field flat_sessions_dir boolean

local M = {}

---Placeholder extract_diff text when there is no event to render.
M.NO_DIFF = "(no diff data available)"

---Placeholder extract_diff text when an event matched but carries no diff payload.
M.NO_EVENT_DIFF = "(event matched but contains no diff data)"

M.push_following = false

M.flat_sessions_dir = false

---@return string?
function M.session_id(_jsonl_path)
  return nil
end

---@return string?
function M.session_id_from_lines(_lines)
  return nil
end

---@return number
function M.on_pin(_jsonl_path, file_size)
  return file_size
end

---@return string?
function M.inotify_events()
  return nil
end

---@return string?
function M.projects_dir()
  return nil
end

---No session to own: the watcher is off, so ownership is never actually queried.
---@return "match"|"mismatch"|"unknown"
function M.session_ownership(_nvim_cwd, _lines, _jsonl_path)
  return "unknown"
end

---@return string?
function M.find_reset_command(_lines)
  return nil
end

---@return boolean
function M.is_same_file_reset(_cmd)
  return false
end

---@return table?
function M.parse_tool_result(_line, _line_number)
  return nil
end

return M
