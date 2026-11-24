"""Verify the offline artwork and exercise the theme picker from the built Mac page."""
import base64
from html.parser import HTMLParser
import json
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory


class BundledPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.select_options = {name: [] for name in ('theme-choice', 'picture-choice', 'logo-choice')}
        self.ids = []
        self.classes = set()
        self.art = {}
        self.script = None
        self.scripts = []
        self.select_id = None
        self.template = None
        self.logos = []
        self.logo_links = []
        self.logo_images = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get('id'):
            self.ids.append(attrs['id'])
        self.classes.update(attrs.get('class', '').split())
        if tag == 'svg' and 'tool-logo' in attrs.get('class', '').split():
            self.logos.append(attrs)
        if tag == 'use':
            self.logo_links.append(attrs.get('href'))
        if tag == 'image':
            self.logo_images.append(attrs.get('href') or attrs.get('xlink:href'))
        if tag == 'select':
            self.select_id = attrs.get('id')
        if tag == 'option' and self.select_id in self.select_options:
            self.select_options[self.select_id].append(attrs['value'])
        if tag == 'template':
            self.template = attrs.get('id', '')
        if tag == 'img' and 'theme-art' in attrs.get('class', '').split():
            assert self.template not in self.art, 'Duplicate artwork in template'
            self.art[self.template] = attrs['src']
        if tag == 'script':
            self.script = []

    def handle_data(self, data):
        if self.script is not None:
            self.script.append(data)

    def handle_endtag(self, tag):
        if tag == 'select':
            self.select_id = None
        if tag == 'template':
            self.template = None
        if tag == 'script':
            self.scripts.append(''.join(self.script))
            self.script = None


# The packaged picker runs against a fresh catalog and native preference bridge
# on each launch. Moving an existing card keeps its pending update state.
FIXTURE = r'''
function assert(condition, message) {
  if (!condition) throw Error(message);
}
function launch(initial, initialPicture, initialLogo) {
  const state = {saved: initial, picture: initialPicture, logo: initialLogo,
                 location: 'inline', sent: [], art: null};
  const node = () => ({
    dataset: {}, innerHTML: '', hidden: false, children: [], text: '',
    get textContent() { return this.text; },
    set textContent(value) { this.text = value; this.children = []; },
    replaceChildren(...parts) {
      this.children = parts.filter(part => typeof part !== 'string');
      this.text = parts.filter(part => typeof part === 'string').join('');
    }
  });
  const ids = Object.fromEntries(requiredIDs.map(id => [id, node()]));
  ids['tool-logo'] = {viewBox: {baseVal: {width: 178, height: 71}}};
  ids['tool-logo-2006'] = {viewBox: {baseVal: {width: 930, height: 216}}};
  const picker = ids['theme-choice'];
  const pictures = ids['picture-choice'];
  const logos = ids['logo-choice'];
  for (const [select, values] of [[picker, themes], [pictures, pictureIDs], [logos, logoIDs]]) {
    select.options = values.map(value => ({value}));
    select.addEventListener = (event, handler) => { if (event === 'change') select.choose = handler; };
  }
  const original = ['A good night. A great recording.', 'Find your next live listen.',
                    'Explore the archive<br>Find it in Plexamp.'];
  const copy = Object.fromEntries(['.eyebrow', 'h1', 'p:last-child', '.theme-total', '.theme-years']
                                 .map(key => [key, node()]));
  copy['.eyebrow'].textContent = original[0];
  copy.h1.textContent = original[1];
  copy['p:last-child'].innerHTML = original[2];
  const updates = node();
  const dialog = ids['updates-dialog'];
  dialog.showModal = () => { dialog.open = true; };
  dialog.close = () => { dialog.open = false; };
  function move(section, location) {
    assert(section === updates, 'An update section was duplicated or lost');
    state.location = location;
  }
  dialog.append = element => move(element, 'dialog');
  const hero = node();
  function attributes(initialValues) {
    const values = {...initialValues};
    return {
      values,
      getAttribute: key => values[key],
      setAttribute: (key, value) => { values[key] = String(value); }
    };
  }
  function toolLogo(svgAttrs, useAttrs) {
    const svg = attributes(svgAttrs);
    const use = attributes(useAttrs);
    return {...svg, name: 'TOOL', querySelector: () => use, cloneNode: () => toolLogo(svg.values, use.values)};
  }
  const toolbarLogo = toolLogo({}, {href: '#tool-logo'});
  const liveLogos = () => [toolbarLogo, ...copy.h1.children, ...copy['.eyebrow'].children];
  const queries = {
    '.wordmark .tool-logo': toolbarLogo,
    '.hero': hero,
    '.hero-copy': {querySelector: key => copy[key]},
    '.hero-art': {querySelector: () => state.art, appendChild: el => { state.art = el; }},
    '.updates': updates,
    '.workspace': {before: el => move(el, 'inline')}
  };
  ids['total-shows'].textContent = '1,299';
  ids['year-span'].textContent = '1991–2026';
  for (const name of artwork) {
    ids[name] = {content: {cloneNode: () => ({name, remove: () => { state.art = null; }})}};
  }
  const document = {
    documentElement: node(),
    getElementById: key => ids[key] || null,
    querySelector: selector => queries[selector],
    querySelectorAll: selector => selector === '.tool-logo' ? liveLogos() : []
  };
  const window = {
    toolMac: {theme: initial, setTheme: id => { state.saved = id; },
              picture: initialPicture, setPicture: id => { state.picture = id; },
              logo: initialLogo, setLogo: id => { state.logo = id; }},
    webkit: {messageHandlers: {updates: {postMessage: action => state.sent.push(action)}}},
    refreshNightShift() {}
  };
  // PACKAGED_PICKER
  const titles = {
    'front-row': '', 'night-shift': 'DRIVE',
    graphite: original[1],
    'laser-grid': 'Signal index'
  };
  function checkTheme(id) {
    assert(document.documentElement.dataset.theme === id && picker.value === id, 'Picker mismatch: ' + id);
    assert(copy.h1.textContent.trim() === titles[id], 'Masthead mismatch: ' + id);
    const marks = copy.h1.children.filter(child => child.name === 'TOOL');
    assert(marks.length === Number(id === 'front-row' || id === 'night-shift'), 'Unexpected number of masthead logos: ' + id);
    assert(ids['picture-picker'].hidden === (id !== 'front-row'), 'Picture picker visibility: ' + id);
    assert(!logos.hidden && document.documentElement.dataset.logo === logos.value, 'Logo picker mismatch');
    for (const mark of liveLogos()) {
      assert(mark.querySelector('use').getAttribute('href') === (logos.value === 'classic' ? '#tool-logo' : '#tool-logo-2006'),
             'Wrong logo symbol: ' + id);
    }
    const picture = id === 'front-row' ? pictures.value : undefined;
    assert(hero.dataset.picture === picture,
           'Picture framing does not follow the selected theme: ' + id);
    const artId = 'art-' + (picture || id);
    const expectedArt = artwork.includes(artId) ? artId : null;
    assert((state.art && state.art.name) === expectedArt, 'Wrong artwork: ' + id);
    const graphite = id === 'graphite';
    assert(ids['show-updates'].hidden === graphite, 'Wrong updates trigger visibility: ' + id);
    assert(state.location === (graphite ? 'inline' : 'dialog'), 'Wrong updates location: ' + id);
    if (graphite) {
      assert(copy['.eyebrow'].textContent === original[0] &&
             copy['p:last-child'].innerHTML === original[2], 'Graphite masthead lost its original copy');
    }
    for (const [key, source] of [['.theme-total', 'total-shows'], ['.theme-years', 'year-span']]) {
      assert(copy[key].textContent === ids[source].textContent, 'Stale catalog statistic: ' + key);
    }
  }
  function select(id) {
    picker.value = id;
    picker.choose();
    checkTheme(id);
    assert(state.saved === id, 'Native preference was not saved: ' + id);
  }
  return {checkTheme, select, state, ids, window};
}
for (const retired of ['negative-space', 'parallax', 'nerve', 'umbra', 'unknown-theme', undefined]) {
  const restored = launch(retired);
  restored.checkTheme('front-row');
  if (retired) assert(restored.state.saved === 'front-row', 'Retired preference was not migrated: ' + retired);
}
for (const retired of ['plasma-bloom', 'lightfall', 'violet-hour', 'solar-flare']) {
  const migrated = launch(retired, 'governors-ball', '2006');
  migrated.checkTheme('laser-grid');
  assert(migrated.state.saved === 'laser-grid', 'Retired concert theme was not migrated: ' + retired);
  const {saved, picture, logo} = migrated.state;
  assert(picture === 'governors-ball' && logo === '2006',
         'Retiring a concert theme changed another preference: ' + retired);
  const reopened = launch(saved, picture, logo);
  reopened.checkTheme('laser-grid');
  assert(reopened.ids['logo-choice'].value === '2006', 'Logo lost after concert theme migration');
  reopened.select('front-row');
  assert(reopened.state.art.name === 'art-governors-ball', 'Front Row picture lost after concert theme migration');
}
const session = launch('front-row');
assert(session.ids['logo-choice'].value === 'classic', 'Upgrading lost the existing logo');
function choose(session, selector, value) {
  const control = session.ids[selector];
  control.value = value;
  control.choose();
}
for (const theme of themes) {
  session.select(theme);
  for (const logo of ['2006', 'classic', '2006']) {
    const previousArt = session.state.art;
    choose(session, 'logo-choice', logo);
    session.checkTheme(theme);
    assert(session.state.logo === logo, 'Native logo preference was not written');
    assert(session.state.art === previousArt && session.state.saved === theme, 'Changing the logo disturbed the theme');
  }
}
session.select('front-row');
choose(session, 'picture-choice', 'governors-ball');
const relaunch = launch(session.state.saved, session.state.picture, session.state.logo);
relaunch.checkTheme('front-row');
assert(relaunch.state.art.name === 'art-governors-ball' && relaunch.ids['logo-choice'].value === '2006',
       'Front Row artwork or logo lost on restart');
for (const retired of ['negative-space', 'index-blue']) {
  const migratedFrontRow = launch(retired, 'governors-ball', '2006');
  migratedFrontRow.checkTheme('front-row');
  assert(migratedFrontRow.state.saved === 'front-row', 'Fallback was not saved: ' + retired);
  assert(migratedFrontRow.state.art.name === 'art-governors-ball' && migratedFrontRow.ids['logo-choice'].value === '2006',
         'Retired theme migration changed the chosen picture or logo: ' + retired);
}
const invalid = launch('front-row', 'governors-ball', 'unknown-logo');
assert(invalid.ids['logo-choice'].value === 'classic', 'Invalid saved logo must fall back to Classic');
session.select('front-row');
for (const oldValue of ['prism-rain', 'tape-vault', undefined, '', 'original-photo', 42]) {
  const opened = launch('front-row', oldValue);
  opened.checkTheme('front-row');
  if (oldValue === 'prism-rain' || oldValue === 'tape-vault') {
    assert(opened.state.picture === 'blue-silhouette', 'Retired saved picture was not migrated: ' + oldValue);
    const otherTheme = launch('night-shift', oldValue);
    otherTheme.checkTheme('night-shift');
    assert(otherTheme.state.saved === 'night-shift', 'Migrating a retired picture changed the theme');
    otherTheme.select('front-row');
    assert(otherTheme.ids['picture-choice'].value === 'blue-silhouette', 'Fallback lost during theme switch');
  }
  assert(opened.ids['picture-choice'].value === 'blue-silhouette' &&
         opened.state.art.name === 'art-blue-silhouette', 'Default picture did not migrate');
}
for (const id of ['governors-ball', 'blue-silhouette', 'governors-ball']) {
  const pictures = session.ids['picture-choice'];
  pictures.value = id;
  pictures.choose();
  session.checkTheme('front-row');
  assert(session.state.picture === id && session.state.art.name === 'art-' + id, 'Picture selection: ' + id);
  session.select('night-shift');
  session.select('front-row');
  assert(pictures.value === id && session.state.art.name === 'art-' + id, 'Picture lost after theme switch');
  const reopened = launch('front-row', session.state.picture);
  reopened.checkTheme('front-row');
  assert(reopened.state.art.name === 'art-' + id, 'Picture lost after reopening');
}
session.ids['show-updates'].onclick();
assert(session.ids['updates-dialog'].open, 'Update dialog did not open');
session.ids['catalog-update'].onclick();
session.ids['app-update'].onclick();
assert(session.state.sent.join(',') === 'catalog,app', 'Update actions did not reach native bridge');
session.ids['close-updates'].onclick();
assert(!session.ids['updates-dialog'].open, 'Update dialog did not close');
session.window.macUpdateState('app', 'Version ready', 'Restart to update', false, true);
session.ids['total-shows'].textContent = '1,304';
session.ids['year-span'].textContent = '1991–2027';
session.window.refreshMacTheme();
for (const id of themes) {
  session.select(id);
  assert(session.ids['app-update'].textContent === 'Restart to update', 'Theme switch lost ready update');
  launch(session.state.saved).checkTheme(id);
}
'''

def main():
    mac = Path(__file__).resolve().parents[1]
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else mac / 'dist/Tool Drive Offline.app/Contents/Resources/index.html'
    page = BundledPage()
    page.feed(path.read_text(encoding='utf-8'))
    themes = ['front-row', 'night-shift', 'graphite', 'laser-grid']
    assert page.ids.count('tool-logo') == 1, 'Expected one shared TOOL logo symbol'
    assert page.ids.count('tool-logo-2006') == 1, 'Expected one 2006 TOOL logo symbol'
    assert len(page.logos) == 1 and page.logos[0].get('aria-label') == 'TOOL', 'Missing accessible toolbar logo'
    assert '#tool-logo' in page.logo_links, 'Missing embedded logo reference'
    logo_mask = (mac / 'Themes/tool-logo-2006.png').read_bytes()
    embedded_mask = 'data:image/png;base64,' + base64.b64encode(logo_mask).decode('ascii')
    assert embedded_mask in page.logo_images, '2006 artwork must be embedded for offline use'
    assert page.select_options['theme-choice'] == themes, 'Unexpected theme list or default'
    pictures = ['blue-silhouette', 'governors-ball']
    logos = ['classic', '2006']
    assert page.select_options['picture-choice'] == pictures, 'Unexpected Front Row picture list or default'
    assert page.select_options['logo-choice'] == logos and 'sleeve-choice' not in page.ids
    required_ids = ['theme-choice', 'picture-choice', 'picture-picker', 'logo-choice',
                    'show-updates', 'close-updates', 'updates-dialog',
                    'total-shows', 'year-span'] + [
        f'{kind}-{suffix}' for kind in ('catalog', 'app') for suffix in ('update', 'status', 'card')]
    assert all(page.ids.count(id_) == 1 for id_ in required_ids), 'Missing or duplicated integration control'
    assert {'hero-art', 'hero-copy', 'theme-total', 'theme-years', 'updates', 'workspace'} <= page.classes
    expected_art = pictures + ['laser-grid']
    assert set(page.art) == {'art-' + name for name in expected_art}, 'Unexpected offline artwork'
    for name, src in page.art.items():
        prefix, payload = src.split(',', 1)
        data = base64.b64decode(payload, validate=True)
        assert prefix == 'data:image/jpeg;base64' and data.startswith(b'\xff\xd8'), 'Invalid concert photo'
        assert data == (mac / 'Themes' / (name[4:] + '.jpg')).read_bytes(), 'Picture differs from source'
    scripts = [s for s in page.scripts if 'theme-choice' in s and 'setTheme' in s]
    assert len(scripts) == 1, 'Missing theme script'
    shell = Path('/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc')
    engine = str(shell) if shell.exists() else shutil.which('node')
    if engine is None:
        raise SystemExit('Run this check using system JavaScriptCore or Node.js.')
    with TemporaryDirectory() as tmp:
        test = Path(tmp) / 'picker.js'
        test.write_text('const themes = ' + json.dumps(themes) + ';\n'
                        'const pictureIDs = ' + json.dumps(pictures) + ';\n'
                        'const logoIDs = ' + json.dumps(logos) + ';\n'
                        'const artwork = ' + json.dumps(list(page.art)) + ';\n'
                        'const requiredIDs = ' + json.dumps(required_ids) + ';\n' +
                        FIXTURE.replace('// PACKAGED_PICKER', scripts[0]))
        subprocess.run([engine, str(test)], check=True)
    print('PASS independent theme, logo and picture choices, offline artwork, preference restoration, live counts and update controls')


if __name__ == '__main__':
    main()
