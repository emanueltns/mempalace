#!/bin/bash
# CONTEXT WATCHDOG (UserPromptSubmit hook)
#
# Enforces the "keep the interactive session lean" preference: when the estimated
# context passes a soft cap, it injects a one-line nudge telling the assistant to
# make sure memory is saved and recommend /compact (or /clear at a boundary).
# A NUDGE, not a hard gate: hooks cannot run /compact themselves. It is aimed at
# INTERACTIVE terminal sessions, the only place a human can type /compact.
#
# The cap IS enforceable since Claude Code 2.1.233, which takes a custom
# auto-compact threshold three ways: the `autoCompactWindow` setting (settings
# .json, accepts 100k-1M), the CLAUDE_CODE_AUTO_COMPACT_WINDOW env var, or the
# --autocompact flag. Compaction arms near 88% of that window, not at it.
# Phone/voice turns are one-shot `claude -p --resume` runs with cwd
# /root/voicebridge-home, so /root/voicebridge-home/.claude/settings.json pins
# autoCompactWindow to 250000 and those sessions compact unattended. That file
# is the enforcement; this hook stays advisory. See feedback_enforce_dont_remind.
#
# CAVEAT, measured 2026-08-16: in `claude -p` print mode the PreCompact hook does
# NOT fire, so mempal_precompact_hook.sh never runs on the phone path: no memory
# save and no raw transcript backup before a voice session compacts. It also
# means last_compact_ts is never stamped there, so the GRACE_S check below can
# never apply to voice sessions. Only SessionStart:startup and
# SessionStart:compact fire in print mode.
#
# Estimate = transcript bytes / BYTES_PER_TOKEN (calibrated ~9.7 on 2026-07-02:
# 5.9MB transcript == ~607k context tokens). Rough on purpose; a nudge only.
# After a compaction the PreCompact hook stamps last_compact_ts; we stay quiet
# for GRACE_S so we do not nag right after the user just compacted.
#
# Tunables (env): VB_CONTEXT_CAP_TOKENS (default 250000), VB_BYTES_PER_TOKEN
# (default 10), VB_CONTEXT_GRACE_S (default 600).
set -uo pipefail

CAP_TOKENS=${VB_CONTEXT_CAP_TOKENS:-250000}
BYTES_PER_TOKEN=${VB_BYTES_PER_TOKEN:-10}
GRACE_S=${VB_CONTEXT_GRACE_S:-600}
STATE_DIR="$HOME/.mempalace/hook_state"

INPUT=$(cat)
T=$(printf '%s' "$INPUT" | python3 -c "import sys,json;print(json.load(sys.stdin).get('transcript_path',''))" 2>/dev/null)
[ -n "$T" ] && [ -f "$T" ] || exit 0

# Grace window: skip nudging shortly after a compaction/clear.
TS_FILE="$STATE_DIR/last_compact_ts"
if [ -f "$TS_FILE" ]; then
    last=$(cat "$TS_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    if [ $(( now - last )) -lt "$GRACE_S" ]; then exit 0; fi
fi

# PRECISE source first: every assistant entry in the transcript carries
# message.usage; the LAST one's input+cache tokens IS the live context of the
# most recent request (verified 2026-07-29: usage said 296k while the old
# byte estimate claimed 2.47M on a tool-heavy session, an 8x overshoot that
# nagged /compact at 29% of a 1M window). Bytes/10 remains only as a fallback
# for transcripts without usage entries.
EST=$(python3 - "$T" <<'PYEOF' 2>/dev/null
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
EST=${EST:-0}
if [ "$EST" -le 0 ]; then
    BYTES=$(wc -c < "$T" 2>/dev/null || echo 0)
    EST=$(( BYTES / BYTES_PER_TOKEN ))
fi

# Routine over-cap nudging now lives in the Stop hook (mempal_save_hook.sh):
# it fires at the END of a turn, forces the memory save first, and only then
# recommends /compact, so the user is never interrupted mid-exchange (owner
# 2026-07-29: "should first check if we are active and wait for a response,
# save then compact"). This prompt-time hook only screams on a true
# emergency: double the soft cap.
if [ "$EST" -ge $(( CAP_TOKENS * 2 )) ]; then
    K=$(( EST / 1000 ))
    CAPK=$(( CAP_TOKENS / 1000 ))
    cat <<EOF
CONTEXT WATCHDOG (EMERGENCY): live context is ${K}k tokens, more than double the ${CAPK}k soft cap. Answer the user's request briefly, then urge running /compact in this same reply.
EOF
fi
exit 0
