#!/bin/bash
# MEMPALACE PRE-COMPACT HOOK — Emergency save before compaction
#
# Claude Code "PreCompact" hook. Fires RIGHT BEFORE the conversation
# gets compressed to free up context window space.
#
# This is the safety net. When compaction happens, the AI loses detailed
# context about what was discussed. This hook forces one final save of
# EVERYTHING before that happens.
#
# Unlike the save hook (which triggers every N exchanges), this ALWAYS
# blocks — because compaction is always worth saving before.
#
# === INSTALL ===
# Add to .claude/settings.local.json:
#
#   "hooks": {
#     "PreCompact": [{
#       "hooks": [{
#         "type": "command",
#         "command": "/absolute/path/to/mempal_precompact_hook.sh",
#         "timeout": 30
#       }]
#     }]
#   }
#
# For Codex CLI, add to .codex/hooks.json:
#
#   "PreCompact": [{
#     "type": "command",
#     "command": "/absolute/path/to/mempal_precompact_hook.sh",
#     "timeout": 30
#   }]
#
# === HOW IT WORKS ===
#
# Claude Code sends JSON on stdin with:
#   session_id — unique session identifier
#
# We always return decision: "block" with a reason telling the AI
# to save everything. After the AI saves, compaction proceeds normally.
#
# === MEMPALACE CLI ===
# This repo uses: mempalace mine <dir>
# or:            mempalace mine <dir> --mode convos
# Set MEMPAL_DIR below if you want the hook to auto-ingest before compaction.
# Leave blank to rely on the AI's own save instructions.

STATE_DIR="$HOME/.mempalace/hook_state"
mkdir -p "$STATE_DIR"

# Optional: set to the directory you want auto-ingested before compaction.
# Example: MEMPAL_DIR="$HOME/conversations"
# Leave empty to skip auto-ingest (AI handles saving via the block reason).
MEMPAL_DIR=""

# Read JSON input from stdin
INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id','unknown'))" 2>/dev/null)
TRANSCRIPT=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)

echo "[$(date '+%H:%M:%S')] PRE-COMPACT triggered for session $SESSION_ID" >> "$STATE_DIR/hook.log"

# Stamp the compaction time so the context watchdog gives a grace window after
# a compact/clear instead of nagging immediately (context_watchdog.sh reads it).
date +%s > "$STATE_DIR/last_compact_ts" 2>/dev/null

# Record the transcript byte size at compaction. The transcript .jsonl NEVER
# shrinks on /compact (compaction replaces the in-context history, not the
# file), so the watchdog must estimate from bytes ADDED SINCE the last compact,
# not total bytes -- otherwise it false-positives forever after one compact
# (seen 2026-07-03: file said 665k, real context was 157k).
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    wc -c < "$TRANSCRIPT" > "$STATE_DIR/bytes_at_last_compact" 2>/dev/null
fi

# Raw, full-fidelity backup of the transcript BEFORE compaction. This is the
# "save everything" half, done deterministically by the hook (a shell script
# cannot distill into memory, but it CAN preserve the raw record). It sits on
# top of the continuous distilled saves the Stop hook already does every turn,
# so nothing is lost even though we no longer block.
BACKUP_DIR="$STATE_DIR/backups"
mkdir -p "$BACKUP_DIR"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
    cp "$TRANSCRIPT" "$BACKUP_DIR/precompact-${SESSION_ID}-$(date '+%Y%m%d-%H%M%S').jsonl" 2>/dev/null \
        && echo "[$(date '+%H:%M:%S')] raw transcript backed up before compaction" >> "$STATE_DIR/hook.log"
fi

# Optional: run mempalace ingest synchronously so memories land before compaction
if [ -n "$MEMPAL_DIR" ] && [ -d "$MEMPAL_DIR" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_DIR="$(dirname "$SCRIPT_DIR")"
    python3 -m mempalace mine "$MEMPAL_DIR" >> "$STATE_DIR/hook.log" 2>&1
fi

# ALLOW compaction to proceed (changed 2026-07-02 from always-block, per owner:
# "save everything then compact, so we don't use too many tokens"). The
# conversation is already saved two ways -- (1) the Stop hook distills to the
# memory .md files every turn, so memory is always current; (2) the raw
# transcript backup above -- so there is nothing to block for. Exit 0 with no
# "decision":"block" lets Claude Code compact and free the context window,
# which is the whole point.
exit 0
