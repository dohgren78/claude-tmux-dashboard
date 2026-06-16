# claude-dash

A read-only [fzf](https://github.com/junegunn/fzf) popup that lists every **live Claude Code session** across all your tmux sessions — so you can tell at a glance *which Claude is waiting on you* and jump straight to it.

Built for running many Claude Code sessions in parallel (one project per tmux session) where `tmux ls` alone doesn't tell you which one needs attention.

```
╭─ claude-dash · live sessions ─────────────────────────────────╮
│ ? wait   > busy   & bg-shell   . idle                         │
│ sort: [s]tatus  [c]tx%  [t]ime  [p]roj  ·  r=refresh  Enter=jump│
│ STAT  CTX%  PROJECT               TARGET             LAST      │
│ ▶ ?    41%   homelab-fixes         homelab:1.1        2m       │
│   >    88%   ios-healthkit         ios:1.1            5s       │
│   .    63%   dev-env               dev:1.1            1h       │
╰───────────────────────────────────────────────────────────────╯
```

## Install

Requires `fzf`, `jq`, and `tmux`.

```sh
git clone https://github.com/dohgren78/claude-tmux-dashboard.git
cd claude-tmux-dashboard
./install.sh
```

`install.sh` symlinks `claude-dash.sh` into `~/.claude/bin/` and adds a `prefix + Ctrl-j` binding to `~/.tmux.conf` (idempotent — safe to re-run). Then press **`prefix` + `Ctrl-j`** inside any tmux session.

## Controls

| Key | Action |
|-----|--------|
| `Enter` | Jump to that session's tmux pane |
| `s` | Sort by status (default: waiting → busy → bg-shell → idle, recent first within each) |
| `c` | Sort by context % (fullest first) |
| `t` | Sort by last activity (most recent first) |
| `p` | Sort by project name (A–Z) |
| `r` | Refresh |

Because `s`/`c`/`t`/`p` are sort keys they don't type-to-filter the fzf query — fine for a short list.

## Columns

- **STAT** — live status read straight from each session's state file:
  - `?` **waiting** on you (input / permission prompt)
  - `>` busy (Claude working)
  - `&` bg-shell — live session with a background shell running (Claude reports `status: "shell"` whenever a session has ≥1 background shell)
  - `.` idle
- **CTX%** — context-window fill, from the transcript's last token-usage record. Window-aware (÷200k, or ÷1M for 1M-window sessions), capped at 99%.
- **TARGET** — the tmux `session:window.pane` it lives in.
- **LAST** — time since last activity.

## How it works

- **Live sessions** come from `~/.claude/sessions/<pid>.json` (`pid`, `status`, `waitingFor`, `cwd`, `sessionId`, `updatedAt`). Dead PIDs are filtered out.
- **tty → pane** mapping is resolved at query time by joining `ps -o tty= -p <pid>` against `tmux list-panes -a` — no stale cache.
- **Context %** is parsed from the session transcript (`~/.claude/projects/<slug>/<sessionId>.jsonl`), summing the last record's input + cache-read + cache-creation + output tokens.

## Read-only

The script never writes Claude session state and never touches tmux session-persistence tooling (resurrect / continuum / restore). The only mutation it performs is the explicit jump (`select-window` / `select-pane` / `switch-client`) when you press Enter.

## License

Personal tool, no warranty. Use at your own risk.
