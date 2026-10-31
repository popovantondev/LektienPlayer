# Build and requirements

Install Xcode 16.4 or later and select its developer directory. Run `swift build` from the project folder to compile. `bash scripts/build-preview.sh` additionally requires Runtime matching Config/runtime-manifest.json; it validates every pinned size and SHA-256 and does not download components. Supply it using LEKTIEN_RUNTIME_DIRECTORY. The model and media tools are excluded from Git. The manifest records the existing local artifact set, not a public download service. No automatic, reproducible runtime acquisition is provided yet.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
# With the separately prepared runtime:
LEKTIEN_RUNTIME_DIRECTORY=/path/to/Runtime bash scripts/build-preview.sh
```

Kseniya currently expects an existing Python environment in ~/Library/Application Support/SRTVoiceover/.venv-silero with Python/Torch/Silero and the voice model. Codex CLI must be installed and authorized independently. The application also uses system Ruby. A source build alone does not install these components. Do not copy credentials or a virtual environment between machines.

Source only; no ready-to-install package. macOS 15+, Apple Silicon, Xcode 16.4+ / Swift 6.1. Full functionality needs a separate Runtime, Codex CLI signed in to ChatGPT, and Python/Torch/Silero Kseniya. Installation on a clean Mac is not yet verified.
