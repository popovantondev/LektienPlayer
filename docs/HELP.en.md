# Lektien Player – Quick guide

1. **Open** selects a video. Matching `.de.srt`, `.srt` and `.ru.srt` files in the same folder connect automatically. **Library** lists videos from a folder you choose.
2. **Subtitles** selects external SRT files or an embedded text track. **Turn off all subtitles** hides everything. Use **Subtitle appearance…** for font size, colors, outline and background.
3. **Translate** prepares translation, selective review and Russian speech in sections. Existing complete Russian SRT files are reused. **Read aloud** prepares existing Russian text using Silero Kseniya.
4. **Space** plays or pauses. The timeline shows ready sections and preparation. Seeking prioritizes the new position. A manual pause stays paused while the buffer keeps growing. Defaults: six minutes ahead during playback, ten minutes while paused.


5. **Audio** mixes embedded audio tracks. **Original** and **Kseniya** have separate volume controls. **Duck original** gently lowers the background during Russian speech.
6. **View → Controls layout** or **Settings** offers three layouts: below the video, fading over the video, sliding up from the bottom. The two overlay layouts can hide automatically or with the arrow. The bottom edge brings them back. Showing and hiding do not resize the window. Opacity is adjustable.
7. In **Fullscreen**, all buttons share the sliding bottom panel. The bottom edge reveals it; only the macOS system bar appears at the top. **Esc** exits fullscreen. **Fill the screen** chooses cropping or the entire picture with margins. In windowed mode the whole picture stays below the title bar. **Settings → Video behind the title bar** enables top-edge overlap separately.
8. **Settings → Interface language** switches between Deutsch, English and Русский. This does not change processing: currently German → Russian with Kseniya. More translation directions and voices are planned.

ChatGPT shows the remaining quota for the entire account. Finished translations and speech sections live in `.lektien` beside the videos. Keep that folder when moving the library. Original files are not replaced.

Without SRT, **Translate** first looks for embedded text, then offers a German audio track. **More → Subtitles from video** allows manual selection. Recognition runs on the Mac in 30-second sections; purple areas show its buffer. Uncheck translation for German text without ChatGPT requests. Complete `.de.srt` is saved beside the video after all sections are ready. Cache and playback position remain in `.lektien`.

For Telegram, select a channel and choose **Watch**. Video starts through byte ranges. Without an external SRT, **Translate** offers a German audio track and recognizes it in 30-second sections without waiting for the complete file. Seeking prioritizes the new position. Ranges and completed sections are saved; selecting another video stops the old preparation. Only recognized text is sent for translation. OCR is excluded.


### Timeline colours

Time runs left to right. Dark grey is not prepared. Bright purple means recognition is running; translucent purple means German text has been recognised. Blue ahead of the playhead is translation or selective review. Teal means Russian text is ready. Yellow-orange means speech is being generated. Light grey is cached audio. The filled bar behind the playhead shows elapsed playback in the system accent colour, usually blue, covering the other colours.

A German SRT skips recognition; a ready Russian SRT goes directly to speech. Seeking prioritises the new position and keeps finished sections.

### Save voice

**More → Save voice and subtitles…** asks for a folder. If Russian text is not ready yet, start **Translate** first. Saving prepares the entire lecture, including sections before the viewing position, and continues while paused. Playback keeps priority. Cached sections are reused; missing translation uses the normal quota. An existing Russian SRT needs no translation requests.

The new folder contains `voice.ru.m4a`, `voice.ru.srt` and, if available, `voice.de.srt`. Audio contains only Kseniya, with video-timed pauses and silence through the end; the original soundtrack is not mixed in. Playback volume controls do not change the saved file. **Show saved files** opens the result in Finder. Name collisions receive a new numbered folder. **Cancel saving** restores the normal 6–10 minute buffer and keeps the cache. During assembly, cancelling removes only the temporary result.

### Stress and pronunciation


After Telegram sign-in and selection of an allowed channel on the Mac, its videos and adjacent SRT files appear in the same LAN browser. Choose video, audio and subtitles; playback and seeking use byte ranges without a full download. With no text, choose a German audio track and start preparation for Russian speech. After starting or seeking far, the browser waits for 200 seconds of loaded speech.


New translations automatically include pronunciation hints for difficult identifiers
and foreign names. Subtitles keep `NF-κB`, while the voice reads its Russian name.
No separate request is needed; hints are saved for this video. Numbers, indices,
charges and individual Greek symbols are handled locally. The editor below is
only needed for manual corrections.

**More → Stress and pronunciation…** opens the dictionary for all videos in the
current folder. Example: `кремний => кр+емний`, with + before the stressed vowel.
An acute accent also works: `кре́мний`. For ambiguous words, use a phrase such as
`дверной замок => дверной зам+ок`. Longer phrases take priority. Kseniya determines
other stresses and ё automatically, but may make mistakes. **Listen to Kseniya**
tests the draft locally and pauses the video. **Save and apply** regenerates affected
audio parts. Translation and subtitle text/timing stay unchanged. Rules are stored
in `.lektien/pronunciation.txt` beside the videos.

### Save a video with tracks

Russian Kseniya audio comes first and is enabled by default; the German original is a separate selectable track. Russian subtitles also come first and are enabled, while German subtitles remain separate and disabled. You can change the default audio in the save dialog.

**More → Save video with voice…** lets you choose MP4/MKV, original audio tracks, default audio and RU/DE subtitles. Then choose a folder. Kseniya remains a separate switchable track; mixer volume and ducking are not baked into the file.

The new folder contains `video.mp4` or `video.mkv` and separate M4A/SRT files. Video is copied without quality loss; original audio incompatible with MP4 is converted to AAC. MKV is available when the video codec cannot be placed in MP4. Subtitles remain switchable and are not burned into the picture. The source is preserved, and existing folder names receive a numeric suffix. Playing the saved MKV requires a player that supports its codecs.

Source only; no ready-to-install package. macOS 15+, Apple Silicon, Xcode 16.4+ / Swift 6.1. Full functionality needs a separate Runtime, Codex CLI signed in to ChatGPT, and Python/Torch/Silero Kseniya. Installation on a clean Mac is not yet verified.
