'use strict';

// Prepared WAV files are small complete clips. Decode ahead and schedule them
// on one clock, rather than replacing an HTML audio source at every boundary.
class PreparedSpeechAudio extends EventTarget {
    constructor({contextFactory = () => new (window.AudioContext || window.webkitAudioContext)(),
                 fetchFile = (...args) => fetch(...args), now = () => Date.now()} = {}) {
        super();
        this.contextFactory = contextFactory;
        this.fetchFile = fetchFile;
        this.now = now;
        this.context = null;
        this.gain = null;
        this.cache = new Map();
        this.nodes = new Map();
        this.retries = new Map();
        this.clips = [];
        this.loading = null;
        this.epoch = 0;
        this.transport = 0;
        this.duration = NaN;
        this.position = 0;
        this.anchorTime = 0;
        this.target = 0;
        this.paused = true;
        this.seeking = false;
        this.rate = 1;
        this.level = 1;
        this.silent = true;
        this.src = 'prepared';
        this.requiresPriming = false;
        this.clockCorrection = false;
        // The phone must have a meaningful reserve before video is allowed to
        // start. Chunks are usually 30 seconds, so the displayed amount can
        // be slightly above this target.
        this.minimumBufferSeconds = 200;
        this.lookahead = this.minimumBufferSeconds;
        this.maximumBytes = 48 * 1024 * 1024;
    }
    ensureContext() {
        if (this.context) return;
        this.context = this.contextFactory();
        this.gain = this.context.createGain();
        this.gain.connect(this.context.destination);
        this.applyGain();
        this.context.addEventListener('statechange', () => {
            if (this.context.state !== 'running' && !this.paused) {
                this.pause(); this.dispatchEvent(new Event('interrupted'));
            }
            this.dispatchEvent(new Event('canplay'));
        });
    }
    unlock() {
        this.ensureContext();
        return this.context.resume();
    }
    reset() {
        this.pause(); this.epoch++;
        this.loading?.controller.abort(); this.loading = null;
        this.cache.clear(); this.retries.clear(); this.clips = [];
        this.duration = NaN; this.position = this.target = 0;
    }
    update(job, position) {
        this.duration = job?.duration ?? NaN;
        this.target = position;
        this.clips = (job?.clips || []).filter(c => Number.isFinite(c.start) && c.end > c.start &&
            /^\/prepared\/[a-f0-9]{64}\/[a-f0-9]{64}\.wav$/.test(c.url)).sort((a,b) => a.start-b.start);
        const wanted = new Set(this.clips.filter(c => c.end > position - 30 && c.start < position + this.lookahead).map(c => c.url));
        if (this.loading && !wanted.has(this.loading.url)) {
            this.loading.controller.abort(); this.loading = null;
        }
        let removedNode = false;
        for (const [url] of this.cache) if (!wanted.has(url)) {
            this.cache.delete(url);
            const node = this.nodes.get(url);
            if (node) { node.stop(); node.disconnect(); this.nodes.delete(url); removedNode = true; }
        }
        if (removedNode && !this.paused) this.schedule();
        this.downloadNext();
        this.tick();
    }
    async downloadNext() {
        if (this.loading) return;
        const clip = this.clips.find(c => c.end > this.target && c.start < this.target + this.lookahead &&
            !this.cache.has(c.url) && ((this.retries.get(c.url)?.after ?? 0) <= this.now() || this.target >= (this.retries.get(c.url)?.position ?? Infinity)));
        if (!clip) return;
        this.ensureContext();
        const request = {url:clip.url,controller:new AbortController(),epoch:this.epoch};
        this.loading = request;
        try {
            const response = await this.fetchFile(clip.url, {signal:request.controller.signal});
            if (!response.ok) throw Error('network');
            const limit = 16 * 1024 * 1024;
            if (Number(response.headers?.get('Content-Length')) > limit) throw Error('size');
            const bytes = await response.arrayBuffer();
            if (bytes.byteLength > limit) throw Error('size');
            if (this.loading !== request || this.epoch !== request.epoch) return;
            const buffer = await this.context.decodeAudioData(bytes);
            if (this.loading !== request || this.epoch !== request.epoch) return;
            const size = buffer.length * buffer.numberOfChannels * 4;
            if (size > this.maximumBytes) throw Error('size');
            // Retain the current clip first. Old and distant clips are cheaper
            // to fetch again than unbounded decoded audio on a phone.
            let used = [...this.cache.values()].reduce((sum,e) => sum+e.size,0);
            for (const [url,entry] of [...this.cache].sort((a,b) => Math.abs(b[1].clip.start-this.target)-Math.abs(a[1].clip.start-this.target))) {
                if (used + size <= this.maximumBytes) break;
                if (entry.clip.end > this.target && Math.abs(entry.clip.start-this.target) <= Math.abs(clip.start-this.target)) continue;
                this.cache.delete(url); used -= entry.size;
                const node = this.nodes.get(url);
                if (node) { node.stop(); node.disconnect(); this.nodes.delete(url); }
            }
            if (used + size > this.maximumBytes) {
                this.retries.set(clip.url,{attempts:0,after:Infinity,position:this.target+15});
                return;
            }
            this.cache.set(clip.url,{clip,buffer,size}); this.retries.delete(clip.url);
            this.schedule();
            this.dispatchEvent(new Event('progress'));
            this.dispatchEvent(new Event('canplay'));
        } catch (error) {
            if (this.loading === request && error.name !== 'AbortError') {
                const attempts = (this.retries.get(clip.url)?.attempts ?? 0)+1;
                this.retries.set(clip.url,{attempts,after:this.now()+Math.min(10000,1000*2**Math.min(attempts-1,4))});
                this.dispatchEvent(new Event('downloaderror'));
            }
        } finally {
            if (this.loading === request) { this.loading = null; this.downloadNext(); }
        }
    }
    ranges() {
        const ranges = [];
        for (const clip of this.clips) {
            if (!this.cache.has(clip.url)) continue;
            const last = ranges[ranges.length-1];
            if (last && clip.start <= last[1]+0.05) last[1] = Math.max(last[1],clip.end);
            else ranges.push([clip.start,clip.end]);
        }
        return ranges;
    }
    get buffered() {
        const ranges = this.ranges();
        return {length:ranges.length,start:i=>ranges[i][0],end:i=>ranges[i][1]};
    }
    bufferAhead(time = this.target) {
        const range = this.ranges().find(r => r[0] <= time+0.05 && r[1] > time);
        return range ? range[1]-time : 0;
    }
    get readyState() {
        if (!Number.isFinite(this.duration)) return 0;
        return this.bufferAhead(this.currentTime) > 0 ? 4 : 1;
    }
    get currentTime() {
        return this.paused || !this.context ? this.position :
            Math.min(this.duration,this.position+(this.context.currentTime-this.anchorTime)*this.rate);
    }
    set currentTime(value) {
        const playing = !this.paused;
        this.stopNodes(); this.position = value; this.anchorTime = this.context?.currentTime ?? 0;
        this.seeking = true;
        queueMicrotask(() => {this.seeking=false;this.dispatchEvent(new Event('seeked'));});
        if (playing) this.schedule();
    }
    get playbackRate() { return this.rate; }
    set playbackRate(value) {
        if (value === this.rate) return;
        this.position = this.currentTime; this.anchorTime = this.context?.currentTime ?? 0;
        this.rate = value; this.stopNodes(); this.schedule();
    }
    get volume() { return this.level; }
    set volume(value) { this.level=value; this.applyGain(); }
    get muted() { return this.silent; }
    set muted(value) { this.silent=value; this.applyGain(); }
    applyGain() { if (this.gain) this.gain.gain.value=this.silent?0:this.level; }
    async play() {
        const token = ++this.transport;
        await this.unlock();
        if (token !== this.transport) throw Object.assign(Error('cancelled'),{name:'AbortError'});
        if (!this.paused) return;
        this.anchorTime=this.context.currentTime;this.paused=false;this.schedule();
    }
    pause() {
        this.transport++;
        this.position=this.currentTime;this.paused=true;this.stopNodes();
    }
    stopNodes() {
        for (const node of this.nodes.values()) { node.stop(); node.disconnect(); }
        this.nodes.clear();
    }
    schedule() {
        if (this.paused || !this.context) return;
        const current = this.currentTime;
        for (const clip of this.clips) {
            if (clip.end <= current || this.nodes.has(clip.url)) continue;
            const entry = this.cache.get(clip.url); if (!entry) continue;
            const offset = Math.max(0,current-clip.start);
            const length = Math.min(entry.buffer.duration,clip.end-clip.start)-offset;
            if (length <= 0) continue; // The rest of this planned clip is silence.
            const node = this.context.createBufferSource();node.buffer=entry.buffer;
            node.playbackRate.value=this.rate;node.connect(this.gain);
            const when = this.anchorTime+(Math.max(clip.start,current)-this.position)/this.rate;
            node.start(when,offset,length);this.nodes.set(clip.url,node);
        }
    }
    tick() {
        if (this.paused) return;
        if (this.currentTime >= this.duration) {this.pause();return;}
        if (this.bufferAhead(this.currentTime) <= 0) {
            this.pause();this.dispatchEvent(new Event('waiting'));return;
        }
        this.schedule();
    }
}
if (typeof module !== 'undefined') module.exports={PreparedSpeechAudio};
