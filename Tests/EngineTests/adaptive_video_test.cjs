'use strict';
const assert = require('node:assert/strict');
const {test} = require('node:test');
const {AdaptiveVideo} = require('../../Sources/PlayerLAN/Web/adaptive-video.js');

test('independent fMP4 parts each append their own initialization before media', async () => {
 const old = {window:global.window,MediaSource:global.MediaSource,fetch:global.fetch,
  create:URL.createObjectURL,revoke:URL.revokeObjectURL};
 const requested=[],appended=[];
 let source;
 class Buffer extends EventTarget {
  updating=false;
  buffered={length:0};
  appendBuffer(bytes){appended.push(new TextDecoder().decode(bytes));this.updating=true;
   queueMicrotask(()=>{this.updating=false;this.dispatchEvent(new Event('updateend'));});}
 }
 class Source extends EventTarget {
  static isTypeSupported(){return true;}
  constructor(){super();source=this;this.readyState='open';}
  addSourceBuffer(){return new Buffer();}
  endOfStream(){this.readyState='ended';}
 }
 try {
  global.window={MediaSource:Source};global.MediaSource=Source;
  URL.createObjectURL=()=> 'blob:fixture';URL.revokeObjectURL=()=>{};
  global.fetch=async url=>{const name=url.split('/').pop();requested.push(name);
   return {ok:true,arrayBuffer:async()=>new TextEncoder().encode(name).buffer};};
  const video=new EventTarget();video.currentTime=0;video.buffered={length:0};
  video.canPlayType=()=>'';video.load=()=>queueMicrotask(()=>source.dispatchEvent(new Event('sourceopen')));
  const adapter=new AdaptiveVideo(video,()=>{});
  adapter.load({mode:'adapted',url:'/adapted/id/index.m3u8',duration:24,
   segmentDuration:12,mimeType:'video/mp4; codecs="avc1.640028"'});
  for(let i=0;i<20&&appended.length<4;i++)await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(requested,['0.init.mp4','0.media.m4s','1.init.mp4','1.media.m4s']);
  assert.deepEqual(appended,requested);
  assert.equal(source.readyState,'ended');
  adapter.close();
 } finally {
  global.window=old.window;global.MediaSource=old.MediaSource;global.fetch=old.fetch;
  URL.createObjectURL=old.create;URL.revokeObjectURL=old.revoke;
 }
});
