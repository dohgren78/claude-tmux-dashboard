# vhs tape -> demo.gif for the README.
# Render:  brew install vhs  &&  vhs demo.tape
# demo/run.sh builds a throwaway world first (fake sessions + transcripts and a
# private `tmux -L cdash-demo` server under /tmp/cdash-demo), so the recording
# never shows your own conversations. The Shift+R segment needs a cproj helper.

Output demo.gif
Require tmux
Require fzf
Require jq

Set Shell "bash"
Set FontFamily "JetBrainsMono Nerd Font Mono"
Set FontSize 16
Set Width 1600
Set Height 900
Set Padding 20
Set Theme "Catppuccin Mocha"

Hide
Type "demo/run.sh" Enter
Sleep 4s
Type "clear" Enter
Sleep 500ms
Show

# Open the dashboard: Ctrl+b, then Space
Sleep 1s
Ctrl+B
Space
Sleep 3s

# Browse; the preview follows the cursor
Down@700ms 2
Sleep 1.5s
Up@300ms 2
Sleep 1s

# Shift+R: past conversations of the highlighted project; Esc returns to the list
Type "R"
Sleep 3s
Down@700ms 2
Sleep 2s
Escape
Sleep 3.5s

# i: open any conversation by its session ID (preview confirms which one)
Type "i"
Sleep 1.5s
Type@25ms "4f2c9a1e-7b3d-4e8a-9c21-5d6e8f0a1b2c"
Sleep 3s
Escape
Sleep 3.5s

# Sort by context %, then back to status
Type "c"
Sleep 2s
Type "s"
Sleep 1.5s

# Close
Escape
Sleep 1s

Hide
Ctrl+B
Type "d"
Sleep 500ms
Type "tmux -L cdash-demo kill-server" Enter
