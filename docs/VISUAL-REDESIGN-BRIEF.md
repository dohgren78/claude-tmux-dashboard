# claude-dash — Visual Redesign Brief

**Status:** Rigged, not started. Scheduled for the next session ("we'll do it tomorrow", teed up 2026-07-07).
**Goal:** Make the dashboard look nicer and more polished. Pure visual/UX pass — **no behavioral changes**.
**Baseline:** `docs/redesign-baseline.txt` (exact before-render, ANSI-stripped, at commit `9353660`).

---

## Hard constraints (do NOT break)

These are load-bearing from quick tasks 260614-ovf / 260707-u4z / 260707-un0. A visual pass must preserve them:

- **Read-only guarantee.** Only mutation is the tmux jump/resume on Enter and sleep on `x`. No new writes.
- **13-field tab-delimited row contract.** fzf shows field 13 (`--with-nth=13`). Data fields: jump=**f7**, cwd=**f10**, sid=**f11**, act_epoch=**f12**. Sort keys: `-k2` ctx, `-k3` proj, `-k6` status, `-k12` activity. **Any width/column change touches the display string (f13) and the three printf sites only — never the data fields or their order.**
- **Three display printfs must stay mutually aligned:** live rows (`disp`, ~line 208 via `build_row`), dormant rows (`nzdisp`, ~line 378), and the header (`COLHDR`, ~line 501). Change one width → change all three.
- **bash 3.2 / macOS.** No associative arrays, no GNU-only flags. ANSI only in the glyph + via fzf `--color`.
- **fzf field plumbing.** `--delimiter=$'\t' --with-nth=13 --nth=13`. Preview passes the full tab line back to `--preview`.

## Current visual vocabulary (what exists today)

- **Glyphs (status):** `?` wait (bold red), `>` busy (bold yellow), `&` bg-shell (cyan), `.` idle (dim), `z` resume (dim). ASCII, ANSI-colored, no emoji (matches user's global "no emojis" rule).
- **Columns (field 13):** `glyph  CTX%(4)  MODEL(10)  PROJECT(20)  TARGET(20)  LAST(4)`.
- **fzf chrome:** `--border=rounded`, label ` claude-dash · sessions ` at pos 2, `--layout=reverse`, `--pointer='▶'`, `--prompt='filter ▸ '`, `--info=inline`.
- **Color scheme (hex):** hl `#ffaf5f`, fg+ `#ffffff`, bg+ `#262626`, hl+ `#ffd75f`, header `#87afaf`, info `#6c6c6c`, pointer `#ff5f5f`, prompt `#5fafd7`, border `#5f87af`, label `#afd7ff`.
- **Header:** two legend lines (status glyphs + sort/key hints) then a dim column header.
- **Preview pane:** `right:45%:wrap:border-left`. Lines: Session / Status / WaitingFor / Context / Model / Job / Pane / LastAct / CWD / PID, then a `── transcript tail ──` of the last ~12 turns.

## Decisions to make tomorrow (each with a recommendation)

> Per house rule: lead with the recommendation. These are the levers; tomorrow we pick and execute, likely via `/gsd:quick --discuss` so the choices get captured in CONTEXT.md.

1. **Status encoding — glyph+color vs colored glyph+colored row.**
   *Recommend:* keep ASCII glyphs (no emoji, honors global rule + terminal-safe), but **colorize the whole row by status** (dim idle rows, bright the waiting/busy ones) so state reads at a glance without parsing the glyph. Low risk — color lives in field 13 / fzf only.

2. **Column polish — separators & alignment.**
   *Recommend:* add a subtle column gap / faint vertical separators and right-align CTX%. Keep widths (contract-safe). Consider a unicode light-vertical `│` in dim between columns. Verify width math against all three printfs.

3. **Context% as a visual gauge.**
   *Recommend:* render CTX% as a tiny 4-cell bar (e.g. `▁▃▅▇`/block-eighths) colored green→amber→red by fill, keeping the numeric too if it fits. High polish payoff; must stay within the 4-wide column or widen it in all three printfs.

4. **Palette — keep the current blue/amber or move to a named theme.**
   *Recommend:* keep the existing hex palette (it's coherent) but tighten contrast on dim/idle and align accent to the amber `#ffaf5f` highlight. Optionally expose the palette as vars at the top of the script for future theming. Avoid a full re-theme — scope creep.

5. **Header/legend density.**
   *Recommend:* compress the two legend lines into one, move key hints into the border label or footer, so the list gets more vertical room. Reversible, cosmetic.

6. **Preview pane layout.**
   *Recommend:* group the preview into a small "identity" block + a "state" block with aligned labels and a rule between, and colorize the Status line to match the row. Keep the transcript tail.

7. **Border/pointer/prompt flourishes.**
   *Recommend:* keep rounded border + `▶` pointer; consider a nerd-font-free heavier prompt and a border-label that shows live session count (e.g. ` claude-dash · 12 sessions `). Cheap wins.

## Approach & verification (for tomorrow)

- **Route:** `/gsd:quick --discuss` in dev-env-optimization (dashboard code commits in *this* repo `~/Code/claude-tmux-dashboard`; planning artifacts in dev-env-optimization, per established split).
- **Diff against baseline:** re-render `--list` / `--preview` after each change and compare to `docs/redesign-baseline.txt`. Because it's a TUI, capture ANSI-stripped for structure + eyeball the colored version in a real fzf popup.
- **Regression gate every step:** `bash -n`; assert 13 tab fields per row; confirm f7/f10/f11 and sorts `-k2/-k3/-k6/-k12` still resolve; confirm the three printfs stay width-aligned; confirm read-only (only `claude-dash.sh` changes).
- **Live fixture:** the running fleet (~12 sessions incl. the whispa bg/interactive merge) is the visual test bed — check the merged row, the `z` dormant rows, and a `detached` row all still render cleanly.

## Open question to settle first tomorrow

Terminal/font: is a **nerd font** available in the user's terminal? If yes, unlocks richer glyphs/separators; if not, everything must stay ASCII + box-drawing unicode. *Assume ASCII-safe until confirmed.*
