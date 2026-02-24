#!/bin/sh
set -eu

# Host-side continuous STT listener.
# Captures microphone chunks, transcribes with Whisper webservice, and pushes text into Redis.
#
# Usage:
#   scripts/host-stt-listener.sh
#
# Env:
#   COMPOSE_FILE (default: docker-compose.yml)
#   STT_INPUT_LIST (default: stt:transcripts)
#   WHISPER_URL (default: http://127.0.0.1:9000/asr)
#   WHISPER_LANGUAGE (default: de)
#   CHUNK_SECONDS (default: 2)
#   AUDIO_RATE (default: 16000)
#   AUDIO_DEVICE (optional ALSA device, e.g. default, hw:2,0)
#   MIN_CHARS (default: 2)
#   DENOISE (default: 1)
#     0 = off
#     1 = light (recommended)
#     2 = strong
#   RMS_DB_THRESHOLD (default: -56)
#   MIN_SPEECH_SEC (default: 0.20)
#   PAUSE_SILENT_CHUNKS (default: 2)
#   MAX_BUFFER_CHUNKS (default: 8)
#   USE_FLATPAK_SPAWN (default: 0)

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
STT_INPUT_LIST="${STT_INPUT_LIST:-stt:transcripts}"
WHISPER_URL="${WHISPER_URL:-http://127.0.0.1:9000/asr}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-de}"
CHUNK_SECONDS="${CHUNK_SECONDS:-2}"
AUDIO_RATE="${AUDIO_RATE:-16000}"
AUDIO_DEVICE="${AUDIO_DEVICE:-}"
MIN_CHARS="${MIN_CHARS:-2}"
DENOISE="${DENOISE:-1}"
RMS_DB_THRESHOLD="${RMS_DB_THRESHOLD:--56}"
MIN_SPEECH_SEC="${MIN_SPEECH_SEC:-0.20}"
PAUSE_SILENT_CHUNKS="${PAUSE_SILENT_CHUNKS:-2}"
MAX_BUFFER_CHUNKS="${MAX_BUFFER_CHUNKS:-8}"
USE_FLATPAK_SPAWN="${USE_FLATPAK_SPAWN:-0}"

if ! command -v arecord >/dev/null 2>&1; then
  echo "arecord not found on host. Install alsa-utils." >&2
  exit 1
fi

push_redis() {
  text="$1"
  [ -z "$text" ] && return 0
  if [ "$USE_FLATPAK_SPAWN" = "1" ]; then
    flatpak-spawn --host podman compose -f "$COMPOSE_FILE" exec -T redis redis-cli LPUSH "$STT_INPUT_LIST" "$text" >/dev/null || true
  else
    podman compose -f "$COMPOSE_FILE" exec -T redis redis-cli LPUSH "$STT_INPUT_LIST" "$text" >/dev/null || true
  fi
}

TMP_WAV="/tmp/host-stt-chunk.wav"
TMP_WAV_PROC="/tmp/host-stt-chunk-processed.wav"
BUFFER_TEXT=""
BUFFER_CHUNKS=0
LAST_CHUNK_TEXT=""
SILENT_CHUNKS=0

process_audio() {
  IN="$1"
  OUT="$2"
  if [ "$DENOISE" != "1" ] || ! command -v ffmpeg >/dev/null 2>&1; then
    if [ "$DENOISE" = "0" ] || ! command -v ffmpeg >/dev/null 2>&1; then
      cp "$IN" "$OUT"
      return 0
    fi
  fi
  if [ "$DENOISE" = "2" ]; then
    ffmpeg -y -loglevel error -i "$IN" \
      -af "highpass=f=80,lowpass=f=7000,afftdn=nf=-12,volume=1.15" \
      -ar "$AUDIO_RATE" -ac 1 "$OUT" >/dev/null 2>&1 || cp "$IN" "$OUT"
  else
    ffmpeg -y -loglevel error -i "$IN" \
      -af "highpass=f=70,lowpass=f=7600,volume=1.08" \
      -ar "$AUDIO_RATE" -ac 1 "$OUT" >/dev/null 2>&1 || cp "$IN" "$OUT"
  fi
}

speech_seconds() {
  WAV="$1"
  python3 - "$WAV" "$RMS_DB_THRESHOLD" <<'PY'
import array
import math
import sys
import wave

path = sys.argv[1]
thr_db = float(sys.argv[2])
frame_ms = 30

try:
    w = wave.open(path, "rb")
except Exception:
    print("0")
    raise SystemExit(0)

rate = w.getframerate()
width = w.getsampwidth()
channels = w.getnchannels()
frame_size = max(1, int(rate * frame_ms / 1000))
speech = 0.0

while True:
    raw = w.readframes(frame_size)
    if not raw:
        break
    if width != 2:
        continue
    vals = array.array("h")
    vals.frombytes(raw)
    if channels > 1:
        mono = []
        for i in range(0, len(vals), channels):
            chunk = vals[i:i+channels]
            if not chunk:
                continue
            mono.append(int(sum(chunk) / len(chunk)))
        vals = array.array("h", mono)
    if len(vals) == 0:
        continue
    sq = 0.0
    for v in vals:
        sq += float(v) * float(v)
    rms = math.sqrt(sq / len(vals))
    db = -120.0 if rms <= 0 else 20.0 * math.log10(rms / float((1 << (8 * width - 1)) - 1))
    if db >= thr_db:
        speech += frame_ms / 1000.0

w.close()
print(f"{speech:.3f}")
PY
}

flush_buffer() {
  [ -z "$BUFFER_TEXT" ] && return 0
  echo "[host-stt] $BUFFER_TEXT" >&2
  push_redis "$BUFFER_TEXT"
  BUFFER_TEXT=""
  BUFFER_CHUNKS=0
  LAST_CHUNK_TEXT=""
}

while :; do
  if [ -n "$AUDIO_DEVICE" ]; then
    arecord -q -D "$AUDIO_DEVICE" -f S16_LE -c 1 -r "$AUDIO_RATE" -d "$CHUNK_SECONDS" "$TMP_WAV" || true
  else
    arecord -q -f S16_LE -c 1 -r "$AUDIO_RATE" -d "$CHUNK_SECONDS" "$TMP_WAV" || true
  fi
  [ -s "$TMP_WAV" ] || continue
  process_audio "$TMP_WAV" "$TMP_WAV_PROC"

  SPEECH_SEC="$(speech_seconds "$TMP_WAV_PROC")"
  SPEECH_BELOW="$(python3 - "$SPEECH_SEC" "$MIN_SPEECH_SEC" <<'PY'
import sys
print(1 if float(sys.argv[1]) < float(sys.argv[2]) else 0)
PY
)"
  if [ "$SPEECH_BELOW" = "1" ]; then
    SILENT_CHUNKS=$((SILENT_CHUNKS + 1))
    if [ -n "$BUFFER_TEXT" ] && [ "$SILENT_CHUNKS" -ge "$PAUSE_SILENT_CHUNKS" ]; then
      flush_buffer
    fi
    continue
  fi
  SILENT_CHUNKS=0

  RESP="$(curl -sS --fail -X POST \
    -F "audio_file=@$TMP_WAV_PROC" \
    "$WHISPER_URL?task=transcribe&output=txt&language=$WHISPER_LANGUAGE" 2>/dev/null || true)"

  TEXT="$(printf '%s' "$RESP" | tr -d '\r' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')"
  [ "${#TEXT}" -lt "$MIN_CHARS" ] && continue
  [ "$TEXT" = "$LAST_CHUNK_TEXT" ] && continue
  LAST_CHUNK_TEXT="$TEXT"

  if [ -n "$BUFFER_TEXT" ]; then
    BUFFER_TEXT="$BUFFER_TEXT $TEXT"
  else
    BUFFER_TEXT="$TEXT"
  fi
  BUFFER_CHUNKS=$((BUFFER_CHUNKS + 1))

  if [ "$BUFFER_CHUNKS" -ge "$MAX_BUFFER_CHUNKS" ]; then
    flush_buffer
  fi
done
