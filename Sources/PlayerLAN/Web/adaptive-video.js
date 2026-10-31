'use strict';
class AdaptiveVideo {
 constructor(video,onState){this.video=video;this.onState=onState;this.generation=0;this.url=null;this.source=null;this.buffer=null;this.plan=null;this.next=0;this.loading=false;this.initialized=false;this.failed=false;
  video.addEventListener('seeking',()=>this.seek());video.addEventListener('timeupdate',()=>this.pump());}
 close(){this.generation++;this.loading=false;this.plan=null;this.buffer=null;this.source=null;if(this.url)URL.revokeObjectURL(this.url);this.url=null;this.initialized=false;this.failed=false;}
 load(plan,position=0){this.close();this.plan=plan;
  if(plan.mode==='direct'){this.video.src=plan.url;this.video.load();return;}
  if(plan.mode!=='adapted')throw Error(plan.error||'videoInvalid');
  this.onState('videoPreparing');
  if(this.video.canPlayType('application/vnd.apple.mpegurl')){this.video.src=plan.url;this.video.load();return;}
  if(!window.MediaSource||!MediaSource.isTypeSupported(plan.mimeType))throw Error('videoUnsupported');
  const token=this.generation,source=new MediaSource();this.source=source;this.url=URL.createObjectURL(source);this.video.src=this.url;
  source.addEventListener('sourceopen',()=>{if(token!==this.generation)return;try{this.buffer=source.addSourceBuffer(plan.mimeType);this.buffer.mode='segments';source.duration=plan.duration;this.next=Math.floor(position/plan.segmentDuration);this.pump(true);}catch(_){this.onState('videoUnsupported');}},{once:true});this.video.load();}
 async append(bytes,offset){if(!this.buffer)throw Error('videoUnsupported');if(offset!==null)this.buffer.timestampOffset=offset;
  await new Promise((resolve,reject)=>{const done=()=>{cleanup();resolve();},bad=()=>{cleanup();reject(Error('videoInvalid'));},cleanup=()=>{this.buffer?.removeEventListener('updateend',done);this.buffer?.removeEventListener('error',bad);};this.buffer.addEventListener('updateend',done,{once:true});this.buffer.addEventListener('error',bad,{once:true});this.buffer.appendBuffer(bytes);});}
 async pump(force=false){if(!this.plan||this.plan.mode!=='adapted'||!this.buffer||this.buffer.updating||this.loading||this.failed)return;
  const ahead=this.bufferedAhead();if(!force&&ahead>36)return;const count=Math.ceil(this.plan.duration/this.plan.segmentDuration);if(this.next>=count){if(this.source?.readyState==='open'&&!this.buffer.updating)try{this.source.endOfStream();}catch(_){}return;}
  const token=this.generation,index=this.next;this.loading=true;
  try{const init=await this.bytes(index+'.init.mp4');if(token!==this.generation)return;await this.append(init,null);
   const media=await this.bytes(index+'.media.m4s');if(token!==this.generation)return;await this.append(media,index*this.plan.segmentDuration);this.next=index+1;this.onState('');
  }catch(error){if(token===this.generation){this.failed=true;this.onState(error.message||'videoFFmpegFailed');}}finally{if(token===this.generation){this.loading=false;if(!this.failed)queueMicrotask(()=>this.pump());}}}
 async bytes(name){const base=this.plan.url.slice(0,this.plan.url.lastIndexOf('/')+1),response=await fetch(base+name);if(!response.ok){let key='videoFFmpegFailed';try{key=(await response.json()).error||key;}catch(_){}throw Error(key);}return await response.arrayBuffer();}
 bufferedAhead(){const time=this.video.currentTime;for(let i=0;i<this.video.buffered.length;i++)if(this.video.buffered.start(i)<=time+.05&&this.video.buffered.end(i)>=time)return this.video.buffered.end(i)-time;return 0;}
 seek(){if(!this.plan||this.plan.mode!=='adapted'||!this.buffer)return;const index=Math.floor(this.video.currentTime/this.plan.segmentDuration);if(index===this.next-1&&this.bufferedAhead()>0)return;this.generation++;this.next=index;this.loading=false;
  if(this.buffer.updating)try{this.buffer.abort();}catch(_){}const restart=()=>{if(!this.buffer)return;try{if(this.buffer.buffered.length)this.buffer.remove(0,this.plan.duration);else this.pump(true);}catch(_){this.pump(true);}};
  this.failed=false;if(this.buffer.updating)this.buffer.addEventListener('updateend',restart,{once:true});else restart();this.onState('videoPreparing');}
}
if(typeof module!=='undefined')module.exports={AdaptiveVideo};
