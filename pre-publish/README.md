# Pre-Publish: Audio Track Processing Scripts

Automated pipeline for processing audio tracks and distributing to AWS S3 buckets.

## Scripts

| Script | Purpose |
|--------|---------|
| `process-track.sh` | Full pipeline: create MP3/MP4, embed metadata, upload to S3 |
| `resync-track.sh` | Re-sync existing files, update checksums and version IDs |

## Prerequisites

### Environment Variables

```bash
export ENV_SITE="example.com"           # Private bucket / artist domain
export ENV_MEDIA_SITE="media.example.com"  # Public bucket / media domain
```

### Required Tools

- `aws` (AWS CLI, configured with credentials)
- `jq` (JSON processor)
- `ffmpeg` / `ffprobe`
- `eyeD3` (MP3 tagging)
- `bwfmetaedit` (WAV/BWF metadata)
- `convert` (ImageMagick)
- `sha256sum`

### Required Files (in working directory)

| File | Description |
|------|-------------|
| `PREFIX_opus_NNNN_master.wav` | Source audio (pattern must match) |
| `ART.jpg` | Square artwork (≥512px recommended) |
| `track.meta.json` | Sidecar metadata (no `ENTER_` placeholders) |

Note: see the supplied sample track.meta.json for a template.

## Usage

### Full Processing (New Track)

```bash
# First, fill in track.meta.json - replace all ENTER_ fields with actual data
# Then run:
./process-track.sh wilds_opus_6817_master.wav
```

### Dry Run (Preview)

```bash
./process-track.sh --dry-run wilds_opus_6817_master.wav
```

### Local Processing Only (No S3)

```bash
./process-track.sh --skip-upload wilds_opus_6817_master.wav
```

### Resync Existing Files

```bash
./resync-track.sh wilds_opus_6817_master.wav
```

### Update Checksums Only

```bash
./resync-track.sh --checksums-only wilds_opus_6817_master.wav
```

## What the Scripts Do

### process-track.sh

1. **Validates** inputs (environment, files, no `ENTER_` placeholders)
2. **Parses** WAV filename to extract prefix and opus number
3. **Calculates** S3 INFIX path (e.g., `6817` → `6/8/6817`)
4. **Creates** artwork variants (1024px, 512px)
5. **Generates** MP3 and MP4 from WAV
6. **Embeds** metadata (ID3v2.3 for MP3, BWF for WAV)
7. **Embeds** 512px artwork into MP3
8. **Computes** checksums (SHA-256) and loudness (LUFS/LRA/TP)
9. **Uploads** artwork to public S3 bucket
10. **Uploads** media files to private S3 bucket
11. **Extracts** S3 version IDs
12. **Updates** sidecar JSON with all computed data
13. **Uploads** final sidecar to private bucket

### resync-track.sh

1. Recomputes checksums and loudness
2. Re-uploads all files to S3
3. Fetches fresh version IDs
4. Updates and uploads sidecar

## S3 Path Structure

Given opus number `6817`:

```
Public bucket (art):
  s3://media.example.com/6/8/6817/ART.jpg
  s3://media.example.com/6/8/6817/ART_1024.jpg
  s3://media.example.com/6/8/6817/ART_512.jpg

Private bucket (media):
  s3://example.com/6/8/6817/prefix_opus_6817_master.wav
  s3://example.com/6/8/6817/prefix_opus_6817.mp3
  s3://example.com/6/8/6817/prefix_opus_6817.mp4
  s3://example.com/6/8/6817/6817.track.meta.json
```

## INFIX Calculation Rules

1. Left-pad opus to minimum 3 digits
2. Remove two rightmost digits
3. Slash-separate remaining digits
4. Append full opus number

Examples:
- `57` → `0/57`
- `123` → `1/123`
- `6817` → `6/8/6817`
- `12345` → `1/2/3/12345`

## Options Reference

### process-track.sh

| Option | Description |
|--------|-------------|
| `-n, --dry-run` | Preview without executing |
| `-v, --verbose` | Show detailed output |
| `-f, --force` | Overwrite existing files |
| `-s, --skip-upload` | Local processing only |
| `--no-cleanup` | Keep intermediate files |

### resync-track.sh

| Option | Description |
|--------|-------------|
| `-n, --dry-run` | Preview without executing |
| `-v, --verbose` | Show detailed output |
| `-s, --skip-upload` | Update checksums, no upload |
| `-c, --checksums-only` | Only update checksums |

## Error Handling

- Scripts exit immediately on any error (`set -e`)
- `ENTER_` placeholders in sidecar cause immediate abort
- Missing dependencies are reported before processing
- Non-square artwork triggers error
