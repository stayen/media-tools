#!/usr/bin/env bash
set -euo pipefail

#
# Does denoising and mastering to selected loudness parms
#

usage() {
  cat <<'USAGE'
Usage:
   slowdown-video.sh [OPTIONS] -i INFILE -o OUTFILE
Options:
  -f factor      Slowdown factor; 2.0 by default.

Examples:
  slowdown-video.sh -f 2.5 -i in.mp4 -o out.mp4
USAGE
}

INFILE=""
OUTFILE=""

ARGS=()
FACTOR="2.0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)        FACTOR="$2"; shift 2;;
    -i)        INFILE="$2"; shift 2;;
    -o)        OUTFILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) echo "Unknown option: $1" >&2; usage; exit 1;;
    *) ARGS+=("$1"); shift;;
  esac
done

if [[ "x${INFILE}" == "x" ]]; then
    usage
    exit 0
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 1; }; }
need ffmpeg-normalize
need ffmpeg

ffmpeg -i "${INFILE}" -vf "setpts=${FACTOR}*PTS" -an "${OUTFILE}"
