# Build und Voraussetzungen

Xcode 16.4 oder neuer installieren und dessen Entwicklerverzeichnis auswählen. Im Projektordner `swift build` ausführen. `bash scripts/build-preview.sh` benötigt zusätzlich Runtime passend zu Config/runtime-manifest.json: Alle Größen und SHA-256 werden geprüft, nichts wird heruntergeladen. Der Pfad kann mit LEKTIEN_RUNTIME_DIRECTORY gesetzt werden. Modelle und Medienwerkzeuge sind nicht in Git enthalten. Das Manifest beschreibt vorhandene lokale Artefakte, keinen öffentlichen Download-Dienst. Eine automatische reproduzierbare Beschaffung der Laufzeit ist noch nicht verfügbar.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build
# With the separately prepared runtime:
LEKTIEN_RUNTIME_DIRECTORY=/path/to/Runtime bash scripts/build-preview.sh
```

Kseniya erwartet derzeit eine vorhandene Python-Umgebung unter ~/Library/Application Support/SRTVoiceover/.venv-silero mit Python/Torch/Silero und dem Sprachmodell. Codex CLI muss separat installiert und angemeldet werden. System-Ruby wird ebenfalls verwendet. Ein Quellcode-Build installiert diese Komponenten nicht. Zugangsdaten und virtuelle Umgebungen nicht zwischen Rechnern kopieren.

Nur Quellcode, kein fertiges Installationspaket. macOS 15+, Apple Silicon, Xcode 16.4+ / Swift 6.1. Für alle Funktionen sind ein separates Runtime-Paket, Codex CLI mit ChatGPT-Anmeldung sowie Python/Torch/Silero Kseniya erforderlich. Die Installation auf einem frisch eingerichteten Mac ist noch nicht geprüft.
