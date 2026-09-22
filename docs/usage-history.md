# Usage History

Where the Today / Yesterday / Last 30 Days rows, the Usage Trend chart, and its streaks come from — and why days older than that don't show up.

## The window is 31 days

OpenUsage always shows a rolling window: today plus the previous 30 days, grouped by your Mac's local calendar. When a new day arrives, the oldest day leaves the window. That's by design, not lost data — no setting extends it. [iCloud Sync](icloud-sync.md) shares this same 31-day window across your Macs.

## Local logs and their retention

Most spend-tracking providers don't fetch history from an API. OpenUsage reads the session logs the CLI already writes on your Mac, so the app can only show days those logs still cover. The CLIs clean up (or keep) their own logs, and that's the single most common reason a day inside the window shows no usage. It's the client's retention policy, not an OpenUsage bug — and OpenUsage itself never deletes any of these files.

- **Claude Code** stores session transcripts under `~/.claude/projects/` (or wherever `CLAUDE_CONFIG_DIR` points) and deletes them after **30 days by default**, in a background sweep when a session starts. To keep them longer, set `cleanupPeriodDays` to a larger whole number in `~/.claude/settings.json` (minimum 1 — `0` is rejected):

  ```json
  { "cleanupPeriodDays": 365 }
  ```

- **Codex CLI** writes session rollouts under `~/.codex/sessions/` and `~/.codex/archived_sessions/` (or `$CODEX_HOME`). We found **no documented automatic cleanup** — rollouts stay until you remove them, and a configurable retention period is still an open feature request ([openai/codex#6015](https://github.com/openai/codex/issues/6015)). The `[history]` settings in `~/.codex/config.toml` (`persistence`, `max_bytes`) only govern the typed-prompt history file (`history.jsonl`), not session rollouts. So for Codex, missing days are the 31-day window rolling past them, not logs being cleaned.

- **ZCode** writes per-request token totals, including cache read and cache write, in `~/.zcode/cli/db/db.sqlite` (`model_usage`). OpenUsage uses completed BigModel rows as Z.ai's This Mac detail. They are not added to Z.ai's account totals.
- **Kimi Code CLI** writes turn usage in `~/.kimi-code/server/events/session_*.jsonl` (`inputOther`, `inputCacheRead`, `inputCacheCreation`, `output`). Those rows feed Kimi's local spend tiles.
- **pi coding agent** sessions live under `~/.pi/agent/sessions/` (or `$PI_CODING_AGENT_SESSION_DIR`; pi usage folds into Codex's rows). No automatic cleanup is documented — sessions stay until you delete their `.jsonl` files or remove them from `/resume`.

- **OpenCode** history comes from its local storage (`~/.local/share/opencode/`). No automatic cleanup is documented; clearing that storage removes the history.

- **Grok CLI** sessions live under `~/.grok/sessions/` (or `$GROK_HOME`). We found no reliable documentation of a retention policy either way.

- **Cursor** spend rows come from Cursor's account-wide usage export, not from local logs — nothing cleaned up on your Mac affects them.

## What this means for streaks

The [Usage Trend](dashboard.md) streaks count consecutive days with any recorded usage inside that same 31-day window, so a streak can never read longer than the window (a run that fills it shows as `31+ Days`). A day with zero usage — or a day the client's logs no longer cover — breaks the run.
