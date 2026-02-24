#!/bin/sh
set -eu

# Complete restart helper:
# 1) stop host audio bridge
# 2) recreate full compose stack
# 3) start host audio bridge again
#
# Optional env overrides:
#   AUDIO_PLAYER
#   AUDIO_IN_DEVICE
#   AUDIO_OUT_DEVICE
#   WHISPER_LANGUAGE
#   DENOISE

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

cd "$ROOT_DIR"

echo "[restart] stopping audio bridge..."
./scripts/start-audio-bridge.sh stop || true

echo "[restart] restarting compose stack..."
podman compose down --remove-orphans
podman compose up -d --force-recreate

echo "[restart] starting audio bridge..."
./scripts/start-audio-bridge.sh start

echo "[restart] stack status:"
podman compose ps

echo "[restart] done."
echo "Logs:"
echo "  /tmp/host-stt-listener.log"
echo "  /tmp/host-tts-player.log"
