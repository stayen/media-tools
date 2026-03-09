#!/usr/bin/env bash
# embed-art-mp3.sh
# Cleanly (re)embed a single Front Cover image into MP3 files as ID3v2.3.

set -euo pipefail

if ! command -v eyeD3 >/dev/null 2>&1; then
  echo "Error: eyeD3 not found." >&2
  exit 1
fi

if [[ $# -lt 2 ]]; then
  cat <<USAGE
Usage: $0 <cover.jpg> <file-or-glob.mp3> [more.mp3 ...]
Tips:
  - Use a baseline 500–600px JPEG for best car/tablet compatibility.
  - Example: $0 cover_600.jpg *.mp3
USAGE
  exit 1
fi

cover="$1"; shift
if [[ ! -f "$cover" ]]; then
  echo "Error: cover image not found: $cover" >&2
  exit 1
fi

rc=0
for f in "$@"; do
  if [[ ! -f "$f" ]]; then
    echo "Skip (not a file): $f" >&2
    rc=1
    continue
  fi

  echo ">> Processing: $f"
  # Remove all existing images / APIC frames (avoid duplicate/secondary types).
  eyeD3 --remove-all-images "$f" >/dev/null

  # Ensure ID3v2 tag exists (some files might be missing it).
  eyeD3 --v2 "$f" >/dev/null

  # Add exactly one Front Cover. (APIC type: FRONT_COVER)
  eyeD3 --add-image "$cover:FRONT_COVER" "$f" >/dev/null

  # Convert tag flavor to v2.3 for older devices.
  eyeD3 --to-v2.3 "$f" >/dev/null

  echo "   OK: embedded Front Cover (ID3v2.3)"
done

exit $rc
