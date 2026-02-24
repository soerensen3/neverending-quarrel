#!/bin/sh
set -eu

# Host-side TTS player for rootless Podman setups where /dev/snd is blocked in containers.
# It reads speech text from Redis list tts:out and plays audio via host aplay.
#
# Usage:
#   scripts/host-tts-player.sh
#
# Env:
#   COMPOSE_FILE (default: docker-compose.yml)
#   TTS_OUT_LIST (default: tts:out)
#   TTS_URL (default: http://127.0.0.1:8080/api/tts)
#   TTS_VOICE (default: de-thorsten-low.onnx)
#   TTS_VOICE_DE (default: $TTS_VOICE)
#   TTS_VOICE_EN (default: $TTS_VOICE_DE)
#   TTS_FORMAT (default: wav)
#   AUDIO_OUT_DEVICE (optional ALSA output device, e.g. hw:0,0)
#   AUDIO_PLAYER (default: pw-play; fallback: paplay, aplay)
#   USE_FLATPAK_SPAWN (default: 0)

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
TTS_OUT_LIST="${TTS_OUT_LIST:-tts:out}"
TTS_URL="${TTS_URL:-${KOKORO_URL:-http://127.0.0.1:8080/api/tts}}"
TTS_VOICE="${TTS_VOICE:-${KOKORO_VOICE:-de-thorsten-low.onnx}}"
TTS_VOICE_DE="${TTS_VOICE_DE:-$TTS_VOICE}"
TTS_VOICE_EN="${TTS_VOICE_EN:-en-us-lessac-medium.onnx}"
TTS_FORMAT="${TTS_FORMAT:-${KOKORO_FORMAT:-wav}}"
AUDIO_OUT_DEVICE="${AUDIO_OUT_DEVICE:-}"
AUDIO_PLAYER="${AUDIO_PLAYER:-pw-play}"
USE_FLATPAK_SPAWN="${USE_FLATPAK_SPAWN:-0}"

if ! command -v aplay >/dev/null 2>&1; then
  echo "aplay not found on host. Install alsa-utils." >&2
  exit 1
fi

TMP_AUDIO="/tmp/host-tts.${TTS_FORMAT}"

choose_tts_voice() {
  TXT="$1"
  python3 - "$TXT" "$TTS_VOICE_DE" "$TTS_VOICE_EN" <<'PY'
import re
import sys

text = (sys.argv[1] or "").lower()
voice_de = sys.argv[2]
voice_en = sys.argv[3]
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
    print(voice_de if de_score >= en_score else voice_en)
PY
}

while :; do
  if [ "$USE_FLATPAK_SPAWN" = "1" ]; then
    OUT="$(flatpak-spawn --host podman compose -f "$COMPOSE_FILE" exec -T redis redis-cli --raw BRPOP "$TTS_OUT_LIST" 0 || true)"
  else
    OUT="$(podman compose -f "$COMPOSE_FILE" exec -T redis redis-cli --raw BRPOP "$TTS_OUT_LIST" 0 || true)"
  fi
  TEXT="$(printf '%s\n' "$OUT" | sed -n '2p')"
  [ -z "$TEXT" ] && continue

  VOICE="$(choose_tts_voice "$TEXT")"
  PAYLOAD="$(python3 - "$TEXT" "$VOICE" <<'PY'
import json
import sys
text, voice = sys.argv[1:3]
print(json.dumps({
    "text": text,
    "voice": voice
}))
PY
)"

  OK=0
  if curl -sS --fail -H 'Content-Type: application/json' -d "$PAYLOAD" "$TTS_URL" --output "$TMP_AUDIO"; then
    OK=1
  elif [ "$VOICE" != "$TTS_VOICE_DE" ]; then
    PAYLOAD="$(python3 - "$TEXT" "$TTS_VOICE_DE" <<'PY'
import json
import sys
text, voice = sys.argv[1:3]
print(json.dumps({"text": text, "voice": voice}))
PY
)"
    if curl -sS --fail -H 'Content-Type: application/json' -d "$PAYLOAD" "$TTS_URL" --output "$TMP_AUDIO"; then
      OK=1
    fi
  fi

  if [ "$OK" = "1" ]; then
    if [ "$AUDIO_PLAYER" = "pw-play" ] && command -v pw-play >/dev/null 2>&1; then
      if ! pw-play "$TMP_AUDIO" >/dev/null 2>&1; then
        echo "[host-tts] pw-play failed" >&2
      fi
    elif [ "$AUDIO_PLAYER" = "paplay" ] && command -v paplay >/dev/null 2>&1; then
      if ! paplay "$TMP_AUDIO" >/dev/null 2>&1; then
        echo "[host-tts] paplay failed" >&2
      fi
    else
      if [ -n "$AUDIO_OUT_DEVICE" ]; then
        if ! aplay -q -D "$AUDIO_OUT_DEVICE" "$TMP_AUDIO"; then
          echo "[host-tts] aplay failed on device=$AUDIO_OUT_DEVICE" >&2
        fi
      else
        if ! aplay -q "$TMP_AUDIO"; then
          echo "[host-tts] aplay failed on default device" >&2
        fi
      fi
    fi
  else
    echo "[host-tts] synthesis failed for text chunk" >&2
  fi
done
