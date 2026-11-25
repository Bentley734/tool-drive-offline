'use strict';
(() => {
  const tunnel = document.querySelector('#tunnel');
  const filaments = document.querySelector('#filaments');
  let canvas, renderer, kind, preset, gpuLost = false;
  let moving = false, tick = 0, last = 0, t = 0, samples = 0, sampleStart = 0, edge = 960;
  let bands = [0, 0, 0], envelope = [0, 0, 0];
  const presets = new Set(['tunnel', 'ember', 'tidal', 'prism']);

  function resize() {
    if (!canvas) return;
    const width = innerWidth, height = innerHeight;
    const scale = Math.min(devicePixelRatio, edge / Math.max(1, width, height));
    canvas.width = Math.max(1, Math.round(width * scale));
    canvas.height = Math.max(1, Math.round(height * scale));
    renderer.draw(preset === 'tunnel' ? t % 48 : t, envelope);
  }
  function choose(value) {
    const requested = value === 'tunnel' ? (gpuLost ? 'fallback' : 'gpu') : 'flame';
    if (kind !== requested) {
      renderer?.dispose();
      kind = requested;
      if (kind === 'gpu') {
        renderer = window.createHyperspaceTunnel(tunnel);
        if (!renderer) { kind = 'fallback'; gpuLost = true; }
      }
      canvas = kind === 'gpu' ? tunnel : filaments;
      if (kind === 'fallback') renderer = window.createTunnelFallback(canvas);
      if (kind === 'flame') renderer = window.createFlameVisualizer(canvas);
      tunnel.hidden = canvas !== tunnel;
      filaments.hidden = canvas !== filaments;
    }
    preset = value;
    if (kind === 'flame') renderer.setPreset(preset);
    edge = kind === 'gpu' ? 960 : 1000;
    sampleStart = samples = 0;
    resize();
  }
  function frame(now) {
    tick = 0;
    if (!moving || document.hidden) return;
    const interval = kind === 'gpu' ? 1000 / 60 : 1000 / 30;
    if (!last || now - last + 0.75 >= interval) {
      const dt = last ? Math.min((now - last) / 1000, 0.1) : 0;
      last = now;
      t += dt;
      envelope = envelope.map((old, i) => old + (bands[i] - old) * (1 - Math.exp(-dt / 0.12)));
      renderer.draw(preset === 'tunnel' ? t % 48 : t, envelope);
      if (kind === 'gpu' && edge > 480) {
        if (!sampleStart) sampleStart = now;
        samples++;
        if (now - sampleStart >= 1600) {
          if (1000 * samples / (now - sampleStart) < 50) { edge = Math.max(480, Math.round(edge * 0.8)); resize(); }
          sampleStart = now; samples = 0;
        }
      }
    }
    tick = requestAnimationFrame(frame);
  }
  function schedule() {
    cancelAnimationFrame(tick);
    last = tick = sampleStart = samples = 0;
    if (moving && !document.hidden) tick = requestAnimationFrame(frame);
  }
  window.mobileVisual = (value, animate) => {
    if (!presets.has(value)) return;
    if (preset !== value) choose(value);
    if (moving !== animate) { moving = animate; schedule(); }
  };
  window.mobileBands = values => { bands = values.map(n => Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : 0); };
  tunnel.addEventListener('webglcontextlost', e => { e.preventDefault(); gpuLost = true; if (preset === 'tunnel') choose(preset); });
  tunnel.addEventListener('webglcontextrestored', () => { gpuLost = false; if (preset === 'tunnel') choose(preset); });
  addEventListener('resize', resize);
  document.addEventListener('visibilitychange', schedule);
})();
