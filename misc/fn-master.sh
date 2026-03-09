#!/usr/bin/env bash
set -euo pipefail

#
# Does denoising and mastering to selected loudness parms
#

usage() {
  cat <<'USAGE'
Usage:
   fn-master.sh [options] -i INFILE -o OUTFILE
Options:
  -I, --lufs          Expected integrated loudness LUFS   [-14]
  -T, --tp            Expected true peak (dBTP)           [-1.0]
  -L, --lra           Expected loudness range (LU)        [11]

Examples:
  fn-master.sh -I 14 -T -1.0 -L 11 -i in.wav -o out.wav
USAGE
}

INFILE=""
OUTFILE=""
I_TARGET="-14"
TP_TARGET="-1.0"
LRA_TARGET="11"
SAMPLE_RATE="48000"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -I|--lufs) I_TARGET="$2"; shift 2;;
    -T|--tp)   TP_TARGET="$2"; shift 2;;
    -L|--lra)  LRA_TARGET="$2"; shift 2;;
    -ar)       SAMPLE_RATE="$2"; shift 2;;
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

ffmpeg-normalize "${INFILE}" \
   -nt ebu -t ${I_TARGET} -tp ${TP_TARGET} -lrt ${LRA_TARGET} --keep-lra-above-loudness-range-target \
  -prf "highpass=60,lowpass=16000,afftdn=nr=12:nf=-45" \
  -ar ${SAMPLE_RATE} -c:a pcm_s24le -p -o "${OUTFILE}"
