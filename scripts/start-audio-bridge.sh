#!/bin/sh
set -eu

# Manage host audio bridge processes:
# - host-stt-listener.sh (mic -> whisper -> redis stt:transcripts)
# - host-tts-player.sh (redis tts:out -> piper -> speakers)
#
# Usage:
#   scripts/start-audio-bridge.sh start
#   scripts/start-audio-bridge.sh stop
#   scripts/start-audio-bridge.sh status
#   scripts/start-audio-bridge.sh test

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

AUDIO_IN_DEVICE="${AUDIO_IN_DEVICE:-default}"
AUDIO_OUT_DEVICE="${AUDIO_OUT_DEVICE:-plughw:CARD=Headset,DEV=0}"
AUDIO_PLAYER="${AUDIO_PLAYER:-pw-play}"
AUDIO_RATE="${AUDIO_RATE:-48000}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-de}"
DENOISE="${DENOISE:-1}"
CHUNK_SECONDS="${CHUNK_SECONDS:-2}"
PAUSE_SILENT_CHUNKS="${PAUSE_SILENT_CHUNKS:-2}"
MIN_SPEECH_SEC="${MIN_SPEECH_SEC:-0.20}"
RMS_DB_THRESHOLD="${RMS_DB_THRESHOLD:--56}"
MAX_BUFFER_CHUNKS="${MAX_BUFFER_CHUNKS:-8}"

start_bridge() {
  stop_bridge

  cd "$ROOT_DIR"
  nohup env \
    AUDIO_PLAYER="$AUDIO_PLAYER" \
    AUDIO_OUT_DEVICE="$AUDIO_OUT_DEVICE" \
    sh ./scripts/host-tts-player.sh >/tmp/host-tts-player.log 2>&1 < /dev/null &

  nohup env \
    AUDIO_DEVICE="$AUDIO_IN_DEVICE" \
    AUDIO_RATE="$AUDIO_RATE" \
    WHISPER_LANGUAGE="$WHISPER_LANGUAGE" \
    DENOISE="$DENOISE" \
    CHUNK_SECONDS="$CHUNK_SECONDS" \
    PAUSE_SILENT_CHUNKS="$PAUSE_SILENT_CHUNKS" \
    MIN_SPEECH_SEC="$MIN_SPEECH_SEC" \
    RMS_DB_THRESHOLD="$RMS_DB_THRESHOLD" \
    MAX_BUFFER_CHUNKS="$MAX_BUFFER_CHUNKS" \
    sh ./scripts/host-stt-listener.sh >/tmp/host-stt-listener.log 2>&1 < /dev/null &

  sleep 1
  status_bridge
}

stop_bridge() {
  ps -eo pid,args | awk '$0 ~ /^ *[0-9]+ sh \.\/scripts\/host-tts-player\.sh$/ {print $1}' | xargs -r kill
  ps -eo pid,args | awk '$0 ~ /^ *[0-9]+ sh \.\/scripts\/host-stt-listener\.sh$/ {print $1}' | xargs -r kill
}

status_bridge() {
  echo "TTS:"
  pgrep -af "^sh ./scripts/host-tts-player.sh$" || echo "  not running"
  echo "STT:"
  pgrep -af "^sh ./scripts/host-stt-listener.sh$" || echo "  not running"
}

test_bridge() {
  cd "$ROOT_DIR"
  podman compose exec -T redis redis-cli LPUSH tts:out "Audio bridge test." >/dev/null
  echo "queued tts test"
}

CMD="${1:-status}"
case "$CMD" in
  start) start_bridge ;;
  stop) stop_bridge; status_bridge ;;
  status) status_bridge ;;
  test) test_bridge ;;
  *)
    echo "usage: $0 {start|stop|status|test}" >&2
    exit 2
    ;;
esac
