# Architecture

PlayerCore contains media-independent models. PlayerMedia probes/extracts streams. PlayerTranscription recognizes German sections with boundary context. PlayerTranslation prepares text and validates responses. PlayerSpeech normalizes pronunciation and synthesizes timed chunks. PlayerExport assembles new output folders atomically. PlayerLAN serves an allowlisted library and prepared speech to one viewer. The SwiftUI executable coordinates playback, Telegram, settings and cancellation. Completed work is cached; seeking prioritizes the new location and rejects stale results.

Speech recognition and synthesis run locally. Translation sends prepared subtitle text to the signed-in service. Telegram requests use your own authorized session. Credentials are stored separately on the Mac. Source recordings are preserved; cache data is stored in .lektien. Only share the chosen library on a trusted home network; do not forward its port to the Internet.
