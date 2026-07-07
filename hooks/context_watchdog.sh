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

BYTES=$(wc -c < "$T" 2>/dev/null || echo 0)

# The transcript file never shrinks on /compact (compaction replaces the
# in-context history, not the file). Estimate from bytes ADDED since the last
# compaction, plus a flat allowance for the compact summary carried forward.
# Baseline is written by the PreCompact hook (bytes_at_last_compact).
BASE_FILE="$STATE_DIR/bytes_at_last_compact"
SUMMARY_ALLOWANCE_TOKENS=${VB_COMPACT_SUMMARY_TOKENS:-40000}
if [ -f "$BASE_FILE" ]; then
    base=$(cat "$BASE_FILE" 2>/dev/null | tr -dc '0-9')
    base=${base:-0}
    # A smaller file than the baseline means a different/new session: ignore it.
    if [ "$base" -gt 0 ] && [ "$BYTES" -ge "$base" ]; then
        EST=$(( (BYTES - base) / BYTES_PER_TOKEN + SUMMARY_ALLOWANCE_TOKENS ))
    else
        EST=$(( BYTES / BYTES_PER_TOKEN ))
    fi
else
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
