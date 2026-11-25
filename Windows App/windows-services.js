'use strict';

window.windowsMedia = (() => {
  const player = window.windowsPlayback;
  let request = 0, revision = 0;
  function post(channel, body) { window.chrome.webview.postMessage({channel,body}); }
  function send(channel,p) {
    if (channel === 'equalizer') { player.eq(p); return; }
    if (channel === 'visualizer') { player.visualize(p); return; }
    if (channel === 'player' && !['load','playLibrary'].includes(p.action)) {
      player.action(p);
      if (p.action === 'close') { ++request; post('player',{action:'release'}); }
      return;
    }
    if (channel === 'plex' && ['disconnect','selectServer','selectLibrary','connect'].includes(p.action) && player.origin === 'plex') {
      player.reset(); ++request; post('player',{action:'release'});
    }
    if (channel === 'player' || (channel === 'plex' && ['play','playMatch'].includes(p.action))) {
      player.prepareAudio();
      revision = player.reset(p.venue || 'Opening recording…',channel === 'plex' ? 'plex' : 'archive');
      p = {...p,request:++request};
    }
    post(channel,p);
  }
  window.windowsMediaReply = answer => {
    if (!answer || answer.request !== request || revision !== player.revision) return;
    if (answer.error) player.fail(answer.error);
    else player.queue(answer,answer.startIndex,revision);
  };
  return {send};
})();
window.windowsMediaNotice = message => {
  window.showWindowsNotice?.(message);
};
