#!/usr/bin/env bash
# claude-dash.sh — Read-only Claude Code session dashboard
# Opens an fzf popup listing every live Claude session with status, context %, and jump.
# Read-only against all session state. Only mutation: tmux jump on Enter (select+switch-client).
# See PLAN for hard constraints on what this script must not touch.
set -euo pipefail

SESSIONS_DIR="$HOME/.claude/sessions"
PROJECTS_DIR="$HOME/.claude/projects"

# ── helpers ──────────────────────────────────────────────────────────────────

# Human-friendly elapsed time from epoch seconds.
elapsed_human() {
  local now delta
  now=$(date +%s)
  delta=$(( now - $1 ))
  if   (( delta < 60 ));    then echo "${delta}s"
  elif (( delta < 3600 ));  then echo "$(( delta / 60 ))m"
  elif (( delta < 86400 )); then echo "$(( delta / 3600 ))h"
  else                           echo "$(( delta / 86400 ))d"
  fi
}

# Context % from transcript jsonl.
# Usage: context_pct <cwd> <sessionId>
context_pct() {
  local cwd="$1" sid="$2"
  local slug tf usage_line result
  slug="${cwd//\//-}"
  tf="$PROJECTS_DIR/$slug/$sid.jsonl"
  if [[ ! -f "$tf" ]]; then
    echo "-"
    return 0
  fi
  # grep -m1 exits 1 when no match — capture result explicitly to avoid set -e
  usage_line=$(tail -r "$tf" 2>/dev/null | grep -m1 '"usage"' || true)
  if [[ -z "$usage_line" ]]; then
    echo "-"
    return 0
  fi
  result=$(printf '%s\n' "$usage_line" | jq -r '
    .message.usage
    | ((.input_tokens//0)+(.cache_creation_input_tokens//0)
       +(.cache_read_input_tokens//0)+(.output_tokens//0)) as $t
    | (if $t > 200000 then 1000000 else 200000 end) as $w
    | (($t*100/$w)|floor) as $p
    | "\(if $p > 99 then 99 else $p end)%"
  ' 2>/dev/null || true)
  echo "${result:--}"
}

# Mtime of transcript jsonl in epoch seconds (fall back to 0).
transcript_mtime() {
  local cwd="$1" sid="$2"
  local slug tf result
  slug="${cwd//\//-}"
  tf="$PROJECTS_DIR/$slug/$sid.jsonl"
  if [[ -f "$tf" ]]; then
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
  local rows="" row
  shopt -s nullglob

  for f in "$SESSIONS_DIR"/*.json; do
    [[ -f "$f" ]] || continue

    # Parse all fields in one jq call
    local fields
    fields=$(jq -r '[.pid//"", (.status//"idle"), (.waitingFor//"-"), (.cwd//""), (.sessionId//""), (.updatedAt//0)] | @tsv' "$f" 2>/dev/null) || continue

    local pid sess_status waiting_for cwd sid updated_at
    IFS=$'\t' read -r pid sess_status waiting_for cwd sid updated_at <<< "$fields"

    [[ -z "$pid" ]] && continue

    # Dead-pid filter — stale files persist after pid dies
    ps -p "$pid" -o pid= >/dev/null 2>&1 || continue

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

    # Status glyph + sort key + color (ASCII glyphs, ANSI color — no emojis)
    local glyph sortkey gcolor
    case "$sess_status" in
      waiting) glyph="?" ; sortkey=0 ; gcolor=$'\033[1;31m' ;;  # bold red
      busy)    glyph=">" ; sortkey=1 ; gcolor=$'\033[1;33m' ;;  # bold yellow
      idle)    glyph="." ; sortkey=2 ; gcolor=$'\033[2;37m' ;;  # dim
      shell)   glyph='$' ; sortkey=3 ; gcolor=$'\033[1;34m' ;;  # bold blue
      *)       glyph="?" ; sortkey=4 ; gcolor=$'\033[0m'    ;;
    esac
    local glyph_disp="${gcolor}${glyph}"$'\033[0m'

    # Context %
    local ctx_pct
    ctx_pct=$(context_pct "$cwd" "$sid" || true)
    ctx_pct="${ctx_pct:--}"

    # Last activity: prefer transcript mtime, fall back to updatedAt epoch ms
    local tmtime act_epoch act_str
    tmtime=$(transcript_mtime "$cwd" "$sid" || true)
    tmtime="${tmtime:-0}"
    if [[ "$tmtime" != "0" ]]; then
      act_epoch="$tmtime"
    else
      act_epoch=$(( updated_at / 1000 ))
    fi
    act_str=$(elapsed_human "$act_epoch" || true)
    act_str="${act_str:-?}"

    # Project basename
    local proj
    proj=$(basename "${cwd:-unknown}")

    # Row: GLYPH<TAB>CTX%<TAB>PROJECT<TAB>TARGET<TAB>LASTACT<TAB>SORTKEY<TAB>JUMP<TAB>WAITINGFOR<TAB>PID<TAB>CWD<TAB>SID<TAB>ACTEPOCH
    row="${glyph_disp}	${ctx_pct}	${proj}	${tmux_target}	${act_str}	${sortkey}	${jump_target}	${waiting_for}	${pid}	${cwd}	${sid}	${act_epoch}"
    rows="${rows}${row}
"
  done

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

  local status_word glyph_plain
  case "$sortkey" in
    0) status_word="waiting" ; glyph_plain="?" ;;
    1) status_word="busy"    ; glyph_plain=">" ;;
    2) status_word="idle"    ; glyph_plain="." ;;
    3) status_word="shell"   ; glyph_plain='$' ;;
    *) status_word="unknown" ; glyph_plain="?" ;;
  esac

  echo "Session:    $sid"
  echo "Status:     $glyph_plain $status_word"
  echo "WaitingFor: $waiting"
  echo "Context:    $ctx"
  echo "Pane:       $target"
  echo "LastAct:    $lastact"
  echo "CWD:        $cwd"
  echo "PID:        $pid"
  echo ""

  local slug tf
  slug="${cwd//\//-}"
  tf="$PROJECTS_DIR/$slug/$sid.jsonl"
  if [[ -f "$tf" ]]; then
    echo "── transcript tail ──"
    tail -r "$tf" 2>/dev/null | head -30 | jq -r '
      if .type then
        "\(.role // .type): \(.message.content // .content // "" | if type=="array" then (.[0].text // "") else . end | .[0:200])"
      else empty end
    ' 2>/dev/null | head -12 || true
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

export -f elapsed_human context_pct transcript_mtime pane_lookup preview_session enumerate_sessions
export SESSIONS_DIR PROJECTS_DIR TTY_MAP_FILE

if [[ "${1:-}" == "--list" ]]; then
  enumerate_sessions "${2:-status}"
  exit 0
fi

if [[ "${1:-}" == "--preview" ]]; then
  preview_session "${2:-}"
  exit 0
fi

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# fzf pipeline — Enter accepts and returns the selected line; jump happens
# AFTER fzf exits / the popup closes (switch-client inside an open popup is flaky).
sel=$(
  enumerate_sessions \
    | fzf \
        --ansi \
        --layout=reverse \
        --no-sort \
        --delimiter=$'\t' \
        --with-nth=1,2,3,4,5 \
        --border=rounded \
        --border-label=' claude-dash · live sessions ' \
        --border-label-pos=2 \
        --color=fg:-1,bg:-1,hl:#ffaf5f,fg+:#ffffff,bg+:#262626,hl+:#ffd75f,header:#87afaf,info:#6c6c6c,pointer:#ff5f5f,prompt:#5fafd7,border:#5f87af,label:#afd7ff,gutter:-1 \
        --pointer='▶' \
        --prompt='filter ▸ ' \
        --info=inline \
        --header=$'\033[1;31m?\033[0m wait   \033[1;33m>\033[0m busy   \033[2;37m.\033[0m idle   \033[1;34m$\033[0m shell\nsort: [s]tatus  [c]tx%  [t]ime  [p]roj    ·    r=refresh    Enter=jump\n\033[2mSTAT  CTX%  PROJECT               TARGET             LAST\033[0m' \
        --preview="\"$SCRIPT_PATH\" --preview {}" \
        --preview-window=right:45%:wrap:border-left \
        --bind "r:reload(\"$SCRIPT_PATH\" --list status)" \
        --bind "s:reload(\"$SCRIPT_PATH\" --list status)" \
        --bind "c:reload(\"$SCRIPT_PATH\" --list ctx)" \
        --bind "t:reload(\"$SCRIPT_PATH\" --list activity)" \
        --bind "p:reload(\"$SCRIPT_PATH\" --list project)"
) || exit 0

[[ -z "$sel" ]] && exit 0

jump=$(printf '%s' "$sel" | cut -f7)
[[ "$jump" == "-" || -z "$jump" ]] && { echo "no tmux pane for this session" >&2; exit 0; }

IFS='|' read -r j_sess j_win j_pane <<< "$jump"
tmux select-window -t "$j_sess:$j_win" \; \
     select-pane -t "$j_sess:$j_win.$j_pane" \; \
     switch-client -t "$j_sess"
