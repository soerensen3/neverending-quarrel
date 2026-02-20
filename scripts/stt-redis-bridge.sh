#!/bin/sh
set -eu

# Bridge raw STT outputs from one Redis list into gated conversation queues.
# Expected input queue item:
# - plain text transcript, or
# - JSON with a top-level "text" field
#
# Env:
#   REDIS_HOST (default: redis)
#   MACHINE_ID (default: machine-local)
#   STT_INPUT_LIST (default: stt:transcripts)
#   BRPOP_TIMEOUT (default: 2)
#   COOLDOWN_MS (default: 1200)
#   ECHO_WINDOW_MS (default: 4000)
#   MIN_TEXT_LEN (default: 3)
#   DEBUG (default: 0)

REDIS_HOST="${REDIS_HOST:-redis}"
MACHINE_ID="${MACHINE_ID:-machine-local}"
STT_INPUT_LIST="${STT_INPUT_LIST:-stt:transcripts}"
BRPOP_TIMEOUT="${BRPOP_TIMEOUT:-2}"
COOLDOWN_MS="${COOLDOWN_MS:-1200}"
ECHO_WINDOW_MS="${ECHO_WINDOW_MS:-4000}"
MIN_TEXT_LEN="${MIN_TEXT_LEN:-3}"
DEBUG="${DEBUG:-0}"

extract_text() {
  RAW="$1"
  # Handle common JSON payload shape: {"text":"..."}
  if printf '%s' "$RAW" | grep -q '"text"[[:space:]]*:'; then
    printf '%s' "$RAW" \
      | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | sed 's/\\"/"/g; s/\\\\/\\/g'
  else
    printf '%s' "$RAW"
  fi
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

gate_and_enqueue() {
  TEXT="$(trim_spaces "$1")"
  [ -z "$TEXT" ] && return 0
  [ "${#TEXT}" -lt "$MIN_TEXT_LEN" ] && return 0

  NOW_MS="$(( $(date +%s) * 1000 ))"

  SPEAKING="$(redis-cli -h "$REDIS_HOST" GET agent:speaking 2>/dev/null || true)"
  if [ "$SPEAKING" = "1" ]; then
    [ "$DEBUG" = "1" ] && echo "[stt-bridge] dropped speaking=1" >&2 || true
    return 0
  fi

  COOLDOWN_UNTIL_MS="$(redis-cli -h "$REDIS_HOST" GET agent:cooldown_until_ms 2>/dev/null || true)"
  if [ -n "$COOLDOWN_UNTIL_MS" ] && [ "$COOLDOWN_UNTIL_MS" -gt "$NOW_MS" ] 2>/dev/null; then
    [ "$DEBUG" = "1" ] && echo "[stt-bridge] dropped cooldown" >&2 || true
    return 0
  fi

  LAST_TTS_TEXT="$(redis-cli -h "$REDIS_HOST" GET agent:last_tts_text 2>/dev/null || true)"
  LAST_TTS_TS_MS="$(redis-cli -h "$REDIS_HOST" GET agent:last_tts_ts_ms 2>/dev/null || true)"
  if [ -n "$LAST_TTS_TEXT" ] && [ -n "$LAST_TTS_TS_MS" ]; then
    AGE_MS=$((NOW_MS - LAST_TTS_TS_MS))
    if [ "$AGE_MS" -ge 0 ] && [ "$AGE_MS" -le "$ECHO_WINDOW_MS" ]; then
      NORM_TEXT="$(norm_text "$TEXT")"
      NORM_LAST="$(norm_text "$LAST_TTS_TEXT")"
      if [ -n "$NORM_TEXT" ] && [ "$NORM_TEXT" = "$NORM_LAST" ]; then
        [ "$DEBUG" = "1" ] && echo "[stt-bridge] dropped matches recent tts" >&2 || true
        return 0
      fi
    fi
  fi

  ESC_TEXT="$(printf '%s' "$TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  PAYLOAD="{\"source\":\"$MACHINE_ID\",\"kind\":\"user\",\"text\":\"$ESC_TEXT\",\"timestamp_ms\":$NOW_MS}"

  redis-cli -h "$REDIS_HOST" LPUSH conversation:incoming "$PAYLOAD" >/dev/null
  redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$PAYLOAD" >/dev/null
  redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99 >/dev/null
  redis-cli -h "$REDIS_HOST" SET agent:cooldown_until_ms "$((NOW_MS + COOLDOWN_MS))" EX 5 >/dev/null
  [ "$DEBUG" = "1" ] && echo "[stt-bridge] accepted=$TEXT" >&2 || true
}

while :; do
  OUT="$(redis-cli --raw -h "$REDIS_HOST" BRPOP "$STT_INPUT_LIST" "$BRPOP_TIMEOUT" 2>/dev/null || true)"
  [ -z "$OUT" ] && continue

  # BRPOP output format:
  # 1) list name
  # 2) payload
  RAW="$(printf '%s\n' "$OUT" | sed -n '2p')"
  [ -z "$RAW" ] && continue

  TEXT="$(extract_text "$RAW")"
  [ -z "$TEXT" ] && continue

  if [ "$DEBUG" = "1" ]; then
    echo "[stt-bridge] raw=$RAW" >&2
  fi

  gate_and_enqueue "$TEXT" || true
done
