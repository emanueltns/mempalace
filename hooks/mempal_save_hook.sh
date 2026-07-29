#!/bin/bash
# MEMPALACE SAVE HOOK — Auto-save every N exchanges
#
# Claude Code "Stop" hook. After every assistant response:
# 1. Counts human messages in the session transcript
# 2. Every SAVE_INTERVAL messages, BLOCKS the AI from stopping
# 3. Returns a reason telling the AI to save structured diary + palace entries
# 4. AI does the save (topics, decisions, code, quotes → organized into palace)
# 5. Next Stop fires with stop_hook_active=true → lets AI stop normally
#
# The AI does the classification — it knows what wing/hall/closet to use
# because it has context about the conversation. No regex needed.
#
# === INSTALL ===
# Add to .claude/settings.local.json:
#
#   "hooks": {
#     "Stop": [{
#       "matcher": "*",
#       "hooks": [{
#         "type": "command",
#         "command": "/absolute/path/to/mempal_save_hook.sh",
#         "timeout": 30
#       }]
#     }]
#   }
#
# For Codex CLI, add to .codex/hooks.json:
#
#   "Stop": [{
#     "type": "command",
#     "command": "/absolute/path/to/mempal_save_hook.sh",
#     "timeout": 30
#   }]
#
# === HOW IT WORKS ===
#
# Claude Code sends JSON on stdin with these fields:
#   session_id       — unique session identifier
#   stop_hook_active — true if AI is already in a save cycle (prevents infinite loop)
#   transcript_path  — path to the JSONL transcript file
#
# When we block, Claude Code shows our "reason" to the AI as a system message.
# The AI then saves to memory, and when it tries to stop again,
# stop_hook_active=true so we let it through. No infinite loop.
#
# === MEMPALACE CLI ===
# This repo uses: mempalace mine <dir>
# or:            mempalace mine <dir> --mode convos
# Set MEMPAL_DIR below if you want the hook to auto-ingest after blocking.
# Leave blank to rely on the AI's own save instructions.
#
# === CONFIGURATION ===

SAVE_INTERVAL=15  # Save every N human messages (adjust to taste)
STATE_DIR="$HOME/.mempalace/hook_state"
mkdir -p "$STATE_DIR"

# Optional: set to the directory you want auto-ingested on each save trigger.
# Example: MEMPAL_DIR="$HOME/conversations"
# Leave empty to skip auto-ingest (AI handles saving via the block reason).
MEMPAL_DIR=""

# Read JSON input from stdin
INPUT=$(cat)

# Parse fields from Claude Code's JSON
SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)
# Sanitize SESSION_ID to prevent path traversal (only allow alnum, dash, underscore)
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
STOP_HOOK_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

# Expand ~ in path
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# If we're already in a save cycle, let the AI stop normally
# This is the infinite-loop prevention: block once → AI saves → tries to stop again → we let it through
if [ "$STOP_HOOK_ACTIVE" = "True" ] || [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    echo "{}"
    exit 0
fi

# Count human messages in the JSONL transcript
if [ -f "$TRANSCRIPT_PATH" ]; then
    EXCHANGE_COUNT=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import json, sys
count = 0
with open(sys.argv[1]) as f:
    for line in f:
        try:
            entry = json.loads(line)
            msg = entry.get('message', {})
            if isinstance(msg, dict) and msg.get('role') == 'user':
                content = msg.get('content', '')
                # Skip system/command messages — only count real human input
                if isinstance(content, str) and '<command-message>' in content:
                    continue
                count += 1
        except:
            pass
print(count)
PYEOF
2>/dev/null)
else
    EXCHANGE_COUNT=0
fi

# Track last save point for this session
LAST_SAVE_FILE="$STATE_DIR/${SESSION_ID}_last_save"
LAST_SAVE=0
if [ -f "$LAST_SAVE_FILE" ]; then
    LAST_SAVE=$(cat "$LAST_SAVE_FILE")
fi

SINCE_LAST=$((EXCHANGE_COUNT - LAST_SAVE))

# Log for debugging (check ~/.mempalace/hook_state/hook.log)
echo "[$(date '+%H:%M:%S')] Session $SESSION_ID: $EXCHANGE_COUNT exchanges, $SINCE_LAST since last save" >> "$STATE_DIR/hook.log"

# Over-cap check (owner 2026-07-29: nudge only at a turn boundary, save
# FIRST, then recommend /compact). Reads the live context from the last
# usage entry, mirroring context_watchdog.sh; nags at most once per
# NUDGE_INTERVAL_S and never right after a compaction (last_compact_ts).
CAP_TOKENS=${VB_CONTEXT_CAP_TOKENS:-250000}
NUDGE_INTERVAL_S=${VB_CONTEXT_NUDGE_INTERVAL_S:-1800}
CONTEXT_EST=0
if [ -f "$TRANSCRIPT_PATH" ]; then
    CONTEXT_EST=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF' 2>/dev/null
import json, sys
last = 0
with open(sys.argv[1]) as f:
    for line in f:
        try:
            u = (json.loads(line).get("message") or {}).get("usage")
        except Exception:
            continue
        if u and "input_tokens" in u:
            last = (u.get("input_tokens", 0)
                    + u.get("cache_read_input_tokens", 0)
                    + u.get("cache_creation_input_tokens", 0))
print(last)
PYEOF
)
    CONTEXT_EST=${CONTEXT_EST:-0}
fi
OVER_CAP=0
if [ "$CONTEXT_EST" -ge "$CAP_TOKENS" ] 2>/dev/null; then
    now=$(date +%s)
    compact_ts=$(cat "$STATE_DIR/last_compact_ts" 2>/dev/null || echo 0)
    nudge_ts=$(cat "$STATE_DIR/last_capnudge_ts" 2>/dev/null || echo 0)
    if [ $(( now - compact_ts )) -ge "$NUDGE_INTERVAL_S" ] && [ $(( now - nudge_ts )) -ge "$NUDGE_INTERVAL_S" ]; then
        OVER_CAP=1
    fi
fi

if [ "$OVER_CAP" -eq 1 ]; then
    echo "$(date +%s)" > "$STATE_DIR/last_capnudge_ts"
    echo "$EXCHANGE_COUNT" > "$LAST_SAVE_FILE"
    K=$(( CONTEXT_EST / 1000 ))
    CAPK=$(( CAP_TOKENS / 1000 ))
    python3 - "$K" "$CAPK" <<'PYEOF'
import json, sys
k, capk = sys.argv[1], sys.argv[2]
print(json.dumps({
  "decision": "block",
  "reason": ("CONTEXT BOUNDARY: the turn is over and live context is %sk tokens "
             "(soft cap %sk). FIRST save all unsaved state, decisions, quotes and "
             "any friction lessons to memory now. THEN end with one short line "
             "telling the user this is a natural boundary and recommending /compact. "
             "Do not start new work.") % (k, capk)
}))
PYEOF
    exit 0
fi

# Time to save?
if [ "$SINCE_LAST" -ge "$SAVE_INTERVAL" ] && [ "$EXCHANGE_COUNT" -gt 0 ]; then
    # Update last save point
    echo "$EXCHANGE_COUNT" > "$LAST_SAVE_FILE"

    echo "[$(date '+%H:%M:%S')] TRIGGERING SAVE at exchange $EXCHANGE_COUNT" >> "$STATE_DIR/hook.log"

    # Optional: run mempalace ingest in background if MEMPAL_DIR is set
    if [ -n "$MEMPAL_DIR" ] && [ -d "$MEMPAL_DIR" ]; then
        SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        REPO_DIR="$(dirname "$SCRIPT_DIR")"
        python3 -m mempalace mine "$MEMPAL_DIR" >> "$STATE_DIR/hook.log" 2>&1 &
    fi

    # Block the AI and tell it to save
    # The "reason" becomes a system message the AI sees and acts on
    cat << 'HOOKJSON'
{
  "decision": "block",
  "reason": "AUTO-SAVE checkpoint. Save key topics, decisions, quotes, and code from this session to your memory system. Organize into appropriate categories. Use verbatim quotes where possible. ALSO: if the exchanges since the last save contained a correction the user made to you, a claim you retracted, a misunderstanding the user had to re-explain, or a mistake you caught — distill it into a feedback_* lesson file NOW, not just state notes; friction is the most valuable thing to save. Continue conversation after saving."
}
HOOKJSON
else
    # Not time yet — let the AI stop normally
    echo "{}"
fi
