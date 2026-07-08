# claude-tmux-dashboard

A read-only [fzf](https://github.com/junegunn/fzf) popup — the **`claude-dash`** command — that lists every **live Claude Code session** across all your tmux sessions, so you can tell at a glance *which Claude is waiting on you, what model it's on, and how full its context is* — and jump straight to it.

Built for running many Claude Code sessions in parallel (one project per tmux session) where `tmux ls` alone doesn't tell you which one needs attention.

Companion to [claude-tmux-continuity](https://github.com/dohgren78/claude-tmux-continuity), which restores those same sessions verbatim after a reboot.

![claude-dash in action](demo.gif)

```text
 claude-dash · 9 sessions
────────────────────────────────────────────────────────────────────────────
 ? wait   > busy   & bg-shell   . idle   z resume
 s status   c ctx%   t time   p proj   x sleep   r refresh   ↵ jump/resume

     CTX% MODEL    │ PROJECT              │ TARGET             │ LAST
 > ▁ 14%  Opus 4.8 │ GrapplingTracks      │ daily-porrada:1.1  │ 44s
 . ▃ 41%  Opus 4.8 │ whispa               │ whispa:1.1         │ 2m
 > ▇ 88%  Sonnet 5 │ homelab-fixes        │ homelab-omada:1.1  │ 5s
 . ▁ 6%   Haiku    │ dev-env-optimization │ dev-env-fixes:1.1  │ 1h
 z   -    -        │ media-creation       │ (resume)           │ 1d
────────────────────────────────────────────────────────────────────────────
```

> The status column (`?` `>` `&` `.` `z` above) is shown here as ASCII. **In the terminal these are colour-coded [Nerd Font](https://www.nerdfonts.com/) icons** by default — a spinner for busy, a folder-shell for bg-shell, a dot for idle, and so on — and the CTX% gauge (`▁▃▅▇`) is graded green → amber → red. Without a Nerd Font, set `CLAUDE_DASH_ASCII=1` for exactly the ASCII glyphs above (see [Install](#install)).

Live sessions on top (jump with Enter), parked ones (`z`) below (Enter resumes the exact conversation, `x` sleeps a live one). The status icon, CTX% gauge, and MODEL are colour-coded, and the whole row dims when idle so the active ones stand out.

## Install

Requires [Claude Code](https://claude.com/claude-code), `tmux`, `fzf`, and `jq`. No other dependencies — it reads Claude Code's own session/transcript files and shells out to `tmux`; there's no personal wrapper or extra service to install.

```sh
git clone https://github.com/dohgren78/claude-tmux-dashboard.git
cd claude-tmux-dashboard
./install.sh
```

`install.sh` symlinks `claude-dash.sh` into `~/.claude/bin/` and adds a `prefix + Ctrl-j` binding to `~/.tmux.conf` (idempotent — safe to re-run). Then press **`prefix` + `Ctrl-j`** inside any tmux session.

**Nerd Font (for the status icons):** the status column uses [Nerd Font](https://www.nerdfonts.com/) icons. Set your terminal font to a patched font (e.g. `JetBrainsMono Nerd Font`) so they render. If you don't use a Nerd Font, set **`CLAUDE_DASH_ASCII=1`** to get the plain ASCII glyphs (`?` `>` `&` `.` `z`) instead of empty boxes — e.g. change the tmux bind to `... -E "CLAUDE_DASH_ASCII=1 ~/.claude/bin/claude-dash.sh"`, or export it in your shell. Everything else (the gauge bars, `│` separators, colours) is standard Unicode and works in any font.

## Controls

| Key | Action |
|-----|--------|
| `Enter` | Live row → jump to its tmux pane. Dormant (`z`) row → resume that exact conversation (`claude --resume`) |
| `s` | Sort by status (default: waiting → busy → bg-shell → idle, recent first within each) |
| `c` | Sort by context % (fullest first) |
| `t` | Sort by last activity (most recent first) |
| `p` | Sort by project name (A–Z) |
| `x` | Sleep the selected live session — kills its tmux session to free RAM; the conversation persists and reappears as a dormant `z` row, resumable. The border label confirms the result instantly (`slept: …`). No-op (with an explanatory label) on dormant rows, unmapped rows, and the dashboard's own session. |
| `r` | Refresh |

Because `s`/`c`/`t`/`p`/`x` are action keys they don't type-to-filter the fzf query — fine for a short list. The key legend at the top **wraps onto extra rows on narrow terminals** instead of truncating.

## Columns

- **STAT** — live status read straight from each session's state file, shown as a colour-coded [Nerd Font](https://www.nerdfonts.com/) icon (ASCII stand-in in parentheses, as used in the mockup above):
  - `?` **waiting** on you (input / permission prompt) — the one to look at first
  - `>` **busy** (Claude working)
  - `&` **bg-shell** — live session with a background shell running (Claude reports `status: "shell"`)
  - `.` **idle**
  - `z` **dormant** — a session you slept with `x`. Listed below the live ones; **Enter resumes that exact conversation** (`claude --resume <sessionId>`).
- **CTX%** — context-window fill as a colour-graded gauge bar (`▁▃▅▇`, green → amber → red) plus the number. Window-aware (÷200k, or ÷1M for 1M-window models), capped at 99%. Read from the transcript's last **main-chain** token-usage record (sub-agent usage lines are skipped so a spawned Haiku/other-model agent can't mislabel the session).
- **MODEL** — the active model (e.g. `Opus 4.8`, `Sonnet 5`, `Haiku`, `Fable 5`), derived from the session's transcript.
- **PROJECT** — the project (cwd basename).
- **TARGET** — the tmux `session:window.pane` to jump to. May instead show a diagnostic marker (see [Daemon-aware merge](#daemon-aware-merge)): `detached`, `unlinked?`, or `ambiguous?`.
- **LAST** — time since last activity.

## Daemon-aware merge

Claude Code 2.1.x runs each session as **two processes**: a daemon-hosted **bg job** (`kind: "bg"` — does the actual work, owns the model/status/context, but has no tty) and an **interactive client** (`kind: "interactive"` — owns the tmux pane that renders it). There are also `--bg-spare` pre-warm processes.

claude-dash presents these as **one logical row**: identity, model, status, and context come from the bg job; the **jump target comes from the interactive client's pane**. Spares are filtered out. Correlation is keyed on the bg job's `jobId` (which names its daemon socket and transcript) — not its `sessionId`, because those can diverge between Claude Code builds.

When correlation can't be completed the TARGET column says so instead of failing silently:

- `detached` — a bg job that resolved fine but has no interactive client attached (nothing to jump to).
- `unlinked?` — the bg job's daemon identity couldn't be resolved (socket/transcript/jobId missing). Usually means a Claude Code update changed the daemon layout — run `--doctor`.
- `ambiguous?` — two or more bg jobs share the same daemon instance + cwd and can't be uniquely paired.

## `--doctor` — self-check

Because the dashboard reads **undocumented Claude Code internals** that can change between releases, `claude-dash --doctor` runs a read-only checklist of every layout assumption against your live sessions and reports `PASS`/`WARN`/`FAIL`:

```sh
~/.claude/bin/claude-dash.sh --doctor
```

It reports the detected Claude Code version (and the version the assumptions were validated against), the daemon instance count, per-bg-job socket/transcript resolution, per-interactive-client pane resolution, the merge tally (merged / detached / unlinked / ambiguous), and a session-json schema probe. If a future update breaks the dashboard, `--doctor` names the exact missing piece so it's a two-minute fix rather than an investigation.

## How it works

- **Live sessions** come from `~/.claude/sessions/<pid>.json` (`pid`, `status`, `waitingFor`, `cwd`, `sessionId`, `kind`, `jobId`, `updatedAt`). Dead PIDs are filtered out; `--bg-spare` processes are excluded.
- **tty → pane** mapping is resolved at query time by joining `ps -o tty= -p <pid>` against `tmux list-panes -a` — no stale cache.
- **Model & context** are parsed from the session transcript (`~/.claude/projects/<slug>/<jobId-or-sessionId>*.jsonl`), from the last main-chain token-usage record.
- **Dormant (`z`) sessions** are the ones you slept with `x`, recorded in `~/.claude/.claude-dash-slept` (`sessionId` → tmux name → `cwd`). Resume targets the exact `sessionId`, reopening that precise conversation under its original name — not "the most recent one in the directory."

## Read-only

The script never writes Claude session state and never touches tmux session-persistence tooling (resurrect / continuum / restore). The only mutations are the explicit `Enter` actions — **jump** (`select-window` / `select-pane` / `switch-client`) for a live row, or **resume** for a dormant row — and `x`, which sleeps a live session by killing its tmux session (the conversation persists). `--doctor`, `--list`, and `--preview` are pure reads.

## Compatibility & assumptions

- **macOS** as written — it uses BSD `tail -r`, `stat -f`, `ps -o tty=`, and `stty size </dev/tty` for width. On Linux, swap `tail -r`→`tac` and `stat -f %m`→`stat -c %Y`.
- Reads **Claude Code's internal file layout** and **daemon architecture** (`~/.claude/sessions/<pid>.json`, `/tmp/cc-daemon-<uid>/<instance>/`, transcripts under `~/.claude/projects/`). These are undocumented internals and change between versions — run `--doctor` after a Claude Code update; if it reports a `FAIL`, that's the first place to look.
- The bg-job ↔ interactive-client correlation is a `(daemon instance + cwd)` heuristic; two bg jobs in the same directory can't be uniquely paired (shown as `ambiguous?`).

## State & recovery

The dashboard is stateless except for one file: **`~/.claude/.claude-dash-slept`** — appended each time you sleep a session with `x`, one line per sleep (`<sessionId>\t<tmux-name>\t<cwd>`). The dormant `z` list is built entirely from it (entries that aren't currently live and still have a transcript; newest name per `sessionId` wins).

- **Clear the slept list:** `rm ~/.claude/.claude-dash-slept`. (Conversations are untouched — this tool never deletes transcripts.)
- **Rebuild it after data loss:** the conversations live on as transcripts, so you can reconstruct one resumable entry per project (most-recent non-live transcript):

  ```sh
  live=$(for f in ~/.claude/sessions/*.json; do ps -p "$(jq -r .pid "$f")" -o pid= >/dev/null 2>&1 && jq -r .sessionId "$f"; done)
  for d in ~/.claude/projects/*/; do
    for tf in $(ls -t "$d"*.jsonl 2>/dev/null); do
      sid=${tf##*/}; sid=${sid%.jsonl}
      case $sid in agent-*) continue;; esac
      printf '%s\n' "$live" | grep -qxF "$sid" && continue
      cwd=$(grep -m1 -o '"cwd":"[^"]*"' "$tf" | sed 's/.*"cwd":"//;s/"$//')
      printf '%s\t%s\t%s\n' "$sid" "${cwd##*/}" "$cwd" >> ~/.claude/.claude-dash-slept
      break
    done
  done
  ```

## License

[MIT](./LICENSE) — no warranty, use at your own risk.
