#!/usr/bin/env bash
# claude-dash.sh — Read-only Claude Code session dashboard
# Opens an fzf popup listing every live Claude session with status, context %, and jump.
# Read-only against all session state. Only mutation: tmux jump on Enter (select+switch-client).
# See PLAN for hard constraints on what this script must not touch.
set -euo pipefail

SESSIONS_DIR="$HOME/.claude/sessions"
PROJECTS_DIR="$HOME/.claude/projects"
NAMES_FILE="$HOME/.claude/.claude-dash-slept"   # sessionId<TAB>tmux-name<TAB>cwd, written on sleep

# ── palette (hoisted for future theming; blue/amber family, NOT a re-theme) ──

# fzf chrome hex scheme (was inline on the --color arg)
HL='#ffaf5f'; FGP='#ffffff'; BGP='#262626'; HLP='#ffd75f'; HDR='#87afaf'
INFO='#6c6c6c'; PTR='#ff5f5f'; PROMPT='#5fafd7'; BORDER='#5f87af'; LABEL='#afd7ff'

# Status/ANSI codes. Row color (C_*_ROW) is non-bold so a full waiting/busy
# row reads brighter than idle without being eye-searing; glyph keeps its own
# bolder hue (see build_row). Idle tuned a touch dimmer than shell for contrast.
C_WAIT=$'\033[1;31m'; C_BUSY=$'\033[1;33m'; C_SHELL=$'\033[1;36m'
C_IDLE=$'\033[2;37m'; C_DIM=$'\033[2m'; C_RESET=$'\033[0m'
C_WAIT_ROW=$'\033[31m'; C_BUSY_ROW=$'\033[33m'; C_SHELL_ROW=$'\033[36m'; C_IDLE_ROW=$'\033[2;37m'

# ── helpers ──────────────────────────────────────────────────────────────────

# Human-friendly elapsed time from epoch seconds.
elapsed_human() {
  local now delta
  now=${_NOW:-$(date +%s)}   # _NOW cached once per enumerate to avoid ~30 date spawns
  delta=$(( now - $1 ))
  if   (( delta < 60 ));    then echo "${delta}s"
  elif (( delta < 3600 ));  then echo "$(( delta / 60 ))m"
  elif (( delta < 86400 )); then echo "$(( delta / 3600 ))h"
  else                           echo "$(( delta / 86400 ))d"
  fi
}

# CTX gauge: raw ctx_pct string ("19%" or "-") → a single color-graded
# box-drawing block char, wrapped in its own color+reset. DISPLAY-ONLY — the
# caller must never feed this into data field 2 (raw ctx_pct stays numeric).
# Bins: <25 green ▁ · 25-50 green/amber ▃ · 50-75 amber ▅ · >75 red ▇ (near
# compaction). Non-numeric ("-", empty) → a single blank (no color), so the
# gauge column still aligns for dormant/no-data rows.
ctx_gauge() {
  local raw="${1:-}" n
  n="${raw%\%}"
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo " "
    return 0
  fi
  if   (( n < 25 )); then echo $'\033[32m'"▁"$'\033[0m'
  elif (( n < 50 )); then echo $'\033[32m'"▃"$'\033[0m'
  elif (( n < 75 )); then echo $'\033[33m'"▅"$'\033[0m'
  else                    echo $'\033[31m'"▇"$'\033[0m'
  fi
}

# status_icon: single source-of-truth glyph mapping (Nerd Fonts v3,
# FontAwesome-legacy codepoints — font confirmed active: JetBrainsMono Nerd
# Font Mono, single-width). Plain glyph only, no color — callers wrap it in
# their own status color. If any codepoint renders as a box on a given
# terminal, swap it for a more common v3 glyph per the inline comment.
status_icon() {
  case "$1" in
    waiting) echo '' ;;  # nf-fa-hourglass, was ASCII "?"
    busy)    echo '' ;;  # nf-fa-play, was ASCII ">"
    shell)   echo '' ;;  # nf-fa-terminal, was ASCII "&"
    idle)    echo '' ;;  # nf-fa-circle, was ASCII "."
    dormant) echo '' ;;  # nf-fa-history, was ASCII "z"
    *)       echo '' ;;  # nf-fa-question, fallback
  esac
}

# Raw model id → short display label. Pure function, single source of truth
# for both the list column and the preview "Model:" line.
model_label() {
  local id="$1"
  case "$id" in
    claude-opus-4-8*)   echo "Opus 4.8" ;;
    claude-opus-4-7*)   echo "Opus 4.7" ;;
    claude-opus-4-6*)   echo "Opus 4.6" ;;
    claude-sonnet-5*)   echo "Sonnet 5" ;;
    claude-sonnet-4-6*) echo "Sonnet 4.6" ;;
    claude-haiku*)      echo "Haiku" ;;
    claude-fable-5*)    echo "Fable 5" ;;
    ""|unknown|-)       echo "?" ;;
    *)
      local rest tok
      rest="${id#claude-}"
      tok="${rest%%-*}"
      echo "${tok:-?}"
      ;;
  esac
}

# MAINCHAIN: last main-chain (non-sidechain) usage record from a transcript.
mainchain_usage_line() {
  local tf="$1"
  [[ -f "$tf" ]] || return 0
  tail -r "$tf" 2>/dev/null \
    | jq -Rc 'fromjson? | select((.message.usage != null) and (.isSidechain != true))' 2>/dev/null \
    | head -1 || true
}

# Resolve a transcript jsonl path for a given cwd + id. Exact match first
# (id == full sessionId, the common case). Falls back to a prefix glob when
# id is a short daemon jobId that is only the LEADING segment of the
# transcript's full UUID filename — confirmed live: bg job jobId "a8e0cf07"
# resolves to transcript "a8e0cf07-cf17-....jsonl", NOT literally
# "a8e0cf07.jsonl" (the socket IS named exactly by the short jobId; the
# transcript filename is not). Echoes the path if found, empty otherwise.
transcript_file() {
  local cwd="$1" id="$2"
  local slug tf cand
  slug="${cwd//\//-}"
  tf="$PROJECTS_DIR/$slug/$id.jsonl"
  if [[ -f "$tf" ]]; then
    echo "$tf"
    return 0
  fi
  cand=$(ls "$PROJECTS_DIR/$slug/$id"*.jsonl 2>/dev/null | head -1) || true
  echo "${cand:-}"
}

# Context % from transcript jsonl. Echoes "<pct>%<TAB><raw-model-id>" (model id
# is the raw id, NOT the label — model_label() maps it downstream).
# Usage: context_pct <cwd> <sessionId>
context_pct() {
  local cwd="$1" sid="$2"
  local tf usage_line model total window pct
  tf=$(transcript_file "$cwd" "$sid")
  if [[ -z "$tf" || ! -f "$tf" ]]; then
    printf '%s\t%s\n' "-" ""
    return 0
  fi
  # Main-chain-only (skips isSidechain subagent lines) — see mainchain_usage_line.
  usage_line=$(mainchain_usage_line "$tf")
  if [[ -z "$usage_line" ]]; then
    printf '%s\t%s\n' "-" ""
    return 0
  fi
  # Context occupancy = prompt tokens (input + cache read + cache creation).
  # output_tokens is the generated reply, not window occupancy at request time.
  IFS=$'\t' read -r model total < <(printf '%s\n' "$usage_line" | jq -r '
    [ (.message.model // "unknown"),
      (.message.usage | ((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0))) ]
    | @tsv' 2>/dev/null)
  if [[ -z "$total" || ! "$total" =~ ^[0-9]+$ ]]; then
    printf '%s\t%s\n' "-" "$model"
    return 0
  fi
  # The transcript records no context-window size, so infer it from the model.
  # Current-generation Claude models all have a 1M-token window natively (Opus
  # 4.5-4.8, Sonnet 4.5/4.6/5, Fable/Mythos 5); only Haiku and legacy 3.x/2.x
  # models are 200k. So default to 1M and treat 200k as the exception.
  # CLAUDE_DASH_200K_MODEL_RE overrides the 200k-model regex. The <=200k guard is
  # a safety net — a session over 200k tokens is by definition on a 1M window.
  window=1000000
  if (( total <= 200000 )) && [[ "$model" =~ ${CLAUDE_DASH_200K_MODEL_RE:-haiku|claude-3|claude-2|claude-instant} ]]; then
    window=200000
  fi
  pct=$(( total * 100 / window ))
  (( pct > 99 )) && pct=99
  printf '%s\t%s\n' "${pct}%" "$model"
}

# Mtime of transcript jsonl in epoch seconds (fall back to 0).
transcript_mtime() {
  local cwd="$1" sid="$2"
  local tf result
  tf=$(transcript_file "$cwd" "$sid")
  if [[ -n "$tf" && -f "$tf" ]]; then
    result=$(stat -f %m "$tf" 2>/dev/null || true)
    echo "${result:-0}"
  else
    echo "0"
  fi
}

# Look up a tty in the pane-map temp file.
# Prints "sess|win|pane" or "" if not found.
pane_lookup() {
  local tty="$1" mapfile="$2"
  awk -F'|' -v key="$tty" '$1==key {print $2"|"$3"|"$4; exit}' "$mapfile"
}

# bg_instance: given a bg job's jobId (jq `.jobId` from the session json —
# the sessionId has been observed to diverge from the jobId on current CC
# builds, so it is NOT derived from the sessionId), return the daemon <inst>
# dir name that owns its pty/rv socket. Both pty (active job) and rv (spare)
# subdirs are globbed so a spare's socket is still discoverable.
# /tmp/cc-daemon-$(id -u)/<inst>/{pty,rv}/<jobId>.sock. Returns "" if none
# found. Relies on nullglob already being set by the caller.
bg_instance() {
  local sock
  for sock in /tmp/cc-daemon-"$(id -u)"/*/pty/"$1".sock /tmp/cc-daemon-"$(id -u)"/*/rv/"$1".sock; do
    sock="${sock%/pty/*}"
    sock="${sock%/rv/*}"
    echo "${sock##*/}"
    return 0
  done
}

# build_row emits exactly the 13-field tab row:
#   1=glyph_disp 2=ctx_pct 3=proj 4=tmux_target 5=act_str 6=sortkey
#   7=jump_target 8=waiting_for 9=pid 10=cwd 11=sid 12=act_epoch 13=display
# Merged and single rows BOTH go through here — single source of the field
# contract. args: sid cwd pid status waiting_for updated_at tmux_target jump_target [xscript_id]
# xscript_id (9th arg, optional) is the id used to resolve the transcript
# jsonl for context%/mtime — defaults to sid. bg rows pass the daemon jobId
# here (transcript is jobId-named), while field 11 (sid) always stays the
# REAL resumable sessionId regardless of xscript_id.
build_row() {
  local sid="$1" cwd="$2" pid="$3" sess_status="$4" waiting_for="$5" updated_at="$6" tmux_target="$7" jump_target="$8"
  local xscript_id="${9:-$sid}"

  # Status glyph (Nerd Font icon via status_icon, single source of truth) +
  # sort key + color. rowcolor tints the WHOLE display row (D-ROWCOLOR):
  # active states brighter, idle dimmer; glyph keeps its own (bolder) hue
  # via gcolor — the icon inherits the status hue.
  local statkey glyph sortkey gcolor rowcolor
  case "$sess_status" in
    waiting) statkey="waiting" ; sortkey=0 ; gcolor="$C_WAIT"  ; rowcolor="$C_WAIT_ROW"  ;;
    busy)    statkey="busy"    ; sortkey=1 ; gcolor="$C_BUSY"  ; rowcolor="$C_BUSY_ROW"  ;;
    shell)   statkey="shell"   ; sortkey=2 ; gcolor="$C_SHELL" ; rowcolor="$C_SHELL_ROW" ;;  # live, has a background shell
    idle)    statkey="idle"    ; sortkey=3 ; gcolor="$C_IDLE"  ; rowcolor="$C_IDLE_ROW"  ;;
    *)       statkey=""        ; sortkey=4 ; gcolor="$C_RESET" ; rowcolor=""             ;;
  esac
  glyph=$(status_icon "$statkey")
  local glyph_disp="${gcolor}${glyph}"$'\033[0m'

  # Context % + model label
  local ctx_pct model_id model_lbl
  IFS=$'\t' read -r ctx_pct model_id < <(context_pct "$cwd" "$xscript_id" || true)
  ctx_pct="${ctx_pct:--}"
  model_lbl=$(model_label "$model_id")

  # Last activity: prefer transcript mtime, fall back to updatedAt epoch ms
  local tmtime act_epoch act_str
  tmtime=$(transcript_mtime "$cwd" "$xscript_id" || true)
  tmtime="${tmtime:-0}"
  if [[ "$tmtime" != "0" ]]; then
    act_epoch="$tmtime"
  else
    act_epoch=$(( updated_at / 1000 ))
  fi
  act_str=$(elapsed_human "$act_epoch" || true)
  act_str="${act_str:-?}"

  # Project basename (parameter expansion — no subshell)
  local proj="${cwd:-unknown}"
  proj="${proj##*/}"

  # Padded display column (field 13). NO ANSI inside disp itself — ANSI
  # corrupts %-Ns width math. Dim │ separators between MODEL|PROJECT,
  # PROJECT|TARGET, TARGET|LAST are plain chars (1 col each, printf-safe).
  # ANSI (gauge + row color) is composed OUTSIDE disp, same pattern as glyph.
  local disp
  printf -v disp '%-4s %-10.10s │ %-20.20s │ %-20.20s │ %-4s' \
    "$ctx_pct" "$model_lbl" "$proj" "$tmux_target" "$act_str"

  # CTX gauge token (display-only, field 13; ctx_pct in field 2 stays raw).
  local gauge_tok
  gauge_tok=$(ctx_gauge "$ctx_pct")
  local disp_colored="${rowcolor}${disp}${C_RESET}"

  # Data fields 1-12 (sort/jump/preview, unchanged) + display field 13.
  # field 13 = "<glyph_disp> <gauge_tok> <rowcolor><disp><reset>" — added a
  # space between gauge_tok and disp (was cramped as "▁14%"; now "▁ 14%").
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s %s %s\n' \
    "$glyph_disp" "$ctx_pct" "$proj" "$tmux_target" "$act_str" "$sortkey" \
    "$jump_target" "$waiting_for" "$pid" "$cwd" "$sid" "$act_epoch" "$glyph_disp" "$gauge_tok" "$disp_colored"
}

# ── build tty→pane map ───────────────────────────────────────────────────────
# Written to a temp file: one line per pane:
#   stripped_tty|sess|win|pane|path|cmd

TTY_MAP_FILE=$(mktemp /tmp/claude-dash-ttymap.XXXXXX)
trap 'rm -f "$TTY_MAP_FILE"' EXIT

if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
  tmux list-panes -a \
    -F '#{pane_tty}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_path}|#{pane_current_command}' \
    2>/dev/null \
  | while IFS='|' read -r ptty sess win pane path cmd; do
      key="${ptty##*/}"
      printf '%s|%s|%s|%s|%s|%s\n' "$key" "$sess" "$win" "$pane" "$path" "$cmd"
    done > "$TTY_MAP_FILE" || true
fi

# ── enumerate sessions ────────────────────────────────────────────────────────

enumerate_sessions() {
  local mode="${1:-status}"
  local rows="" row live_sids=""
  _NOW=$(date +%s)
  shopt -s nullglob

  # Daemon instance dirs, computed once. Today there is a single instance —
  # correlation for interactive records degrades to cwd-grouping when exactly
  # one instance dir exists (see correlation_assumption in PLAN).
  local -a INSTANCE_DIRS=()
  local _d
  for _d in /tmp/cc-daemon-"$(id -u)"/*/; do
    _d="${_d%/}"
    INSTANCE_DIRS+=("${_d##*/}")
  done

  # PASS 1: collect surviving, non-spare records into an array. Nothing is
  # emitted here — DAEMON-MERGE (below) decides how records become rows.
  local -a records=()

  for f in "$SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue

    # Parse all fields in one jq call, including daemon `kind` (defaults to
    # "interactive" for pre-daemon session json that predates this field).
    local fields
    fields=$(jq -r '[.pid//"", (.status//"idle"), (.waitingFor//"-"), (.cwd//""), (.sessionId//""), (.updatedAt//0), (.kind // "interactive"), (.jobId // "")] | @tsv' "$f" 2>/dev/null) || continue

    local pid sess_status waiting_for cwd sid updated_at kind jobid
    IFS=$'\t' read -r pid sess_status waiting_for cwd sid updated_at kind jobid <<< "$fields"

    [[ -z "$pid" ]] && continue

    # Dead-pid filter — stale files persist after pid dies
    ps -p "$pid" -o pid= >/dev/null 2>&1 || continue
    live_sids="${live_sids}${sid}"$'\n'

    # SPARE-FILTER: primary signal is `--bg-spare` on the process cmdline.
    # The ~232B stub session json (no usage lines) and the `rv/<id>.sock`
    # under the daemon instance dir are corroborating signals only — the
    # cmdline check is authoritative and runs first, before any kind-based
    # grouping, since a spare proc's session json can carry kind=bg too.
    local cmdline
    cmdline=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmdline" == *--bg-spare* ]] && continue

    # Resolve tty → pane via temp mapfile
    local raw_tty tty pane_info jump_target tmux_target
    raw_tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ') || raw_tty=""
    tty="${raw_tty##*/}"
    pane_info=$(pane_lookup "$tty" "$TTY_MAP_FILE")

    if [[ -n "$pane_info" ]]; then
      local p_sess p_win p_pane
      IFS='|' read -r p_sess p_win p_pane <<< "$pane_info"
      tmux_target="$p_sess:$p_win.$p_pane"
      jump_target="$p_sess|$p_win|$p_pane"
    else
      tmux_target="-"
      jump_target="-"
    fi

    # Instance correlation (see .kind read + correlation_assumption).
    local instance
    if [[ "$kind" == "bg" ]]; then
      instance=$(bg_instance "$jobid")
    else
      # Interactive session json carries no instance/daemon-id field in
      # 2.1.202 (confirmed against a live interactive record) — fall back
      # to the sole instance dir when exactly one exists.
      if [[ "${#INSTANCE_DIRS[@]}" -eq 1 ]]; then
        instance="${INSTANCE_DIRS[0]}"
      else
        instance=""
      fi
    fi
    # NEVER let a tab-delimited record field be empty: IFS=$'\t' `read`
    # collapses RUNS of tab (an IFS-whitespace char) exactly like it collapses
    # runs of space, so two adjacent tabs (an empty field) silently swallow a
    # column and shift every field after it. "-" is this script's existing
    # placeholder for "no value" (see tmux_target/jump_target above).
    instance="${instance:--}"

    records+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$kind" "$sid" "$pid" "$cwd" "$instance" "$sess_status" "$waiting_for" "$updated_at" "$tmux_target" "$jump_target" "$jobid")")
  done

  # DAEMON-MERGE: correlate bg jobs with interactive clients into ONE logical
  # row when they share the same daemon instance + cwd (correlation_assumption
  # in PLAN). bash 3.2 (macOS default, no associative arrays) — parse each
  # tab-record once into parallel indexed arrays, then correlate by linear
  # scan. The fleet this runs against is a handful of sessions, so O(n^2) is
  # cheap and keeps this bash-3.2-safe without reaching for `declare -A`.
  local -a R_KIND=() R_SID=() R_PID=() R_CWD=() R_INSTANCE=() R_STATUS=() R_WAITING=() R_UPDATED=() R_TMUX=() R_JUMP=() R_JOBID=()
  local rec rk rsid rpid rcwd rinstance rstatus rwaiting rupdated rtmux rjump rjobid
  for rec in "${records[@]}"; do
    IFS=$'\t' read -r rk rsid rpid rcwd rinstance rstatus rwaiting rupdated rtmux rjump rjobid <<< "$rec"
    R_KIND+=("$rk"); R_SID+=("$rsid"); R_PID+=("$rpid"); R_CWD+=("$rcwd")
    R_INSTANCE+=("$rinstance"); R_STATUS+=("$rstatus"); R_WAITING+=("$rwaiting")
    R_UPDATED+=("$rupdated"); R_TMUX+=("$rtmux"); R_JUMP+=("$rjump"); R_JOBID+=("$rjobid")
  done

  local n=${#R_KIND[@]}
  local consumed_interactive="|"   # pipe-delimited set of consumed record indices
  local bi ij sj

  for (( bi=0; bi<n; bi++ )); do
    [[ "${R_KIND[$bi]}" == "bg" ]] || continue
    local bg_key="${R_INSTANCE[$bi]}|${R_CWD[$bi]}"

    # ≥2 bg jobs sharing the same instance+cwd cannot be uniquely paired with
    # a single interactive client — emit each separately rather than mis-pair
    # (correlation_assumption edge case).
    local bg_sibling_count=0
    for (( sj=0; sj<n; sj++ )); do
      [[ "${R_KIND[$sj]}" == "bg" && "${R_INSTANCE[$sj]}|${R_CWD[$sj]}" == "$bg_key" ]] && bg_sibling_count=$((bg_sibling_count+1))
    done

    local match_ij=-1 match_count=0
    for (( ij=0; ij<n; ij++ )); do
      [[ "${R_KIND[$ij]}" == "interactive" ]] || continue
      [[ "${R_INSTANCE[$ij]}|${R_CWD[$ij]}" == "$bg_key" ]] || continue
      case "$consumed_interactive" in *"|${ij}|"*) continue ;; esac
      match_count=$((match_count+1))
      match_ij=$ij
    done

    if [[ "$bg_sibling_count" -eq 1 && "$match_count" -eq 1 ]]; then
      # MERGE: bg job has identity/status/model/context authority; the
      # interactive client contributes the tmux pane it owns (Enter jumps
      # there, since only the interactive client has a controlling tty).
      row=$(build_row "${R_SID[$bi]}" "${R_CWD[$bi]}" "${R_PID[$bi]}" "${R_STATUS[$bi]}" \
                       "${R_WAITING[$bi]}" "${R_UPDATED[$bi]}" "${R_TMUX[$match_ij]}" "${R_JUMP[$match_ij]}" \
                       "${R_JOBID[$bi]}")
      consumed_interactive="${consumed_interactive}${match_ij}|"
    else
      # No interactive partner, or ambiguous (≥2 bg siblings) → standalone,
      # non-jumpable row. A bg job has no controlling tty of its own.
      row=$(build_row "${R_SID[$bi]}" "${R_CWD[$bi]}" "${R_PID[$bi]}" "${R_STATUS[$bi]}" \
                       "${R_WAITING[$bi]}" "${R_UPDATED[$bi]}" "detached" "-" \
                       "${R_JOBID[$bi]}")
    fi
    rows="${rows}${row}
"
  done

  # Every UNCONSUMED interactive record is a plain single row — unchanged
  # behavior for interactive sessions with no bg job.
  for (( ij=0; ij<n; ij++ )); do
    [[ "${R_KIND[$ij]}" == "interactive" ]] || continue
    case "$consumed_interactive" in *"|${ij}|"*) continue ;; esac
    row=$(build_row "${R_SID[$ij]}" "${R_CWD[$ij]}" "${R_PID[$ij]}" "${R_STATUS[$ij]}" \
                     "${R_WAITING[$ij]}" "${R_UPDATED[$ij]}" "${R_TMUX[$ij]}" "${R_JUMP[$ij]}")
    rows="${rows}${row}
"
  done

  # Dormant (resumable) = sessions YOU slept via x (recorded in NAMES_FILE) that
  # aren't currently live. Not a scan of every old transcript — just your parked
  # sessions. Keyed by exact sessionId; resume targets that precise conversation.
  if [[ -f "$NAMES_FILE" ]]; then
    local seen="" dcount=0 nsid nname ncwd nslug ntf nmt ndact nzdisp
    while IFS=$'\t' read -r nsid nname ncwd; do
      [[ -n "$nsid" && -n "$ncwd" ]] || continue
      case "$seen" in *"|${nsid}|"*) continue ;; esac   # newest entry per sid wins
      seen="${seen}|${nsid}|"
      printf '%s' "$live_sids" | grep -qxF "$nsid" && continue   # resumed/live now → skip
      nslug="${ncwd//\//-}"
      ntf="$PROJECTS_DIR/$nslug/$nsid.jsonl"
      [[ -f "$ntf" ]] || continue                        # transcript gone → can't resume
      nmt=$(stat -f %m "$ntf" 2>/dev/null || echo 0)
      ndact=$(elapsed_human "$nmt" 2>/dev/null || echo "-")
      [[ -n "$nname" ]] || nname="${ncwd##*/}"
      # Matching gauge-prefix + separators + row-dim as the live disp/rowcolor
      # composition — ctx_gauge "-" returns a blank placeholder (no ANSI) so
      # the gauge column still aligns. Icon uses the shared status_icon()
      # source of truth, dim-wrapped (C_IDLE_ROW) so the resume icon carries
      # the same dim hue as the rest of the dormant row.
      local nzgauge nzdisp_colored nzglyph
      nzgauge=$(ctx_gauge "-")
      nzglyph="${C_IDLE_ROW}$(status_icon dormant)${C_RESET}"
      printf -v nzdisp '%-4s %-10.10s │ %-20.20s │ %-20.20s │ %-4s' "-" "-" "$nname" "(resume)" "$ndact"
      nzdisp_colored="${C_IDLE_ROW}${nzdisp}${C_RESET}"
      rows="${rows}${nzglyph}	-	${nname}	(resume)	${ndact}	5	RESUME|${nsid}|${ncwd}	-	-	${ncwd}	${nsid}	${nmt}	${nzglyph} ${nzgauge} ${nzdisp_colored}
"
      dcount=$((dcount+1)); [[ $dcount -ge 20 ]] && break
    done < <(tail -r "$NAMES_FILE" 2>/dev/null)          # newest first
  fi

  # Sort mode (strip trailing blank line first). Default = status priority
  # (col 6 asc: waiting first) then most-recent activity (col 12 epoch desc).
  local sortargs
  case "$mode" in
    ctx)      sortargs="-k2,2rn" ;;          # context % desc (field 2; sort -n reads the leading number)
    activity) sortargs="-k12,12rn" ;;        # most-recent activity first (epoch field 12)
    project)  sortargs="-k3,3" ;;            # project name A-Z (field 3)
    *)        sortargs="-k6,6n -k12,12rn" ;; # status priority then recent (default)
  esac
  printf '%s' "$rows" | grep -v '^$' | sort -t$'\t' $sortargs
}

# ── preview helper ────────────────────────────────────────────────────────────

preview_session() {
  local line="$1"
  local glyph ctx proj target lastact sortkey jump waiting pid cwd sid
  IFS=$'\t' read -r glyph ctx proj target lastact sortkey jump waiting pid cwd sid actepoch <<< "$line"

  # status_color matches the row's status hue (D-PREVIEW: color-matched Status line).
  local status_word glyph_plain status_color
  case "$sortkey" in
    0) status_word="waiting" ; glyph_plain="?" ; status_color="$C_WAIT"  ;;
    1) status_word="busy"    ; glyph_plain=">" ; status_color="$C_BUSY"  ;;
    2) status_word="bg-shell (live, has a background shell)" ; glyph_plain="&" ; status_color="$C_SHELL" ;;
    3) status_word="idle"    ; glyph_plain="." ; status_color="$C_IDLE"  ;;
    5) status_word="dormant — press Enter to resume (claude --resume)" ; glyph_plain="z" ; status_color="$C_DIM"  ;;
    *) status_word="unknown" ; glyph_plain="?" ; status_color="$C_RESET" ;;
  esac

  local slug tf model_id preview_usage_line
  slug="${cwd//\//-}"
  tf=$(transcript_file "$cwd" "$sid")

  # DAEMON-MERGE enrichment: field 11 (sid) / field 9 (pid) on a merged row
  # are the BG job's own — surface its daemon job name (session json is keyed
  # by pid, not sid). No field-count change; read-only lookup. Also read
  # .jobId here: bg rows resolve their transcript by jobId (socket + jsonl
  # are jobId-prefixed, not sessionId-named — sessionId can diverge from
  # jobId on current CC builds), so recompute tf BEFORE the model-id read.
  local job_name="" job_kind="" job_id=""
  if [[ -f "$SESSIONS_DIR/$pid.json" ]]; then
    IFS=$'\t' read -r job_name job_kind job_id < <(jq -r '[(.name // ""), (.kind // ""), (.jobId // "")] | @tsv' "$SESSIONS_DIR/$pid.json" 2>/dev/null)
    [[ "$job_kind" == "bg" ]] || job_name=""
  fi
  if [[ "$job_kind" == "bg" && -n "$job_id" ]]; then
    tf=$(transcript_file "$cwd" "$job_id")
  fi

  model_id=""
  if [[ -f "$tf" ]]; then
    preview_usage_line=$(mainchain_usage_line "$tf")
    if [[ -n "$preview_usage_line" ]]; then
      model_id=$(printf '%s\n' "$preview_usage_line" | jq -r '.message.model // ""' 2>/dev/null)
    fi
  fi

  # D-PREVIEW: grouped identity / state blocks, rules between, color-matched
  # Status line. Same data reads/lookups as before — labels only reorganized.
  local rule
  rule=$'\033[2m'"────────────────────"$'\033[0m'

  echo "Session:    $sid"
  [[ -n "$job_name" ]] && echo "Job:        $job_name"
  echo "$rule"
  echo "Status:     ${status_color}${glyph_plain} ${status_word}${C_RESET}"
  echo "WaitingFor: $waiting"
  echo "Context:    $ctx"
  echo "Model:      $(model_label "$model_id")"
  echo "Pane:       $target"
  echo "LastAct:    $lastact"
  echo "CWD:        $cwd"
  echo "PID:        $pid"
  echo "$rule"

  if [[ -f "$tf" ]]; then
    echo "── transcript tail ──"
    tail -r "$tf" 2>/dev/null | head -30 | jq -r '
      if .type then
        "\(.role // .type): \(.message.content // .content // "" | if type=="array" then (.[0].text // "") else . end | .[0:200])"
      else empty end
    ' 2>/dev/null | head -12 || true
  fi
}

# Sleep/quit a live session: kill its tmux session (frees the RAM; the
# conversation persists and reappears as a dormant 'z' row, resumable).
# Prints a one-line status used as the fzf border label (instant feedback).
# No-op (with an explanatory label) on dormant rows, unmapped rows, and on the
# session the dashboard itself is attached to.
kill_session() {
  local line="$1" jump sess cur sid cwd
  jump=$(printf '%s' "$line" | cut -f7)
  if [[ "$jump" == RESUME\|* ]]; then printf ' z row — press Enter to resume (x only sleeps live) '; return 0; fi
  if [[ "$jump" == "-" || -z "$jump" ]]; then printf ' no tmux pane — nothing to sleep '; return 0; fi
  IFS='|' read -r sess _ _ <<< "$jump"
  [[ -z "$sess" ]] && { printf ' nothing to sleep '; return 0; }
  cur=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
  if [[ -n "$cur" && "$sess" == "$cur" ]]; then printf ' cannot sleep the current session (%s) ' "$sess"; return 0; fi
  if tmux kill-session -t "$sess" 2>/dev/null; then
    # Record sessionId -> tmux name -> cwd: the dormant 'z' list is built from this.
    sid=$(printf '%s' "$line" | cut -f11)
    cwd=$(printf '%s' "$line" | cut -f10)
    [[ -n "$sid" ]] && printf '%s\t%s\t%s\n' "$sid" "$sess" "$cwd" >> "$NAMES_FILE" 2>/dev/null
    printf ' slept: %s (now a z row) ' "$sess"
  else printf ' could not sleep %s ' "$sess"; fi
}

# ── main ──────────────────────────────────────────────────────────────────────

export -f elapsed_human ctx_gauge context_pct model_label mainchain_usage_line transcript_file transcript_mtime pane_lookup bg_instance build_row preview_session enumerate_sessions kill_session
export SESSIONS_DIR PROJECTS_DIR TTY_MAP_FILE

if [[ "${1:-}" == "--list" ]]; then
  enumerate_sessions "${2:-status}"
  exit 0
fi

if [[ "${1:-}" == "--preview" ]]; then
  preview_session "${2:-}"
  exit 0
fi

if [[ "${1:-}" == "--kill" ]]; then
  kill_session "${2:-}"
  exit 0
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Column header padded to the same widths as the display field (see enumerate).
# Leading %-4s accounts for the field-13 prefix: glyph(1)+space(1)+gauge(1)+space(1)
# — the gauge now has a separating space before the CTX% number (reads "▁ 19%"
# per D-GAUGE), hence 4 not 3 cols.
# │ separators mirror disp/nzdisp exactly (between MODEL|PROJECT, PROJECT|TARGET, TARGET|LAST).
printf -v COLHDR '%-4s%-4s %-10s │ %-20s │ %-20s │ %s' '' 'CTX%' 'MODEL' 'PROJECT' 'TARGET' 'LAST'
# D-CHROME.2: one-line legend (glyph key only) + COLHDR. Sort/key hints moved
# to --prompt below, freeing the second legend line.
HEADER=$'\033[1;31m?\033[0m wait   \033[1;33m>\033[0m busy   \033[1;36m&\033[0m bg-shell   \033[2;37m.\033[0m idle   \033[2;37mz\033[0m resume\n'$'\033[2m'"${COLHDR}"$'\033[0m'

# D-CHROME.1: live (non-dormant) session count for the border label. Sort key
# (field 6) != 5 means not-dormant. Reload (r/s/c/t/p/x binds) doesn't re-fire
# the label — it stays at this initial count, matching fzf's reload semantics.
live_count=$(enumerate_sessions status | awk -F'\t' '$6!=5' | wc -l | tr -d ' ')

# fzf pipeline — Enter accepts and returns the selected line; jump happens
# AFTER fzf exits / the popup closes (switch-client inside an open popup is flaky).
sel=$(
  enumerate_sessions \
    | fzf \
        --ansi \
        --layout=reverse \
        --no-sort \
        --delimiter=$'\t' \
        --with-nth=13 \
        --nth=13 \
        --border=rounded \
        --border-label=" claude-dash · ${live_count} sessions " \
        --border-label-pos=2 \
        --color="fg:-1,bg:-1,hl:${HL},fg+:${FGP},bg+:${BGP},hl+:${HLP},header:${HDR},info:${INFO},pointer:${PTR},prompt:${PROMPT},border:${BORDER},label:${LABEL},gutter:-1" \
        --pointer='▶' \
        --prompt='[s/c/t/p·x] filter ▸ ' \
        --info=inline \
        --header="$HEADER" \
        --preview="\"$SCRIPT_PATH\" --preview {}" \
        --preview-window=right:45%:wrap:border-left \
        --bind "r:reload(\"$SCRIPT_PATH\" --list status)" \
        --bind "s:reload(\"$SCRIPT_PATH\" --list status)" \
        --bind "c:reload(\"$SCRIPT_PATH\" --list ctx)" \
        --bind "t:reload(\"$SCRIPT_PATH\" --list activity)" \
        --bind "p:reload(\"$SCRIPT_PATH\" --list project)" \
        --bind "x:transform-border-label(\"$SCRIPT_PATH\" --kill {})+reload(\"$SCRIPT_PATH\" --list status)"
) || exit 0

[[ -z "$sel" ]] && exit 0

jump=$(printf '%s' "$sel" | cut -f7)

# Dormant row → resume THIS exact conversation (claude --resume <sessionId>) in a
# fresh tmux session at its cwd. Never --continue (which grabs the cwd's most-recent).
if [[ "$jump" == RESUME\|* ]]; then
  IFS='|' read -r _ r_sid r_cwd <<< "$jump"
  r_name=$(printf '%s' "$sel" | cut -f3)   # PROJECT col = original tmux name (if recorded) else cwd basename
  [[ -n "$r_name" ]] || r_name="${r_cwd##*/}"
  if tmux has-session -t "$r_name" 2>/dev/null; then r_name="${r_name}-${r_sid:0:6}"; fi
  tmux new-session -d -s "$r_name" -c "$r_cwd" -n claude
  tmux send-keys -t "$r_name:claude" "claude --resume $r_sid" C-m
  exec tmux switch-client -t "$r_name"
fi

[[ "$jump" == "-" || -z "$jump" ]] && { echo "no tmux pane for this session" >&2; exit 0; }

IFS='|' read -r j_sess j_win j_pane <<< "$jump"
tmux select-window -t "$j_sess:$j_win" \; \
     select-pane -t "$j_sess:$j_win.$j_pane" \; \
     switch-client -t "$j_sess"
