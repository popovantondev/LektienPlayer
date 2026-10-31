'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { SynchronizedPlayback } = require('../../Sources/PlayerLAN/Web/playback.js');

class Media extends EventTarget {
    paused = true;
    readyState = 4;
    time = 0;
    seekCount = 0;
    pauseCount = 0;
    playCount = 0;
    ranges = [[0, 100]];
    get currentTime() { return this.time; }
    set currentTime(value) {
        this.time = value; this.seekCount++; this.seeking = true;
        queueMicrotask(() => { this.seeking = false; this.dispatchEvent(new Event('seeked')); });
    }
    get buffered() {
        return {length:this.ranges.length, start:i=>this.ranges[i][0], end:i=>this.ranges[i][1]};
    }
    duration = 100;
    playbackRate = 1;
    seeking = false;
    muted = false;
    src = '/audio';
    play() {
        this.playCount++;
        if (this.paused) { this.paused = false; queueMicrotask(() => this.dispatchEvent(new Event('play'))); }
        if (this.readyState >= 3) return Promise.resolve();
        return new Promise((resolve, reject) => { this.pending = {resolve, reject}; });
    }
    pause() {
        if (this.paused) return;
        this.paused = true; this.pauseCount++;
        if (this.pending) { this.pending.reject(Object.assign(new Error(), {name:'AbortError'})); this.pending = null; }
        queueMicrotask(() => this.dispatchEvent(new Event('pause')));
    }
    ready() {
        this.readyState = 4;
        this.pending?.resolve(); this.pending = null;
        this.dispatchEvent(new Event('canplay'));
    }
}
const settle = () => new Promise(resolve => setImmediate(resolve));
function setup() {
    const video = new Media(), voice = new Media();
    let clock = 0;
    const playback = new SynchronizedPlayback(video, voice, () => {}, () => clock);
    const tick = async (milliseconds = 600) => { clock += milliseconds; playback.pump(); await settle(); };
    const ready = async () => { await settle(); await tick(); await tick(); };
    playback.configure(true);
    return { video, voice, playback, tick, ready };
}
test('cold speech holds the video until both tracks are ready', async () => {
    const {video, voice, playback, tick, ready} = setup();
    voice.readyState = 0;
    playback.play(); await settle();
    assert.equal(video.paused, true);
    assert.equal(voice.muted, true);
    voice.ready(); await ready();
    assert.equal(video.paused, false);
    assert.equal(voice.paused, false);
    assert.equal(voice.muted, false);
});
test('manual pause during loading never resumes automatically', async () => {
    const {video, voice, playback, tick, ready} = setup();
    voice.readyState = 0;
    playback.play(); playback.pause(); voice.ready(); await ready(); playback.pump();
    assert.equal(playback.requested, false);
    assert.equal(video.paused, true); assert.equal(voice.paused, true);
});
test('buffer loss pauses both tracks and readiness resumes both', async () => {
    const {video, voice, playback, tick, ready} = setup();
    playback.play(); await ready();
    voice.readyState = 2; voice.dispatchEvent(new Event('waiting')); await settle();
    assert.equal(video.paused, true); assert.equal(voice.paused, true);
    assert.equal(playback.requested, true);
    voice.ready(); await ready();
    assert.equal(video.paused, false); assert.equal(voice.paused, false);
});
test('seek uses the new time, including a speech chunk offset', async () => {
    const {video, voice, playback, tick, ready} = setup();
    video.currentTime = 65;
    playback.configure(true, 60);
    playback.play(); await ready();
    assert.equal(voice.currentTime, 5);
    video.seeking = true; video.currentTime = 78; video.dispatchEvent(new Event('seeking'));
    assert.equal(video.paused, true);
    video.seeking = false; video.dispatchEvent(new Event('seeked')); await ready();
    assert.equal(voice.currentTime, 18); assert.equal(video.paused, false);
});
test('missing prepared chunk holds playback without losing intent', async () => {
    const {video, voice, playback, tick, ready} = setup();
    playback.configure(true, 0, false); playback.play(); await settle();
    assert.equal(video.paused, true);
    playback.configure(true, 0, true); await ready();
    assert.equal(video.paused, false); assert.equal(voice.paused, false);
});
test('native video pause cancels automatic continuation', async () => {
    const {video, voice, playback, tick, ready} = setup();
    playback.play(); await ready(); video.pause(); await settle();
    playback.pump(); await settle();
    assert.equal(playback.requested, false); assert.equal(voice.paused, true);
});

test('silence after a short speech file keeps video moving without original audio', async () => {
 const {video,voice,playback,tick,ready}=setup();voice.duration=4;video.currentTime=5;
 playback.play();await ready();
 assert.equal(video.paused,false);assert.equal(voice.paused,true);assert.equal(video.muted,true);
});

test('small clock differences never repeatedly seek or pause the playing tracks', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 const seeks=voice.seekCount, pauses=video.pauseCount, starts=video.playCount;
 for(let i=0;i<100;i++){video.time+=.1;voice.time=video.time-.12;await tick(100);}
 assert.equal(voice.seekCount,seeks);assert.equal(video.pauseCount,pauses);assert.equal(video.playCount,starts);
});
test('seek waits for three seconds at the new position and stable readiness', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 video.currentTime=50;video.dispatchEvent(new Event('seeking'));voice.ranges=[[0,10],[50,50.2]];
 await settle();await tick();const starts=video.playCount;
 for(let i=0;i<30;i++){voice.dispatchEvent(new Event('canplay'));await tick(100);}
 assert.equal(video.paused,true);assert.equal(video.playCount,starts);assert.equal(voice.currentTime,50);
 voice.ranges=[[50,54]];await tick(100);await tick(400);assert.equal(video.paused,true);
 await tick(100);assert.equal(video.paused,false);assert.equal(video.playCount,starts+1);
});
test('a readiness flicker resets the stability window without repeated starts', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 voice.readyState=2;voice.dispatchEvent(new Event('waiting'));await settle();const starts=video.playCount;
 for(let i=0;i<10;i++){voice.readyState=4;await tick(100);voice.readyState=2;await tick(100);}
 assert.equal(video.playCount,starts);assert.equal(video.paused,true);
 voice.ready();await ready();assert.equal(video.playCount,starts+1);
});
test('large sustained drift is aligned once while paused, then resumes after buffering', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 video.time=20;voice.time=18;await tick(100);await tick(600);
 assert.equal(video.paused,true);assert.equal(voice.currentTime,20);const seeks=voice.seekCount;
 await ready();assert.equal(video.paused,false);assert.equal(voice.seekCount,seeks);
});
test('last second of a file does not require three seconds beyond its end', async () => {
 const {video,voice,playback,ready}=setup();video.time=99;voice.time=99;video.ranges=voice.ranges=[[99,100]];
 playback.play();await ready();assert.equal(video.paused,false);
});

test('a browser with a shallow paused audio buffer primes silently before resuming', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 video.currentTime=60;video.dispatchEvent(new Event('seeking'));voice.ranges=[[60,62]];
 await settle();await tick();assert.equal(video.paused,true);assert.equal(voice.muted,true);
 const starts=video.playCount, primingStarts=voice.playCount;
 for(let i=0;i<10;i++)await tick(100);
 assert.equal(video.playCount,starts);assert.equal(voice.playCount,primingStarts);
 voice.ranges=[[60,68]];voice.time=60.8;
 await ready();await tick();
 assert.equal(video.paused,false);assert.equal(voice.muted,false);assert.equal(voice.currentTime,60);
});


test('decoded video can resume after a backward seek despite a gap in reported ranges', async () => {
 const {video,voice,playback,tick,ready}=setup();playback.play();await ready();
 video.time=80;voice.time=80;
 video.currentTime=20;video.dispatchEvent(new Event('seeking'));
 video.ranges=[[0,10],[30,50]];voice.ranges=[[20,30]];
 video.readyState=2;await settle();await tick();assert.equal(video.paused,true);
 video.ready();await ready();
 assert.equal(video.paused,false);assert.equal(voice.paused,false);assert.equal(voice.currentTime,20);
});
