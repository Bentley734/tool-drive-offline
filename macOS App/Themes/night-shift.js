// Seven-segment displays supplement the catalog's own text. A repaint never
// changes a rating, filter, selection, or accessible label.
(() => {
  const namespace = 'http://www.w3.org/2000/svg';
  const segments = [
    'M2 0H12L14 2 12 4H3L0 2Z',
    'M12 4 14 2V11L12 13 10 11V6Z',
    'M12 13 14 15V22L12 24 10 22V15Z',
    'M3 21H11L13 23 11 25H2L0 23Z',
    'M0 15 2 13 4 15V20L2 23 0 21Z',
    'M0 3 2 3 4 5V10L2 12 0 10Z',
    'M3 10.5H11L13 12.5 11 14.5H3L1 12.5Z'
  ];
  // Bits, from low to high: top, upper right, lower right, bottom,
  // lower left, upper left, middle.
  const digitMasks = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111];

  function element(tag, attributes) {
    const node = document.createElementNS(namespace, tag);
    Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, value));
    return node;
  }

  function digits(value) {
    const svg = element('svg', {class: 'night-digits', 'aria-hidden': 'true', focusable: 'false'});
    let x = 0;
    for (const character of value) {
      if (character === '.') {
        svg.appendChild(element('circle', {cx: x + 1, cy: 23, r: 1.8, class: 'night-lit'}));
        x += 6;
      } else {
        const mask = digitMasks[Number(character)];
        const glyph = element('g', {transform: 'translate(' + x + ' 0)'});
        const lit = segments.filter((_, i) => mask & (1 << i)).join(' ');
        const unlit = segments.filter((_, i) => !(mask & (1 << i))).join(' ');
        if (unlit) glyph.appendChild(element('path', {d: unlit, class: 'night-unlit'}));
        glyph.appendChild(element('path', {d: lit, class: 'night-lit'}));
        svg.appendChild(glyph);
        x += 17;
      }
    }
    const width = Math.max(1, x - 2);
    svg.setAttribute('viewBox', '0 0 ' + width + ' 26');
    svg.setAttribute('width', width);
    svg.setAttribute('height', 26);
    return svg;
  }

  function drawRating(host) {
    const text = host.textContent.trim();
    const match = text.match(/^(\d+(?:\.\d+)?)(?:\s*\/\s*10)?$/);
    const rating = match && Number(match[1]);
    if (!match || rating < 0 || rating > 10 || host.classList.contains('night-enhanced')) return;
    const display = document.createElement('span');
    display.className = 'night-decoration night-rating';
    display.setAttribute('aria-hidden', 'true');
    display.appendChild(digits(rating.toFixed(1)));
    const bars = document.createElement('span');
    bars.className = 'night-bars';
    bars.style.setProperty('--night-level', (rating * 10) + '%');
    display.appendChild(bars);
    host.appendChild(display);
    host.classList.add('night-enhanced');
  }

  let active = false;
  window.refreshNightShift = function refreshNightShift() {
    if (document.documentElement.dataset.theme !== 'night-shift') {
      if (active) {
        document.querySelectorAll('.night-decoration').forEach(node => node.remove());
        document.querySelectorAll('.night-enhanced').forEach(node => node.classList.remove('night-enhanced'));
      }
      active = false;
      return;
    }
    active = true;
    const count = document.getElementById('total-shows').textContent.replace(/[^0-9]/g, '');
    let counter = document.querySelector('.night-counter');
    if (count && (!counter || counter.dataset.value !== count)) {
      if (counter) counter.remove();
      counter = document.createElement('div');
      counter.className = 'night-decoration night-counter';
      counter.setAttribute('aria-hidden', 'true');
      counter.dataset.value = count;
      const label = document.createElement('span');
      label.className = 'night-count-label';
      label.textContent = 'Catalog';
      const unit = document.createElement('small');
      unit.textContent = 'Shows';
      label.appendChild(unit);
      counter.appendChild(label);
      counter.appendChild(digits(count));
      document.querySelector('.hero').appendChild(counter);
    }
    document.querySelectorAll('.sound-value:not(.unrated), .source-score').forEach(drawRating);
  };
})();
