#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
git diff --check
xcrun swift test --sdk "$SDKROOT"
ruby -c Sources/PlayerSpeech/Resources/Engine/player_speech.rb
ruby -c Sources/PlayerSpeech/Resources/Engine/srt_voiceover.rb
ruby -c Sources/PlayerSpeech/Resources/Engine/speech_normalizer.rb
xcrun python3 -c 'from pathlib import Path; p = Path("Sources/PlayerSpeech/Resources/Engine/silero_worker.py"); compile(p.read_text(), str(p), "exec")'
xcrun python3 -c 'from pathlib import Path; p = Path("scripts/package-runtime.py"); compile(p.read_text(), str(p), "exec")'
bash -n scripts/build-preview.sh
bash -n scripts/package-portable.sh
test -s docs/CLEAN_MAC_README.md

ruby Tests/EngineTests/smooth_tempo_test.rb
ruby Tests/EngineTests/parallel_digest_test.rb
ruby Tests/EngineTests/formula_normalization_test.rb
ruby Tests/EngineTests/stress_test.rb

# Browser regressions use the developer's Node runtime; it is not an app dependency.
if command -v node >/dev/null 2>&1; then
    node --check Sources/PlayerLAN/Web/player.js
    node --check Sources/PlayerLAN/Web/adaptive-video.js
    node --check Sources/PlayerLAN/Web/prepared-speech.js
    node --test Tests/EngineTests/browser_playback_test.cjs Tests/EngineTests/prepared_speech_test.cjs Tests/EngineTests/adaptive_video_test.cjs
fi
