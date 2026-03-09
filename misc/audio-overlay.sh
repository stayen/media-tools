#!/usr/bin/env bash
# audio-overlay.sh
# Overlay/replace audio track in video starting at specified time index
#
# Usage: audio-overlay.sh -ia <audio> -iv <video> -index <time> -ov <output> [options]

set -euo pipefail

VERSION="1.0.0"

# Defaults
INPUT_AUDIO=""
INPUT_VIDEO=""
OUTPUT_VIDEO=""
START_INDEX="00:00.00"
AUDIO_OFFSET="00:00.00"
LOOP_AUDIO=0
RESPECT_LENGTH="video"
AUDIO_CODEC="aac"
AUDIO_BITRATE="192k"
VERBOSE=0
DRY_RUN=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<'USAGE'
Usage: audio-overlay.sh -ia <audio> -iv <video> -index <time> -ov <output> [options]

Overlay or replace audio track in a video file starting at a specified time index.
The video stream is copied without re-encoding.

Required Arguments:
  -ia, --input-audio <file>    Input audio file (.mp3, .wav, .flac, .m4a, etc.)
  -iv, --input-video <file>    Input video file (.mp4, .mkv, .mov, etc.)
  -ov, --output-video <file>   Output video file

Time Index:
  -index, --start-index <time> Start time for audio insertion in video (default: 00:00.00)
                               Formats: HH:MM:SS.ms, MM:SS.ms, SS.ms, or seconds
  -ao, --audio-offset <time>   Start offset within source audio file (default: 00:00.00)
                               Skips this amount from the beginning of the audio

Output Length Control:
  -rl, --respect-length <v|a>  Which duration to preserve (default: video)
                               video (v): Keep original video length, pad/loop/trim audio
                               audio (a): Keep full audio length, extend video with last frame if needed

Audio Handling (when audio is shorter than remaining video):
  -la, --loop-audio            Loop audio to fill remaining duration
                               (default: pad with silence)
                               Note: Only applies when --respect-length=video

Encoding Options:
  -ac, --audio-codec <codec>   Audio codec (default: aac)
  -ab, --audio-bitrate <rate>  Audio bitrate (default: 192k)

General Options:
  -n, --dry-run                Show ffmpeg command without executing
  -v, --verbose                Show detailed output
  -h, --help                   Show this help message
  --version                    Show version

Examples:
  # Insert audio starting at 2:34 in the video (respect video length)
  audio-overlay.sh -ia music.mp3 -iv video.mp4 -index 02:34.00 -ov output.mp4

  # Use audio starting from 1:30 in the source file, insert at video start
  audio-overlay.sh -ia music.mp3 -iv video.mp4 -ao 01:30.00 -ov output.mp4

  # Respect audio length: extend video with last frame if audio is longer
  audio-overlay.sh -ia long_audio.mp3 -iv short_video.mp4 -rl audio -ov output.mp4

  # Combine: skip first 30s of audio, insert at 1:00 in video, loop to fill
  audio-overlay.sh -ia music.mp3 -iv video.mp4 -ao 00:30 -index 01:00 -ov output.mp4 -la

  # Loop short audio clip to fill entire video from start
  audio-overlay.sh -ia jingle.wav -iv video.mp4 -index 00:00 -ov output.mp4 --loop-audio

  # Dry run to preview command
  audio-overlay.sh -ia audio.mp3 -iv video.mp4 -index 00:30 -ov out.mp4 -n
USAGE
}

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

die() { log_error "$*"; exit 1; }

# Convert time string to seconds (float)
# Accepts: HH:MM:SS.ms, MM:SS.ms, SS.ms, or plain seconds
time_to_seconds() {
  local time_str="$1"
  local seconds=0
  
  # Remove leading/trailing whitespace
  time_str="$(echo "$time_str" | xargs)"
  
  # Handle plain number (already seconds)
  if [[ "$time_str" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "$time_str"
    return
  fi
  
  # Split by colons
  IFS=':' read -ra parts <<< "$time_str"
  local num_parts=${#parts[@]}
  
  case $num_parts in
    1)  # SS.ms
      seconds="${parts[0]}"
      ;;
    2)  # MM:SS.ms
      seconds=$(echo "${parts[0]} * 60 + ${parts[1]}" | bc -l)
      ;;
    3)  # HH:MM:SS.ms
      seconds=$(echo "${parts[0]} * 3600 + ${parts[1]} * 60 + ${parts[2]}" | bc -l)
      ;;
    *)
      die "Invalid time format: $time_str"
      ;;
  esac
  
  echo "$seconds"
}

# Convert seconds to milliseconds (integer)
seconds_to_ms() {
  local secs="$1"
  echo "$(echo "$secs * 1000" | bc -l | cut -d. -f1)"
}

# Get media duration in seconds
get_duration() {
  local file="$1"
  ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "0"
}

# Get number of audio channels
get_channels() {
  local file="$1"
  ffprobe -v error -select_streams a:0 -show_entries stream=channels \
    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "2"
}

# Check dependencies
check_deps() {
  local missing=()
  for cmd in ffmpeg ffprobe bc; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing dependencies: ${missing[*]}"
  fi
}

# Validate inputs
validate_inputs() {
  [[ -z "$INPUT_AUDIO" ]] && die "Input audio not specified (-ia)" || true
  [[ -z "$INPUT_VIDEO" ]] && die "Input video not specified (-iv)" || true
  [[ -z "$OUTPUT_VIDEO" ]] && die "Output video not specified (-ov)" || true
  
  [[ ! -f "$INPUT_AUDIO" ]] && die "Audio file not found: $INPUT_AUDIO" || true
  [[ ! -f "$INPUT_VIDEO" ]] && die "Video file not found: $INPUT_VIDEO" || true
  
  # Check output directory exists
  local out_dir
  out_dir="$(dirname "$OUTPUT_VIDEO")"
  [[ "$out_dir" != "." && ! -d "$out_dir" ]] && die "Output directory not found: $out_dir" || true
}

# Parse arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -ia|--input-audio)
        INPUT_AUDIO="$2"; shift 2 ;;
      -iv|--input-video)
        INPUT_VIDEO="$2"; shift 2 ;;
      -ov|--output-video)
        OUTPUT_VIDEO="$2"; shift 2 ;;
      -index|--start-index)
        START_INDEX="$2"; shift 2 ;;
      -ao|--audio-offset)
        AUDIO_OFFSET="$2"; shift 2 ;;
      -rl|--respect-length)
        case "$2" in
          v|video) RESPECT_LENGTH="video" ;;
          a|audio) RESPECT_LENGTH="audio" ;;
          *) die "Invalid --respect-length value: $2 (use 'video' or 'audio')" ;;
        esac
        shift 2 ;;
      -la|--loop-audio)
        LOOP_AUDIO=1; shift ;;
      -ac|--audio-codec)
        AUDIO_CODEC="$2"; shift 2 ;;
      -ab|--audio-bitrate)
        AUDIO_BITRATE="$2"; shift 2 ;;
      -n|--dry-run)
        DRY_RUN=1; shift ;;
      -v|--verbose)
        VERBOSE=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --version)
        echo "audio-overlay.sh v${VERSION}"; exit 0 ;;
      -*)
        die "Unknown option: $1" ;;
      *)
        die "Unexpected argument: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  
  # Show help if no args
  [[ -z "$INPUT_AUDIO" && -z "$INPUT_VIDEO" && -z "$OUTPUT_VIDEO" ]] && { usage; exit 0; }
  
  check_deps
  validate_inputs
  
  # Get durations
  local video_duration audio_duration
  video_duration=$(get_duration "$INPUT_VIDEO")
  audio_duration=$(get_duration "$INPUT_AUDIO")
  
  [[ "$video_duration" == "0" || -z "$video_duration" ]] && die "Cannot determine video duration" || true
  [[ "$audio_duration" == "0" || -z "$audio_duration" ]] && die "Cannot determine audio duration" || true
  
  # Convert start index to seconds and milliseconds
  local start_seconds start_ms
  start_seconds=$(time_to_seconds "$START_INDEX")
  start_ms=$(seconds_to_ms "$start_seconds")
  
  # Convert audio offset to seconds
  local audio_offset_seconds
  audio_offset_seconds=$(time_to_seconds "$AUDIO_OFFSET")
  
  # Validate start index
  local cmp
  cmp=$(echo "$start_seconds >= $video_duration" | bc -l)
  [[ "$cmp" -eq 1 ]] && die "Start index ($start_seconds s) exceeds video duration ($video_duration s)" || true
  
  # Validate audio offset
  cmp=$(echo "$audio_offset_seconds >= $audio_duration" | bc -l)
  [[ "$cmp" -eq 1 ]] && die "Audio offset ($audio_offset_seconds s) exceeds audio duration ($audio_duration s)" || true
  
  # Calculate effective audio duration after offset
  local effective_audio_duration
  effective_audio_duration=$(echo "$audio_duration - $audio_offset_seconds" | bc -l)
  
  # Calculate needed audio duration (from start point to video end)
  local needed_duration
  needed_duration=$(echo "$video_duration - $start_seconds" | bc -l)
  
  # Get audio channels for adelay filter
  local channels
  channels=$(get_channels "$INPUT_AUDIO")
  
  # Build adelay parameter (one delay value per channel, pipe-separated)
  local adelay_param=""
  for ((i=0; i<channels; i++)); do
    [[ -n "$adelay_param" ]] && adelay_param+="|"
    adelay_param+="${start_ms}"
  done
  
  # Display info
  if [[ $VERBOSE -eq 1 || $DRY_RUN -eq 1 ]]; then
    echo ""
    log_info "Video duration:  ${video_duration}s"
    log_info "Audio duration:  ${audio_duration}s (total)"
    log_info "Audio offset:    ${audio_offset_seconds}s"
    log_info "Effective audio: ${effective_audio_duration}s (after offset)"
    log_info "Start index:     ${start_seconds}s (${start_ms}ms delay in video)"
    log_info "Needed duration: ${needed_duration}s (video remaining after start)"
    log_info "Audio channels:  ${channels}"
    log_info "Respect length:  ${RESPECT_LENGTH}"
    [[ "$RESPECT_LENGTH" == "video" ]] && \
      log_info "Loop audio:      $([ $LOOP_AUDIO -eq 1 ] && echo 'yes' || echo 'no (pad silence)')"
    echo ""
  fi
  
  # Build ffmpeg command
  local ffmpeg_cmd filter_complex video_filter audio_filter
  
  # Check if we have a non-zero audio offset
  local has_offset=0
  cmp=$(echo "$audio_offset_seconds > 0" | bc -l)
  [[ "$cmp" -eq 1 ]] && has_offset=1
  
  # Calculate if audio extends beyond video (for audio-respect mode)
  local audio_end_time video_extend_duration
  audio_end_time=$(echo "$start_seconds + $effective_audio_duration" | bc -l)
  
  # Determine output duration and whether video needs extending
  local output_duration needs_video_extend=0
  if [[ "$RESPECT_LENGTH" == "audio" ]]; then
    # Audio mode: output matches audio timeline
    output_duration="$audio_end_time"
    cmp=$(echo "$audio_end_time > $video_duration" | bc -l)
    if [[ "$cmp" -eq 1 ]]; then
      needs_video_extend=1
      video_extend_duration=$(echo "$audio_end_time - $video_duration" | bc -l)
      [[ $VERBOSE -eq 1 || $DRY_RUN -eq 1 ]] && \
        log_info "Video extend:    ${video_extend_duration}s (last frame hold)"
    fi
  else
    # Video mode: output matches video duration
    output_duration="$video_duration"
  fi
  
  if [[ "$RESPECT_LENGTH" == "audio" ]]; then
    # AUDIO RESPECT MODE
    # Audio is kept at full length (after offset), video extended if needed
    
    # Build audio filter: offset (if any) + delay
    if [[ $has_offset -eq 1 ]]; then
      audio_filter="[1:a]atrim=start=${audio_offset_seconds},asetpts=PTS-STARTPTS,adelay=${adelay_param}[aout]"
    else
      audio_filter="[1:a]adelay=${adelay_param}[aout]"
    fi
    
    if [[ $needs_video_extend -eq 1 ]]; then
      # Need to extend video with last frame - requires re-encoding
      video_filter="[0:v]tpad=stop_mode=clone:stop_duration=${video_extend_duration}[vout]"
      filter_complex="${video_filter};${audio_filter}"
      
      ffmpeg_cmd=(
        ffmpeg -y
        -i "$INPUT_VIDEO"
        -i "$INPUT_AUDIO"
        -filter_complex "$filter_complex"
        -map "[vout]" -map "[aout]"
        -c:v libx264 -preset fast -crf 18
        -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE"
        -t "$output_duration"
        "$OUTPUT_VIDEO"
      )
    else
      # Audio fits within video - can copy video stream
      filter_complex="$audio_filter"
      
      ffmpeg_cmd=(
        ffmpeg -y
        -i "$INPUT_VIDEO"
        -i "$INPUT_AUDIO"
        -filter_complex "$filter_complex"
        -map 0:v:0 -map "[aout]"
        -c:v copy
        -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE"
        -t "$output_duration"
        "$OUTPUT_VIDEO"
      )
    fi
    
  elif [[ $LOOP_AUDIO -eq 1 ]]; then
    # VIDEO RESPECT MODE + LOOP AUDIO
    # Loop audio to fill remaining video duration
    
    if [[ $has_offset -eq 1 ]]; then
      # With offset: seek into audio, then loop, trim to needed duration, delay
      audio_filter="[1:a]atrim=duration=${needed_duration},asetpts=PTS-STARTPTS,adelay=${adelay_param}[aout]"
      
      ffmpeg_cmd=(
        ffmpeg -y
        -i "$INPUT_VIDEO"
        -ss "$audio_offset_seconds" -stream_loop -1 -i "$INPUT_AUDIO"
        -filter_complex "$audio_filter"
        -map 0:v:0 -map "[aout]"
        -c:v copy
        -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE"
        -shortest
        "$OUTPUT_VIDEO"
      )
    else
      # No offset: simple loop
      audio_filter="[1:a]atrim=duration=${needed_duration},asetpts=PTS-STARTPTS,adelay=${adelay_param}[aout]"
      
      ffmpeg_cmd=(
        ffmpeg -y
        -i "$INPUT_VIDEO"
        -stream_loop -1 -i "$INPUT_AUDIO"
        -filter_complex "$audio_filter"
        -map 0:v:0 -map "[aout]"
        -c:v copy
        -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE"
        -shortest
        "$OUTPUT_VIDEO"
      )
    fi
    
  else
    # VIDEO RESPECT MODE + PAD SILENCE (default)
    # Pad audio with silence to match video duration, truncate if longer
    
    if [[ $has_offset -eq 1 ]]; then
      audio_filter="[1:a]atrim=start=${audio_offset_seconds},asetpts=PTS-STARTPTS,adelay=${adelay_param},apad=whole_dur=${video_duration},atrim=duration=${video_duration}[aout]"
    else
      audio_filter="[1:a]adelay=${adelay_param},apad=whole_dur=${video_duration},atrim=duration=${video_duration}[aout]"
    fi
    
    ffmpeg_cmd=(
      ffmpeg -y
      -i "$INPUT_VIDEO"
      -i "$INPUT_AUDIO"
      -filter_complex "$audio_filter"
      -map 0:v:0 -map "[aout]"
      -c:v copy
      -c:a "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE"
      -shortest
      "$OUTPUT_VIDEO"
    )
  fi
  
  # Execute or display
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "Command to execute:"
    echo ""
    # Pretty print the command
    printf '%s' "${ffmpeg_cmd[0]}"
    for ((i=1; i<${#ffmpeg_cmd[@]}; i++)); do
      local arg="${ffmpeg_cmd[$i]}"
      if [[ "$arg" == -* ]]; then
        printf ' \\\n  %s' "$arg"
      else
        printf ' %q' "$arg"
      fi
    done
    echo ""
    echo ""
  else
    log_info "Processing..."
    
    if [[ $VERBOSE -eq 1 ]]; then
      "${ffmpeg_cmd[@]}"
    else
      "${ffmpeg_cmd[@]}" -loglevel warning
    fi
    
    if [[ -f "$OUTPUT_VIDEO" ]]; then
      local out_size
      out_size=$(du -h "$OUTPUT_VIDEO" | cut -f1)
      echo ""
      log_ok "Output created: $OUTPUT_VIDEO ($out_size)"
    else
      die "Output file was not created"
    fi
  fi
}

main "$@"
