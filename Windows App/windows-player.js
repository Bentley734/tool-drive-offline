'use strict';

// The stream proxy returns same-origin, seekable URLs for every source, including
// Plex. This keeps credentials out of the player and permits real audio analysis.
window.windowsPlayback = (() => {
  const audio = new Audio();
  audio.preload = 'metadata';
  audio.crossOrigin = 'anonymous';
  let tracks = [], index = 0, collection = '', origin = '', state = 'closed', error = '';
  let context, filters, analyser, spectrum, meter = 0, attempt = 0, expectedURL = '';
  let wantsPlay = false, revision = 0;
  let retryTimer = 0, retries = 0, resumeAt = 0, healthySince = 0;
  const magik = [[315,-0.75],[400,-2.6],[500,-4.75],[630,-7.65],[800,-4.75],[1000,-2.6],[1250,-0.75],[10000,0.15]];
  function publish() {
    const track = tracks[index] || {};
    window.macPlayerState?.({
      visible: state !== 'closed', status: state, message: error, error,
      tracks: tracks.map(({title, durationSeconds}) => ({title, durationSeconds})),
      trackIndex: index, context: collection, title: track.title || collection,
      duration: Number.isFinite(audio.duration) && audio.currentSrc === expectedURL ? audio.duration : track.durationSeconds || 0,
      elapsed: audio.currentSrc === expectedURL ? audio.currentTime : 0,
      canPrevious: index > 0, canNext: index + 1 < tracks.length
    });
    if ('mediaSession' in navigator) {
      navigator.mediaSession.playbackState = state === 'playing' ? 'playing' : state === 'paused' ? 'paused' : 'none';
    }
  }
  function prepareAudio() {
    if (!context) {
      try {
        context = new AudioContext();
        filters = [['lowshelf',200,1], ['peaking',1000,1], ['highshelf',4000,1],
          ...magik.map(([hz]) => ['peaking',hz,4.3])].map(([type,hz,q]) => {
          const f = context.createBiquadFilter();
          f.type = type; f.frequency.value = hz; f.Q.value = q; return f;
        });
        analyser = context.createAnalyser(); analyser.fftSize = 2048;
        spectrum = new Uint8Array(analyser.frequencyBinCount);
        const limiter = context.createDynamicsCompressor();
        limiter.threshold.value = -1; limiter.knee.value = 0; limiter.ratio.value = 20;
        limiter.attack.value = .001; limiter.release.value = .1;
        const source = context.createMediaElementSource(audio);
        let last = source;
        for (const node of [...filters, limiter, analyser, context.destination]) { last.connect(node); last = node; }
      } catch {
        window.macEqualizerState?.({available:false}); return;
      }
    }
    if (context.state === 'suspended') context.resume().catch(() => {});
    window.macEqualizerState?.({available:Boolean(analyser)});
  }
  function eq(values = {}) {
    if (!filters) return;
    const gain = key => Math.max(-10,Math.min(10,Number(values[key]) || 0));
    const gains = [gain('bass'), gain('mid'), gain('treble'), ...magik.map(([,db]) => values.magik ? db : 0)];
    filters.forEach((filter,i) => filter.gain.setTargetAtTime(gains[i], context.currentTime,.012));
  }
  function measure() {
    if (!analyser || audio.paused || document.hidden) return;
    analyser.getByteFrequencyData(spectrum);
    const ranges = [[35,240],[240,2400],[2400,12000]];
    const scale = analyser.fftSize / context.sampleRate;
    const levels = ranges.map(([lo,hi]) => {
      let total = 0; const begin = Math.max(1,Math.ceil(lo*scale)), end = Math.min(spectrum.length,Math.ceil(hi*scale));
      for (let i=begin; i<end; i++) total += (spectrum[i]/255)**2;
      return Math.sqrt(total / Math.max(1,end-begin));
    });
    window.macVisualizerLevels?.(levels);
  }
  function windowState() { window.macVisualizerWindowState?.({visible:!document.hidden,fullScreen:Boolean(document.fullscreenElement)}); }
  function visualize(p) {
    if (p.action === 'listen' && !meter) meter = setInterval(measure, 40);
    if (p.action === 'idle') { clearInterval(meter); meter = 0; }
    if (p.action === 'window') windowState();
    if (p.action === 'fullscreen') {
      const action = document.fullscreenElement ? document.exitFullscreen() : document.documentElement.requestFullscreen();
      action.catch(windowState);
    }
  }
  document.addEventListener('fullscreenchange',windowState);
  document.addEventListener('visibilitychange',windowState);
  function cancelRetry() {
    clearTimeout(retryTimer);
    retryTimer = retries = resumeAt = healthySince = 0;
  }
  function retryOrFail() {
    if (!wantsPlay || !tracks[index] || retryTimer) return;
    if (retries >= 2 || audio.error?.code === MediaError.MEDIA_ERR_DECODE) {
      fail('Audio unavailable or unsupported on this device.');
      return;
    }
    retries++;
    healthySince = 0;
    if (audio.currentTime > 0) resumeAt = audio.currentTime;
    state = 'loading';
    error = 'Retrying playback…';
    publish();
    retryTimer = setTimeout(() => {
      retryTimer = 0;
      if (!wantsPlay || !tracks[index]) return;
      audio.load();
      play();
    }, retries * 1000);
  }
  function reset(label, type) {
    cancelRetry();
    revision++; wantsPlay = false; attempt++; expectedURL = ''; audio.pause();
    audio.removeAttribute('src'); audio.load();
    tracks = []; index = 0; collection = label || ''; origin = type || ''; error = '';
    state = type ? 'loading' : 'closed';
    eq(); window.macEqualizerState?.({reset:true}); publish();
    if ('mediaSession' in navigator) navigator.mediaSession.metadata = null;
    return revision;
  }
  function fail(message) {
    state = 'error'; error = message || 'This audio could not be played.'; wantsPlay = false; publish();
  }
  function play() {
    if (!tracks[index]) return;
    prepareAudio();
    const serial = ++attempt;
    wantsPlay = true;
    audio.play().catch(e => {
      if (serial !== attempt || e.name === 'AbortError') return;
      if (e.name === 'NotAllowedError') { wantsPlay = false; state = 'paused'; error = 'Press Play to start audio.'; publish(); }
      else retryOrFail();
    });
  }
  function select(i, autoplay) {
    if (!Number.isInteger(i) || !tracks[i]) return;
    cancelRetry();
    index=i; attempt++; wantsPlay=autoplay; error=''; state=autoplay?'loading':'paused';
    const track = tracks[i];
    expectedURL = new URL(track.url, location.href).href;
    const handle = new URL(expectedURL).pathname.slice(1);
    if (/^[a-f0-9]{32}$/.test(handle)) window.chrome?.webview?.postMessage({channel:'player',body:{action:'beginTrack',handle}});
    audio.src = expectedURL;
    if ('mediaSession' in navigator && 'MediaMetadata' in window) {
      navigator.mediaSession.metadata = new MediaMetadata({title:track.title,artist:'TOOL',album:collection});
    }
    if (autoplay) play();
    publish();
  }
  function queue(payload, start=0, expectedRevision) {
    if (expectedRevision !== undefined && expectedRevision !== revision) return;
    if (!Array.isArray(payload?.tracks) || !payload.tracks.length) { fail('No playable tracks were found.'); return; }
    tracks = payload.tracks; collection = payload.context || collection; origin = payload.origin || origin;
    select(Math.min(Math.max(0,Number(start)||0),tracks.length-1),true);
  }
  function pause() { cancelRetry(); wantsPlay = false; attempt++; audio.pause(); if (tracks.length) {state='paused'; publish();} }
  function seek(time) {
    if (tracks.length && Number.isFinite(time) && Number.isFinite(audio.duration)) {
      const handle = new URL(expectedURL).pathname.slice(1);
      if (/^[a-f0-9]{32}$/.test(handle)) window.chrome?.webview?.postMessage({channel:'player',body:{action:'seekTrack',handle}});
      audio.currentTime = Math.max(0, Math.min(audio.duration,time));
    }
  }
  function action(p) {
    switch(p.action) {
      case 'toggle': if (audio.paused) play(); else pause(); break;
      case 'previous': select(index-1,true); break;
      case 'next': select(index+1,true); break;
      case 'seek': seek(Number(p.seconds)); break;
      case 'playTrack': select(Number(p.index),true); break;
      case 'close': reset(); break;
    }
  }
  function current() { return tracks.length && audio.currentSrc === expectedURL; }
  for (const event of ['timeupdate','durationchange','loadedmetadata']) audio.addEventListener(event,() => {
    if (!current()) return;
    if (event === 'loadedmetadata' && resumeAt > 0) { const position = resumeAt; resumeAt = 0; seek(position); }
    if (healthySince && performance.now() - healthySince >= 5000) { healthySince = 0; retries = 0; }
    publish();
  });
  audio.addEventListener('playing',() => { if (current()) {state='playing'; error=''; healthySince=performance.now(); publish();} });
  audio.addEventListener('pause',() => { if (current() && audio.paused && !audio.ended && !wantsPlay) {state='paused'; publish();} });
  audio.addEventListener('waiting',() => { if (current() && wantsPlay) {state='loading'; publish();} });
  audio.addEventListener('ended',() => { if (current()) { if (index+1<tracks.length) select(index+1,true); else pause(); } });
  audio.addEventListener('error',() => { if (current() && audio.error) retryOrFail(); });
  if ('mediaSession' in navigator) {
    for (const [key,handler] of Object.entries({play,pause,previoustrack:()=>select(index-1,true),nexttrack:()=>select(index+1,true),
      seekto:p=>seek(p.seekTime),seekbackward:p=>seek(audio.currentTime-(p.seekOffset||10)),seekforward:p=>seek(audio.currentTime+(p.seekOffset||10)),stop:()=>reset()})) {
      try { navigator.mediaSession.setActionHandler(key,handler); } catch { /* Optional media command. */ }
    }
  }
  function release() {
    cancelRetry(); clearInterval(meter); meter=0; wantsPlay=false; attempt++; audio.pause();
    audio.removeAttribute('src'); audio.load();
    if (context && context.state !== 'closed') context.close().catch(() => {});
  }
  window.addEventListener('pagehide', release, {once:true});
  window.addEventListener('beforeunload', release, {once:true});
  return {prepareAudio,action,visualize,eq,queue,reset,fail, get revision(){return revision;}, get origin(){return origin;}};
})();
