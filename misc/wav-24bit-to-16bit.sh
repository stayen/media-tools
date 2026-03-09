#!/usr/bin/env bash
# wav-24bit-to-16bit — Convert 24-bit WAV to 16-bit WAV, preserving metadata.
# Usage: wav-24bit-to-16bit [-s] <input.wav> <output.wav>
#   -s  strip (skip) metadata copy (default: metadata is preserved)

set -euo pipefail

COPY_META=true

while getopts "s" opt; do
  case "$opt" in
    s) COPY_META=false ;;
    *) echo "Usage: $(basename "$0") [-s] <input.wav> <output.wav>" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ $# -ne 2 ]]; then
  echo "Usage: $(basename "$0") [-s] <input.wav> <output.wav>" >&2
  exit 1
fi

INPUT="$1"
OUTPUT="$2"

if [[ ! -f "$INPUT" ]]; then
  echo "Error: input file '$INPUT' not found." >&2
  exit 1
fi

MAP_META=()
if $COPY_META; then
  MAP_META=(-map_metadata 0)
fi

ffmpeg -hide_banner -i "$INPUT" \
  -acodec pcm_s16le \
  -sample_fmt s16 \
  "${MAP_META[@]}" \
  -bitexact \
  "$OUTPUT"
