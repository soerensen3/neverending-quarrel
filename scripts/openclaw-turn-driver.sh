#!/bin/sh
set -eu

# Consume gated user turns from Redis and trigger OpenClaw runs.
#
# Env:
#   REDIS_HOST (default: redis)
#   MACHINE_ID (default: machine-local)
#   BRPOP_TIMEOUT (default: 2)
#   OPENCLAW_LOCAL (default: 1) -> use `openclaw agent --local`
#   OPENCLAW_AGENT (optional) -> pass `--agent <id>`
#   OPENCLAW_SESSION_ID (default: "$MACHINE_ID-loop")
#   COOLDOWN_MS (default: 1200)
#   DEBUG (default: 0)

REDIS_HOST="${REDIS_HOST:-redis}"
MACHINE_ID="${MACHINE_ID:-machine-local}"
BRPOP_TIMEOUT="${BRPOP_TIMEOUT:-2}"
OPENCLAW_LOCAL="${OPENCLAW_LOCAL:-1}"
OPENCLAW_AGENT="${OPENCLAW_AGENT:-}"
OPENCLAW_SESSION_ID="${OPENCLAW_SESSION_ID:-${MACHINE_ID}-loop}"
OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-ws://openclaw:18789}"
COOLDOWN_MS="${COOLDOWN_MS:-1200}"
DEBUG="${DEBUG:-0}"
OPENCLAW_BIN="${OPENCLAW_BIN:-}"

debug() {
  [ "$DEBUG" = "1" ] && echo "[turn-driver] $*" >&2 || true
}

echo "[turn-driver] started machine=${MACHINE_ID} redis_host=${REDIS_HOST} local=${OPENCLAW_LOCAL} session=${OPENCLAW_SESSION_ID} gateway=${OPENCLAW_GATEWAY_URL}" >&2
export OPENCLAW_GATEWAY_URL

# Wait for Redis DNS + readiness (important with shared network namespace startup races).
WAIT_SECS=60
I=0
while :; do
  if redis-cli -h "$REDIS_HOST" PING >/dev/null 2>&1; then
    echo "[turn-driver] redis_ready host=${REDIS_HOST}" >&2
    break
  fi
  I=$((I + 1))
  if [ "$I" -ge "$WAIT_SECS" ]; then
    echo "[turn-driver] redis_unreachable host=${REDIS_HOST} after ${WAIT_SECS}s" >&2
    exit 1
  fi
  sleep 1
done

extract_text() {
  RAW="$1"
  if printf '%s' "$RAW" | grep -q '"text"[[:space:]]*:'; then
    printf '%s' "$RAW" \
      | sed -n 's/.*"text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | sed 's/\\"/"/g; s/\\\\/\\/g'
  else
    printf '%s' "$RAW"
  fi
}

run_agent() {
  MSG="$1"
  BIN="$OPENCLAW_BIN"
  RUNNER=""
  ROUTE_FLAG=""
  ROUTE_VALUE=""

  if [ -n "$OPENCLAW_AGENT" ]; then
    ROUTE_FLAG="--agent"
    ROUTE_VALUE="$OPENCLAW_AGENT"
  else
    ROUTE_FLAG="--session-id"
    ROUTE_VALUE="$OPENCLAW_SESSION_ID"
  fi

  if [ -z "$BIN" ]; then
    if command -v openclaw >/dev/null 2>&1; then
      BIN="$(command -v openclaw)"
    elif [ -x /home/node/.local/bin/openclaw ]; then
      BIN="/home/node/.local/bin/openclaw"
    elif [ -x /home/node/.bun/bin/openclaw ]; then
      BIN="/home/node/.bun/bin/openclaw"
    elif [ -x /root/.local/bin/openclaw ]; then
      BIN="/root/.local/bin/openclaw"
    elif [ -x /root/.bun/bin/openclaw ]; then
      BIN="/root/.bun/bin/openclaw"
    else
      if command -v bunx >/dev/null 2>&1; then
        RUNNER="bunx"
      elif command -v npx >/dev/null 2>&1; then
        RUNNER="npx"
      else
        echo "openclaw CLI not found in PATH/known locations and no bunx/npx fallback available" >&2
        return 127
      fi
    fi
  fi

  if [ -n "$RUNNER" ]; then
    debug "runner=$RUNNER"
    if [ "$RUNNER" = "bunx" ]; then
      if [ "$OPENCLAW_LOCAL" = "1" ]; then
        bunx --bun openclaw agent --local "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
      else
        bunx --bun openclaw agent "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
      fi
    else
      if [ "$OPENCLAW_LOCAL" = "1" ]; then
        npx --yes openclaw agent --local "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
      else
        npx --yes openclaw agent "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
      fi
    fi
  else
    debug "bin=$BIN"
    if [ "$OPENCLAW_LOCAL" = "1" ]; then
      "$BIN" agent --local "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
    else
      "$BIN" agent "$ROUTE_FLAG" "$ROUTE_VALUE" --message "$MSG" 2>&1
    fi
  fi
}

while :; do
  OUT="$(redis-cli --raw -h "$REDIS_HOST" BRPOP conversation:incoming "$BRPOP_TIMEOUT" || true)"
  [ -z "$OUT" ] && continue

  RAW="$(printf '%s\n' "$OUT" | sed -n '2p')"
  [ -z "$RAW" ] && continue

  TEXT="$(extract_text "$RAW")"
  [ -z "$TEXT" ] && continue
  debug "incoming=$TEXT"

  NOW_MS="$(( $(date +%s) * 1000 ))"
  redis-cli -h "$REDIS_HOST" SET agent:speaking 1 EX 30 >/dev/null || true

  REPLY="$(run_agent "$TEXT" || true)"
  debug "reply=$REPLY"

  NOW_MS="$(( $(date +%s) * 1000 ))"
  ESC_REPLY="$(printf '%s' "$REPLY" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  ASSISTANT_PAYLOAD="{\"source\":\"$MACHINE_ID\",\"kind\":\"assistant\",\"text\":\"$ESC_REPLY\",\"timestamp_ms\":$NOW_MS}"

  redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$ASSISTANT_PAYLOAD" >/dev/null || true
  redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:last_tts_text "$REPLY" EX 120 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:last_tts_ts_ms "$NOW_MS" EX 120 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:speaking 0 EX 2 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:cooldown_until_ms "$((NOW_MS + COOLDOWN_MS))" EX 5 >/dev/null || true
done
