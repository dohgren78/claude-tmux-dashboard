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
      # DEGRADATION MARKERS: the MERGE condition failed. Distinguish three
      # outcomes so future daemon-layout breakage is VISIBLE instead of
      # masquerading as a normal detach (the f5v/un0 regression class was
      # invisible until the user noticed a row "going nowhere"). Field 7
      # (jump_target) stays "-" for all three — a bg job never has its own
      # controlling tty, so Enter safely no-ops regardless of marker.
      local target
      if [[ "$bg_sibling_count" -ge 2 ]]; then
        # 1. AMBIGUOUS: ≥2 bg jobs share instance+cwd — cannot uniquely pair
        # with a single interactive client. Label instead of silently
        # emitting separate detached rows.
        target="ambiguous?"
      else
        # sibling==1, no unique interactive match. Distinguish "identity
        # failed to resolve" (unlinked?) from "identity resolved fine,
        # legitimately no interactive client" (detached) by checking the
        # same signals the merge itself depends on: instance dir, jobId,
        # transcript, socket.
        local xtf sock_found=""
        xtf=$(transcript_file "${R_CWD[$bi]}" "${R_JOBID[$bi]}")
        for _s in /tmp/cc-daemon-"$(id -u)"/*/pty/"${R_JOBID[$bi]}"*.sock; do [[ -e "$_s" ]] && sock_found=1 && break; done
        if [[ "${R_INSTANCE[$bi]}" == "-" || -z "${R_JOBID[$bi]}" || -z "$xtf" || -z "$sock_found" ]]; then
          # 2. UNLINKED: daemon identity failed to resolve — the regression
          # class this marker exists to surface (broken socket/transcript
          # naming assumptions, missing instance dir, etc).
          target="unlinked?"
        else
          # 3. DETACHED: identity resolved fine, this bg job simply has no
          # interactive client right now — expected, legitimate, fine.
          target="detached"
        fi
      fi
      row=$(build_row "${R_SID[$bi]}" "${R_CWD[$bi]}" "${R_PID[$bi]}" "${R_STATUS[$bi]}" \
                       "${R_WAITING[$bi]}" "${R_UPDATED[$bi]}" "$target" "-" \
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

  # status_color matches the row's status hue (D-PREVIEW: color-matched Status
  # line). glyph_plain uses the same status_icon() source of truth as the
  # list row, so the preview Status line mirrors the list icon exactly.
  local status_word glyph_plain status_color
  case "$sortkey" in
    0) status_word="waiting" ; glyph_plain=$(status_icon waiting) ; status_color="$C_WAIT"  ;;
    1) status_word="busy"    ; glyph_plain=$(status_icon busy)    ; status_color="$C_BUSY"  ;;
    2) status_word="bg-shell (live, has a background shell)" ; glyph_plain=$(status_icon shell) ; status_color="$C_SHELL" ;;
    3) status_word="idle"    ; glyph_plain=$(status_icon idle)    ; status_color="$C_IDLE"  ;;
    5) status_word="dormant — press Enter to resume (claude --resume)" ; glyph_plain=$(status_icon dormant) ; status_color="$C_DIM"  ;;
    *) status_word="unknown" ; glyph_plain=$(status_icon)         ; status_color="$C_RESET" ;;
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
    # Newest-first, last ~12 REAL user/assistant text messages. Confirmed
    # entry shapes: type=="user" content is a string OR an array whose
    # blocks may be tool_result (no text, skipped); type=="assistant"
    # content is an array whose first text block may follow thinking/
    # tool_use blocks. Junk entries (message==null: attachment,
    # custom-title, file-history-snapshot, last-prompt, mode,
    # permission-mode, system) are filtered by the type select. head -12
    # closes the pipe early (SIGPIPE upstream), so this avoids a full-file
    # forward scan despite no line-count pre-limit.
    tail -r "$tf" 2>/dev/null | jq -r '
      select(.type=="user" or .type=="assistant")
      | .message.content as $c
      | ( if   ($c|type)=="string" then $c
          elif ($c|type)=="array"  then ([ $c[] | select(.type=="text") | .text ] | first)
          else empty end ) as $t
      | select($t != null and ($t|type=="string") and ($t|length) > 0)
      | "\(.type): \($t[0:200])"
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

# doctor_check: READ-ONLY diagnostic against the LIVE session set. Mirrors
# enumerate PASS-1 liveness logic (pid alive via `ps -p`, skip --bg-spare on
# cmdline). Never mutates anything (no tmux new/kill/send-keys, no writes
# beyond the pre-existing TTY_MAP_FILE the top-level pane-map build already
# created). Prints one line per check plus a `PASS:n WARN:n FAIL:n` summary.
doctor_check() {
  local GRN=$'\033[1;32m'
  local pass_n=0 warn_n=0 fail_n=0
  _pass() { pass_n=$((pass_n+1)); printf '%s✓%s %s\n' "$GRN" "$C_RESET" "$1"; }
  _warn() { warn_n=$((warn_n+1)); printf '%s!%s %s\n' "$C_BUSY" "$C_RESET" "$1"; }
  _fail() { fail_n=$((fail_n+1)); printf '%s✗%s %s\n' "$C_WAIT" "$C_RESET" "$1"; }

  echo "── claude-dash --doctor (read-only) ──"
  shopt -s nullglob

  # Collect live, non-spare records — same PASS-1 filter as enumerate_sessions.
  local -a D_KIND=() D_SID=() D_PID=() D_CWD=() D_JOBID=() D_JSON=()
  local f fields pid sess_status waiting_for cwd sid updated_at kind jobid cmdline
  for f in "$SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    fields=$(jq -r '[.pid//"", (.status//"idle"), (.waitingFor//"-"), (.cwd//""), (.sessionId//""), (.updatedAt//0), (.kind // "interactive"), (.jobId // "")] | @tsv' "$f" 2>/dev/null) || continue
    IFS=$'\t' read -r pid sess_status waiting_for cwd sid updated_at kind jobid <<< "$fields"
    [[ -z "$pid" ]] && continue
    ps -p "$pid" -o pid= >/dev/null 2>&1 || continue
    cmdline=$(ps -o command= -p "$pid" 2>/dev/null || true)
    [[ "$cmdline" == *--bg-spare* ]] && continue
    D_KIND+=("$kind"); D_SID+=("$sid"); D_PID+=("$pid"); D_CWD+=("$cwd"); D_JOBID+=("$jobid"); D_JSON+=("$f")
  done

  # 1. CC version — read off a live session json; fall back to `claude --version`.
  local cc_version=""
  if [[ ${#D_JSON[@]} -gt 0 ]]; then
    cc_version=$(jq -r '.version // empty' "${D_JSON[0]}" 2>/dev/null) || true
  fi
  [[ -z "$cc_version" ]] && { cc_version=$(claude --version 2>/dev/null | head -1) || true; }
  if [[ -n "$cc_version" ]]; then
    _pass "CC version: $cc_version (assumptions validated against 2.1.202)"
  else
    _warn "CC version: could not determine (assumptions validated against 2.1.202)"
  fi

  # 2. Daemon instance dir(s) — exactly 1 expected; >1 ambiguates the
  # interactive->bg instance fallback used by DAEMON-MERGE.
  local -a inst_dirs=()
  local _d
  for _d in /tmp/cc-daemon-"$(id -u)"/*/; do
    _d="${_d%/}"
    inst_dirs+=("${_d##*/}")
  done
  if [[ ${#inst_dirs[@]} -eq 1 ]]; then
    _pass "Daemon instance dir(s): 1 (${inst_dirs[0]})"
  else
    _warn "Daemon instance dir(s): ${#inst_dirs[@]} (0 = no daemon running; >1 ambiguates interactive->bg fallback correlation)"
  fi

  # 3. Per live kind==bg: jobId present? socket resolvable? transcript resolvable?
  local i any_bg=0
  for (( i=0; i<${#D_KIND[@]}; i++ )); do
    [[ "${D_KIND[$i]}" == "bg" ]] || continue
    any_bg=1
    local bjob="${D_JOBID[$i]}" bcwd="${D_CWD[$i]}" bmiss=""
    if [[ -z "$bjob" ]]; then
      _fail "bg pid ${D_PID[$i]}: jobId MISSING"
      continue
    fi
    local bsock="" _s
    for _s in /tmp/cc-daemon-"$(id -u)"/*/pty/"$bjob"*.sock; do [[ -e "$_s" ]] && bsock=1 && break; done
    [[ -z "$bsock" ]] && bmiss="socket"
    local btf
    btf=$(transcript_file "$bcwd" "$bjob")
    [[ -z "$btf" ]] && bmiss="${bmiss:+$bmiss, }transcript"
    if [[ -n "$bmiss" ]]; then
      _fail "bg $bjob: $bmiss MISSING"
    else
      _pass "bg $bjob: jobId + socket + transcript resolved"
    fi
  done
  [[ "$any_bg" -eq 0 ]] && _pass "bg jobs: none live (nothing to check)"

  # 4. Per live kind==interactive: tty resolvable to a tmux pane?
  local any_ia=0
  for (( i=0; i<${#D_KIND[@]}; i++ )); do
    [[ "${D_KIND[$i]}" == "interactive" ]] || continue
    any_ia=1
    local raw_tty tty pane_info
    raw_tty=$(ps -o tty= -p "${D_PID[$i]}" 2>/dev/null | tr -d ' ') || raw_tty=""
    tty="${raw_tty##*/}"
    pane_info=$(pane_lookup "$tty" "$TTY_MAP_FILE")
    if [[ -n "$pane_info" ]]; then
      _pass "interactive pid ${D_PID[$i]} (tty $tty): pane resolved ($pane_info)"
    else
      _fail "interactive pid ${D_PID[$i]} (tty $tty): pane NOT resolved"
    fi
  done
  [[ "$any_ia" -eq 0 ]] && _pass "interactive sessions: none live (nothing to check)"

  # 5. Merge sanity — tally DAEMON-MERGE target-marker outcomes among bg rows
  # (bg_total from check 3) against a live enumerate pass. Ideal: every bg
  # job with exactly one same-key interactive merges 1:1 (merged==bg_total).
  local bg_total=0
  for (( i=0; i<${#D_KIND[@]}; i++ )); do [[ "${D_KIND[$i]}" == "bg" ]] && bg_total=$((bg_total+1)); done
  local list_out t4_col detached=0 unlinked=0 ambiguous=0 merged=0
  list_out=$(enumerate_sessions status) || true
  t4_col=$(printf '%s\n' "$list_out" | cut -f4)
  detached=$(printf '%s\n' "$t4_col" | grep -cx 'detached' || true)
  unlinked=$(printf '%s\n' "$t4_col" | grep -cx 'unlinked?' || true)
  ambiguous=$(printf '%s\n' "$t4_col" | grep -cx 'ambiguous?' || true)
  merged=$(( bg_total - detached - unlinked - ambiguous ))
  (( merged < 0 )) && merged=0
  if [[ "$unlinked" -gt 0 ]]; then
    _fail "merge tally: bg_total=$bg_total merged=$merged detached=$detached unlinked?=$unlinked ambiguous?=$ambiguous"
  elif [[ "$ambiguous" -gt 0 ]]; then
    _warn "merge tally: bg_total=$bg_total merged=$merged detached=$detached unlinked?=$unlinked ambiguous?=$ambiguous"
  else
    _pass "merge tally: bg_total=$bg_total merged=$merged detached=$detached unlinked?=$unlinked ambiguous?=$ambiguous"
  fi

  # 6. Session-json schema probe — kind/sessionId present on any live sample;
  # jobId is only checked on a kind==bg sample — by design, interactive
  # session json carries no jobId key at all (confirmed against a live
  # interactive record), so requiring it there would be a false FAIL, not a
  # real schema break. Prefer a bg sample when one is live so all three
  # fields (the class that broke in un0/f5v) get checked in one pass.
  if [[ ${#D_JSON[@]} -gt 0 ]]; then
    local sample="" si
    for (( si=0; si<${#D_KIND[@]}; si++ )); do
      if [[ "${D_KIND[$si]}" == "bg" ]]; then sample="${D_JSON[$si]}"; break; fi
    done
    [[ -z "$sample" ]] && sample="${D_JSON[0]}"
    local sample_kind missing_fields="" has_kind has_jobid has_sid
    sample_kind=$(jq -r '.kind // "interactive"' "$sample" 2>/dev/null) || true
    has_kind=$(jq -r 'has("kind")' "$sample" 2>/dev/null) || true
    has_sid=$(jq -r 'has("sessionId")' "$sample" 2>/dev/null) || true
    [[ "$has_kind" != "true" ]] && missing_fields="${missing_fields}kind "
    [[ "$has_sid" != "true" ]] && missing_fields="${missing_fields}sessionId "
    if [[ "$sample_kind" == "bg" ]]; then
      has_jobid=$(jq -r 'has("jobId")' "$sample" 2>/dev/null) || true
      [[ "$has_jobid" != "true" ]] && missing_fields="${missing_fields}jobId "
    fi
    if [[ -n "$missing_fields" ]]; then
      _fail "session-json schema: missing field(s): $missing_fields(sample: $(basename "$sample"), kind=$sample_kind)"
    else
      _pass "session-json schema: kind/sessionId$([[ "$sample_kind" == "bg" ]] && echo "/jobId") present (sample: $(basename "$sample"), kind=$sample_kind)"
    fi
  else
    _warn "session-json schema: no live session json to sample"
  fi

  echo "── PASS:$pass_n WARN:$warn_n FAIL:$fail_n ──"
}

# ── responsive header ────────────────────────────────────────────────────────

# pack_groups: GROUP_VIS[i] / GROUP_REND[i] are parallel arrays — VIS is the
# plain (no-ANSI) text used for width math, REND is the ANSI-colored text
# actually emitted. Greedily packs groups into lines <= $cols (visible width),
# joining with a 3-space separator; a line break happens BEFORE a group that
# would overflow (never mid-group, never truncated). Echoes the packed block.
pack_groups() {
  local sep="   " out="" cur="" cur_vis=0 i gvis grend newvis
  for (( i=0; i<${#GROUP_VIS[@]}; i++ )); do
    gvis="${GROUP_VIS[$i]}"; grend="${GROUP_REND[$i]}"
    if [[ -z "$cur" ]]; then
      cur="$grend"; cur_vis=${#gvis}
    else
      newvis=$(( cur_vis + ${#sep} + ${#gvis} ))
      if (( newvis <= cols )); then
        cur="${cur}${sep}${grend}"; cur_vis=$newvis
      else
        out="${out}${cur}"$'\n'
        cur="$grend"; cur_vis=${#gvis}
      fi
    fi
  done
  [[ -n "$cur" ]] && out="${out}${cur}"
  printf '%s' "$out"
}

# build_header: width-aware header assembly. Sets globals COLHDR and HEADER.
# Header is built ONCE at launch, so it reflows on relaunch/refresh (r/s/c/t/p
# binds), NOT on live terminal resize — acceptable: the complaint is small
# windows truncating at open, not live reflow. CLAUDE_DASH_COLS is a
# test/override hook (see --print-header dispatch); real launches fall back
# to `tput cols` then 80.
build_header() {
  # Width source: `tput cols` returns a useless 80 inside a tmux display-popup
  # (measured: tput=80 while the popup was really 169 cols wide), so prefer
  # `stty size </dev/tty`, which reads the actual pty geometry. Fall back to
  # tput then 80. CLAUDE_DASH_COLS overrides everything (test/debug hook).
  local raw_cols="${CLAUDE_DASH_COLS:-}"
  if [[ -z "$raw_cols" ]]; then
    raw_cols=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
    [[ "$raw_cols" =~ ^[0-9]+$ ]] || raw_cols=$(tput cols 2>/dev/null || echo 80)
  fi
  [[ "$raw_cols" =~ ^[0-9]+$ ]] || raw_cols=80

  # The fzf --header renders ONLY in the left list pane; the preview pane takes
  # PREVIEW_PCT of the width on the right (see --preview-window=right:45% below),
  # plus ~4 cols of rounded-border + border-left + gutter. The legend wrap budget
  # must exclude that — measuring against the full popup width lets a legend
  # "fit" the popup yet still get truncated inside the narrower list pane.
  # Keep PREVIEW_PCT in sync with the --preview-window=right:NN% flag below.
  local PREVIEW_PCT=45
  cols=$(( raw_cols * (100 - PREVIEW_PCT) / 100 - 4 ))
  (( cols < 24 )) && cols=24

  # Column header padded to the same widths as the display field (see
  # enumerate). Leading %-4s accounts for the field-13 prefix:
  # glyph(1)+space(1)+gauge(1)+space(1) — gauge has a separating space before
  # the CTX% number (reads "▁ 19%" per D-GAUGE), hence 4 not 3 cols. │
  # separators mirror disp/nzdisp exactly (MODEL|PROJECT, PROJECT|TARGET, TARGET|LAST).
  # NOT wrapped — it's the data column ruler and stays one line.
  printf -v COLHDR '%-4s%-4s %-10s │ %-20s │ %-20s │ %s' '' 'CTX%' 'MODEL' 'PROJECT' 'TARGET' 'LAST'

  # Icon legend groups: status_icon glyphs, each colored with its status hue.
  GROUP_VIS=(); GROUP_REND=()
  GROUP_VIS+=("$(status_icon waiting) wait");   GROUP_REND+=("${C_WAIT}$(status_icon waiting)${C_RESET} wait")
  GROUP_VIS+=("$(status_icon busy) busy");      GROUP_REND+=("${C_BUSY}$(status_icon busy)${C_RESET} busy")
  GROUP_VIS+=("$(status_icon shell) bg-shell"); GROUP_REND+=("${C_SHELL}$(status_icon shell)${C_RESET} bg-shell")
  GROUP_VIS+=("$(status_icon idle) idle");      GROUP_REND+=("${C_IDLE}$(status_icon idle)${C_RESET} idle")
  GROUP_VIS+=("$(status_icon dormant) resume"); GROUP_REND+=("${C_DIM}$(status_icon dormant)${C_RESET} resume")
  local icon_lines
  icon_lines=$(pack_groups)

  # Key legend groups — tightened wording (dropped the repeated "sort:"
  # prefix; terser key=action pairs). This is the authoritative key reference.
  GROUP_VIS=(); GROUP_REND=()
  GROUP_VIS+=("s status");      GROUP_REND+=("${C_DIM}s status${C_RESET}")
  GROUP_VIS+=("c ctx%");        GROUP_REND+=("${C_DIM}c ctx%${C_RESET}")
  GROUP_VIS+=("t time");        GROUP_REND+=("${C_DIM}t time${C_RESET}")
  GROUP_VIS+=("p proj");        GROUP_REND+=("${C_DIM}p proj${C_RESET}")
  GROUP_VIS+=("x sleep");       GROUP_REND+=("${C_DIM}x sleep${C_RESET}")
  GROUP_VIS+=("r refresh");     GROUP_REND+=("${C_DIM}r refresh${C_RESET}")
  GROUP_VIS+=("⏎ jump/resume"); GROUP_REND+=("${C_DIM}⏎ jump/resume${C_RESET}")
  local key_lines
  key_lines=$(pack_groups)

  HEADER="${icon_lines}"$'\n'"${key_lines}"$'\n'"${C_DIM}${COLHDR}${C_RESET}"
}

# ── main ──────────────────────────────────────────────────────────────────────

export -f elapsed_human ctx_gauge context_pct model_label mainchain_usage_line transcript_file transcript_mtime pane_lookup bg_instance build_row preview_session enumerate_sessions kill_session doctor_check build_header pack_groups
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

if [[ "${1:-}" == "--print-header" ]]; then
  build_header
  printf '%s\n' "$HEADER"
  exit 0
fi

if [[ "${1:-}" == "--doctor" ]]; then
  doctor_check
  exit 0
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Width-aware icon/key legend + COLHDR, packed into $HEADER (see build_header).
build_header

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
        --prompt='filter ▸ ' \
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
