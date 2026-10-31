'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {PreparedSpeechAudio}=require('../../Sources/PlayerLAN/Web/prepared-speech.js');
const {SynchronizedPlayback}=require('../../Sources/PlayerLAN/Web/playback.js');
const settle=()=>new Promise(resolve=>setImmediate(resolve));
const clip=(start,end,key)=>({start,end,url:'/prepared/'+'a'.repeat(64)+'/'+key.repeat(64)+'.wav'});
const longClip=i=>({start:i*30,end:(i+1)*30,url:'/prepared/'+'a'.repeat(64)+'/'+i.toString(16).padStart(64,'0')+'.wav'});
class Context extends EventTarget {
 currentTime=0;state='running';destination={};starts=[];stops=[];
 resume(){this.state='running';return Promise.resolve();}
 createGain(){return {gain:{value:0},connect(){}};}
 createBufferSource(){const owner=this;return {playbackRate:{value:1},connect(){},disconnect(){},
  start(when,offset,duration){owner.starts.push({when,offset,duration});},stop(){owner.stops.push(true);}};}
 decodeAudioData(){return Promise.resolve({duration:30,length:720000,numberOfChannels:1});}
}
function fixture(fetchFile){
 const context=new Context(),requests=[];
 const voice=new PreparedSpeechAudio({contextFactory:()=>context,fetchFile:fetchFile||((url)=>{
  requests.push(url);return Promise.resolve({ok:true,arrayBuffer:()=>Promise.resolve(new ArrayBuffer(8))});})});
 return {context,voice,requests};
}
class Video extends EventTarget {
 paused=true;currentTime=0;readyState=4;seeking=false;duration=180;playbackRate=1;pauses=0;plays=0;
 pause(){if(!this.paused){this.paused=true;this.pauses++;queueMicrotask(()=>this.dispatchEvent(new Event('pause')));}}
 play(){if(this.paused){this.paused=false;this.plays++;queueMicrotask(()=>this.dispatchEvent(new Event('play')));}return Promise.resolve();}
}
test('clips are downloaded while paused and scheduled across a boundary on one clock',async()=>{
 const {voice,context,requests}=fixture();voice.update({duration:90,clips:[clip(0,30,'1'),clip(30,60,'2'),clip(60,90,'3')]},0);
 await settle();await settle();assert.equal(voice.bufferAhead(0),90);assert.equal(voice.paused,true);
 await voice.play();assert.equal(context.starts.length,3);
 assert.deepEqual(context.starts.map(s=>s.when),[0,30,60]);
 context.currentTime=31;voice.tick();assert.equal(voice.currentTime,31);assert.equal(context.stops.length,0);
 voice.update({duration:90,clips:[clip(0,30,'1'),clip(30,60,'2'),clip(60,90,'3')]},31);
 await settle();assert.equal(requests.length,3);assert.equal(context.starts.length,3);
});
test('newly prepared data starts after the existing node without restarting it',async()=>{
 const {voice,context}=fixture();voice.update({duration:60,clips:[clip(0,30,'1')]},0);await settle();await voice.play();
 context.currentTime=10;voice.update({duration:60,clips:[clip(0,30,'1'),clip(30,60,'2')]},10);await settle();
 assert.deepEqual(context.starts.map(s=>s.when),[0,30]);assert.equal(context.stops.length,0);
});
test('decoded clips cross two boundaries without any video pause',async()=>{
 const {voice,context}=fixture(),video=new Video();let now=0;
 voice.update({duration:90,clips:[clip(0,30,'1'),clip(30,60,'2'),clip(60,90,'3')]},0);await settle();
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();assert.equal(video.paused,false);
 const pauses=video.pauses;
 for(let i=1;i<=700;i++){context.currentTime=i/10;video.currentTime=i/10;voice.tick();now+=100;sync.pump();await settle();}
 assert.equal(video.pauses,pauses);assert.equal(video.plays,1);assert.equal(context.starts.length,3);
});
test('buffer exhaustion holds the video and resumes only after missing data is decoded',async()=>{
 const {voice,context}=fixture(),video=new Video();let now=0;
 voice.update({duration:60,clips:[clip(0,30,'1')]},0);await settle();
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();context.currentTime=30.1;video.currentTime=30.1;voice.tick();
 assert.equal(video.paused,true);const starts=video.plays;
 for(let i=0;i<20;i++){now+=100;sync.pump();await settle();}assert.equal(video.plays,starts);
 voice.update({duration:60,clips:[clip(0,30,'1'),clip(30,60,'2')]},30.1);await settle();
 now+=600;sync.pump();await settle();assert.equal(video.paused,false);
});
test('seek cancels an obsolete download and ignores its late decoded result',async()=>{
 const pending=[];const {voice}=fixture((url,{signal})=>new Promise(resolve=>pending.push({url,signal,resolve})));
 const clips=[clip(0,30,'1'),clip(120,150,'2')];voice.update({duration:150,clips},0);
 voice.update({duration:150,clips},120);assert.equal(pending[0].signal.aborted,true);assert.equal(pending.length,2);
 const response={ok:true,arrayBuffer:()=>Promise.resolve(new ArrayBuffer(8))};
 pending[0].resolve(response);pending[1].resolve(response);await settle();await settle();
 assert.equal(voice.cache.has(clips[0].url),false);assert.equal(voice.bufferAhead(120),30);
});
test('reset discards old lecture buffers and pending playback',async()=>{
 const {voice,context}=fixture();voice.update({duration:30,clips:[clip(0,30,'1')]},0);await settle();
 let resume;context.resume=()=>new Promise(resolve=>{resume=resolve;});
 const playing=voice.play();voice.reset();resume();await assert.rejects(playing,{name:'AbortError'});
 assert.equal(voice.paused,true);assert.equal(voice.cache.size,0);assert.equal(context.starts.length,0);
});
test('a gap is not advertised as loaded and a short WAV has a silent planned tail',async()=>{
 const {voice,context}=fixture();voice.update({duration:120,clips:[clip(0,40,'1'),clip(60,90,'2')]},0);await settle();
 assert.equal(voice.bufferAhead(0),40);assert.equal(voice.bufferAhead(45),0);
 await voice.play();context.currentTime=35;voice.tick();assert.equal(voice.paused,false);
 context.currentTime=41;voice.tick();assert.equal(voice.paused,true);
});
test('network failure backs off rather than repeatedly requesting on each tick',async()=>{
 let calls=0;const {voice}=fixture(()=>{calls++;return Promise.reject(Error('offline'));});
 let now=0;voice.now=()=>now;const job={duration:30,clips:[clip(0,30,'1')]};
 voice.update(job,0);await settle();for(let i=0;i<100;i++)voice.update(job,0);
 assert.equal(calls,1);now=1000;voice.update(job,0);await settle();assert.equal(calls,2);
});

test('playback waits for a 200-second device reserve before starting',async()=>{
 const {voice,context}=fixture(),video=new Video();let now=0;
 const clips=Array.from({length:8},(_,index)=>clip(index*30,(index+1)*30,String(index+1)));
 voice.update({duration:240,clips},0);await settle();await settle();
 assert.equal(voice.bufferAhead(0),210);
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();
 assert.equal(video.paused,false);
});

test('two audio stalls reset playback and require the full device reserve again',async()=>{
 const {voice,context}=fixture(),video=new Video();let now=0;
 const clips=Array.from({length:8},(_,index)=>clip(index*30,(index+1)*30,String(index+1)));
 voice.update({duration:240,clips},0);await settle();await settle();
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();assert.equal(video.paused,false);
 voice.cache.clear();voice.dispatchEvent(new Event('waiting'));await settle();
 voice.update({duration:240,clips},0);await settle();await settle();
 voice.cache.clear();now=1_000;voice.dispatchEvent(new Event('waiting'));await settle();
 assert.equal(video.paused,true);assert.equal(voice.minimumBufferSeconds,200);
 voice.update({duration:240,clips:clips.slice(0,6)},0);await settle();await settle();
 assert.equal(voice.bufferAhead(0),180);
 now=1_600;sync.pump();await settle();assert.equal(video.paused,true);
 voice.update({duration:240,clips},0);await settle();await settle();
 now=2_200;sync.pump();await settle();assert.equal(video.paused,false);
});

test('decoded memory is bounded without evicting and repeatedly fetching nearer clips',async()=>{
 const {voice,requests}=fixture();voice.maximumBytes=6*1024*1024;
 const job={duration:90,clips:[clip(0,30,'1'),clip(30,60,'2'),clip(60,90,'3')]};
 voice.update(job,0);await settle();await settle();assert.equal(voice.bufferAhead(0),60);
 for(let i=0;i<50;i++)voice.update(job,0);await settle();assert.equal(requests.length,3);
 assert.ok([...voice.cache.values()].reduce((s,c)=>s+c.size,0)<=voice.maximumBytes);
 voice.update(job,40);await settle();assert.equal(voice.bufferAhead(40),50);
});
test('an audio interruption pauses video and asks for a fresh play gesture',async()=>{
 const {voice,context}=fixture(),video=new Video();let now=0,status='';
 voice.update({duration:30,clips:[clip(0,30,'1')]},0);await settle();
 const sync=new SynchronizedPlayback(video,voice,s=>status=s,()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();context.state='interrupted';context.dispatchEvent(new Event('statechange'));
 assert.equal(video.paused,true);assert.equal(sync.requested,false);assert.equal(status,'audio');
});

test('an hour of virtual playback crosses speech parts without restarting either clock',async()=>{
 const {voice,context,requests}=fixture(),video=new Video();let now=0;
 const duration=3900,clips=Array.from({length:130},(_,i)=>longClip(i));
 const job={duration,clips};video.duration=duration;
 voice.update(job,0);await settle();await settle();
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);sync.play();await settle();
 now=600;sync.pump();await settle();assert.equal(video.paused,false);
 for(let second=1;second<=3600;second++){
  context.currentTime=second;video.currentTime=second;now+=1000;
  voice.update(job,second);voice.tick();sync.pump();await settle();
  assert.ok([...voice.cache.values()].reduce((sum,item)=>sum+item.size,0)<=voice.maximumBytes);
  assert.equal(video.paused,false,`unexpected pause at ${second}s`);
 }
 assert.equal(video.plays,1);assert.equal(video.pauses,0);
 assert.equal(requests.length,127);
 assert.equal(new Set(requests).size,requests.length);
 assert.equal(context.starts.length,127);
 assert.equal(context.stops.length<=125,true);
});

test('far seeks discard late responses and manual pause survives later readiness',async()=>{
 const pending=[];const {voice,context}=fixture((url,{signal})=>new Promise(resolve=>pending.push({url,signal,resolve})));
 const video=new Video();video.duration=3900;let now=0;
 const clips=Array.from({length:130},(_,i)=>longClip(i));
 const job={duration:3900,clips},response={ok:true,arrayBuffer:()=>Promise.resolve(new ArrayBuffer(8))};
 const sync=new SynchronizedPlayback(video,voice,()=>{},()=>now);sync.configure(true);
 voice.update(job,0);assert.equal(pending.length,1);
 for(const target of [1800,300,2700,600]){
  video.currentTime=target;video.seeking=true;video.dispatchEvent(new Event('seeking'));
  voice.update(job,target);video.seeking=false;video.dispatchEvent(new Event('seeked'));
  assert.equal(pending.at(-2).signal.aborted,true);
 }
 for(const obsolete of pending.slice(0,-1).reverse())obsolete.resolve(response);
 await settle();await settle();
 assert.equal(voice.cache.size,0);
 const firstCurrent=pending.length-1;
 for(let index=firstCurrent;index<firstCurrent+7;index++){
  pending[index].resolve(response);await settle();await settle();
 }
 assert.ok(voice.bufferAhead(600)>=200);
 sync.play();await settle();now=600;sync.pump();await settle();assert.equal(video.paused,false);
 sync.pause();const starts=video.plays;
 for(let i=0;i<20;i++){now+=1000;voice.update(job,600);sync.pump();await settle();}
 assert.equal(sync.requested,false);assert.equal(video.paused,true);assert.equal(video.plays,starts);
 assert.ok([...voice.cache.values()].reduce((sum,item)=>sum+item.size,0)<=voice.maximumBytes);
});
