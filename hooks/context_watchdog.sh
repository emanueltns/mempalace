#!/bin/bash
# CONTEXT WATCHDOG (UserPromptSubmit hook)
#
# Enforces the "keep the interactive session lean" preference: when the estimated
# context passes a soft cap, it injects a one-line nudge telling the assistant to
# make sure memory is saved and recommend /compact (or /clear at a boundary).
# A NUDGE, not a hard gate -- hooks cannot run /compact themselves, and Claude
# Code exposes no custom compact threshold (built-in auto-compact only fires near
# the ~1M hard limit). See memory feedback_enforce_dont_remind.
#
# Estimate = transcript bytes / BYTES_PER_TOKEN (calibrated ~9.7 on 2026-07-02:
# 5.9MB transcript == ~607k context tokens). Rough on purpose; a nudge only.
# After a compaction the PreCompact hook stamps last_compact_ts; we stay quiet
# for GRACE_S so we do not nag right after the user just compacted.
#
# Tunables (env): VB_CONTEXT_CAP_TOKENS (default 400000), VB_BYTES_PER_TOKEN
# (default 10), VB_CONTEXT_GRACE_S (default 600).
set -uo pipefail

CAP_TOKENS=${VB_CONTEXT_CAP_TOKENS:-400000}
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

if [ "$EST" -ge "$CAP_TOKENS" ]; then
    K=$(( EST / 1000 ))
    CAPK=$(( CAP_TOKENS / 1000 ))
    cat <<EOF
CONTEXT WATCHDOG: this interactive session is at roughly ${K}k tokens, over the ${CAPK}k soft cap. Confirm the latest state and decisions are in memory (the Stop hook does this each turn), then in ONE short sentence tell the user context is over the cap and recommend running /compact now (or /clear at a natural task boundary) to free tokens. Do not derail the user's actual request; answer it, and append the reminder.
EOF
fi
exit 0
