#!/bin/bash
# SessionStart: surface live tmux/rmux sessions so a director session starts
# with the orchestration map already in context. Silent when there's nothing.

MUX=""
command -v rmux >/dev/null 2>&1 && MUX=rmux
[ -z "$MUX" ] && command -v tmux >/dev/null 2>&1 && MUX=tmux
[ -z "$MUX" ] && exit 0

SESSIONS=$($MUX list-sessions 2>/dev/null)
[ -z "$SESSIONS" ] && exit 0

PANES=$($MUX list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} [#{pane_width}x#{pane_height}] #{pane_title}' 2>/dev/null | head -12)

cat <<EOF
[orchestration-studio] Live $MUX sessions detected:
$SESSIONS

Panes (titles are STALE — they show each session's first prompt; use
'capture-pane | grep -c "esc to"' for real state):
$PANES
EOF
exit 0
