'use strict';

window.mountMacEqualizer = function () {
  const get = id => document.getElementById(id);
  const panel = get('mac-eq-panel'), toggle = get('mac-player-eq'), magik = get('mac-eq-magik');
  const message = get('mac-eq-status');
  const presets = {flat: [0, 0, 0], bassBoost: [8, 0, 2], vocal: [-3, 6, 1], bright: [-1, 1, 7]};
  const names = ['bass', 'mid', 'treble'];
  const sliders = names.map(name => get('mac-eq-' + name));
  const buttons = Array.from(panel.querySelectorAll('[data-eq-preset]'));
  let values = presets.flat.slice(), layered = false, preset = 'flat', available = null;

  function paint() {
    const flat = values.every(n => n === 0) && !layered;
    toggle.dataset.active = String(!flat);
    magik.setAttribute('aria-pressed', String(layered));
    for (const button of buttons) {
      const id = button.dataset.eqPreset;
      button.setAttribute('aria-pressed', String(id === 'flat' ? flat : id === preset));
    }
    sliders.forEach((slider, i) => {
      const gain = values[i];
      slider.disabled = i === 1 && layered;
      // TDP estimates the locked Mid display by summing Magik's seven bells
      // between 200 Hz and 2 kHz. The audio uses each individual bell.
      const displayed = slider.disabled ? Math.round(gain - 23.85) : gain;
      slider.min = slider.disabled ? '-34' : '-10';
      slider.max = slider.disabled ? '34' : '10';
      slider.value = String(displayed);
      const db = (displayed > 0 ? '+' : '') + displayed + ' dB';
      slider.setAttribute('aria-valuetext', slider.disabled ? 'About ' + db + ' with Magik' : db);
      slider.nextElementSibling.textContent = (slider.disabled ? '≈' : '') + db;
      slider.title = slider.disabled ? 'Estimated midrange with Magik · fixed while on' : db;
    });
    message.hidden = available !== false || flat;
    message.textContent = message.hidden ? '' : 'This track is playing without EQ.';
  }

  function apply() {
    paint();
    window.toolMac.equalizer?.({bass: values[0], mid: values[1], treble: values[2], magik: layered});
  }

  function hide(focus = false) {
    if (panel.hidden) return;
    panel.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
    if (focus && !get('mac-player').hidden) toggle.focus({preventScroll: true});
  }

  toggle.addEventListener('click', () => {
    if (!panel.hidden) { hide(true); return; }
    panel.hidden = false;
    toggle.setAttribute('aria-expanded', 'true');
    (buttons.find(b => b.getAttribute('aria-pressed') === 'true') || magik).focus({preventScroll: true});
  });
  get('mac-eq-close').addEventListener('click', () => hide(true));
  buttons.forEach(button => button.addEventListener('click', () => {
    const id = button.dataset.eqPreset;
    preset = id === preset ? 'flat' : id;
    values = presets[preset].slice();
    if (preset === 'flat') layered = false;
    apply();
  }));
  sliders.forEach((slider, i) => slider.addEventListener('input', () => {
    if (slider.disabled) return;
    values[i] = slider.valueAsNumber;
    preset = 'custom';
    apply();
  }));
  magik.addEventListener('click', () => { layered = !layered; apply(); });
  document.addEventListener('pointerdown', event => {
    if (!panel.hidden && !panel.contains(event.target) && !toggle.contains(event.target)) hide();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !panel.hidden) { event.preventDefault(); hide(true); }
  });
  window.macEqualizerState = state => {
    if (state.reset) { values = presets.flat.slice(); layered = false; preset = 'flat'; available = null; }
    if ('available' in state) available = state.available;
    paint();
  };
  paint();
  return {hide};
};
