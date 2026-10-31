'use strict';

// A paused video is also the clock while either media element is buffering.
class SynchronizedPlayback {
    constructor(video, voice, status, now = () => performance.now()) {
        this.video = video;
        this.voice = voice;
        this.status = status;
        this.now = now;
        this.buffering = true;
        this.readySince = null;
        this.driftSince = null;
        this.alignmentPending = false;
        this.audioPriming = false;
        this.minimumBufferSeconds = 3;
        this.stableBufferMilliseconds = 500;
        this.requested = false;
        this.external = false;
        this.offset = 0;
        this.available = true;
        this.generation = 0;
        this.internalPauses = 0;
        this.internalPlays = 0;
        this.starting = false;
        this.warming = false;
        this.stallTimes = [];
        video.addEventListener('play', () => {
            if (this.internalPlays) { this.internalPlays--; return; }
            this.play();
        });
        video.addEventListener('pause', () => {
            if (this.internalPauses) { this.internalPauses--; return; }
            this.pause();
        });
        video.addEventListener('seeking', () => { this.hold(); this.readySince = null; this.pump(); });
        video.addEventListener('waiting', () => { if (video.readyState < 3) this.hold(); });
        this.boundVoices = new Set([voice]);
        this.bindVoice(voice);
        for (const event of ['loadedmetadata', 'canplay', 'seeked', 'progress']) {
            video.addEventListener(event, () => this.pump());
        }
        video.addEventListener('ratechange', () => { this.voice.playbackRate = video.playbackRate; });
        video.addEventListener('ended', () => this.pause());
    }
    bindVoice(voice) {
        voice.addEventListener('interrupted', () => {
            if (this.voice === voice && this.external) { this.pause(); this.status('audio'); }
        });
        voice.addEventListener('waiting', () => {
            if (this.voice === voice && this.external && voice.readyState < 3) this.hold('audio-stall');
        });
        voice.addEventListener('seeked', () => { if (this.voice === voice) this.alignmentPending = false; });
        for (const event of ['loadedmetadata', 'canplay', 'seeked', 'progress']) {
            voice.addEventListener(event, () => { if (this.voice === voice) this.pump(); });
        }
    }
    setVoice(voice) {
        if (this.voice === voice) return;
        this.generation++; this.starting = false; this.warming = false;
        this.hold(); this.voice = voice; this.alignmentPending = false;
        this.boundVoices ??= new Set();
        if (!this.boundVoices.has(voice)) { this.bindVoice(voice); this.boundVoices.add(voice); }
        this.hold();
    }
    pauseVideo() {
        if (!this.video.paused) { this.internalPauses++; this.video.pause(); }
    }
    hold(reason = '') {
        if (reason === 'audio-stall') this.recordAudioStall();
        if (!this.buffering) {
            // Ignore completions from a play() interrupted by a seek or stall.
            this.generation++;
            this.starting = false;
            this.warming = false;
        }
        this.buffering = true;
        this.readySince = null;
        this.driftSince = null;
        this.audioPriming = false;
        this.voice.playbackRate = this.video.playbackRate;
        this.pauseVideo();
        this.voice.pause();
        if (this.requested) this.status('buffering');
    }
    recordAudioStall() {
        const cutoff = this.now() - 30_000;
        this.stallTimes = this.stallTimes.filter(time => time >= cutoff);
        this.stallTimes.push(this.now());
        // A second interruption is evidence that a short reserve is not
        // enough for this connection. Keep the video stopped and rebuild the
        // same full reserve instead of cycling pause/play.
        if (this.stallTimes.length >= 2 && this.voice.minimumBufferSeconds) {
            this.voice.minimumBufferSeconds = Math.max(this.voice.minimumBufferSeconds, 200);
        }
    }
    pause() {
        this.requested = false;
        this.generation++;
        this.starting = false;
        this.warming = false;
        this.hold();
        this.status('');
    }
    configure(external, offset = 0, available = true) {
        const changed = this.external !== external || this.offset !== offset || this.available !== available;
        this.external = external;
        this.offset = offset;
        this.available = available;
        this.video.muted = external;
        if (changed) {
            this.generation++;
            this.starting = false;
            this.warming = false;
            this.alignmentPending = false;
            this.hold();
        }
        this.pump();
    }
    play() {
        this.requested = true;
        this.video.preload = 'auto';
        this.voice.preload = 'auto';
        if (this.external && this.voice.unlock) {
            this.hold();
            const token = this.generation;
            this.warming = true;
            this.voice.unlock().then(() => {
                if (token !== this.generation) return;
                this.warming = false; this.pump();
            }).catch(() => { if (token === this.generation) { this.pause(); this.status('audio'); } });
            return;
        }
        // Start audio in the tap's activation context, inaudibly. Safari may
        // otherwise reject its first play after asynchronous video buffering.
        if (this.external && this.available && this.voice.src && !this.warming && this.voice.paused) {
            this.hold();
            this.align();
            const token = this.generation;
            this.warming = true;
            this.voice.muted = true;
            this.voice.play().then(() => {
                if (token !== this.generation) return;
                this.voice.pause();
                this.warming = false;
                this.pump();
            }).catch(error => {
                if (token !== this.generation) return;
                this.warming = false;
                if (error.name !== 'AbortError') { this.pause(); this.status('audio'); }
            });
        }
        this.pump();
    }
    toggle() { if (this.requested) this.pause(); else this.play(); }
    audioTarget() {
        return Math.min(Number.isFinite(this.voice.duration) ? this.voice.duration : Infinity,
            Math.max(0, this.video.currentTime - this.offset));
    }
    align() {
        if (this.alignmentPending || this.voice.seeking || this.voice.readyState === 0) return;
        const target = this.audioTarget();
        if (Math.abs(this.voice.currentTime - target) > 0.04) {
            this.alignmentPending = true;
            this.readySince = null;
            this.voice.currentTime = target;
        }
    }
    hasBuffer(media, time, requireReady = true) {
        if ((requireReady && media.readyState < 3) || media.seeking) return false;
        const remaining = Number.isFinite(media.duration) ? Math.max(0, media.duration - time) : Infinity;
        const reserve = media.minimumBufferSeconds ?? this.minimumBufferSeconds;
        const required = Math.min(reserve * this.video.playbackRate, remaining);
        if (required < 0.05) return true;
        for (let i = 0; i < media.buffered.length; i++) {
            if (media.buffered.start(i) <= time + 0.05 && media.buffered.end(i) >= time + required - 0.05) return true;
        }
        return false;
    }
    primeAudio() {
        if (this.audioPriming || this.voice.readyState === 0 || this.voice.seeking) return;
        const token = this.generation;
        this.audioPriming = true;
        this.voice.muted = true;
        // Some browsers stop fetching while paused with only ~2 seconds at
        // the seek target. Decode silently until the required range arrives.
        this.voice.play().catch(error => {
            if (token !== this.generation || !this.audioPriming) return;
            this.audioPriming = false;
            if (error.name !== 'AbortError') { this.pause(); this.status('audio'); }
        });
    }
    pump() {
        if (!this.requested || this.starting || this.warming) return;
        const video = this.video, voice = this.voice;
        const audible = this.external && !(Number.isFinite(voice.duration) && video.currentTime - this.offset >= voice.duration);
        if (!this.available || video.seeking || video.readyState < 3) {
            this.hold(); return;
        }
        if (!audible) voice.pause();
        if (!this.buffering && !video.paused && (!audible || !voice.paused)) {
            if (audible) {
                const drift = this.audioTarget() - voice.currentTime;
                if (Math.abs(drift) > 0.75) {
                    this.driftSince ??= this.now();
                    if (this.now() - this.driftSince >= 600) { this.hold(); this.pump(); }
                } else {
                    this.driftSince = null;
                    // Small clock differences must not repeatedly seek the audio
                    // decoder. Preserve pitch while gently converging the clocks.
                    const correction = voice.clockCorrection !== false && Math.abs(drift) > 0.15 ? Math.max(-0.02, Math.min(0.02, drift * 0.05)) : 0;
                    voice.playbackRate = video.playbackRate * (1 + correction);
                }
            }
            return;
        }
        if (!this.buffering) this.hold();
        if (this.audioPriming) {
            if (!this.hasBuffer(voice, this.audioTarget())) return;
            voice.pause();
            this.audioPriming = false;
        }
        if (audible) this.align();
        if (audible && !this.alignmentPending && !this.hasBuffer(voice, this.audioTarget(), false)) {
            this.readySince = null;
            if (voice.requiresPriming !== false) this.primeAudio();
            return;
        }
        // A paused browser may omit already decoded video from TimeRanges.
        // Its stable readyState is authoritative; require ranges for speech.
        if (this.alignmentPending ||
            (audible && !this.hasBuffer(voice, this.audioTarget()))) {
            this.readySince = null;
            return;
        }
        // Hysteresis: require a real contiguous buffer at the new time and
        // stable readiness, not one transient canplay/seeked notification.
        this.readySince ??= this.now();
        if (this.now() - this.readySince < this.stableBufferMilliseconds) return;
        const token = this.generation;
        this.starting = true;
        this.buffering = false;
        voice.playbackRate = video.playbackRate;
        voice.muted = true;
        const audio = audible ? voice.play() : Promise.resolve();
        if (video.paused) this.internalPlays++;
        Promise.all([audio, video.play()]).then(() => {
            if (token !== this.generation || !this.requested) return;
            this.starting = false;
            // Do not seek again here: both play() calls have just started their
            // clocks and a small startup difference is expected.
            voice.muted = false;
            this.status('');
        }).catch(error => {
            if (token !== this.generation) return;
            this.starting = false;
            if (error.name === 'AbortError') { this.hold(); return; }
            this.pause(); this.status(this.external ? 'audio' : 'error');
        });
    }
}

if (typeof module !== 'undefined') module.exports = { SynchronizedPlayback };
