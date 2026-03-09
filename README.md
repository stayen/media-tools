# Media tools for those creating Suno music

Some useful scripts/script sets are provided to make it simpler to use the generative audio content to further transmute into audio/video and publish.

## audio-overlay

Add audio track or its part over source video (to make shorts, for example).

## pre-publish

Do all the routing work to create provenance files and reference media files before publishing to streaming services.

## misc

Several scripts to do typical operations over media files, and a sample of track.meta.json sidecar file, to comply with Spotify DDEX self-marking initiative.

Scripts:

```text
**loudnorm-two-pass.sh: adjust the track's loudness parameters; by default tries to make LUFS:-14.0, LU:11, TP (TruePeak): -1.0db**
```

```bash
Syntax:

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
```

```
**fn-master.sh: loudness correction script using ffmpeg (best in most cases)**
```

```bash
Usage:
   fn-master.sh [options] -i INFILE -o OUTFILE
Options:
  -I, --lufs          Expected integrated loudness LUFS   [-14]
  -T, --tp            Expected true peak (dBTP)           [-1.0]
  -L, --lra           Expected loudness range (LU)        [11]

Examples:
  fn-master.sh -I 14 -T -1.0 -L 11 -i in.wav -o out.wav
```

```
**embed-art.sh: incorporates art image (600x6000 or smaller square JPEG) to be correctly displayed by media players**
```

```bash
Usage: ./embed-art.sh <cover.jpg> <file-or-glob.mp3> [more.mp3 ...]
Tips:
  - Use a baseline 500–600px JPEG for best car/tablet compatibility.
  - Example: ./embed-art.sh cover_600.jpg *.mp3
```

```
**slowdown-video.sh: makes a slowed down (i.e. longer) video, keeping its major parameters the same**
```

```bash
Usage:
   slowdown-video.sh [OPTIONS] -i INFILE -o OUTFILE
Options:
  -f factor      Slowdown factor; 2.0 by default.

Examples:
  slowdown-video.sh -f 2.5 -i in.mp4 -o out.mp4
```

```
**wav-24bit-to-16bit.sh: converts 24-bit .wav files to 16-bit version**
```

```bash
wav-24bit-to-16bit.sh 24bit.wav 16bit.wav
```
