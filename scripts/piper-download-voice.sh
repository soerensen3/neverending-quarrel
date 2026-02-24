#!/bin/sh
set -eu

# Download a Piper voice archive into ./models/piper and extract it.
# Usage:
#   scripts/piper-download-voice.sh voice-de-thorsten-low.tar.gz
#   scripts/piper-download-voice.sh voice-de-thorsten-medium.tar.gz

VOICE_ARCHIVE="${1:-voice-de-thorsten-low.tar.gz}"
TARGET_DIR="${2:-./models/piper}"
BASE_URL="https://github.com/rhasspy/piper/releases/download/v0.0.2"

mkdir -p "$TARGET_DIR"
TMP_ARCHIVE="/tmp/${VOICE_ARCHIVE}"

echo "Downloading $VOICE_ARCHIVE ..."
curl -fL "${BASE_URL}/${VOICE_ARCHIVE}" -o "$TMP_ARCHIVE"
tar -xzf "$TMP_ARCHIVE" -C "$TARGET_DIR"
rm -f "$TMP_ARCHIVE"

echo "Voice extracted to $TARGET_DIR"
echo "Now restart piper: podman compose up -d --force-recreate piper"
