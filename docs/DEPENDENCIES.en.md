# Third-party components

Swift 6.1 / Xcode 16.4; SwiftUI, AppKit, AVFoundation, CryptoKit; FFmpeg/FFprobe; whisper.cpp / Whisper / Silero VAD; TDLib; Codex CLI; system Ruby; Python, Torch, Silero TTS (Kseniya).

Kseniya currently expects an existing Python environment in ~/Library/Application Support/SRTVoiceover/.venv-silero with Python/Torch/Silero and the voice model. Codex CLI must be installed and authorized independently. The application also uses system Ruby. A source build alone does not install these components. Do not copy credentials or a virtual environment between machines.

No project license has been assigned. Public source availability does not itself grant permission to redistribute or relicense it. Third-party components retain their own terms.

[FFmpeg](https://ffmpeg.org/legal.html) · [whisper.cpp](https://github.com/ggml-org/whisper.cpp) · [Whisper](https://github.com/openai/whisper) · [Silero](https://github.com/snakers4/silero-models) · [TDLib](https://github.com/tdlib/td) · [Codex](https://github.com/openai/codex)

`Config/runtime-manifest.json`
