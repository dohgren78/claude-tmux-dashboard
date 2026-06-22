# claude-dash

A read-only [fzf](https://github.com/junegunn/fzf) popup that lists every **live Claude Code session** across all your tmux sessions — so you can tell at a glance *which Claude is waiting on you* and jump straight to it.

Built for running many Claude Code sessions in parallel (one project per tmux session) where `tmux ls` alone doesn't tell you which one needs attention.

```
╭─ claude-dash · live sessions ─────────────────────────────────╮
│ ? wait  > busy  & bg-shell  . idle  z resume                  │
│ sort: [s]tatus [c]tx% [t]ime [p]roj · r=refresh · Enter=jump/resume│
│ STAT  CTX%  PROJECT               TARGET             LAST      │
│ ▶ ?    41%   homelab-fixes         homelab:1.1        2m       │
│   >    88%   ios-healthkit         ios:1.1            5s       │
│   .    63%   dev-env               dev:1.1            1h       │
│   z     -    quantcorp             (resume)           3h       │
│   z     -    media-creation        (resume)           1d       │
╰───────────────────────────────────────────────────────────────╯
```

## Install

Requires [Claude Code](https://claude.com/claude-code), `tmux`, `fzf`, and `jq`. No other dependencies — it reads Claude Code's own session/transcript files and shells out to `tmux`; there's no personal wrapper or extra service to install.

```sh
git clone https://github.com/dohgren78/claude-tmux-dashboard.git
cd claude-tmux-dashboard
./install.sh
```

`install.sh` symlinks `claude-dash.sh` into `~/.claude/bin/` and adds a `prefix + Ctrl-j` binding to `~/.tmux.conf` (idempotent — safe to re-run). Then press **`prefix` + `Ctrl-j`** inside any tmux session.

## Controls

| Key | Action |
|-----|--------|
| `Enter` | Live row → jump to its tmux pane. Dormant (`z`) row → resume that exact conversation (`claude --resume`) |
| `s` | Sort by status (default: waiting → busy → bg-shell → idle, recent first within each) |
| `c` | Sort by context % (fullest first) |
| `t` | Sort by last activity (most recent first) |
| `p` | Sort by project name (A–Z) |
| `x` | Sleep the selected live session — kills its tmux session to free RAM; the conversation persists and reappears as a dormant `z` row, resumable. The border label confirms the result instantly (`slept: …`). No-op (with an explanatory label) on dormant rows, unmapped rows, and the dashboard's own session — you can't sleep the session you're viewing from. |
| `r` | Refresh |

Because `s`/`c`/`t`/`p`/`x` are action keys they don't type-to-filter the fzf query — fine for a short list.

## Columns

- **STAT** — live status read straight from each session's state file:
  - `?` **waiting** on you (input / permission prompt)
  - `>` busy (Claude working)
  - `&` bg-shell — live session with a background shell running (Claude reports `status: "shell"` whenever a session has ≥1 background shell)
  - `.` idle
  - `z` dormant — a session you **slept** with `x` (and haven't resumed yet). Listed below the live ones; **Enter resumes that exact conversation** (`claude --resume <sessionId>`) in a fresh tmux session, restoring its original name.
- **CTX%** — context-window fill, from the transcript's last token-usage record. Window-aware (÷200k, or ÷1M for 1M-window sessions), capped at 99%.
- **TARGET** — the tmux `session:window.pane` it lives in.
- **LAST** — time since last activity.

## How it works

- **Live sessions** come from `~/.claude/sessions/<pid>.json` (`pid`, `status`, `waitingFor`, `cwd`, `sessionId`, `updatedAt`). Dead PIDs are filtered out.
- **tty → pane** mapping is resolved at query time by joining `ps -o tty= -p <pid>` against `tmux list-panes -a` — no stale cache.
- **Context %** is parsed from the session transcript (`~/.claude/projects/<slug>/<sessionId>.jsonl`), summing the last record's input + cache-read + cache-creation + output tokens.
- **Dormant (`z`) sessions** are the ones you slept with `x`, recorded in `~/.claude/.claude-dash-slept` (`sessionId` → tmux name → `cwd`). A `z` row shows for each slept session that isn't currently live and still has a transcript. Resume targets the exact `sessionId`, so it reopens that precise conversation under its original name — not "the most recent one in the directory." It does **not** list every old conversation you ever had; only what you parked.

## Read-only

The script never writes Claude session state and never touches tmux session-persistence tooling (resurrect / continuum / restore). The only mutations are the explicit Enter actions: **jump** (`select-window` / `select-pane` / `switch-client`) for a live row, or **resume** for a dormant row (creates a tmux session and runs `claude --resume <sessionId>`).

## Compatibility & assumptions

- **macOS** as written — it uses BSD `tail -r`, `stat -f`, and `ps -o tty=`. On Linux, swap `tail -r`→`tac` and `stat -f %m`→`stat -c %Y` (two spots each).
- Reads **Claude Code's internal file layout**: live sessions from `~/.claude/sessions/<pid>.json` (`pid`, `status`, `cwd`, `sessionId`) and transcripts from `~/.claude/projects/<slug>/<sessionId>.jsonl`. These are undocumented internals and can change between Claude Code versions — if a column goes blank after an update, that's the first place to look.
- Status glyphs map Claude Code's `status` values (`waiting` / `busy` / `idle` / `shell`); `shell` means the session holds ≥1 background shell, not that it's parked.
- **No `cproj` or other personal tooling required.** Sleep kills a tmux session; resume runs `claude --resume <id>` in a fresh one — both plain tmux.

## License

Personal tool, no warranty. Use at your own risk.
