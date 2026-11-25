// Run the shipped player's scheduler against predictable display timestamps.
const noop = () => {};
const elements = new Map();
function element(id) {
  if (!elements.has(id)) {
    elements.set(id, {
      hidden: false, value: '', clientWidth: 1200, clientHeight: 700,
      options: [{value: 'ember'}, {value: 'tunnel'}], selectedOptions: [{textContent: 'test'}],
      classList: {add: noop, remove: noop}, focus: noop, setAttribute: noop,
      addEventListener(name, listener) { this[name] = listener; }
    });
  }
  return elements.get(id);
}
const document = {
  hidden: false, body: element('body'), getElementById: element, addEventListener: noop
};
const calls = {flame: 0, gpu: 0, fallback: 0};
const renderer = kind => ({draw() { calls[kind]++; }, setPreset: noop, dispose: noop});
const window = {
  toolMac: {visualizerPreset: 'tunnel', visualizer: noop}, devicePixelRatio: 1,
  createFlameVisualizer: () => renderer('flame'), createHyperspaceTunnel: () => renderer('gpu'),
  createTunnelFallback: () => renderer('fallback')
};
const motion = {matches: false, addListener(listener) { this.changed = listener; }};
const matchMedia = () => motion;
class ResizeObserver { observe() {} }
let frame = null;
function requestAnimationFrame(callback) { frame = callback; return 1; }
function cancelAnimationFrame() { frame = null; }
function assert(value, reason) { if (!value) throw Error(reason); }

// PLAYER_HOST

const stage = element('mac-visualizer');
stage.hidden = true;
const host = window.mountMacVisualizer();
host.updatePlayer(true, true);
element('mac-player-visualizer').click();
const gl = element('mac-visualizer-gl-canvas');
assert(!gl.hidden && element('mac-visualizer-canvas').hidden, 'Saved tunnel should open on GPU');
for (let i = 0; i < 120; i++) frame(i * 1000 / 60);
assert(calls.gpu >= 120 && calls.gpu <= 122, 'Tunnel should draw at 60 Hz on a 60 Hz display');
const before = calls.gpu;
for (let i = 0; i < 240; i++) frame(2000 + i * 1000 / 120);
assert(calls.gpu - before >= 119 && calls.gpu - before <= 121, 'Cap at 60 Hz on a 120 Hz display');
const initialWidth = gl.width;
for (let i = 0; i < 120; i++) frame(4000 + i * 1000 / 30);
assert(gl.width < initialWidth && gl.width >= 640, 'A slower GPU should render the same view at a smaller resolution');
motion.matches = true;
motion.changed();
assert(!frame, 'Reduce Motion should hold a still even during playback');
motion.matches = false;
motion.changed();
assert(frame, 'The animation should resume when Reduce Motion is turned off');
gl.webglcontextlost({preventDefault: noop});
assert(gl.hidden && calls.fallback > 0 && !element('mac-visualizer-canvas').hidden, 'Fallback on context loss');
gl.webglcontextrestored();
assert(!gl.hidden, 'Resume GPU after restoration');
host.updatePlayer(true, false);
assert(!frame, 'Pause should stop the display loop');
const picker = element('mac-visualizer-preset');
picker.value = 'ember';
picker.change();
assert(gl.hidden && calls.flame === 1, 'An original preset should still render while paused');
element('mac-player-visualizer').click();
assert(stage.hidden, 'Close hides the stage');
