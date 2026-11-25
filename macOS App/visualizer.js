'use strict';

window.mountMacVisualizer = function () {
  const get = id => document.getElementById(id);
  const stage = get('mac-visualizer');
  const flatCanvas = get('mac-visualizer-canvas');
  const glCanvas = get('mac-visualizer-gl-canvas');
  const picker = get('mac-visualizer-preset');
  const toggle = get('mac-player-visualizer');
  const full = get('mac-visualizer-fullscreen');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const send = (action, id) => window.toolMac.visualizer?.({action, id});
  const saved = window.toolMac.visualizerPreset;
  if (Array.from(picker.options).some(option => option.value === saved)) picker.value = saved;

  let renderer = null;
  let canvas = flatCanvas;
  let rendererKind = '';
  let glUnavailable = false;
  let gpuLongEdge = 1280;
  let sampleStart = null;
  let sampleFrames = 0;
  let playing = false;
  let visibleWindow = true;
  let listening = false;
  let frame = 0;
  let lastDraw = null;
  let nextDraw = null;
  let time = 0;
  let bands = [0, 0, 0];
  const envelope = [0, 0, 0];

  function onScreen() { return !stage.hidden && !document.hidden && visibleWindow; }
  function moving() { return onScreen() && playing && !reduced.matches; }

  function draw() {
    if (!onScreen() || !renderer) return;
    renderer.draw(picker.value === 'tunnel' ? time % 48 : time, envelope);
  }

  // Measure presentation across many frames so a single stall or a preset
  // change doesn't soften the image. A fresh opening retries full quality.
  function tuneTunnelResolution(now) {
    if (rendererKind !== 'gpu' || gpuLongEdge <= 640) return;
    if (sampleStart === null) { sampleStart = now; sampleFrames = 0; return; }
    sampleFrames++;
    const elapsed = now - sampleStart;
    if (elapsed < 1600) return;
    const fps = 1000 * sampleFrames / elapsed;
    if (fps < 54) {
      const currentEdge = Math.min(gpuLongEdge, Math.max(canvas.width, canvas.height));
      gpuLongEdge = Math.max(640, Math.round(currentEdge * 0.8));
      sizeCanvas();
    }
    sampleStart = now;
    sampleFrames = 0;
  }

  function animate(now) {
    frame = 0;
    if (!moving()) return;
    const interval = 1000 / (picker.value === 'tunnel' ? 60 : 30);
    if (nextDraw === null || now + 1 >= nextDraw) {
      const dt = lastDraw === null ? 0 : Math.min((now - lastDraw) / 1000, 0.12);
      time += dt;
      lastDraw = now;
      // Advance the deadline on the display clock. Comparing consecutive
      // 16.67 ms samples directly can accidentally halve the refresh rate.
      nextDraw = nextDraw === null || now >= nextDraw + interval ? now + interval : nextDraw + interval;
      for (let i = 0; i < 3; i++) {
        const level = bands[i];
        const decay = level > envelope[i] ? 0.055 : 0.18;
        envelope[i] += (level - envelope[i]) * (1 - Math.exp(-dt / decay));
      }
      tuneTunnelResolution(now);
      draw();
    }
    frame = requestAnimationFrame(animate);
  }

  function sync() {
    const run = moving();
    if (listening !== run) {
      listening = run;
      send(run ? 'listen' : 'idle');
    }
    if (run && !frame) frame = requestAnimationFrame(animate);
    if (!run) {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      lastDraw = null;
      nextDraw = null;
      sampleStart = null;
      bands = [0, 0, 0];
    }
  }

  function sizeCanvas() {
    if (!onScreen()) return;
    const width = canvas.clientWidth, height = canvas.clientHeight;
    if (!width || !height) return;
    const limit = rendererKind === 'gpu' ? gpuLongEdge : 1200;
    const scale = Math.min(window.devicePixelRatio || 1, limit / Math.max(width, height));
    const w = Math.max(1, Math.round(width * scale)), h = Math.max(1, Math.round(height * scale));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w; canvas.height = h;
      return true;
    }
    return false;
  }

  function resize() { if (sizeCanvas()) draw(); }

  function applyPreset() {
    const tunnel = picker.value === 'tunnel';
    let kind = tunnel ? (glUnavailable ? 'fallback' : 'gpu') : 'flame';
    if (kind !== rendererKind) {
      renderer?.dispose();
      if (kind === 'gpu') {
        renderer = window.createHyperspaceTunnel(glCanvas);
        if (!renderer) { glUnavailable = true; kind = 'fallback'; }
      }
      if (kind === 'fallback') renderer = window.createTunnelFallback(flatCanvas);
      if (kind === 'flame') renderer = window.createFlameVisualizer(flatCanvas);
      rendererKind = kind;
      canvas = kind === 'gpu' ? glCanvas : flatCanvas;
      flatCanvas.hidden = canvas !== flatCanvas;
      glCanvas.hidden = canvas !== glCanvas;
      gpuLongEdge = 1280;
      sampleStart = lastDraw = nextDraw = null;
    }
    if (!tunnel) renderer.setPreset(picker.value);
    canvas.setAttribute('aria-label', picker.selectedOptions[0].textContent + (tunnel ? ' tunnel' : ' fractal'));
    sizeCanvas();
    draw();
  }

  function show() {
    stage.hidden = false;
    document.body.classList.add('mac-visualizing');
    toggle.setAttribute('aria-expanded', 'true');
    applyPreset();
    picker.focus({preventScroll: true});
    send('window');
    sync();
  }

  function hide() {
    stage.hidden = true;
    document.body.classList.remove('mac-visualizing');
    toggle.setAttribute('aria-expanded', 'false');
    sync();
    renderer?.dispose();
    renderer = null;
    rendererKind = '';
    envelope.fill(0);
    if (!get('mac-player').hidden) toggle.focus({preventScroll: true});
  }

  toggle.addEventListener('click', () => stage.hidden ? show() : hide());
  get('mac-visualizer-close').addEventListener('click', hide);
  full.addEventListener('click', () => send('fullscreen'));
  picker.addEventListener('change', () => { applyPreset(); send('preset', picker.value); });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !stage.hidden && !event.defaultPrevented && get('mac-eq-panel').hidden && !document.querySelector('dialog[open]')) {
      event.preventDefault();
      hide();
    }
  });
  glCanvas.addEventListener('webglcontextlost', event => {
    event.preventDefault();
    glUnavailable = true;
    if (!stage.hidden && rendererKind === 'gpu') applyPreset();
  });
  glCanvas.addEventListener('webglcontextrestored', () => {
    glUnavailable = false;
    if (!stage.hidden && picker.value === 'tunnel') applyPreset();
  });
  new ResizeObserver(resize).observe(stage);
  document.addEventListener('visibilitychange', () => { sizeCanvas(); draw(); sync(); });
  reduced.addListener(() => { sync(); draw(); });
  window.macVisualizerLevels = levels => {
    if (!listening || !Array.isArray(levels) || levels.length !== 3) return;
    bands = levels.map(n => Number.isFinite(n) ? Math.min(1, Math.max(0, n)) : 0);
  };
  window.macVisualizerWindowState = state => {
    visibleWindow = state.visible;
    full.textContent = state.fullScreen ? 'Exit Full Screen' : 'Full Screen';
    full.setAttribute('aria-pressed', String(!!state.fullScreen));
    sizeCanvas(); draw(); sync();
  };
  return {
    updatePlayer(visible, isPlaying) {
      playing = isPlaying;
      if (!visible && !stage.hidden) hide();
      else sync();
    }
  };
};
