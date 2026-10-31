#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

app_path="$(bash scripts/build-preview.sh | tail -n 1)"
[[ -d "$app_path" ]] || { printf '%s\n' 'The application bundle was not built.' >&2; exit 1; }
[[ -f "$app_path/Contents/Resources/Runtime/manifest.json" ]] || { printf '%s\n' 'The runtime component manifest is missing.' >&2; exit 1; }
[[ -f "$app_path/Contents/Resources/CLEAN_MAC_README.md" ]] || { printf '%s\n' 'The clean-Mac README is missing.' >&2; exit 1; }
for component in bin/ffmpeg bin/ffprobe bin/whisper-cli models/ggml-large.bin models/ggml-silero-v6.2.0.bin; do
    [[ -f "$app_path/Contents/Resources/Runtime/$component" ]] || { printf 'Missing required component: %s\n' "$component" >&2; exit 1; }
done
[[ -x "$app_path/Contents/Resources/speech-runtime/bin/python" ]] || {
    printf '%s\n' 'Missing relocatable Silero Kseniya speech runtime; the bundle is not ready for a clean Mac.' >&2
    exit 1
}

# A distributable bundle must not accidentally carry personal library or session data.
if find "$app_path/Contents" \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.m4a' -o -iname '*.srt' -o -iname '*telegram*session*' \) -print -quit | grep -q .; then
    printf '%s\n' 'The application bundle contains user media or a Telegram session.' >&2
    exit 1
fi

# Runtime metadata must stay relocatable; source paths are not allowed in copied text resources.
if grep -R -I -F "$project_dir" "$app_path/Contents/Resources" >/dev/null; then
    printf '%s\n' 'The application bundle contains an absolute developer path.' >&2
    exit 1
fi
printf '%s\n' "$app_path"
