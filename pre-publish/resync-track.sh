#!/usr/bin/env bash
# resync-track.sh
# Re-sync existing media files and update sidecar with current checksums/version IDs
# Usage: resync-track.sh [options] <PREFIX_opus_NNNN_master.wav>
#
# Use this when media files already exist and you need to:
#   - Recompute checksums and loudness data
#   - Re-upload files to S3
#   - Update sidecar with fresh version IDs
#
# Requires same environment as process-track.sh

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

DRY_RUN=0
VERBOSE=0
SKIP_UPLOAD=0
CHECKSUMS_ONLY=0

usage() {
  cat <<'USAGE'
Usage: resync-track.sh [options] <PREFIX_opus_NNNN_master.wav>

Re-syncs existing media files to S3 and updates sidecar metadata.

Use this when:
  - Files already exist (.wav, .mp3, .mp4, artwork)
  - You need to update checksums/loudness in sidecar
  - You need to re-upload to S3 and get fresh version IDs

Required Environment Variables:
  ENV_SITE        Private S3 bucket name / artist domain
  ENV_MEDIA_SITE  Public S3 bucket name / media domain

Options:
  -n, --dry-run        Show what would be done without executing
  -v, --verbose        Enable verbose output
  -s, --skip-upload    Skip S3 upload (only update sidecar checksums)
  -c, --checksums-only Only update checksums, no uploads
  -h, --help           Show this help message

Examples:
  resync-track.sh wilds_opus_6817_master.wav
  resync-track.sh --checksums-only wilds_opus_123_master.wav
USAGE
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${GREEN}▶${NC} $*"; }

die() { log_error "$*"; exit 1; }

run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] $*"
  else
    [[ $VERBOSE -eq 1 ]] && echo "  → $*"
    eval "$@"
  fi
}

check_dependencies() {
  local missing=()
  local cmds=(aws jq ffmpeg ffprobe sha256sum)
  
  for cmd in "${cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  
  [[ ${#missing[@]} -gt 0 ]] && die "Missing: ${missing[*]}"
}

check_environment() {
  [[ -z "${ENV_SITE:-}" ]] && die "ENV_SITE not set"
  [[ -z "${ENV_MEDIA_SITE:-}" ]] && die "ENV_MEDIA_SITE not set"
}

parse_wav_filename() {
  local wav="$1"
  local basename
  basename="$(basename "$wav")"
  
  [[ ! "$basename" =~ ^(.+)_opus_([0-9]+)_master\.wav$ ]] && \
    die "WAV filename must match: PREFIX_opus_NNNN_master.wav"
  
  PREFIX="${BASH_REMATCH[1]}"
  OPUS_NUM="${BASH_REMATCH[2]}"
  OPUS_INT=$((10#$OPUS_NUM))
}

calculate_infix() {
  local opus="$1"
  local padded infix_prefix
  
  padded=$(printf "%03d" "$opus")
  
  if [[ ${#padded} -le 2 ]]; then
    infix_prefix="0"
  else
    infix_prefix="${padded:0:${#padded}-2}"
  fi
  
  local slashed=""
  for ((i=0; i<${#infix_prefix}; i++)); do
    [[ -n "$slashed" ]] && slashed+="/"
    slashed+="${infix_prefix:$i:1}"
  done
  
  INFIX="${slashed}/${opus}"
}

update_checksums() {
  local json="$1"
  shift
  local files=("$@")
  
  log_step "Updating checksums and loudness"
  
  [[ $DRY_RUN -eq 1 ]] && {
    echo "  [dry-run] Would compute checksums for: ${files[*]}"
    return 0
  }
  
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    local ext="${f##*.}"
    ext="${ext,,}"
    local base
    base="$(basename "$f")"
    
    # File SHA-256
    local sha256
    sha256=$(sha256sum "$f" | awk '{print $1}')
    jq --arg ext "$ext" --arg val "$sha256" \
      '.checksums.file_sha256[$ext] = $val' "$json" > "${json}.tmp" && mv "${json}.tmp" "$json"
    
    # Audio stream hash
    local stream_sha
    stream_sha=$(ffmpeg -v error -i "$f" -map 0:a:0 -f streamhash -hash sha256 - 2>/dev/null \
      | tail -n1 | awk -F= '{print $NF}' | tr -d '\r\n') || true
    if [[ -n "$stream_sha" ]]; then
      jq --arg ext "$ext" --arg val "$stream_sha" \
        '.checksums.audio_stream_sha256[$ext] = $val' "$json" > "${json}.tmp" && mv "${json}.tmp" "$json"
    fi
    
    # Loudness
    if [[ "$ext" =~ ^(wav|mp3|mp4|m4a|flac)$ ]]; then
      local loudness_json
      loudness_json=$(ffmpeg -hide_banner -i "$f" \
        -filter:a loudnorm=I=-14:LRA=11:TP=-1.0:print_format=json \
        -f null - 2>&1 | awk 'BEGIN{p=0} /^ *\{/{p=1} {if(p)print} /^ *\}/{if(p){exit}}') || true
      
      if [[ -n "$loudness_json" ]]; then
        local lufs lra tp
        lufs=$(echo "$loudness_json" | jq -r '.input_i // .measured_I' 2>/dev/null | head -1)
        lra=$(echo "$loudness_json" | jq -r '.input_lra // .measured_LRA' 2>/dev/null | head -1)
        tp=$(echo "$loudness_json" | jq -r '.input_tp // .measured_tp' 2>/dev/null | head -1)
        
        jq --arg ext "$ext" --argjson lufs "$lufs" --argjson lra "$lra" --argjson tp "$tp" \
          '.tech.loudness[$ext] = {integrated_lufs: $lufs, lra: $lra, max_true_peak_db: $tp}' \
          "$json" > "${json}.tmp" && mv "${json}.tmp" "$json"
      fi
    fi
    
    echo "  ✓ $base"
  done
  
  log_success "Checksums updated"
}

upload_all() {
  local infix="$1"
  local wav="$2"
  local mp3="$3"
  local mp4="$4"
  
  log_step "Uploading to S3"
  
  # Art to public
  for art in ART.jpg ART_1024.jpg ART_512.jpg; do
    [[ -f "$art" ]] && run_cmd aws s3 cp "\"$art\"" "\"s3://${ENV_MEDIA_SITE}/${infix}/${art}\""
  done
  
  # Media to private
  for f in "$wav" "$mp3" "$mp4"; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    run_cmd aws s3 cp "\"$f\"" "\"s3://${ENV_SITE}/${infix}/${base}\""
  done
  
  [[ $DRY_RUN -eq 0 ]] && log_success "Upload complete"
}

update_version_ids() {
  local json="$1"
  local infix="$2"
  shift 2
  local files=("$@")
  
  log_step "Fetching S3 version IDs"
  
  [[ $DRY_RUN -eq 1 ]] && {
    echo "  [dry-run] Would fetch version IDs"
    return 0
  }
  
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    local base ext version_id
    base="$(basename "$f")"
    ext="${f##*.}"
    ext="${ext,,}"
    
    version_id=$(aws s3api list-object-versions \
      --bucket "${ENV_SITE}" \
      --prefix "${infix}/${base}" \
      --query 'Versions[0].VersionId' \
      --output text 2>/dev/null) || true
    
    if [[ -n "$version_id" && "$version_id" != "None" && "$version_id" != "null" ]]; then
      jq --arg ext "$ext" --arg vid "$version_id" \
        '.media.versionid[$ext] = $vid' "$json" > "${json}.tmp" && mv "${json}.tmp" "$json"
      echo "  $ext: $version_id"
    fi
  done
  
  log_success "Version IDs updated"
}

upload_sidecar() {
  local json="$1"
  local infix="$2"
  local opus="$3"
  
  log_step "Uploading sidecar"
  
  local dest="${opus}.track.meta.json"
  run_cmd aws s3 cp "\"$json\"" "\"s3://${ENV_SITE}/${infix}/${dest}\""
  
  [[ $DRY_RUN -eq 0 ]] && log_success "Sidecar: s3://${ENV_SITE}/${infix}/${dest}"
}

main() {
  local wav_file=""
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)        DRY_RUN=1; shift;;
      -v|--verbose)        VERBOSE=1; shift;;
      -s|--skip-upload)    SKIP_UPLOAD=1; shift;;
      -c|--checksums-only) CHECKSUMS_ONLY=1; SKIP_UPLOAD=1; shift;;
      -h|--help)           usage; exit 0;;
      -*)                  die "Unknown option: $1";;
      *)                   wav_file="$1"; shift;;
    esac
  done
  
  [[ -z "$wav_file" ]] && { usage; exit 1; }
  [[ ! -f "$wav_file" ]] && die "WAV not found: $wav_file"
  
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Track Resync v${VERSION}${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
  [[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}  [DRY RUN]${NC}"
  echo ""
  
  check_dependencies
  check_environment
  
  parse_wav_filename "$wav_file"
  calculate_infix "$OPUS_INT"
  
  local out_prefix="${PREFIX}_opus_${OPUS_NUM}"
  local mp3_file="${out_prefix}.mp3"
  local mp4_file="${out_prefix}.mp4"
  
  # Verify files exist
  [[ ! -f "track.meta.json" ]] && die "track.meta.json not found"
  [[ ! -f "$mp3_file" ]] && die "MP3 not found: $mp3_file"
  [[ ! -f "$mp4_file" ]] && die "MP4 not found: $mp4_file"
  
  log_success "Files verified: $wav_file, $mp3_file, $mp4_file"
  log_info "INFIX: $INFIX"
  
  # Update checksums
  update_checksums "track.meta.json" "$wav_file" "$mp3_file" "$mp4_file"
  
  if [[ $SKIP_UPLOAD -eq 0 ]]; then
    upload_all "$INFIX" "$wav_file" "$mp3_file" "$mp4_file"
    update_version_ids "track.meta.json" "$INFIX" "$wav_file" "$mp3_file" "$mp4_file"
    upload_sidecar "track.meta.json" "$INFIX" "$OPUS_NUM"
  fi
  
  echo ""
  log_success "Resync complete"
}

main "$@"
