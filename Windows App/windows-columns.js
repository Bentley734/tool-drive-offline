// The original Windows view stored widths under these exact names in logical pixels.
(() => {
  'use strict';
  const fields = {Date: 118, Venue: 242, Location: 190, Sound: 89, Sources: 84, Type: 110, Taper: 145};
  const initial = window.toolWindowsInitial?.columnWidths || {};
  const widths = {...fields};
  for (const key of Object.keys(fields)) {
    const width = initial[key];
    if (Number.isInteger(width) && width >= 40 && width <= 3000) widths[key] = width;
  }
  const settings = window.toolWindows;
  const layout = settings.preferences.layout ?? (Object.keys(initial).some(key => key in fields) ? 'columns' : 'cards');
  const head = document.getElementById('windows-column-headers');
  const container = document.getElementById('windows-columns-scroll');
  const names = Object.keys(fields);
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  function measure() {
    container.style.setProperty('--columns-grid', names.map(key => widths[key] + 'px').concat('76px').join(' '));
    container.style.setProperty('--columns-total', (names.reduce((sum, key) => sum + widths[key], 76)) + 'px');
  }
  function resize(key, value, handle) {
    widths[key] = Math.max(40, Math.min(3000, Math.round(value)));
    handle.setAttribute('aria-valuenow', widths[key]);
    measure();
  }
  function persist() { settings.send('columns', {...widths}); }
  for (const key of names) {
    const cell = document.createElement('div');
    cell.setAttribute('role', 'columnheader');
    cell.textContent = key;
    const handle = document.createElement('span');
    handle.className = 'column-grip';
    handle.tabIndex = 0;
    for (const [name, value] of Object.entries({role: 'separator', 'aria-label': 'Resize ' + key, 'aria-orientation': 'vertical',
      'aria-valuemin': '40', 'aria-valuemax': '3000', 'aria-valuenow': widths[key]})) handle.setAttribute(name,value);
    let start = null;
    handle.addEventListener('pointerdown', e => {
      if (e.button !== 0) return;
      e.preventDefault();
      start = {x: e.clientX, width: widths[key]};
      handle.focus({preventScroll: true});
      handle.setPointerCapture(e.pointerId);
    });
    handle.addEventListener('pointermove', e => {
      if (start && handle.hasPointerCapture(e.pointerId)) {
        const zoom = parseFloat(document.documentElement.style.zoom) || 1;
        resize(key, start.width + (e.clientX - start.x) / zoom, handle);
      }
    });
    handle.addEventListener('lostpointercapture', () => { if (start) { start = null; persist(); } });
    handle.addEventListener('keydown', e => {
      if (!['ArrowLeft','ArrowRight','Home','End'].includes(e.key)) return;
      e.preventDefault();
      const step = e.shiftKey ? 32 : 8;
      const target = e.key === 'Home' ? 40 : e.key === 'End' ? 3000 : widths[key] + (e.key === 'ArrowRight' ? step : -step);
      resize(key, target, handle);
      persist();
    });
    handle.addEventListener('dblclick', () => { resize(key, fields[key], handle); persist(); });
    cell.appendChild(handle);
    head.appendChild(cell);
  }
  const actions = document.createElement('span');
  actions.setAttribute('role','columnheader');
  actions.textContent = 'Actions';
  head.appendChild(actions);
  function apply(active) {
    document.documentElement.dataset.windowsLayout = active ? 'columns' : 'cards';
    head.hidden = !active;
    container.toggleAttribute('tabindex', active);
    if (active) {
      container.tabIndex = 0;
      container.setAttribute('role','table');
      container.setAttribute('aria-label','Show results');
      head.setAttribute('role','row');
      document.getElementById('show-list').setAttribute('role','rowgroup');
    } else {
      container.removeAttribute('role');
      container.removeAttribute('aria-label');
      document.getElementById('show-list').removeAttribute('role');
    }
  }
  // Values come from artist/sound metadata and must be escaped before insertion.
  function row(show, source, rating, sourceCount, location, saveButton) {
    const values = [
      escape(show.date),
      `<button class="column-venue" data-open="${escape(show.id)}" aria-label="Open ${escape(show.date)} ${escape(show.venue)}">${escape(show.venue || 'Venue not documented')}</button>`,
      escape(location), `<span class="sound-value mono${rating === null ? ' unrated' : ''}">${rating === null ? '—' : rating.toFixed(1)}</span>`,
      escape(sourceCount), escape(source.recordingType || '—'), escape(source.taper || '—'),
      saveButton + `<button class="column-copy" data-copy-date="${escape(show.id)}" title="Copy date" aria-label="Copy date ${escape(show.date)}">⧉</button>`
    ];
    return '<div class="windows-data-row" role="row">' + values.map(value => '<div role="cell">' + value + '</div>').join('') + '</div>';
  }
  window.windowsColumns = {
    active: layout === 'columns',
    row,
    select(value) {
      this.active = value === 'columns';
      apply(this.active);
      settings.remember({layout: this.active ? 'columns' : 'cards'});
      window.renderWindowsRows?.();
    }
  };
  measure();
  apply(window.windowsColumns.active);
})();
