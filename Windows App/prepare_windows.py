"""Add the Windows host interface to the shared desktop catalog at build time."""
from pathlib import Path
import shutil


def replace_once(page, original, replacement):
    if page.count(original) != 1:
        raise ValueError(f'Desktop catalog integration point changed: {original[:90]}')
    return page.replace(original, replacement, 1)


def render_windows(page, source: Path, output: Path):
    text = lambda name: (source / name).read_text(encoding='utf-8')
    script = lambda name: '<script>' + text(name) + '</script>'
    # The renderer may contact only its two WebView2 virtual hosts. Audio URLs
    # are opaque tickets; archive URLs and Plex credentials live outside the page.
    for original, replacement in [
        ("img-src file: data:", "img-src 'self' data:"),
        ("connect-src 'none'", "connect-src 'self' https://media.tooldrive.invalid"),
        ("media-src 'none'", "media-src 'self' https://media.tooldrive.invalid"),
        ("e.metaKey&&e.key.toLowerCase()==='f'", "e.ctrlKey&&e.key.toLowerCase()==='f'"),
        ('window.webkit.messageHandlers.updates.postMessage(action)', "window.toolWindows.send('updates', action)"),
        ('<meta name="description" content="An offline, metadata-only Tool show catalog. Filter recording sound ratings and find your next listen in Plexamp.">',
         '<meta name="description" content="Browse the TOOL concert archive, stream recordings and play your library.">'),
        ('<title>Tool · Offline listening index</title>', '<title>Tool Drive Offline</title><link rel="icon" href="icons/multicolor.ico">'),
        ('<button id="refresh-library">', '<button id="import-audio">Import audio…</button><button id="refresh-library">'),
        ("      if (savedSourceIDs.has(sourceID)) {",
         """      addSourceButton(row, 'Import original…', () => {
        bridge('library', {action: 'import', ...payload});
      }, {title: 'Import the original audio files or ZIP for this recording'});
      if (savedSourceIDs.has(sourceID)) {"""),
        ('return `<article class="show-row"><div class="date-cell mono">',
         '''if (window.windowsColumns.active) return window.windowsColumns.row(s, b, row.rating, total, location(s), saveButton(s));
return `<article class="show-row"><div class="date-cell mono">'''),
        ('<div id="list-head" class="list-head"', '<div id="windows-columns-scroll"><div id="windows-column-headers" hidden></div><div id="list-head" class="list-head"'),
        ('<div id="show-list"></div><div id="pagination"', '<div id="show-list"></div></div><div id="pagination"'),
        ("function readFilters(){", "window.renderWindowsRows = () => render(false);\nfunction readFilters(){"),
        ('</head>', '<style>' + text('windows.css') + '</style><!--windows-initial--></head>'),
    ]:
        page = replace_once(page, original, replacement)
    # Settings are a dialog so that the narrow and wide window layouts share
    # the same controls, focus behavior and labels.
    page = replace_once(page, '<dialog id="library-dialog"', text('windows-appearance.html') + '<dialog id="library-dialog"')
    page = page.replace('on this Mac', 'on this PC').replace('from this Mac', 'from this PC')
    page = page.replace('-apple-system,BlinkMacSystemFont', '"Segoe UI",system-ui').replace('-apple-system, BlinkMacSystemFont', '"Segoe UI", system-ui')
    first_script = page.index('<script>')
    page = page[:first_script] + script('windows-bridge.js') + script('windows-columns.js') + page[first_script:]
    page = replace_once(page, '<script>(() => {\n  const themePicker =', script('windows-player.js') + script('windows-services.js') +
                        '<script>(() => {\n  const themePicker =')
    page = replace_once(page, '</body>', script('windows-appearance.js') + '</body>')
    shutil.copytree(source / 'Icons', output / 'icons', dirs_exist_ok=True)
    return page
