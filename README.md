# Lektien Player

<!-- public-release:start -->
Lecture player for Mac: local German speech recognition, translation and Russian Kseniya voice-over in sections. Telegram streaming and home-network viewing.

**macOS 15+ · Apple Silicon · Source only development**

**[Source](https://github.com/popovantondev/LektienPlayer)** · **[About the app](https://popovantondev.github.io/LektienPlayer/index-en.html)** · **[User guide](https://popovantondev.github.io/LektienPlayer/Guide-en.html)** · **[Report a problem](https://github.com/popovantondev/LektienPlayer/issues/new)**

**Requirements and limitations:** Source only; no ready-to-install package. macOS 15+, Apple Silicon, Xcode 16.4+ / Swift 6.1. Full functionality needs a separate Runtime, Codex CLI signed in to ChatGPT, and Python/Torch/Silero Kseniya. Installation on a clean Mac is not yet verified.

**First steps:** Read the guide and BUILD.en.md. Compile using swift build; a complete .app needs prepared Runtime components. Open a video, choose subtitles or a German audio track, then start translation.
<!-- public-release:end -->

[RU](README.ru.md) · [DE](README.de.md) · [EN](README.md)

No binary release or installer is published. The repository contains the latest selected recognition improvements; it does not include private development history or machine-specific runtime files.

## What it does

- Local MP4/M4V/MKV playback, embedded audio and text subtitle selection, adjacent SRT discovery.
- German speech recognition in sections, translation with saved text caches, and local Russian Silero Kseniya synthesis.
- Separate voice volume, original-audio ducking, subtitle styling and three control-panel layouts.
- Telegram byte-range streaming and browser viewing over the same home network.
- M4A/SRT export and MP4/MKV with separate Russian and German tracks; video copied without re-encoding when supported.

## Current limitations

- Current processing direction is German → Russian; interface languages are DE/EN/RU. Other voices and translation directions are planned.
- The browser waits for a 200-second speech reserve at startup or after a distant seek; near the end it uses the remaining duration. Manual pause keeps preparing ahead.
- One remote viewer/preparation session; long real-device and weak-Wi-Fi tests remain necessary. Safari HTTPS-only mode may block the local HTTP address.
- OCR, screen capture, live Zoom/Teams translation and a Windows-native application are not implemented.
- Pronunciation and recognition can contain errors. No accuracy, medical interpretation or seamless playback guarantee is made.

## Data and privacy

Speech recognition and synthesis run locally. Translation sends prepared subtitle text to the signed-in service. Telegram requests use your own authorized session. Credentials are stored separately on the Mac. Source recordings are preserved; cache data is stored in .lektien. Only share the chosen library on a trusted home network; do not forward its port to the Internet.

[Build and requirements](docs/BUILD.en.md) · [Architecture](docs/ARCHITECTURE.en.md) · [Third-party notices](docs/DEPENDENCIES.en.md)

No project license has been assigned. Public source availability does not itself grant permission to redistribute or relicense it. Third-party components retain their own terms.
