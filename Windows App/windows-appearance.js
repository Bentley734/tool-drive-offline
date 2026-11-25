(() => {
  'use strict';
  const byID = id => document.getElementById(id);
  const settings = window.toolWindows;
  const dialog = byID('appearance-dialog');
  const button = document.createElement('button');
  button.id = 'show-appearance';
  button.textContent = 'Appearance';
  button.setAttribute('aria-haspopup','dialog');
  byID('show-updates').after(button);

  const group = byID('windows-theme-settings');
  for (const picker of document.querySelectorAll('.topbar-tools .theme-picker')) group.append(picker);
  group.prepend(byID('liquid-glass-control'));
  button.onclick = () => { dialog.showModal(); byID('theme-choice').focus(); };
  byID('close-appearance').onclick = () => dialog.close();
  dialog.addEventListener('close', () => button.focus({preventScroll: true}));
  byID('import-audio').onclick = () => window.windowsMedia.send('library', {action: 'import'});

  const icon = byID('app-icon-choice');
  const allowedIcon = value => ['multicolor','classic','2006'].includes(value);
  function applyIcon(value) {
    if (!allowedIcon(value)) return;
    icon.value = value;
    document.querySelector('link[rel="icon"]').setAttribute('href', 'icons/' + value + '.ico');
    settings.send('appIcon', value);
  }
  applyIcon(allowedIcon(settings.preferences.appIcon) ? settings.preferences.appIcon : 'multicolor');
  icon.onchange = () => { settings.remember({appIcon: icon.value}); applyIcon(icon.value); };

  const layout = byID('windows-layout');
  layout.value = window.windowsColumns.active ? 'columns' : 'cards';
  layout.onchange = () => window.windowsColumns.select(layout.value);
  const zoom = byID('windows-zoom');
  const zoomSteps = [...zoom.options].map(option => parseInt(option.value, 10));
  function setZoom(percent) {
    if (!zoomSteps.includes(percent)) percent = 100;
    document.documentElement.style.zoom = String(percent / 100);
    zoom.value = percent + '%';
  }
  function saveZoom(percent) {
    setZoom(percent);
    settings.remember({zoom: percent});
  }
  setZoom(settings.preferences.zoom);
  zoom.onchange = () => saveZoom(parseInt(zoom.value, 10));
  document.addEventListener('keydown', e => {
    if (!e.ctrlKey || e.altKey || e.metaKey) return;
    if (['+', '=', '-', '0'].includes(e.key)) {
      e.preventDefault();
      const i = zoom.selectedIndex + (e.key === '-' ? -1 : 1);
      saveZoom(e.key === '0' ? 100 : zoomSteps[Math.max(0, Math.min(zoomSteps.length - 1, i))]);
    }
    if (e.key === 'Tab' && byID('show-dialog').open) {
      e.preventDefault();
      const headings = [...byID('dialog-content').querySelectorAll('.section-head')];
      const header = headings.find(item => item.dataset.jumped === 'true');
      const next = header ? (headings.indexOf(header) + (e.shiftKey ? -1 : 1) + headings.length) % headings.length : 0;
      for (const h of headings) delete h.dataset.jumped;
      if (headings[next]) {
        headings[next].dataset.jumped = 'true';
        headings[next].tabIndex = -1;
        headings[next].focus();
      }
    }
  });
  const reduced = matchMedia('(prefers-reduced-transparency: reduce)');
  const contrast = matchMedia('(forced-colors: active)');
  function accessibility() {
    document.documentElement.dataset.glassReduceTransparency = String(window.toolWindowsInitial?.reduceTransparency === true || reduced.matches || contrast.matches);
  }
  reduced.addEventListener('change', accessibility);
  contrast.addEventListener('change', accessibility);
  accessibility();

  let timer;
  window.showWindowsNotice = message => {
    if (!message) return;
    let notice = byID('windows-host-notice');
    if (!notice) {
      notice = document.createElement('div');
      notice.id = 'windows-host-notice';
      notice.setAttribute('role','status');
    }
    (document.querySelector('dialog[open]') || document.body).append(notice);
    notice.textContent = String(message);
    notice.hidden = false;
    clearTimeout(timer);
    timer = setTimeout(() => { notice.hidden = true; }, 6000);
  };
  document.addEventListener('windowsHostNotice', e => window.showWindowsNotice(e.detail));
  settings.send('ready', null);
})();
