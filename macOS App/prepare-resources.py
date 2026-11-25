"""Assemble the bundled desktop catalog without changing the standalone browser edition."""
import argparse
from pathlib import Path
from xml.etree import ElementTree
import base64
from html import escape
import json
import shutil
import sys
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--windows', action='store_true')
args = parser.parse_args()
root, output = args.root.resolve(), args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
html = (root / 'index.html').read_text(encoding='utf-8')
replacements = {
    "img-src data:;": "img-src file: data:;",
    "localStorage.getItem('tool-offline-saved-v1')": "window.toolMac.load()",
    "localStorage.setItem('tool-offline-saved-v1',JSON.stringify([...saved]))": "window.toolMac.save(JSON.stringify([...saved]))",
    "async function copyText(text){": "async function copyText(text){if(window.toolMac){window.toolMac.copy(text);toast('Copied. Paste into Plexamp search.');return;}",
    'Your saved shows stay in this browser.': 'Your saved shows stay on this Mac.',
    'Metadata only. No audio, playback, or download links.': 'Catalog works offline. Streaming, downloads, and Plex are optional.',
    'This catalog contains metadata only. Your saved shows stay on this Mac.': 'Catalog metadata is bundled offline. Your saved shows stay on this Mac.',
    'Segoe UI,Arial,sans-serif': '-apple-system,BlinkMacSystemFont,Arial,sans-serif',
}
for before, after in replacements.items():
    assert before in html, f'Missing integration point: {before}'
    html = html.replace(before, after)
html = html.replace("render();\n})();", "document.addEventListener('keydown',e=>{if(e.metaKey&&e.key.toLowerCase()==='f'){e.preventDefault();$('search').focus();}});\nrender();\n})();")
html = html.replace('Offline catalog', 'Available offline')
html = html.replace('Find your next<br>live listen.', 'Find your next live listen.')
html = html.replace('window.CATALOG = ', 'window.CATALOG = window.toolMac.catalog || ', 1)
html = html.replace('const catalog = window.CATALOG', 'let catalog = window.CATALOG').replace('const shows = catalog.shows;', 'let shows = catalog.shows;')
start = html.index('for(const show of shows)')
end = html.index('function readFilters()', start)
initialization = html[start:end]
html = html[:start] + 'function initializeCatalog(){' + initialization + '}\ninitializeCatalog();\n' + html[end:]
apply = """
window.applyMacCatalog = candidate => {
  const ids=['search','minimum-rating','rating-mode','year-from','year-to','source-status','recording-type','sort'];
  const values=Object.fromEntries(ids.map(id=>[id,$(id).value]));
  catalog=candidate; shows=candidate.shows; window.CATALOG=candidate;
  initializeCatalog();
  for(const id of ids){$(id).value=values[id]; if($(id).selectedIndex===-1)$(id).selectedIndex=0;}
  render(false); if(currentShowId!==null)renderDetail(currentShowId);
};
"""
html = html.replace('function readFilters()', apply + 'function readFilters()', 1)
updates = '<section class="updates" aria-label="Updates">' + ''.join(
    f'<div class="update-card" id="{kind}-card"><span class="update-icon" aria-hidden="true">{icon}</span><div class="update-info"><span class="update-label">{label}</span><span class="update-status" id="{kind}-status" role="status">Ready to check</span></div><button id="{kind}-update">Check now</button></div>'
    for kind, icon, label in [('catalog','↻','Catalog updates'),('app','↓','App updates')]) + '</section>'
html = html.replace('<div class="workspace">', updates + '<div class="workspace">', 1)

mac = root / 'macOS App'
# Build the two reusable marks once. Both use the ink color of their surface.
logo = ElementTree.parse(mac / 'Themes/tool-logo.svg').getroot()
view_box = logo.attrib['viewBox']
width, height = view_box.split()[2:]
path = logo.find('{*}path').attrib['d']
logo_2006 = base64.b64encode((mac / 'Themes/tool-logo-2006.png').read_bytes()).decode('ascii')
# The 2006 mark is the supplied raster alpha, trimmed to its 930 x 216 ink box.
sprite = ('<svg class="brand-symbols" aria-hidden="true" focusable="false" width="0" height="0">'
          f'<symbol id="tool-logo" viewBox="{view_box}"><path fill="currentColor" fill-rule="evenodd" '
          f'clip-rule="evenodd" d="{path}"/></symbol>'
          '<mask id="tool-2006-alpha" maskUnits="userSpaceOnUse" maskContentUnits="userSpaceOnUse" '
          'x="0" y="0" width="930" height="216" style="mask-type:alpha">'
          f'<image href="data:image/png;base64,{logo_2006}" width="930" height="216"/></mask>'
          '<symbol id="tool-logo-2006" viewBox="0 0 930 216">'
          '<rect width="930" height="216" fill="currentColor" mask="url(#tool-2006-alpha)"/></symbol></svg>')
mark = (f'<svg class="tool-logo" role="img" aria-label="TOOL" focusable="false" viewBox="0 0 {width} {height}">'
        '<use href="#tool-logo" width="100%" height="100%"></use></svg>')
wordmark = '<span class="wordmark">TOOL</span>'
assert html.count(wordmark) == 1, 'Expected the toolbar brand'
html = html.replace('<body>', '<body>' + sprite, 1)
html = html.replace(wordmark, '<span class="wordmark">' + mark + '</span>')

themes = ['front-row', 'night-shift', 'graphite', 'laser-grid']
pictures = ['blue-silhouette', 'governors-ball']
manifest = mac / 'Themes/glass-wallpapers.json'
wallpapers = json.loads(manifest.read_text(encoding='utf-8'))
wallpaper_options = ''.join(
    f'<option value="{item["id"]}">{escape(item["title"])}</option>' for item in wallpapers
)
artwork = {
    'blue-silhouette': 'blue-silhouette.jpg',
    'governors-ball': 'governors-ball.jpg',
    'laser-grid': 'laser-grid.jpg',
}


def options(choices):
    return ''.join('<option value="{}">{}</option>'.format(value, value.replace('-', ' ').title())
                   for value in choices)


picker = (
    '<div class="topbar-tools"><button id="show-library" aria-haspopup="dialog">Library</button>'
    '<button id="show-plex" aria-haspopup="dialog">Plex</button>'
    '<button id="show-updates" aria-haspopup="dialog" hidden>Updates</button>'
    '<div class="theme-picker">'
    '<label for="theme-choice">Theme</label>'
    f'<select id="theme-choice">{options(themes)}</select></div>'
    '<template id="glass-theme-option"><option value="liquid-glass">Liquid Glass</option></template>'
    '<div class="theme-picker"><label for="logo-choice">Logo</label>'
    '<select id="logo-choice"><option value="classic">Classic</option><option value="2006">2006</option></select></div>'
    '<div class="theme-picker" id="picture-picker" hidden>'
    '<label for="picture-choice">Picture</label>'
    f'<select id="picture-choice">{options(pictures)}</select></div>'
    '<div class="theme-picker" id="glass-wallpaper-control" hidden><label for="glass-wallpaper-picker">Wallpaper</label>'
    f'<select id="glass-wallpaper-picker" aria-label="Liquid Glass wallpaper">{wallpaper_options}'
    '<option value="shuffle">Shuffle</option></select></div>'
    '<div class="topbar-status"><span class="offline">Available offline</span>'
    '<label class="glass-choice" id="liquid-glass-control" hidden>'
    '<input id="liquid-glass-choice" type="checkbox" switch role="switch">Liquid Glass</label></div></div>'
)
badge = '<span class="offline">Available offline</span>'
assert html.count(badge) == 1, 'Expected the Mac toolbar'
html = html.replace(badge, picker)

# Front Row and Laser Grid retain their embedded photo templates.
gallery = []
image_types = {'.jpg': 'image/jpeg', '.svg': 'image/svg+xml'}
for name, filename in artwork.items():
    mime = image_types[Path(filename).suffix]
    encoded_art = base64.b64encode((mac / 'Themes' / filename).read_bytes()).decode('ascii')
    gallery.append(
        f'<template id="art-{name}"><img class="theme-art" alt="" '
        f'src="data:{mime};base64,{encoded_art}"></template>'
    )
html = html.replace('</header>', '</header>' + ''.join(gallery), 1)
stylesheets = ['mac.css', 'Themes/themes.css', 'Themes/front-row.css',
               'Themes/night-shift.css', 'Themes/laser-grid.css', 'Themes/liquid-glass.css',
               'Themes/glass-theme.css']
styles = '\n'.join((mac / filename).read_text(encoding='utf-8') for filename in stylesheets)
# Each wallpaper loads from the app bundle only when its selector matches.
wallpaper_dir = output / 'Wallpapers'
wallpaper_dir.mkdir(exist_ok=True)
shutil.copyfile(manifest, output / manifest.name)
glass_selector = ':root[data-theme="liquid-glass"][data-liquid-glass="true"]'
for item in wallpapers:
    filename = item['file']
    shutil.copyfile(mac / 'Themes/Wallpapers' / filename, wallpaper_dir / filename)
    styles += (f'\n{glass_selector}[data-glass-wallpaper="{item["id"]}"] {{'
               f'--glass-wallpaper-image: url("Wallpapers/{filename}"); }}')
html = html.replace('</style>', '</style><style>' + styles + '</style>', 1)
html = html.replace('<h1>Find your next live listen.</h1>',
                    '<h1>Find your next live listen.</h1><div class="theme-meta">'
                    '<span class="theme-total"></span><span class="theme-years"></span></div>', 1)
html = html.replace('<div class="search-wrap">', '<h2 class="theme-catalog-heading">Catalog</h2><div class="search-wrap">', 1)
source_card = '<article class="source-card${matches?\'\':\' unmatched\'}">'
source_card_with_identity = (
    '<article class="source-card${matches?\'\':\' unmatched\'}" '
    'data-source-id="${escapeHtml(src.id)}" data-show-id="${escapeHtml(show.id)}" '
    'data-show-date="${escapeHtml(show.date)}" data-show-venue="${escapeHtml(show.venue||\'\')}" '
    'data-source-version="${escapeHtml(src.version||\'\')}" data-source-status="${escapeHtml(src.status||\'\')}">'
)
assert html.count(source_card) == 1, 'Expected the recording source card renderer'
html = html.replace(source_card, source_card_with_identity, 1)
player = (
    '<section class="mac-player" id="mac-player" aria-label="Audio player" hidden>'
    '<div class="mac-player-main">'
    '<div class="mac-player-copy"><strong id="mac-player-title">Nothing playing</strong>'
    '<span id="mac-player-context">Choose Stream from a recording source.</span>'
    '<span class="mac-player-status" id="mac-player-status" role="status" hidden></span></div>'
    '<div class="mac-player-controls" aria-label="Playback controls">'
    '<button id="mac-player-previous" aria-label="Previous track">‹</button>'
    '<button class="mac-player-toggle" id="mac-player-toggle" aria-label="Play">▶</button>'
    '<button id="mac-player-next" aria-label="Next track">›</button></div>'
    '<div class="mac-player-timeline"><span class="mono" id="mac-player-elapsed">0:00</span>'
    '<input id="mac-player-seek" type="range" min="0" max="0" step="1" value="0" aria-label="Playback position">'
    '<span class="mono" id="mac-player-duration">0:00</span></div>'
    '<div class="mac-player-tools"><button id="mac-player-eq" aria-label="Equalizer" '
    'aria-controls="mac-eq-panel" aria-expanded="false">EQ</button>'
    '<button id="mac-player-visualizer" aria-expanded="false" '
    'aria-controls="mac-visualizer">Visualizer</button><button id="mac-player-tracklist" aria-expanded="false" '
    'aria-controls="mac-tracklist-panel">Tracklist</button>'
    '<button id="mac-player-close" aria-label="Close player">×</button></div></div>'
    '<section class="mac-tracklist-panel" id="mac-tracklist-panel" aria-labelledby="mac-tracklist-title" hidden>'
    '<div class="mac-tracklist-heading"><h2 id="mac-tracklist-title">Tracklist</h2>'
    '<label for="mac-tracklist-position">Position</label>'
    '<select id="mac-tracklist-position" aria-label="Tracklist position">'
    '<option value="left">Left</option><option value="bottom" selected>Bottom</option>'
    '<option value="right">Right</option></select></div>'
    '<div class="mac-player-tracks" id="mac-player-tracks"></div></section></section>'
)
eq_bands = ''.join(
    f'<div class="mac-eq-band"><label for="mac-eq-{key}">{name}</label>'
    f'<input id="mac-eq-{key}" type="range" min="-10" max="10" step="1" value="0">'
    f'<output for="mac-eq-{key}">0 dB</output></div>'
    for key, name in [('bass', 'Bass'), ('mid', 'Mid'), ('treble', 'Treble')]
)
equalizer = (
    '<section id="mac-eq-panel" aria-labelledby="mac-eq-title" hidden>'
    '<header><h2 id="mac-eq-title">Equalizer</h2><button id="mac-eq-close" aria-label="Close equalizer">×</button></header>'
    '<div class="mac-eq-presets" role="group" aria-label="Tone preset">'
    '<button data-eq-preset="flat">Flat</button><button data-eq-preset="bassBoost">Bass Boost</button>'
    '<button data-eq-preset="vocal">Vocal</button><button data-eq-preset="bright">Bright</button></div>'
    + eq_bands +
    '<div class="mac-eq-layer"><button id="mac-eq-magik" aria-pressed="false">Magik</button>'
    '<span>Layer with any preset</span></div><p id="mac-eq-status" role="status" hidden></p></section>'
)
visualizer = (
    '<section id="mac-visualizer" aria-label="Music visualizer" hidden>'
    '<canvas id="mac-visualizer-canvas" role="img" aria-label="Ember Bloom fractal"></canvas>'
    '<canvas id="mac-visualizer-gl-canvas" role="img" aria-label="Infinite Filigree tunnel" hidden></canvas>'
    '<div class="visualizer-toolbar">'
    '<label for="mac-visualizer-preset">Visualizer</label>'
    '<select id="mac-visualizer-preset" aria-label="Visualizer preset">'
    '<option value="ember">Ember Bloom</option><option value="tidal">Tidal Glass</option>'
    '<option value="prism">Prism Veil</option><option value="tunnel">Infinite Filigree</option></select>'
    '<button id="mac-visualizer-fullscreen" aria-pressed="false">Full Screen</button>'
    '<button id="mac-visualizer-close" aria-label="Close visualizer" title="Close visualizer">×</button>'
    '</div></section>'
)
library = (
    '<dialog id="library-dialog" aria-labelledby="library-title">'
    '<div class="dialog-top"><div><span class="eyebrow">Downloaded recordings</span>'
    '<h2 id="library-title">Library</h2></div><div class="library-top-actions">'
    '<button id="refresh-library">Refresh</button>'
    '<button class="dialog-close" id="close-library" aria-label="Close library">×</button></div></div>'
    '<div class="dialog-content library-content">'
    '<p class="library-status" id="library-status" role="status">Loading your library…</p>'
    '<div class="library-downloads" id="library-downloads" aria-live="polite"></div>'
    '<div class="library-list" id="library-list"></div></div></dialog>'
)
plex = (
    '<dialog id="plex-dialog" aria-labelledby="plex-title">'
    '<div class="dialog-top"><div><span class="eyebrow">Your music library</span>'
    '<h2 id="plex-title">Plex</h2></div><button class="dialog-close" id="close-plex" aria-label="Close Plex">×</button></div>'
    '<div class="dialog-content plex-content">'
    '<p class="plex-privacy">Plex is optional. Connect it to play recordings already in your own library. '
    'Your sign-in and server details stay private on this Mac.</p>'
    '<div class="plex-connection"><div><span class="plex-state-dot" aria-hidden="true"></span>'
    '<strong id="plex-status-title">Not connected</strong><span id="plex-status-message" role="status">Connect when you are ready.</span></div>'
    '<div class="plex-connection-actions"><button class="primary" id="connect-plex">Connect Plex</button>'
    '<button id="disconnect-plex" hidden>Disconnect</button></div></div>'
    '<div id="plex-browser" hidden><div class="plex-sources"><label for="plex-server">Server</label>'
    '<select id="plex-server" aria-label="Plex server"></select><button id="refresh-plex-servers">Refresh servers</button>'
    '<label for="plex-library">Music library</label><select id="plex-library" aria-describedby="plex-library-status" disabled></select>'
    '<button id="refresh-plex-libraries" disabled>Refresh libraries</button></div>'
    '<p id="plex-library-status" role="status"></p>'
    '<form class="plex-search" id="plex-search-form"><label for="plex-search">Search your library</label>'
    '<div><input id="plex-search" type="search" placeholder="Show date or venue" autocomplete="off" disabled>'
    '<button class="primary" type="submit" id="plex-search-submit" disabled>Search</button></div></form>'
    '<div class="plex-matches" id="plex-matches" aria-live="polite"></div></div></div></dialog>'
)
dialog = ('<dialog id="updates-dialog" aria-labelledby="updates-title">'
          '<div class="dialog-top"><h2 id="updates-title">Updates</h2>'
          '<button class="dialog-close" id="close-updates" aria-label="Close updates">×</button>'
          '</div></dialog>')
html = html.replace('<dialog id="show-dialog"', player + visualizer + equalizer + library + plex + dialog + '<dialog id="show-dialog"', 1)
# Supply the same filtered rows and freshly imported totals to the active skin.
for name, original, arguments, hook in [
    ('render', 'renderRows', 'resetPage', 'window.refreshMacTheme?.()'),
    ('renderDetail', 'renderDetailContents', 'id', 'window.refreshNightShift?.(); window.refreshMacLiveActions?.()'),
]:
    anchor = 'function ' + name + '('
    assert html.count(anchor) == 1, 'Expected catalog renderer: ' + name
    wrapper = f'function {name}({arguments}){{{original}({arguments}); {hook};}}\n'
    html = html.replace(anchor, wrapper + f'function {original}(', 1)
scripts = [mac / 'Themes/night-shift.js', mac / 'visualizer-art.js', mac / 'visualizer-tunnel.js',
           mac / 'visualizer-tunnel-fallback.js', mac / 'visualizer.js', mac / 'equalizer.js', mac / 'mac.js']
html = html.replace('</body>', ''.join('<script>' + path.read_text(encoding='utf-8') + '</script>' for path in scripts) + '</body>', 1)
html = html.replace('Ratings and catalog details are frozen at this snapshot.', 'Updates refresh this offline snapshot. Your library stays private.')
if args.windows:
    sys.path.insert(0, str(root / 'Windows App'))
    from prepare_windows import render_windows
    html = render_windows(html, root / 'Windows App', output)
(output / 'index.html').write_text(html, encoding='utf-8')
(output / 'catalog.json').write_bytes((root / 'catalog.json').read_bytes())
if not args.windows:
    (output / 'install-update.sh').write_bytes((root / 'macOS App/install-update.sh').read_bytes())
for name in (['NOTICE.md'] if args.windows else ['NOTICE.md', 'README.md']):
    (output / name).write_bytes((root / name).read_bytes())
