'use strict';
const strings={
 de:{prepare:'Übersetzung und Stimme vorbereiten…',stop:'Vorbereitung stoppen',source:'Untertitel oder deutsche Tonspur',start:'Vorbereiten und ansehen',prepareHelp:'Ohne Untertitel wird Deutsch lokal erkannt. Die Übersetzung nutzt das Konto auf dem Mac. Fertige Teile bleiben in dessen Bibliothek.',preparing:'Erkennung, Übersetzung und Stimme werden auf dem Mac vorbereitet.',saved:'Die Stimme ist vollständig in der Bibliothek auf dem Mac gespeichert.',stopped:'Vorbereitung angehalten. Fertige Teile bleiben gespeichert.',failed:'Vorbereitung fehlgeschlagen. Im Mac-Player prüfen und erneut starten.',busy:'Der Mac-Player bereitet bereits ein anderes Video vor.',deviceBuffer:'Auf diesem Gerät geladen: ',reserve:' / 200 s',buffer:'Auf dem Mac vorbereitet: ',seconds:' s',connect:'Verbinden',code:'Zugangscode',codeHelp:'Öffne auf dem Mac „Im Heimnetz ansehen“ und kopiere den Code oder öffne den angezeigten Link.',library:'Freigegebene und Telegram-Videos',play:'Wiedergabe / Pause',sound:'Ton',videoSound:'Deutscher Originalton',russian:'Kseniya · Russisch',subtitles:'Untertitel',off:'Aus',volume:'Lautstärke',scope:'Lokale und Telegram-Videos werden automatisch direkt oder als kompatibler Stream wiedergegeben.',empty:'Keine Videos aus den gewählten Quellen.',local:'Lokale Videos',telegram:'Telegram-Videos',login:'Verbindung fehlgeschlagen. Adresse und Code im Mac-Player prüfen.',buffering:'Video und Ton werden gemeinsam gepuffert…',waitingMac:'Die Stimme wird auf dem Mac vorbereitet…',waitingDevice:'Die Stimme wird auf diesem Gerät bis zum 200-Sekunden-Vorrat geladen…',loading:'Video wird geladen…',videoPreparing:'Kompatibler Videostream wird vorbereitet…',videoInvalid:'Die Videodatei ist beschädigt oder enthält keine unterstützte Bildspur.',videoToolsMissing:'Die Medienwerkzeuge fehlen im Programmpaket auf dem Mac.',videoNoSpace:'Auf dem Mac ist nicht genug freier Speicher für den Videostream.',videoFFmpegFailed:'Der kompatible Videostream konnte auf dem Mac nicht vorbereitet werden.',videoUnsupported:'Dieser Browser kann den kompatiblen Videostream nicht wiedergeben.',error:'Das Video konnte nicht wiedergegeben werden.',audio:'Für die russische Tonspur auf Wiedergabe tippen.',network:'Keine Verbindung zum Mac. Server und WLAN prüfen.'},
 ru:{prepare:'Подготовить перевод и озвучку…',stop:'Остановить подготовку',source:'Субтитры или немецкая звуковая дорожка',start:'Подготовить и смотреть',prepareHelp:'Без субтитров немецкая речь распознаётся локально. Перевод использует аккаунт на Mac. Готовые части сохраняются в его библиотеке.',preparing:'Mac распознаёт, переводит и готовит озвучку.',saved:'Озвучка целиком сохранена в библиотеке на Mac.',stopped:'Подготовка остановлена. Готовые части сохранены.',failed:'Ошибка подготовки. Проверь плеер на Mac и запусти повторно.',busy:'Плеер на Mac уже обрабатывает другое видео.',deviceBuffer:'На устройстве загружено: ',reserve:' / 200 с',buffer:'На Mac готово: ',seconds:' с',connect:'Подключиться',code:'Код доступа',codeHelp:'Открой на Mac «Смотреть по сети» и скопируй код либо перейди по показанной ссылке.',library:'Локальные видео и Telegram',play:'Воспроизвести / пауза',sound:'Звук',videoSound:'Немецкий оригинал',russian:'Kseniya · русский',subtitles:'Субтитры',off:'Выключены',volume:'Громкость',scope:'Локальные и Telegram-видео автоматически открываются напрямую или совместимым потоком.',empty:'Нет видео из выбранных источников.',local:'Локальные видео',telegram:'Telegram-видео',login:'Не удалось подключиться. Проверь адрес и код в плеере на Mac.',buffering:'Подготавливаем общий буфер видео и звука…',waitingMac:'Ожидаем подготовку озвучки на Mac…',waitingDevice:'Загружаем озвучку на устройство до запаса 200 секунд…',loading:'Видео загружается…',videoPreparing:'Подготавливаем совместимый видеопоток…',videoInvalid:'Видеофайл повреждён или не содержит поддерживаемой видеодорожки.',videoToolsMissing:'В комплекте приложения на Mac нет медиасредств.',videoNoSpace:'На Mac недостаточно свободного места для видеопотока.',videoFFmpegFailed:'Mac не смог подготовить совместимый видеопоток.',videoUnsupported:'Этот браузер не может воспроизвести совместимый видеопоток.',error:'Не удалось воспроизвести видео.',audio:'Нажми «Воспроизвести» для русской дорожки.',network:'Нет связи с Mac. Проверь сервер и подключение к сети.'},
 en:{prepare:'Prepare translation and voice…',stop:'Stop preparation',source:'Subtitles or German audio track',start:'Prepare and watch',prepareHelp:'Without subtitles, German speech is recognized locally. Translation uses the account on the Mac. Completed parts stay in its library.',preparing:'The Mac is recognizing, translating and preparing speech.',saved:'All speech is saved in the library on the Mac.',stopped:'Preparation stopped. Completed parts are saved.',failed:'Preparation failed. Check the Mac player and start again.',busy:'The Mac player is already preparing another video.',deviceBuffer:'Loaded on this device: ',reserve:' / 200 s',buffer:'Prepared on the Mac: ',seconds:' s',connect:'Connect',code:'Access code',codeHelp:'Open “Watch over LAN” on the Mac and copy the code, or open the displayed link.',library:'Shared and Telegram videos',play:'Play / pause',sound:'Audio',videoSound:'German original',russian:'Kseniya · Russian',subtitles:'Subtitles',off:'Off',volume:'Volume',scope:'Local and Telegram videos automatically use direct playback or a compatible stream.',empty:'No videos from the selected sources.',local:'Local videos',telegram:'Telegram videos',login:'Could not connect. Check the address and code in the Mac player.',buffering:'Buffering video and audio together…',waitingMac:'Waiting for speech preparation on the Mac…',waitingDevice:'Loading speech on this device to a 200-second reserve…',loading:'Loading video…',videoPreparing:'Preparing a compatible video stream…',videoInvalid:'The video is damaged or has no supported video track.',videoToolsMissing:'The media tools are missing from the app bundle on the Mac.',videoNoSpace:'The Mac does not have enough free space for the video stream.',videoFFmpegFailed:'The Mac could not prepare the compatible video stream.',videoUnsupported:'This browser cannot play the compatible video stream.',error:'The video could not be played.',audio:'Tap Play to start the Russian audio track.',network:'No connection to the Mac. Check the server and network.'}
};
const el=id=>document.getElementById(id),video=el('video'),voice=el('voice');
let remote = false, job = null, polling = false, lastReport = 0, selectionGeneration = 0;
const liveTracks = {};
let lang=localStorage.getItem('lektien.language')||'de',lectures=[],selected=null,pendingSeek=0,lastSave=0;
if(!strings[lang])lang='de';
function tr(key){return strings[lang][key]||key;}
function preparedAhead(){
 let end=video.currentTime;
 for(const part of job?.clips||[]){if(part.end<=end)continue;if(part.start>end+.05)break;end=part.end;}
 return Math.max(0,end-video.currentTime);
}
function message(key){
 if(key==='buffering'&&remote&&el('sound').value==='ru'){
  const required=Math.min(200,Math.max(0,(job?.duration??Infinity)-video.currentTime));
  key=preparedAhead()+.05<required?'waitingMac':'waitingDevice';
 }
 const text=key?tr(key):'';el('status').textContent=text;el('playbackStatus').textContent=text;
}
function localize(){document.documentElement.lang=lang;el('language').value=lang;document.querySelectorAll('[data-i18n]').forEach(node=>node.textContent=tr(node.dataset.i18n));}
el('language').onchange=()=>{lang=el('language').value;localStorage.setItem('lektien.language',lang);localize();};localize();
async function catalog(){const [local,telegram]=await Promise.all([fetch('/api/library'),fetch('/api/telegram')]);if(!local.ok||!telegram.ok)throw Error('auth');lectures=[...(await local.json()).map(item=>({...item,source:'local'})),...await telegram.json()];
 const groups={local:document.createElement('optgroup'),telegram:document.createElement('optgroup')};groups.local.label=tr('local');groups.telegram.label=tr('telegram');lectures.forEach((item,index)=>groups[item.source].appendChild(new Option(item.name,String(index))));el('library').replaceChildren(groups.local,groups.telegram);el('login').hidden=true;el('viewer').hidden=false;
 if(!lectures.length){message('empty');el('play').disabled=true;return;}el('play').disabled=false;await choose(Math.max(0,lectures.findIndex(item=>item.id===localStorage.getItem('lektien.selection'))));}
async function login(code){const response=await fetch('/auth',{method:'POST',body:code.trim()});if(!response.ok)throw Error('auth');await catalog();el('code').value='';}
el('login').onsubmit=event=>{event.preventDefault();login(el('code').value).catch(()=>message('login'));};
const preparedVoice = new PreparedSpeechAudio();
const playback = new SynchronizedPlayback(video, voice, message);
const adaptiveVideo = new AdaptiveVideo(video,message);
function mediaPath(suffix){return (selected.source==='telegram'?'/telegram/':'/media/')+selected.id+'/'+suffix;}
async function choose(index){playback.pause();playback.setVoice(voice);preparedVoice.reset();selectionGeneration++;const token=selectionGeneration;remote=false;job=null;el('sources').hidden=true;el('stop').hidden=true;el('prepared').hidden=true;el('preparationStatus').textContent='';el('deviceStatus').textContent='';selected=lectures[index];if(!selected)return;el('library').value=String(index);localStorage.setItem('lektien.selection',selected.id);el('prepare').hidden=selected.audio;
 message('loading');el('title').textContent=selected.name;document.title=selected.name+' · Lektien Player';
 {
  try{const response=await fetch('/api/telegram/select',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:selected.source==='telegram'?selected.id:null})});if(!response.ok)throw Error('network');}
  catch{if(token===selectionGeneration)message('network');return;}
  if(token!==selectionGeneration)return;
 }
 video.querySelectorAll('track').forEach(track=>track.remove());
 for(const language of selected.subtitles){const track=document.createElement('track');track.kind='subtitles';track.srclang=language;track.label=language==='ru'?'Русский':'Deutsch';track.src=mediaPath(language+'.vtt');video.appendChild(track);}
 const saved=Number(localStorage.getItem('lektien.position.'+selected.id));pendingSeek=Number.isFinite(saved)&&saved>0?saved:0;
 try{const response=await fetch('/api/video/'+selected.id);if(!response.ok)throw Error('network');const plan=await response.json();if(token!==selectionGeneration)return;adaptiveVideo.load(plan,pendingSeek);if(plan.mode==='failed')throw Error(plan.error||'videoInvalid');}catch(error){if(token===selectionGeneration)message(error.message);return;}
 if(selected.audio)voice.src=mediaPath('audio');else{voice.removeAttribute('src');voice.load();}
 el('sound').options[1].disabled=!selected.audio;el('sound').value=selected.audio?'ru':'video';
 for(const option of el('subtitles').options)option.disabled=option.value!=='off'&&!selected.subtitles.includes(option.value);
 el('subtitles').value=selected.subtitles.includes('ru')?'ru':'off';
 applySound();setSubtitles();}
function setSubtitles(){for(const track of video.textTracks){const live=Object.values(liveTracks).includes(track);track.mode=track.language===el('subtitles').value && live===remote?'showing':'disabled';}}
video.textTracks.addEventListener('addtrack',setSubtitles);el('subtitles').onchange=setSubtitles;
el('library').onchange=()=>{choose(Number(el('library').value));};
function applySound(){video.volume=Number(el('volume').value);voice.volume=Number(el('volume').value);preparedVoice.volume=Number(el('volume').value);if(remote)updateClip();else playback.configure(el('sound').value==='ru');}
el('sound').onchange=applySound;el('volume').oninput=applySound;
el('play').onclick=()=>{if(selected)playback.toggle();};
video.onloadedmetadata=()=>{if(pendingSeek&&Number.isFinite(video.duration))video.currentTime=Math.min(pendingSeek,Math.max(0,video.duration-1));pendingSeek=0;message('');setSubtitles();};
setInterval(()=>{if(remote)updateClip();playback.pump();},100);
video.ontimeupdate=()=>{if(selected&&Date.now()-lastSave>1000){localStorage.setItem('lektien.position.'+selected.id,String(video.currentTime));lastSave=Date.now();}};
video.addEventListener('seeking',()=>{if(selected)command('/api/video/position').catch(()=>message('network'));});
video.onended=()=>playback.pause();video.onerror=()=>message('error');voice.onerror=()=>message('error');
window.addEventListener('offline',()=>{playback.pause();message('network');});
const fragment=location.hash.slice(1);history.replaceState(null,'',location.pathname);
if(fragment)login(fragment).catch(()=>message('login'));else catalog().catch(()=>{});

async function command(path, extra = {}) {
 const response = await fetch(path, {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:selected.id,position:video.currentTime||0,playing:playback.requested,...extra})});
 if(!response.ok)throw new Error(response.status===409?'busy':'failed');
}
el('prepare').onclick=async()=>{
 const token=selectionGeneration, id=selected?.id;if(!id)return;
 el('prepare').disabled=true;
 try {
  const response=await fetch('/api/sources/'+id);if(!response.ok)throw Error('failed');const data=await response.json();
  if(token!==selectionGeneration)return;
  el('source').replaceChildren(...data.items.map(item=>new Option(item.title,String(item.id))));
  if(data.selected!==null)el('source').value=String(data.selected);
  el('sources').hidden=false;el('start').disabled=!data.items.length;
 }catch(error){if(token===selectionGeneration)message(error.message);}
 finally{el('prepare').disabled=false;}
};
el('start').onclick=async()=>{
 const token=selectionGeneration;el('start').disabled=true;
 try {
  await preparedVoice.unlock();
  await command('/api/prepare',{source:Number(el('source').value),playing:true});
  if(token!==selectionGeneration)return;
  playback.pause();remote=true;job=null;preparedVoice.reset();playback.setVoice(preparedVoice);voice.removeAttribute('src');voice.load();
  el('sound').options[1].disabled=false;el('sound').value='ru';
  for(const option of el('subtitles').options)option.disabled=false;
  el('subtitles').value='ru';el('sources').hidden=true;el('stop').hidden=false;el('prepared').hidden=false;
  playback.configure(true,0,false);playback.play();await pollJob();
 }catch(error){if(token===selectionGeneration)message(error.message);}
 finally{el('start').disabled=false;}
};
el('stop').onclick=async()=>{try{await command('/api/stop');await pollJob();}catch(error){message(error.message);}};
function updateClip(){
 preparedVoice.update(job,video.currentTime);
 el('deviceStatus').textContent=tr('deviceBuffer')+Math.floor(preparedVoice.bufferAhead(video.currentTime))+tr('reserve');
 if(playback.requested&&playback.buffering)message('buffering');
 if(el('sound').value!=='ru'){playback.configure(false);return;}
 playback.setVoice(preparedVoice);
 const available=preparedVoice.bufferAhead(video.currentTime)>0;
 const silentTail=job?.state==='ready' && job.speechEnd>0 && video.currentTime>=job.speechEnd;
 playback.configure(!silentTail,0,available||silentTail);video.muted=true;
}
function updateLiveSubtitles(){
 for(const language of ['ru','de']){
  const track=liveTracks[language]||(liveTracks[language]=video.addTextTrack('subtitles',language==='ru'?'Русский':'Deutsch',language));
  const cues=job?.[language==='ru'?'russian':'german']||[];
  const key=(start,end,text)=>JSON.stringify([start,end,text]);
  const desired=new Map(cues.map(c=>[key(c.start,c.end,c.text),c]));
  for(const cue of Array.from(track.cues||[])){
   const id=key(cue.startTime,cue.endTime,cue.text);
   if(desired.has(id))desired.delete(id);else track.removeCue(cue);
  }
  for(const cue of desired.values())track.addCue(new VTTCue(cue.start,cue.end,cue.text));
 }
 setSubtitles();
}
async function pollJob(){
 if(polling||!selected)return;polling=true;
 const token=selectionGeneration,id=selected.id;
 try{
  const response=await fetch('/api/preparation/'+id);if(!response.ok)throw Error('network');const data=await response.json();
  if(token!==selectionGeneration)return;
  if(data.state==='idle')return;
  // Reopening the page attaches to the existing preparation without starting another job.
  if(!remote){remote=true;el('sound').options[1].disabled=false;el('sound').value='ru';for(const option of el('subtitles').options)option.disabled=false;el('subtitles').value='ru';}
  job=data;el('stop').hidden=!['preparing','ready'].includes(job.state);el('prepared').hidden=false;
  const ranges=(job.clips||[]);
  el('prepared').value=job.duration?ranges.reduce((sum,p)=>sum+p.end-p.start,0)/job.duration:0;
  el('preparationStatus').textContent=tr(job.state==='ready'?'saved':job.state)+' '+tr('buffer')+Math.floor(preparedAhead())+tr('seconds');
  updateLiveSubtitles();updateClip();
  if(['failed','busy'].includes(job.state))playback.pause();
  if(Date.now()-lastReport>1500){lastReport=Date.now();await command('/api/position');}
 }catch(error){if(token===selectionGeneration){playback.hold();message('network');}}
 finally{polling=false;}
}
setInterval(pollJob,1000);
