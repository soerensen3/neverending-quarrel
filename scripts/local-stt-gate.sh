#!/bin/sh
set -eu

# Gate STT transcripts to avoid self-hearing loops.
# Usage:
#   scripts/local-stt-gate.sh "transcribed text"
# Env:
#   REDIS_HOST (default: redis)
#   MACHINE_ID (default: machine-local)
#   COOLDOWN_MS (default: 1200)
#   ECHO_WINDOW_MS (default: 4000)
#   MIN_TEXT_LEN (default: 3)

REDIS_HOST="${REDIS_HOST:-redis}"
MACHINE_ID="${MACHINE_ID:-machine-local}"
COOLDOWN_MS="${COOLDOWN_MS:-1200}"
ECHO_WINDOW_MS="${ECHO_WINDOW_MS:-4000}"
MIN_TEXT_LEN="${MIN_TEXT_LEN:-3}"
DEBUG="${DEBUG:-0}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 \"transcribed text\"" >&2
  exit 2
fi

TEXT="$*"
NOW_MS="$(( $(date +%s) * 1000 ))"

debug() {
  [ "$DEBUG" = "1" ] && echo "[stt-gate] $*" >&2 || true
}

trim_spaces() {
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//'
}

norm_text() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cd '[:alnum:][:space:]' \
    | tr -s '[:space:]' ' ' \
    | sed 's/^ //; s/ $//'
}

TEXT="$(trim_spaces "$TEXT")"
if [ -z "$TEXT" ] || [ "${#TEXT}" -lt "$MIN_TEXT_LEN" ]; then
  debug "dropped: too short"
  exit 0
fi

SPEAKING="$(redis-cli -h "$REDIS_HOST" GET agent:speaking 2>/dev/null || true)"
if [ "$SPEAKING" = "1" ]; then
  debug "dropped: speaking=1"
  exit 0
fi

COOLDOWN_UNTIL_MS="$(redis-cli -h "$REDIS_HOST" GET agent:cooldown_until_ms 2>/dev/null || true)"
if [ -n "$COOLDOWN_UNTIL_MS" ] && [ "$COOLDOWN_UNTIL_MS" -gt "$NOW_MS" ] 2>/dev/null; then
  debug "dropped: cooldown active"
  exit 0
fi

LAST_TTS_TEXT="$(redis-cli -h "$REDIS_HOST" GET agent:last_tts_text 2>/dev/null || true)"
LAST_TTS_TS_MS="$(redis-cli -h "$REDIS_HOST" GET agent:last_tts_ts_ms 2>/dev/null || true)"

if [ -n "$LAST_TTS_TEXT" ] && [ -n "$LAST_TTS_TS_MS" ]; then
  AGE_MS=$((NOW_MS - LAST_TTS_TS_MS))
  if [ "$AGE_MS" -ge 0 ] && [ "$AGE_MS" -le "$ECHO_WINDOW_MS" ]; then
    NORM_TEXT="$(norm_text "$TEXT")"
    NORM_LAST="$(norm_text "$LAST_TTS_TEXT")"
    if [ -n "$NORM_TEXT" ] && [ "$NORM_TEXT" = "$NORM_LAST" ]; then
      debug "dropped: matches recent tts"
      exit 0
    fi
  fi
fi

ESC_TEXT="$(printf '%s' "$TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
PAYLOAD="{\"source\":\"$MACHINE_ID\",\"kind\":\"user\",\"text\":\"$ESC_TEXT\",\"timestamp_ms\":$NOW_MS}"

redis-cli -h "$REDIS_HOST" LPUSH conversation:incoming "$PAYLOAD" >/dev/null
redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$PAYLOAD" >/dev/null
redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99 >/dev/null
debug "accepted: $TEXT"

# Prevent immediate re-trigger from room reflections.
redis-cli -h "$REDIS_HOST" SET agent:cooldown_until_ms "$((NOW_MS + COOLDOWN_MS))" EX 5 >/dev/null
