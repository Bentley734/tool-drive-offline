function(phase) {
  // CoreWebView2 encodes the return value as JSON; this reports assertion details
  // rather than its generic "null" result for an unhandled JavaScript exception.
  try {
    const id = name => document.getElementById(name);
    const root = document.documentElement;
    function expect(value, text) { if (!value) throw Error(text); }
    function select(name, value) {
      const picker = id(name);
      picker.value = value;
      picker.dispatchEvent(new Event('change', {bubbles:true}));
    }
    expect(location.href === 'https://archive.tooldrive.invalid/index.html', 'Production application origin');
    expect(typeof chrome.webview.postMessage === 'function' && Array.isArray(window.toolWindowsInitial.saved), 'Native host startup bridge');
    expect(window.CATALOG.shows.length > 1000, 'Bundled catalog');
    expect(root.dataset.theme === (phase === 'first' ? 'liquid-glass' : 'laser-grid'), 'Launch theme');
    expect(id('saved-count').textContent === (phase === 'first' ? '0' : '1'), 'Native saved show migration');
    id('show-appearance').click();
    expect(id('appearance-dialog').open && id('glass-wallpaper-picker').options.length === 10, 'Wallpaper dialog');
    expect(id('theme-choice').options.length === 5, 'Five desktop themes');
    if (phase === 'first') {
      select('glass-wallpaper-picker','emerald-lasers');
      select('glass-wallpaper-picker','shuffle');
      expect(root.dataset.glassWallpaper !== 'emerald-lasers' && window.toolMac.wallpaperChoice === 'shuffle', 'Shuffle chooses a different photo');
      for (const theme of ['front-row','night-shift','graphite','liquid-glass','laser-grid']) {
        select('theme-choice',theme);
        expect(root.dataset.theme === theme,'Render theme '+theme);
      }
      select('logo-choice','2006');
      select('windows-layout','columns');
      select('app-icon-choice','2006');
    } else {
      expect(id('logo-choice').value === '2006' && id('app-icon-choice').value === '2006','Restored logos');
      expect(id('windows-layout').value === 'columns' && window.toolMac.wallpaperChoice === 'shuffle','Restored layout and wallpaper mode');
    }
    id('close-appearance').click();
    expect(document.querySelector('.windows-data-row button[data-open]'), 'Catalog rows');
    if (phase === 'first') {
      document.querySelector('.windows-data-row [data-save]').click();
      document.querySelector('[aria-label="Resize Venue"]').dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));
    } else {
      expect(window.toolWindowsInitial.columnWidths.Venue === 250, 'Restored native column widths');
      id('saved-only').click();
      expect(document.querySelectorAll('.windows-data-row').length === 1, 'Saved filter');
    }
    document.querySelector('.windows-data-row button[data-open]').click();
    expect(id('show-dialog').open && document.querySelector('.mac-source-actions'), 'Recording detail with playback actions');
    id('close-dialog').click();
    return 'passed';
  } catch (error) { return error.message; }
}
