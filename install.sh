#!/usr/bin/env bash
# Install claude-dash: symlink the script into ~/.claude/bin and add the tmux popup bind.
# Idempotent — safe to re-run. Run after cloning on a new machine:
#   ./install.sh
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SRC/claude-dash.sh"
BIN_DIR="$HOME/.claude/bin"
LINK="$BIN_DIR/claude-dash.sh"
TMUX_CONF="$HOME/.tmux.conf"
BIND='bind-key C-j display-popup -w 90% -h 60% -B -E "~/.claude/bin/claude-dash.sh"'

# Dependencies
for dep in fzf jq tmux; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep (install it first)" >&2; exit 1; }
done

# Symlink into ~/.claude/bin (absolute target so it resolves from anywhere)
mkdir -p "$BIN_DIR"
if [ -L "$LINK" ]; then
  rm "$LINK"
elif [ -e "$LINK" ]; then
  mv "$LINK" "$LINK.bak.$(date +%s)"
  echo "backed up existing $LINK"
fi
chmod +x "$SCRIPT"
ln -s "$SCRIPT" "$LINK"
echo "linked $LINK -> $SCRIPT"

# tmux bind (idempotent — keyed on the script name appearing in the conf)
if [ -f "$TMUX_CONF" ] && grep -qF "claude-dash.sh" "$TMUX_CONF"; then
  echo "tmux bind already present in $TMUX_CONF"
else
  printf '\n# claude-dash — prefix + Ctrl-j opens the session dashboard\n%s\n' "$BIND" >> "$TMUX_CONF"
  echo "added tmux bind to $TMUX_CONF"
fi

# Reload if a tmux server is running
if tmux source-file "$TMUX_CONF" 2>/dev/null; then
  echo "reloaded tmux config"
else
  echo "no tmux server running — bind takes effect next launch"
fi

echo "done — press prefix + Ctrl-j inside tmux"
