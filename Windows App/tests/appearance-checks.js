'use strict';
// Run with Node: exercise the real Windows startup adapter across cold launches.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../windows-bridge.js'), 'utf8');
const choices = JSON.parse(fs.readFileSync(path.join(__dirname, '../../macOS App/Themes/glass-wallpapers.json'), 'utf8')).map(x => x.id);
const storage = new Map();
const localStorage = {getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, value)};
function launch(initial = {}) {
  const messages = [], media = [];
  const window = {
    chrome: {webview: {postMessage: x => messages.push(x)}},
    windowsMedia: {send: (name, payload) => media.push([name, payload])},
    toolWindowsInitial: initial,
    macLiquidGlassEnabled(enabled, theme, photo, choice) {
      Object.assign(window.toolMac, {liquidGlassEnabled:enabled, theme, wallpaper:photo, wallpaperChoice:choice});
    }
  };
  const document = {getElementById: () => ({options:[...choices,'shuffle'].map(value => ({value}))})};
  vm.runInNewContext(source, {window, document, localStorage});
  return {bridge:window.toolMac, messages, media};
}
let {bridge, messages, media} = launch({saved:[100, '101']});
assert.equal(bridge.theme,'liquid-glass');
assert.equal(bridge.load(),'["100","101"]');
bridge.save('["101"]');
assert.equal(JSON.stringify(messages[0]),'{"channel":"saved","body":["101"]}');
bridge.player({action:'load', sourceId:1});
assert.equal(media[0][0],'player');
bridge.setTheme('laser-grid');
bridge.setTheme('liquid-glass');
bridge.setLiquidGlass(false);
assert.equal(bridge.theme,'laser-grid');
bridge = launch().bridge;
assert.equal(bridge.theme,'laser-grid');
assert.equal(bridge.liquidGlassEnabled,false);
bridge.setTheme('liquid-glass');
assert.equal(bridge.theme,'laser-grid');
bridge.setLiquidGlass(true);
bridge.setTheme('liquid-glass');
bridge.setWallpaper('emerald-lasers');
bridge.setWallpaper('shuffle');
let previous = bridge.wallpaper;
assert.notEqual(previous,'emerald-lasers');
for (let i=0; i<20; i++) {
  bridge = launch().bridge;
  assert.equal(bridge.wallpaperChoice,'shuffle');
  assert.ok(choices.includes(bridge.wallpaper));
  assert.notEqual(bridge.wallpaper,previous);
  previous = bridge.wallpaper;
  bridge.setTheme('front-row');
  bridge.setTheme('liquid-glass');
  assert.equal(bridge.wallpaper,previous);
}
bridge.setWallpaper('blue-heptagram');
bridge.setLogo('2006');
bridge.setPicture('governors-ball');
bridge.setTracklistPosition('left');
bridge.visualizer({action:'preset', id:'tunnel'});
bridge=launch().bridge;
assert.equal(bridge.wallpaper,'blue-heptagram');
assert.equal(bridge.wallpaperChoice,bridge.wallpaper);
assert.equal(bridge.logo,'2006');
assert.equal(bridge.picture,'governors-ball');
assert.equal(bridge.tracklistPosition,'left');
assert.equal(bridge.visualizerPreset,'tunnel');
console.log('Windows appearance, saved shows, media dispatch and 20 cold launches passed.');
