# rmux/tmux Command & Key Reference (Director Cheat Sheet)

Every command the director actually uses, with the exact flags. `rmux` is a
tmux-compatible multiplexer — everything here works on both (swap the binary).

## Discovery

| Command | Purpose |
|---|---|
| `rmux list-sessions` | What sessions exist |
| `rmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} [#{pane_width}x#{pane_height}] #{pane_title}'` | Full pane map. **Titles are STALE** (first prompt of the session) — never infer state from them |
| `rmux set -g mouse on` | Enable mouse (scroll/click) for the human watching |

## Sending a prompt to a worker — the exact sequence

```bash
rmux send-keys -t workers:0.N Escape    # 1. dismiss overlays ("How is Claude doing?" survey)
sleep 0.3
rmux send-keys -t workers:0.N C-u       # 2. clear the input line (kills ghost text / stale drafts)
sleep 0.3
rmux send-keys -t workers:0.N -l "the full mandate as ONE literal string"
sleep 0.5
rmux send-keys -t workers:0.N Enter     # 3. submit
```

| Key/flag | Why |
|---|---|
| `-t session:window.pane` | Target syntax, e.g. `workers:0.2` = window 0, pane 2 |
| `-l` | **Literal mode** — without it tmux interprets words as key names. Always use it for prompt text |
| `Escape` first | Dismisses survey overlays/menus that would eat keystrokes |
| `C-u` second | Clears the line. **Ghost text** (dim suggestion on the `❯` line) is NOT input, but Enter would submit it — never blind-Enter |
| `sleep 0.3–0.5` between steps | The TUI needs time per key event; racing drops input |
| `Enter` as its own send | Embedding `\n` in `-l` does not reliably submit |

Queueing while a worker is WORKING: same sequence — the prompt queues and runs
when the current turn ends. Use for addendums, not unrelated new tasks.

## Reading a worker (state + reports)

```bash
# state: count the "esc to interrupt" indicator — TRUNCATED-SAFE prefix
rmux capture-pane -p -t workers:0.N | grep -c 'esc to'      # >0 = WORKING

# report: last 42 lines of scrollback, blank lines stripped
rmux capture-pane -p -S -42 -t workers:0.N | grep -vE '^\s*$' | tail -16

# deep forensics (failure signatures): 80+ lines
rmux capture-pane -p -S -80 -t workers:0.N | grep -vE '^\s*$' | tail -25
```

| Flag | Meaning |
|---|---|
| `capture-pane -p` | Print pane contents to stdout |
| `-S -42` | Start 42 lines into scrollback (negative = back in history) |
| `grep -c 'esc to'` | Why the short prefix: panes ~60 cols wide truncate "esc to interrupt" in the status bar — the full-string grep produced permanent false IDLEs |

**Debounce**: between tool calls the indicator blips off. Require **6–8
consecutive zero-counts at 20s intervals** before declaring IDLE.

## The watcher loop (background task)

```bash
# launch with run_in_background=true — its completion re-invokes the director
declare -A ic; ic[0]=0; ic[1]=0; ic[2]=0
for i in $(seq 1 250); do
  for p in 0 1 2; do
    b=$(rmux capture-pane -p -t workers:0.$p | grep -c 'esc to')
    if [ "$b" -gt 0 ]; then ic[$p]=0; else ic[$p]=$((${ic[$p]}+1)); fi
    if [ "${ic[$p]}" -eq 8 ]; then
      echo "🔔 pane$p IDLE"
      rmux capture-pane -p -S -42 -t workers:0.$p | grep -vE '^\s*$' | tail -16
      exit 0
    fi
  done
  sleep 20
done; echo timeout
```

On fire: **verify the expected artifact exists** (report file / PR / branch)
before treating the task as done — a rate-limited or filter-blocked worker is
also "idle".

## Don'ts

- Don't `send-keys` without `-l` for text. Don't Enter without `C-u` first.
- Don't trust pane titles, full-string indicator greps, or single-poll idles.
- Don't `kill-session`/restart a worker to re-task it — re-prompt in place
  (context survives).
- Don't run watchers in the foreground — the director must stay reactive.
