#!/usr/bin/env bash
# process-track.sh
# Automated audio track processing and S3 distribution pipeline
# Usage: process-track.sh [options] <PREFIX_opus_NNNN_master.wav>
#
# Requires:
#   - ENV_SITE environment variable (private S3 bucket / artist domain)
#   - ENV_MEDIA_SITE environment variable (public S3 bucket / media domain)
#   - ART.jpg in current directory (square JPEG artwork)
#   - track.meta.json in current directory (sidecar metadata, no ENTER_ placeholders)
#
# Dependencies: aws, jq, ffmpeg, ffprobe, eyeD3, bwfmetaedit, imagemagick (convert), sha256sum

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
DRY_RUN=0
VERBOSE=0
FORCE=0
SKIP_UPLOAD=0
CLEANUP=1

usage() {
  cat <<'USAGE'
Usage: process-track.sh [options] <PREFIX_opus_NNNN_master.wav>

Automates audio track processing and S3 distribution:
  1. Validates inputs and environment
  2. Creates artwork variants (1024px, 512px)
  3. Generates MP3 and MP4 from WAV
  4. Embeds metadata and artwork
  5. Computes checksums and loudness data
  6. Uploads to S3 buckets (public for art, private for media)
  7. Updates sidecar JSON with version IDs and technical data

Required Environment Variables:
  ENV_SITE        Private S3 bucket name / artist domain
  ENV_MEDIA_SITE  Public S3 bucket name / media domain

Required Files (in current directory):
  ART.jpg           Square JPEG artwork (original resolution)
  track.meta.json   Sidecar metadata file (no ENTER_ placeholders)

Options:
  -n, --dry-run     Show what would be done without executing
  -v, --verbose     Enable verbose output
  -f, --force       Overwrite existing output files
  -s, --skip-upload Skip S3 upload steps (local processing only)
  --no-cleanup      Keep intermediate files
  -h, --help        Show this help message
  --version         Show version

Examples:
  process-track.sh wilds_opus_6817_master.wav
  process-track.sh --dry-run wilds_opus_123_master.wav
  process-track.sh --skip-upload --verbose kamaskera_opus_45_master.wav
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

# Check for required commands
check_dependencies() {
  local missing=()
  local cmds=(aws jq ffmpeg ffprobe eyeD3 bwfmetaedit convert sha256sum)
  
  for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}"
  fi
  log_success "All dependencies found"
}

# Validate environment variables
check_environment() {
  [[ -z "${ENV_SITE:-}" ]] && die "ENV_SITE environment variable not set"
  [[ -z "${ENV_MEDIA_SITE:-}" ]] && die "ENV_MEDIA_SITE environment variable not set"
  log_success "Environment: ENV_SITE=$ENV_SITE, ENV_MEDIA_SITE=$ENV_MEDIA_SITE"
}

# Parse WAV filename to extract prefix and opus number
# Pattern: PREFIX_opus_NNNN_master.wav
parse_wav_filename() {
  local wav="$1"
  local basename
  basename="$(basename "$wav")"
  
  if [[ ! "$basename" =~ ^(.+)_opus_([0-9]+)_master\.wav$ ]]; then
    die "WAV filename must match pattern: PREFIX_opus_NNNN_master.wav (got: $basename)"
  fi
  
  PREFIX="${BASH_REMATCH[1]}"
  OPUS_NUM="${BASH_REMATCH[2]}"
  OPUS_INT=$((10#$OPUS_NUM))  # Remove leading zeros for arithmetic
  
  log_success "Parsed: PREFIX=$PREFIX, OPUS=$OPUS_NUM (int: $OPUS_INT)"
}

# Calculate S3 INFIX path from opus number
# Example: 6817 → "6/8/6817"
calculate_infix() {
  local opus="$1"
  local padded infix_prefix
  
  # Left-pad to at least 3 digits
  padded=$(printf "%03d" "$opus")
  
  # Remove two rightmost digits to get prefix part
  if [[ ${#padded} -le 2 ]]; then
    infix_prefix="0"
  else
    infix_prefix="${padded:0:${#padded}-2}"
  fi
  
  # Slash-separate each digit of prefix
  local slashed=""
  for ((i=0; i<${#infix_prefix}; i++)); do
    [[ -n "$slashed" ]] && slashed+="/"
    slashed+="${infix_prefix:$i:1}"
  done
  
  # Append full opus number
  INFIX="${slashed}/${opus}"
  log_success "Calculated INFIX: $INFIX"
}

# Validate artwork file
validate_artwork() {
  local art="$1"
  
  [[ ! -f "$art" ]] && die "Artwork file not found: $art"
  
  # Check dimensions are square
  local dims
  dims=$(identify -format "%wx%h" "$art" 2>/dev/null) || die "Cannot read artwork dimensions"
  local width height
  width="${dims%x*}"
  height="${dims#*x}"
  
  if [[ "$width" -ne "$height" ]]; then
    die "Artwork must be square (got ${width}x${height})"
  fi
  
  if [[ "$width" -lt 512 ]]; then
    log_warn "Artwork resolution ($width) is below recommended 512px minimum"
  fi
  
  log_success "Artwork validated: ${width}x${height} pixels"
}

# Validate sidecar JSON - no ENTER_ placeholders allowed
validate_sidecar() {
  local json="$1"
  
  [[ ! -f "$json" ]] && die "Sidecar JSON not found: $json"
  
  # Check for valid JSON
  if ! jq empty "$json" 2>/dev/null; then
    die "Invalid JSON in sidecar file: $json"
  fi
  
  # Check for ENTER_ placeholders
  if grep -q '"ENTER_' "$json"; then
    log_error "Sidecar contains unresolved ENTER_ placeholders:"
    grep -n '"ENTER_' "$json" | head -10
    die "Please fill in all ENTER_ fields before processing"
  fi
  
  log_success "Sidecar JSON validated"
}

# Extract duration from WAV and format as ISO 8601 duration (PTxMxS)
get_iso_duration() {
  local wav="$1"
  local seconds
  
  seconds=$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$wav" 2>/dev/null | cut -d. -f1)
  
  if [[ -z "$seconds" ]]; then
    echo "PT0M0S"
    return
  fi
  
  local mins=$((seconds / 60))
  local secs=$((seconds % 60))
  echo "PT${mins}M${secs}S"
}

# Extract WAV file modification timestamp
get_wav_timestamp() {
  local wav="$1"
  # Use file creation/modification time
  stat -c '%Y' "$wav" 2>/dev/null || date +%s
}

# Update REPLACE_ placeholders in sidecar JSON
update_sidecar_placeholders() {
  local json="$1"
  local wav="$2"
  local opus="$3"
  
  log_step "Updating sidecar REPLACE_ placeholders"
  
  # Get values
  local wav_ts iso_duration wav_date wav_time
  wav_ts=$(get_wav_timestamp "$wav")
  iso_duration=$(get_iso_duration "$wav")
  wav_date=$(date -d "@$wav_ts" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
  wav_time=$(date -d "@$wav_ts" +%H:%M:%S 2>/dev/null || date +%H:%M:%S)
  wav_datetime=$(date -d "@$wav_ts" -Iseconds 2>/dev/null || date -Iseconds)
  
  # Art URI pattern
  local art_uri="${INFIX}/ART_1024.jpg"
  
  [[ $VERBOSE -eq 1 ]] && {
    echo "  Duration: $iso_duration"
    echo "  Date: $wav_date, Time: $wav_time"
    echo "  Art URI: $art_uri"
  }
  
  if [[ $DRY_RUN -eq 0 ]]; then
    local tmp
    tmp=$(mktemp)
    
    jq --arg opus "$opus" \
       --arg duration "$iso_duration" \
       --arg wav_date "$wav_date" \
       --arg wav_time "$wav_time" \
       --arg wav_ts "$wav_datetime" \
       --arg art_uri "$art_uri" \
       --arg env_site "${ENV_SITE}" \
       --arg env_media "${ENV_MEDIA_SITE}" \
       '
       # Replace REPLACE_ patterns
       walk(
         if type == "string" then
           gsub("REPLACE_OPUS"; $opus) |
           gsub("REPLACE_PT2M59S"; $duration) |
           gsub("REPLACE_WAV_DATE"; $wav_date) |
           gsub("REPLACE_WAV_TIME"; $wav_time) |
           gsub("REPLACE_WAV_TIMESTAMP"; $wav_ts) |
           gsub("REPLACE_ART_URI"; $art_uri) |
           gsub("ENV_SITE"; $env_site) |
           gsub("ENV_MEDIA_SITE"; $env_media)
         else .
         end
       )
       ' "$json" > "$tmp" && mv "$tmp" "$json"
    
    log_success "Placeholders updated"
  else
    echo "  [dry-run] Would update placeholders in $json"
  fi
}

# Create artwork variants
create_artwork_variants() {
  local art_src="$1"
  
  log_step "Creating artwork variants"
  
  for size in 1024 512; do
    local out="ART_${size}.jpg"
    if [[ -f "$out" && $FORCE -eq 0 ]]; then
      log_info "Artwork $out already exists (use -f to overwrite)"
    else
      run_cmd convert -geometry "${size}x${size}" -quality 75 "\"$art_src\"" "\"$out\""
      [[ $DRY_RUN -eq 0 ]] && log_success "Created $out"
    fi
  done
}

# Create MP3 and MP4 from WAV
create_media_files() {
  local wav="$1"
  local out_prefix="$2"
  local art="$3"
  
  log_step "Creating MP3 and MP4"
  
  local mp3="${out_prefix}.mp3"
  local mp4="${out_prefix}.mp4"
  
  if [[ -f "$mp3" && $FORCE -eq 0 ]]; then
    log_info "MP3 already exists: $mp3 (use -f to overwrite)"
  else
    # Convert WAV to MP3 (VBR quality 2 ≈ 190 kbps)
    run_cmd ffmpeg -y -i "\"$wav\"" -vn -ar 44100 -ac 2 -q:a 2 "\"$mp3\"" 2>/dev/null
    [[ $DRY_RUN -eq 0 ]] && log_success "Created $mp3"
  fi
  
  if [[ -f "$mp4" && $FORCE -eq 0 ]]; then
    log_info "MP4 already exists: $mp4 (use -f to overwrite)"
  else
    # Create static video with audio (for YouTube/social)
    run_cmd ffmpeg -y -loop 1 -i "\"$art\"" -i "\"$mp3\"" \
      -c:a copy -c:v libx264 -tune stillimage -pix_fmt yuv420p \
      -shortest "\"$mp4\"" 2>/dev/null
    [[ $DRY_RUN -eq 0 ]] && log_success "Created $mp4"
  fi
}

# Embed artwork into MP3
embed_artwork() {
  local art="$1"
  local mp3="$2"
  
  log_step "Embedding artwork into MP3"
  
  if [[ $DRY_RUN -eq 0 ]]; then
    # Remove existing images
    eyeD3 --remove-all-images "$mp3" >/dev/null 2>&1 || true
    # Add front cover
    eyeD3 --add-image "$art:FRONT_COVER" "$mp3" >/dev/null
    # Convert to ID3v2.3 for compatibility
    eyeD3 --to-v2.3 "$mp3" >/dev/null
    log_success "Artwork embedded"
  else
    echo "  [dry-run] Would embed $art into $mp3"
  fi
}

# Update WAV metadata from sidecar
update_wav_metadata() {
  local json="$1"
  local wav="$2"
  
  log_step "Updating WAV metadata (BWF)"
  
  if [[ $DRY_RUN -eq 0 ]]; then
    # Extract BWF fields
    local desc orig origref odate otime ixmlnote
    desc=$(jq -r '.bwf.bext.Description // empty' "$json")
    orig=$(jq -r '.bwf.bext.Originator // empty' "$json")
    origref=$(jq -r '.bwf.bext.OriginatorReference // empty' "$json")
    odate=$(jq -r '.bwf.bext.OriginationDate // empty' "$json")
    otime=$(jq -r '.bwf.bext.OriginationTime // empty' "$json")
    ixmlnote=$(jq -r '.bwf.iXML_note // empty' "$json")
    
    # Apply BWF metadata using bwfmetaedit
    [[ -n "$desc" ]] && bwfmetaedit --Description="$desc" "$wav" 2>/dev/null || true
    [[ -n "$orig" ]] && bwfmetaedit --Originator="$orig" "$wav" 2>/dev/null || true
    [[ -n "$origref" ]] && bwfmetaedit --OriginatorReference="$origref" "$wav" 2>/dev/null || true
    [[ -n "$odate" ]] && bwfmetaedit --OriginationDate="$odate" "$wav" 2>/dev/null || true
    [[ -n "$otime" ]] && bwfmetaedit --OriginationTime="$otime" "$wav" 2>/dev/null || true
    
    log_success "WAV metadata updated"
  else
    echo "  [dry-run] Would update BWF metadata in $wav"
  fi
}

# Update MP3 metadata from sidecar
update_mp3_metadata() {
  local json="$1"
  local mp3="$2"
  
  log_step "Updating MP3 metadata (ID3)"
  
  if [[ $DRY_RUN -eq 0 ]]; then
    # Extract fields from JSON
    local title artist album_artist album genre date composer
    local lyricist publisher copyright isrc comment
    
    title=$(jq -r '.title // empty' "$json")
    artist=$(jq -r '.participants.artist // empty' "$json")
    album_artist=$(jq -r '.participants.album_artist // empty' "$json")
    album=$(jq -r '.participants.album // empty' "$json")
    genre=$(jq -r '.tech.genre // empty' "$json")
    date=$(jq -r '.date_created_utc // empty' "$json")
    composer=$(jq -r '.participants.composer // empty' "$json")
    lyricist=$(jq -r '.participants.lyricist // empty' "$json")
    publisher=$(jq -r '.rights.publisher // empty' "$json")
    copyright=$(jq -r '.rights.copyright // empty' "$json")
    isrc=$(jq -r '.ids.isrc // empty' "$json")
    comment=$(jq -r '.id3.comments[0] // empty' "$json")
    
    # Use ffmpeg for basic tags
    local tmp="${mp3}.tmp.mp3"
    ffmpeg -y -i "$mp3" -id3v2_version 3 -codec copy \
      -metadata title="$title" \
      -metadata artist="$artist" \
      -metadata album_artist="$album_artist" \
      -metadata album="$album" \
      -metadata genre="$genre" \
      -metadata date="$date" \
      -metadata composer="$composer" \
      -metadata lyricist="$lyricist" \
      -metadata publisher="$publisher" \
      -metadata copyright="$copyright" \
      -metadata TSRC="$isrc" \
      "$tmp" 2>/dev/null
    mv "$tmp" "$mp3"
    
    # Add comment via eyeD3
    [[ -n "$comment" ]] && eyeD3 --comment "$comment" "$mp3" >/dev/null 2>&1 || true
    
    # Ensure ID3v2.3
    eyeD3 --to-v2.3 "$mp3" >/dev/null 2>&1 || true
    
    log_success "MP3 metadata updated"
  else
    echo "  [dry-run] Would update ID3 metadata in $mp3"
  fi
}

# Compute and update checksums in sidecar
update_checksums() {
  local json="$1"
  shift
  local files=("$@")
  
  log_step "Computing checksums and loudness"
  
  if [[ $DRY_RUN -eq 0 ]]; then
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
      
      # Loudness (for audio files)
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
      
      [[ $VERBOSE -eq 1 ]] && echo "  Processed: $base"
    done
    
    log_success "Checksums and loudness updated"
  else
    echo "  [dry-run] Would compute checksums for: ${files[*]}"
  fi
}

# Upload art files to public bucket
upload_art_to_public() {
  local infix="$1"
  
  log_step "Uploading artwork to public bucket"
  
  if [[ $SKIP_UPLOAD -eq 1 ]]; then
    log_info "Skipping upload (--skip-upload)"
    return 0
  fi
  
  for art in ART.jpg ART_1024.jpg ART_512.jpg; do
    [[ -f "$art" ]] || continue
    run_cmd aws s3 cp "\"$art\"" "\"s3://${ENV_MEDIA_SITE}/${infix}/${art}\""
  done
  
  [[ $DRY_RUN -eq 0 ]] && log_success "Artwork uploaded to s3://${ENV_MEDIA_SITE}/${infix}/"
}

# Upload media files to private bucket
upload_media_to_private() {
  local infix="$1"
  local wav="$2"
  local mp3="$3"
  local mp4="$4"
  
  log_step "Uploading media to private bucket"
  
  if [[ $SKIP_UPLOAD -eq 1 ]]; then
    log_info "Skipping upload (--skip-upload)"
    return 0
  fi
  
  for f in "$wav" "$mp3" "$mp4"; do
    [[ -f "$f" ]] || continue
    local base
    base="$(basename "$f")"
    run_cmd aws s3 cp "\"$f\"" "\"s3://${ENV_SITE}/${infix}/${base}\""
  done
  
  [[ $DRY_RUN -eq 0 ]] && log_success "Media uploaded to s3://${ENV_SITE}/${infix}/"
}

# Extract S3 version IDs and update sidecar
update_version_ids() {
  local json="$1"
  local infix="$2"
  local wav="$3"
  local mp3="$4"
  local mp4="$5"
  
  log_step "Extracting S3 version IDs"
  
  if [[ $SKIP_UPLOAD -eq 1 ]]; then
    log_info "Skipping version ID extraction (--skip-upload)"
    return 0
  fi
  
  if [[ $DRY_RUN -eq 0 ]]; then
    for f in "$wav" "$mp3" "$mp4"; do
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
        [[ $VERBOSE -eq 1 ]] && echo "  $ext: $version_id"
      fi
    done
    
    log_success "Version IDs updated"
  else
    echo "  [dry-run] Would extract version IDs from S3"
  fi
}

# Upload sidecar JSON to private bucket
upload_sidecar() {
  local json="$1"
  local infix="$2"
  local opus="$3"
  
  log_step "Uploading sidecar JSON"
  
  if [[ $SKIP_UPLOAD -eq 1 ]]; then
    log_info "Skipping upload (--skip-upload)"
    return 0
  fi
  
  local dest_name="${opus}.track.meta.json"
  run_cmd aws s3 cp "\"$json\"" "\"s3://${ENV_SITE}/${infix}/${dest_name}\""
  
  [[ $DRY_RUN -eq 0 ]] && log_success "Sidecar uploaded: s3://${ENV_SITE}/${infix}/${dest_name}"
}

# Cleanup intermediate files
cleanup_files() {
  if [[ $CLEANUP -eq 1 && $DRY_RUN -eq 0 ]]; then
    rm -f ./*.saved output.mp3 2>/dev/null || true
  fi
}

# Main processing function
main() {
  local wav_file=""
  
  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--dry-run)    DRY_RUN=1; shift;;
      -v|--verbose)    VERBOSE=1; shift;;
      -f|--force)      FORCE=1; shift;;
      -s|--skip-upload) SKIP_UPLOAD=1; shift;;
      --no-cleanup)    CLEANUP=0; shift;;
      -h|--help)       usage; exit 0;;
      --version)       echo "process-track.sh v${VERSION}"; exit 0;;
      -*)              die "Unknown option: $1";;
      *)               wav_file="$1"; shift;;
    esac
  done
  
  [[ -z "$wav_file" ]] && { usage; exit 1; }
  [[ ! -f "$wav_file" ]] && die "WAV file not found: $wav_file"
  
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Audio Track Processing Pipeline v${VERSION}${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  [[ $DRY_RUN -eq 1 ]] && echo -e "${YELLOW}  [DRY RUN MODE]${NC}"
  echo ""
  
  # Pre-flight checks
  log_step "Pre-flight checks"
  check_dependencies
  check_environment
  
  # Parse input filename
  parse_wav_filename "$wav_file"
  calculate_infix "$OPUS_INT"
  
  # Validate required files
  validate_artwork "ART.jpg"
  validate_sidecar "track.meta.json"
  
  # Define output filenames
  local out_prefix="${PREFIX}_opus_${OPUS_NUM}"
  local mp3_file="${out_prefix}.mp3"
  local mp4_file="${out_prefix}.mp4"
  
  # Processing steps
  update_sidecar_placeholders "track.meta.json" "$wav_file" "$OPUS_NUM"
  create_artwork_variants "ART.jpg"
  create_media_files "$wav_file" "$out_prefix" "ART_1024.jpg"
  embed_artwork "ART_512.jpg" "$mp3_file"
  update_wav_metadata "track.meta.json" "$wav_file"
  update_mp3_metadata "track.meta.json" "$mp3_file"
  update_checksums "track.meta.json" "$wav_file" "$mp3_file" "$mp4_file"
  
  # Upload steps
  upload_art_to_public "$INFIX"
  upload_media_to_private "$INFIX" "$wav_file" "$mp3_file" "$mp4_file"
  update_version_ids "track.meta.json" "$INFIX" "$wav_file" "$mp3_file" "$mp4_file"
  upload_sidecar "track.meta.json" "$INFIX" "$OPUS_NUM"
  
  # Cleanup
  cleanup_files
  
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  Processing Complete${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Files created:"
  echo "    • ${mp3_file}"
  echo "    • ${mp4_file}"
  echo "    • ART_1024.jpg, ART_512.jpg"
  echo ""
  if [[ $SKIP_UPLOAD -eq 0 ]]; then
    echo "  S3 locations:"
    echo "    • Public art:  s3://${ENV_MEDIA_SITE}/${INFIX}/"
    echo "    • Private:     s3://${ENV_SITE}/${INFIX}/"
    echo "    • Sidecar:     s3://${ENV_SITE}/${INFIX}/${OPUS_NUM}.track.meta.json"
  fi
  echo ""
}

main "$@"
