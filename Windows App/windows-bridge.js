// Match the shared desktop catalog's synchronous preference contract before its
// embedded catalog script runs. Native data stays outside browser storage.
(() => {
  'use strict';
  const initial = window.toolWindowsInitial || {};
  const preferenceKey = 'tool-drive-appearance-v2';
  let preferences = {};
  try {
    const stored = JSON.parse(localStorage.getItem(preferenceKey));
    if (stored && typeof stored === 'object' && !Array.isArray(stored)) preferences = stored;
  } catch {}
  function remember(values) {
    Object.assign(preferences, values);
    try { localStorage.setItem(preferenceKey, JSON.stringify(preferences)); }
    catch { window.showWindowsNotice?.('Appearance changes will last for this session only.'); }
  }
  function send(channel, body) {
    if (!window.chrome?.webview) throw new Error('The Windows host is unavailable.');
    window.chrome.webview.postMessage({channel, body});
  }
  window.toolWindows = {send, preferences, remember};

  const standard = ['front-row', 'night-shift', 'graphite', 'laser-grid'];
  const glass = 'liquid-glass';
  const enabled = preferences.glassEnabled !== false;
  const lastStandard = standard.includes(preferences.lastStandard) ? preferences.lastStandard : standard[0];
  const theme = standard.includes(preferences.theme) ? preferences.theme :
    (enabled ? glass : lastStandard);
  const photos = [...document.getElementById('glass-wallpaper-picker').options].map(x => x.value).filter(id => id !== 'shuffle');
  let photo = photos.includes(preferences.photo) ? preferences.photo : photos[0];
  let shuffle = preferences.shuffle === true;
  let drawn = false;
  let saved = JSON.stringify(Array.isArray(initial.saved) ? initial.saved.map(String) : []);
  function draw() {
    if (!shuffle || drawn) return;
    const choices = photos.filter(id => id !== photo);
    if (choices.length) photo = choices[Math.floor(Math.random() * choices.length)];
    drawn = true;
    remember({photo});
  }
  if (theme === glass) draw();
  function syncTheme() {
    window.macLiquidGlassEnabled?.(bridge.liquidGlassEnabled, bridge.theme, photo, shuffle ? 'shuffle' : photo);
  }
  const bridge = {
    theme, lastStandardTheme: lastStandard, liquidGlassAvailable: true, liquidGlassEnabled: enabled, nativeGlassToolbar: false,
    picture: preferences.picture || 'blue-silhouette', logo: preferences.logo || 'classic',
    wallpaper: photo, wallpaperChoice: shuffle ? 'shuffle' : photo,
    tracklistPosition: preferences.tracklistPosition || 'bottom', visualizerPreset: preferences.visualizerPreset || 'ember',
    catalog: initial.catalog || null,
    load: () => saved,
    save(value) {
      const ids = JSON.parse(value);
      if (!Array.isArray(ids)) return;
      saved = value;
      send('saved', ids);
    },
    copy: value => send('clipboard', value),
    setTheme(id) {
      if (!standard.includes(id) && !(bridge.liquidGlassEnabled && id === glass)) return;
      if (id !== glass) bridge.lastStandardTheme = id;
      else draw();
      bridge.theme = id;
      remember({theme: id, lastStandard: bridge.lastStandardTheme});
      syncTheme();
    },
    setLiquidGlass(value) {
      bridge.liquidGlassEnabled = value === true;
      remember({glassEnabled: bridge.liquidGlassEnabled});
      bridge.setTheme(!bridge.liquidGlassEnabled && bridge.theme === glass ? bridge.lastStandardTheme : bridge.theme);
    },
    setWallpaper(value) {
      if (bridge.theme !== glass || (value !== 'shuffle' && !photos.includes(value))) return;
      shuffle = value === 'shuffle';
      if (shuffle) draw();
      else { photo = value; drawn = false; }
      remember({photo, shuffle});
      syncTheme();
    },
    setLogo(value) { if (['classic','2006'].includes(value)) remember({logo: value}); },
    setPicture(value) { if (['blue-silhouette','governors-ball'].includes(value)) remember({picture: value}); },
    setTracklistPosition(value) { if (['left','bottom','right'].includes(value)) remember({tracklistPosition: value}); },
    visualizer(value) {
      if (value.action === 'preset' && ['ember','tidal','prism','tunnel'].includes(value.id)) remember({visualizerPreset: value.id});
      window.windowsMedia.send('visualizer', value);
    }
  };
  for (const name of ['live','player','download','library','plex','equalizer']) {
    bridge[name] = value => window.windowsMedia.send(name, value);
  }
  window.toolMac = bridge;
})();
