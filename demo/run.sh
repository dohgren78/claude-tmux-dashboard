#!/usr/bin/env bash
# Build a throwaway demo world and attach to it. Used by demo.tape:
#   vhs demo.tape
# Fake sessions, transcripts and a private tmux server (-L cdash-demo), all
# under /tmp/cdash-demo, so the recording never shows your own conversations.
# The Shift+R segment needs a cproj helper (CLAUDE_DASH_CPROJ, PATH or ~/bin).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEMO=/tmp/cdash-demo
REAL_HOME="$HOME"
CPROJ="${CLAUDE_DASH_CPROJ:-$(command -v cproj 2>/dev/null || echo "$REAL_HOME/bin/cproj")}"

tmux -L cdash-demo kill-server 2>/dev/null || true
rm -rf "$DEMO"
mkdir -p "$DEMO/bin" "$DEMO/home/.claude/bin" "$DEMO/code"
ln -s "$REPO/claude-dash.sh" "$DEMO/home/.claude/bin/claude-dash.sh"
ln -s "$REPO/claude-dash.sh" "$DEMO/bin/claude-dash"

export HOME="$DEMO/home" PATH="$DEMO/bin:$PATH"
[[ -x "$CPROJ" ]] && export CLAUDE_DASH_CPROJ="$CPROJ"

printf '%s\n' "PS1='\\[\\e[36m\\]~/code\\[\\e[0m\\] \$ '" > "$DEMO/bashrc"

cat > "$DEMO/tmux.conf" <<'EOF'
set -g default-shell /bin/bash
set -g default-terminal "tmux-256color"
set -g base-index 1
setw -g pane-base-index 1
set -ga terminal-overrides ",*:Tc"
set -g status-style "bg=default,fg=cyan"
set -g status-left "[#S] "
set -g status-right "Ctrl+b ? = keys "
bind Space display-popup -w 94% -h 82% -B -E "claude-dash"
EOF

tmux -L cdash-demo -f "$DEMO/tmux.conf" new-session -d -s main -x 150 -y 40 -c "$DEMO/code" "bash --rcfile $DEMO/bashrc"
python3 -I "$REPO/demo/fixture.py" "$DEMO/code"
[[ "${1:-}" == --no-attach ]] && exit 0
tmux -L cdash-demo attach -t main
