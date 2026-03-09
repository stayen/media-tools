#!/usr/bin/env bash
set -euo pipefail

# Loudness normalize WAV (or any audio) to target LUFS and True Peak using FFmpeg loudnorm (two-pass).
# Requirements: ffmpeg, jq
# Example:
#   ./loudnorm-two-pass.sh -i in.wav -o out.wav -I -14 -T -1.0 -L 11

usage() {
  cat <<'USAGE'
Usage:
  loudnorm-two-pass.sh -i INPUT -o OUTPUT [-I LUFS] [-T dBTP] [-L LRA] [--linear true|false] [--dualmono true|false]

Options (defaults in brackets):
  -i, --input     Input audio file (wav/mp3/flac/m4a etc.)
  -o, --output    Output WAV file (pcm_s24le by default)
  -I, --lufs      Target integrated loudness LUFS         [-14]
  -T, --tp        Target true peak (dBTP)                 [-1.0]
  -L, --lra       Target loudness range (LU)              [11]
      --linear    Linear normalization mode               [true]
      --dualmono  Dual-mono correction                    [false]
      --codec     Output audio codec (e.g. pcm_s24le)     [pcm_s24le]
      --verify    After pass 2, run a verify measurement  [on]
      -ar         Sample rate, Hz                         [48000]

Notes:
- Two-pass loudnorm requires measured_* values from pass 1 to be fed into pass 2. (FFmpeg docs)
- Target LRA should not be lower than the source LRA; if constraints are violated, filter may revert to dynamic mode. (FFmpeg docs)
USAGE
}

# --- defaults ---
I_TARGET="-14"
TP_TARGET="-1.0"
LRA_TARGET="11"
LINEAR="true"
DUALMONO="false"
CODEC="pcm_s24le"
VERIFY=1
SAMPLE_RATE="48000"

# --- parse args ---
IN="" ; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)   IN="$2"; shift 2;;
    -o|--output)  OUT="$2"; shift 2;;
    -I|--lufs)    I_TARGET="$2"; shift 2;;
    -T|--tp)      TP_TARGET="$2"; shift 2;;
    -L|--lra)     LRA_TARGET="$2"; shift 2;;
    --linear)     LINEAR="$2"; shift 2;;
    --dualmono)   DUALMONO="$2"; shift 2;;
    --codec)      CODEC="$2"; shift 2;;
    --verify)     VERIFY=1; shift;;
    -h|--help)    usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

[[ -n "$IN" && -n "$OUT" ]] || { usage; exit 1; }
command -v ffmpeg >/dev/null || { echo "Missing: ffmpeg" >&2; exit 1; }
command -v jq >/dev/null     || { echo "Missing: jq" >&2; exit 1; }
[[ -f "$IN" ]] || { echo "Input not found: $IN" >&2; exit 1; }

# --- PASS 1: measure ---
echo "[1/3] Measuring loudness on: $IN"
PASS1_LOG="$(mktemp)"
# We capture the JSON block from stderr and keep only the JSON object.
ffmpeg -hide_banner -nostdin -i "$IN" \
  -af "loudnorm=I=${I_TARGET}:TP=${TP_TARGET}:LRA=${LRA_TARGET}:print_format=json" \
  -f null - 2> "$PASS1_LOG" || true

# Extract first JSON object from the log (loudnorm prints one).
MEASURE_JSON="$(awk 'BEGIN{p=0} /^\s*\{/{p=1} p{print} /^\s*\}/{if(p){exit}}' "$PASS1_LOG")"
if [[ -z "$MEASURE_JSON" ]]; then
  echo "ERROR: Could not capture loudnorm JSON from pass 1." >&2
  exit 2
fi

# --- parse pass-1 JSON safely ---
meas_I=$(echo "$MEASURE_JSON"      | jq -r '.measured_I // .input_i')
meas_LRA=$(echo "$MEASURE_JSON"    | jq -r '.measured_LRA // .input_lra')
# FFmpeg prints measured_TP (capital TP); some builds show measured_tp/input_tp
meas_TP=$(echo "$MEASURE_JSON"     | jq -r '.measured_TP // .measured_tp // .input_tp')
meas_thresh=$(echo "$MEASURE_JSON" | jq -r '.measured_thresh // .input_thresh // empty')
meas_offset=$(echo "$MEASURE_JSON" | jq -r '.target_offset // .offset // empty')

echo "  measured_I=$meas_I, measured_LRA=$meas_LRA, measured_TP=$meas_TP, measured_thresh=${meas_thresh:-<none>}, offset=${meas_offset:-<none>}"

# If measured_thresh is missing, dynamic mode is safer than forcing linear=true
EFFECTIVE_LINEAR="$LINEAR"
if [[ -z "$meas_thresh" && "$LINEAR" == "true" ]]; then
  echo "  note: measured_thresh is missing; falling back to linear=false for pass 2."
  EFFECTIVE_LINEAR="false"
fi

# --- build pass-2 filter string (only include present keys) ---
FILTER="loudnorm=I=${I_TARGET}:TP=${TP_TARGET}:LRA=${LRA_TARGET}:linear=${EFFECTIVE_LINEAR}:dual_mono=${DUALMONO}"
FILTER="${FILTER}:measured_I=${meas_I}:measured_LRA=${meas_LRA}:measured_TP=${meas_TP}"
[[ -n "$meas_thresh" ]] && FILTER="${FILTER}:measured_thresh=${meas_thresh}"
[[ -n "$meas_offset" ]] && FILTER="${FILTER}:offset=${meas_offset}"
FILTER="${FILTER}:print_format=summary"

echo "[2/3] Applying normalization to: $OUT"
# echo ffmpeg -hide_banner -y -nostdin -i "$IN" -c:a "$CODEC" -af "$FILTER" "$OUT"
ffmpeg -hide_banner -y -nostdin -i "$IN" -ar "${SAMPLE_RATE}" -c:a "$CODEC" -af "$FILTER" "$OUT"

# --- PASS 3: verify (optional) ---
if [[ $VERIFY -eq 1 ]]; then
  echo "[3/3] Verifying result:"
  ffmpeg -hide_banner -nostdin -i "$OUT" \
    -af "loudnorm=I=${I_TARGET}:TP=${TP_TARGET}:LRA=${LRA_TARGET}:print_format=json" \
    -f null - 2>&1 \
    | awk 'BEGIN{p=0} /^\s*\{/{p=1} p{print} /^\s*\}/{if(p){exit}}'
fi

rm -f "$PASS1_LOG"
echo "Done."
