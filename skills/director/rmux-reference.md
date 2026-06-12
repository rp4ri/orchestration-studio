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
sleep 0.5
rmux send-keys -t workers:0.N C-u       # 2. clear the input line (kills ghost text / stale drafts)
sleep 0.5
rmux send-keys -t workers:0.N -l "the full mandate as ONE literal string"
sleep 3                                  # long mandates land as a COLLAPSED PASTE — give the TUI time
rmux capture-pane -p -t workers:0.N | tail -5   # 3. VERIFY the paste is in the composer
rmux send-keys -t workers:0.N Enter     # 4. submit
sleep 6
rmux capture-pane -p -t workers:0.N | tail -5   # 5. VERIFY: composer empty + pane WORKING
```

| Key/flag | Why |
|---|---|
| `-t session:window.pane` | Target syntax, e.g. `workers:0.2` = window 0, pane 2 |
| `-l` | **Literal mode** — without it tmux interprets words as key names. Always use it for prompt text |
| `Escape` first | Dismisses survey overlays/menus that would eat keystrokes |
| `C-u` second | Clears the line. **Ghost text** (dim suggestion on the `❯` line) is NOT input, but Enter would submit it — never blind-Enter |
| `sleep 3` after `-l` | A multi-kB mandate is rendered as a collapsed paste (`paste again to expand`). An Enter sent while the TUI is still ingesting it is **silently dropped** — the mandate sits in the composer forever and the pane reads idle |
| `Enter` as its own send | Embedding `\n` in `-l` does not reliably submit |
| Verify AFTER Enter | **Dispatch is not done until capture-pane proves it**: composer back to an empty `❯` AND the busy indicator up. If the mandate is still in the composer, re-send Enter (one retry is normal on narrow panes); if the composer was not empty BEFORE typing, you were about to ship a hybrid prompt |

Narrow panes (≤55 cols) drop Enters more often — `rmux resize-pane -Z -t workers:0.N`
(zoom) before a long dispatch, dispatch, then `-Z` again to unzoom.

Queueing while a worker is WORKING: same sequence — the prompt queues and runs
when the current turn ends. Use for addendums, not unrelated new tasks.

## Reading a worker (state + reports)

```bash
# state: BOTH signals — the "esc to interrupt" hint AND the live spinner line.
# Newer CLI builds drop the 'esc to' hint in some states while the spinner
# ("Honking… (1m 22s · ↓ 41.5k tokens)") still shows real work — the hint
# alone produced false IDLEs on actively-working panes.
pane=$(rmux capture-pane -p -t workers:0.N)
e=$(echo "$pane" | grep -c 'esc to')
s=$(echo "$pane" | grep -cE '… \([0-9]+m? ?[0-9]*s')
busy=$((e + s))                                              # >0 = WORKING

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
| `grep -cE '… \([0-9]+m? ?[0-9]*s'` | The live spinner carries elapsed time in parens (`Germinating… (15s · …)`). **Completed-turn lines do NOT** (`✻ Churned for 4m 7s` — note `for`, no parens): matching on spinner VERBS marks finished workers as busy forever. Match the `… (Ns` shape, never the verb list |

**Debounce**: between tool calls both signals blip off. Require **6–8
consecutive zero-counts at 20s intervals** before declaring IDLE.

## The watcher loop (background task)

```bash
# launch with run_in_background=true — its completion re-invokes the director
busy_check() {  # both signals: 'esc to' hint + live spinner (elapsed time in parens)
  local pane; pane=$(rmux capture-pane -p -t workers:0.$1 2>/dev/null)
  echo $(( $(echo "$pane" | grep -c 'esc to') + $(echo "$pane" | grep -cE '… \([0-9]+m? ?[0-9]*s') ))
}
declare -A ic; ic[0]=0; ic[1]=0; ic[2]=0
fired=""
for i in $(seq 1 250); do
  for p in 0 1 2; do
    case " $fired " in *" $p "*) continue;; esac
    b=$(busy_check $p)
    if [ "$b" -gt 0 ]; then ic[$p]=0; else ic[$p]=$((${ic[$p]}+1)); fi
    if [ "${ic[$p]}" -ge 8 ]; then
      echo "🔔 pane$p IDLE"
      rmux capture-pane -p -S -42 -t workers:0.$p | grep -vE '^\s*$' | tail -16
      fired="$fired $p"
    fi
  done
  [ "$(echo $fired | wc -w)" -eq 3 ] && exit 0   # report each worker as it lands, exit when all do
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
