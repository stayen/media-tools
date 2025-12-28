# audio-overlay usage

```bash
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
```
