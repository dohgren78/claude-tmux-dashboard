# vhs tape → demo.gif for the README.
# Render:  brew install vhs  &&  vhs demo.tape
# vhs embeds the font in the GIF, so the Nerd Font icons render for everyone.
# Note: this drives claude-dash.sh directly (the fzf list + preview + sort keys),
# which needs no tmux server — only the Enter/jump action does. It reads your
# real ~/.claude sessions, so record it when you have a few live to show off.

Output demo.gif

Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 18
Set Width 1400
Set Height 760
Set Padding 24
Set Theme "Catppuccin Mocha"

Hide
Type "clear" Enter
Show

# Launch the dashboard (fzf list + preview pane)
Type "~/.claude/bin/claude-dash.sh"
Enter
Sleep 2s

# Move through the list
Down@600ms 3
Sleep 1.5s

# Sort by context % (fullest first), then by activity
Type "c"
Sleep 1.8s
Type "t"
Sleep 1.8s

# Back to status sort, browse a couple more
Type "s"
Sleep 1s
Down@600ms 2
Sleep 2s

# Close (Esc) — do NOT press Enter, that would jump/switch panes mid-recording
Escape
Sleep 1s
