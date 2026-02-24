#!/bin/sh
set -eu

# Consume gated user turns from Redis and query Ollama directly.
#
# Env:
#   REDIS_HOST (default: redis)
#   MACHINE_ID (default: machine-local)
#   BRPOP_TIMEOUT (default: 2)
#   OLLAMA_HOST (default: ollama)
#   OLLAMA_PORT (default: 11434)
#   OLLAMA_MODEL (default: qwen2.5-coder:7b-instruct-q4_K_M)
#   OLLAMA_SYSTEM_PROMPT (optional)
#   OLLAMA_NUM_PREDICT (default: 160)
#   OLLAMA_HISTORY_ITEMS (default: 24)
#   TALK_MODE (default: always)
#   TTS_ENDPOINT (default: http://piper:8080/api/tts)
#   TTS_VOICE (default: de-thorsten-low.onnx)
#   TTS_VOICE_DE (default: $TTS_VOICE)
#   TTS_VOICE_EN (default: $TTS_VOICE_DE)
#   TTS_FORMAT (default: wav)
#   TTS_OUT_LIST (default: tts:out)
#   TTS_LOCAL_PLAYBACK (default: 0)
#   COOLDOWN_MS (default: 1200)
#   DEBUG (default: 0)

REDIS_HOST="${REDIS_HOST:-redis}"
MACHINE_ID="${MACHINE_ID:-machine-local}"
BRPOP_TIMEOUT="${BRPOP_TIMEOUT:-2}"
OLLAMA_HOST="${OLLAMA_HOST:-ollama}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:7b-instruct-q4_K_M}"
OLLAMA_SYSTEM_PROMPT="${OLLAMA_SYSTEM_PROMPT:-You are a local voice assistant. Return ONLY compact JSON: {\"tool\":\"talk\",\"text\":\"<what to say>\"} and no markdown.}"
OLLAMA_NUM_PREDICT="${OLLAMA_NUM_PREDICT:-160}"
OLLAMA_HISTORY_ITEMS="${OLLAMA_HISTORY_ITEMS:-24}"
TALK_MODE="${TALK_MODE:-always}"
TTS_ENDPOINT="${TTS_ENDPOINT:-${KOKORO_ENDPOINT:-http://piper:8080/api/tts}}"
TTS_VOICE="${TTS_VOICE:-${KOKORO_VOICE:-de-thorsten-low.onnx}}"
TTS_VOICE_DE="${TTS_VOICE_DE:-$TTS_VOICE}"
TTS_VOICE_EN="${TTS_VOICE_EN:-$TTS_VOICE_DE}"
TTS_FORMAT="${TTS_FORMAT:-${KOKORO_FORMAT:-wav}}"
TTS_OUT_LIST="${TTS_OUT_LIST:-tts:out}"
TTS_LOCAL_PLAYBACK="${TTS_LOCAL_PLAYBACK:-0}"
OPENCLAW_TIMEOUT_SECS="${OPENCLAW_TIMEOUT_SECS:-90}"
COOLDOWN_MS="${COOLDOWN_MS:-1200}"
DEBUG="${DEBUG:-0}"
OLLAMA_CHAT_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/chat"

debug() {
  [ "$DEBUG" = "1" ] && echo "[turn-driver] $*" >&2 || true
}

maybe_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "${OPENCLAW_TIMEOUT_SECS}"s "$@"
  else
    "$@"
  fi
}

echo "[turn-driver] started machine=${MACHINE_ID} redis_host=${REDIS_HOST} ollama=${OLLAMA_HOST}:${OLLAMA_PORT} model=${OLLAMA_MODEL}" >&2

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
  HISTORY_RAW="$(redis-cli --raw -h "$REDIS_HOST" LRANGE conversation:log 0 "$((OLLAMA_HISTORY_ITEMS - 1))" 2>/dev/null || true)"
  PAYLOAD="$(python3 - "$OLLAMA_MODEL" "$OLLAMA_SYSTEM_PROMPT" "$MSG" "$OLLAMA_NUM_PREDICT" "$HISTORY_RAW" <<'PY'
import json
import sys

model, system_prompt, user_msg, num_predict, history_raw = sys.argv[1:6]
history_lines = [ln for ln in history_raw.splitlines() if ln.strip()]
messages = [{"role": "system", "content": system_prompt}]

# Redis list is newest-first due to LPUSH; reverse to chronological.
for line in reversed(history_lines):
    try:
        item = json.loads(line)
    except Exception:
        continue
    kind = (item.get("kind") or "").strip().lower()
    text = (item.get("text") or "").strip()
    if not text:
        continue
    if kind == "user":
        messages.append({"role": "user", "content": text})
    elif kind == "assistant":
        messages.append({"role": "assistant", "content": text})

# Ensure current turn is present exactly once at the end.
if not (messages and messages[-1].get("role") == "user" and messages[-1].get("content") == user_msg):
    messages.append({"role": "user", "content": user_msg})

print(json.dumps({
    "model": model,
    "stream": False,
    "options": {"num_predict": int(num_predict)},
    "messages": messages,
}))
PY
)"

  RESP="$(maybe_timeout curl -sS --fail \
    --connect-timeout 5 \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    "$OLLAMA_CHAT_URL" 2>&1 || true)"

  python3 - "$RESP" <<'PY'
import json
import sys

raw = sys.argv[1]
try:
    doc = json.loads(raw)
    print((doc.get("message") or {}).get("content", "").strip())
except Exception:
    print(raw.strip())
PY
}

parse_reply() {
  RAW_REPLY="$1"
  python3 - "$RAW_REPLY" "$TALK_MODE" <<'PY'
import base64
import json
import re
import sys

raw = (sys.argv[1] or "").strip()
talk_mode = (sys.argv[2] or "always").strip().lower()

def b64(s):
    return base64.b64encode((s or "").encode("utf-8")).decode("ascii")

def try_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None

doc = try_json(raw)
if isinstance(doc, str):
    # Model sometimes returns JSON as a quoted JSON string.
    nested = try_json(doc.strip())
    if isinstance(nested, dict):
        doc = nested
if doc is None:
    # Try fenced JSON blocks.
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, flags=re.S)
    if m:
        doc = try_json(m.group(1))
if doc is None:
    # Fallback: first JSON object in the reply.
    m = re.search(r"\{.*\}", raw, flags=re.S)
    if m:
        doc = try_json(m.group(0))

mode = "text"
assistant_text = raw
talk_text = ""

if isinstance(doc, dict):
    tool = (doc.get("tool") or "").strip().lower()
    txt = (doc.get("text") or doc.get("content") or doc.get("message") or "").strip()
    if tool in {"talk", "tts", "speak"} and txt:
        mode = "talk"
        talk_text = txt
        assistant_text = txt
    elif txt:
        # Even with unknown tools, prefer a provided text/content field over raw JSON.
        mode = "talk" if talk_mode == "always" else "text"
        talk_text = txt
        assistant_text = txt

if mode != "talk" and talk_mode == "always" and raw:
    # Last fallback for plain text replies.
    mode = "talk"
    talk_text = raw
    assistant_text = raw

print(mode + "\t" + b64(talk_text) + "\t" + b64(assistant_text))
PY
}

decode_b64() {
  python3 - "$1" <<'PY'
import base64
import sys
v = sys.argv[1] or ""
if not v:
    print("")
else:
    print(base64.b64decode(v.encode("ascii")).decode("utf-8"))
PY
}

choose_tts_voice() {
  TXT="$1"
  python3 - "$TXT" "$TTS_VOICE_DE" "$TTS_VOICE_EN" <<'PY'
import re
import sys

text = (sys.argv[1] or "").lower()
voice_de = sys.argv[2]
voice_en = sys.argv[3]

# Token-score heuristic for German vs English.
de_words = {
    "der", "die", "das", "und", "ist", "nicht", "bitte", "danke", "ich", "du",
    "sie", "wir", "ihr", "euch", "mir", "dir", "heute", "uhr", "hallo", "gut",
    "wie", "was", "warum", "wo", "wann", "ein", "eine", "einen", "dem", "den",
    "mit", "für", "auf", "im", "am", "zum", "zur", "kein", "ja", "nein"
}
en_words = {
    "the", "and", "is", "are", "not", "please", "thanks", "thank", "i", "you",
    "we", "they", "hello", "good", "what", "why", "where", "when", "a", "an",
    "to", "of", "in", "on", "for", "with", "this", "that", "yes", "no"
}

tokens = re.findall(r"[a-zA-Zäöüß]+", text)
de_score = 0
en_score = 0

if any(ch in text for ch in "äöüß"):
    de_score += 3

for t in tokens:
    if t in de_words:
        de_score += 1
    if t in en_words:
        en_score += 1

if not tokens:
    print(voice_de)
else:
    # Prefer DE on ties to avoid drifting into English voice for mixed/short utterances.
    print(voice_de if de_score >= en_score else voice_en)
PY
}

speak_text() {
  SAY="$1"
  [ -z "$SAY" ] && return 0

  # In this setup, host-tts-player is the default playback path.
  if [ "$TTS_LOCAL_PLAYBACK" != "1" ]; then
    redis-cli -h "$REDIS_HOST" LPUSH "$TTS_OUT_LIST" "$SAY" >/dev/null || true
    return 0
  fi

  TMP_AUDIO="/tmp/turn-driver-tts.${TTS_FORMAT}"
  VOICE="$(choose_tts_voice "$SAY")"
  PAYLOAD="$(python3 - "$SAY" "$VOICE" <<'PY'
import json
import sys
text, voice = sys.argv[1:3]
print(json.dumps({
    "text": text,
    "voice": voice
}))
PY
)"

  if ! maybe_timeout curl -sS --fail \
    --connect-timeout 5 \
    -H 'Content-Type: application/json' \
    -d "$PAYLOAD" \
    "$TTS_ENDPOINT" \
    --output "$TMP_AUDIO" >/dev/null; then
    if [ "$VOICE" != "$TTS_VOICE_DE" ]; then
      PAYLOAD="$(python3 - "$SAY" "$TTS_VOICE_DE" <<'PY'
import json
import sys
text, voice = sys.argv[1:3]
print(json.dumps({"text": text, "voice": voice}))
PY
)"
      maybe_timeout curl -sS --fail \
        --connect-timeout 5 \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD" \
        "$TTS_ENDPOINT" \
        --output "$TMP_AUDIO" >/dev/null || true
    fi
  fi

  PLAYED=0
  if command -v aplay >/dev/null 2>&1; then
    if maybe_timeout aplay -q "$TMP_AUDIO" >/dev/null 2>&1; then
      PLAYED=1
    else
      echo "[turn-driver] playback_failed aplay could not access audio device" >&2
    fi
  else
    echo "[turn-driver] playback_unavailable install aplay/alsa-utils in turn-driver image" >&2
  fi

  if [ "$PLAYED" != "1" ]; then
    redis-cli -h "$REDIS_HOST" LPUSH "$TTS_OUT_LIST" "$SAY" >/dev/null || true
  fi

  rm -f "$TMP_AUDIO"
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
  PARSED_LINE="$(parse_reply "$REPLY")"
  MODE="$(printf '%s' "$PARSED_LINE" | cut -f1)"
  TALK_B64="$(printf '%s' "$PARSED_LINE" | cut -f2)"
  ASSIST_B64="$(printf '%s' "$PARSED_LINE" | cut -f3)"
  TALK_TEXT="$(decode_b64 "$TALK_B64")"
  ASSIST_TEXT="$(decode_b64 "$ASSIST_B64")"

  if [ "$MODE" = "talk" ] && [ -n "$TALK_TEXT" ]; then
    speak_text "$TALK_TEXT" || true
  fi
  [ -z "$ASSIST_TEXT" ] && ASSIST_TEXT="$REPLY"
  debug "reply=$ASSIST_TEXT"

  NOW_MS="$(( $(date +%s) * 1000 ))"
  ESC_REPLY="$(printf '%s' "$ASSIST_TEXT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  ASSISTANT_PAYLOAD="{\"source\":\"$MACHINE_ID\",\"kind\":\"assistant\",\"text\":\"$ESC_REPLY\",\"timestamp_ms\":$NOW_MS}"

  redis-cli -h "$REDIS_HOST" LPUSH conversation:log "$ASSISTANT_PAYLOAD" >/dev/null || true
  redis-cli -h "$REDIS_HOST" LTRIM conversation:log 0 99 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:last_tts_text "$ASSIST_TEXT" EX 120 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:last_tts_ts_ms "$NOW_MS" EX 120 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:speaking 0 EX 2 >/dev/null || true
  redis-cli -h "$REDIS_HOST" SET agent:cooldown_until_ms "$((NOW_MS + COOLDOWN_MS))" EX 5 >/dev/null || true
done
