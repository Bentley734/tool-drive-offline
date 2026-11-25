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
        self.select_options = {name: [] for name in ('theme-choice', 'picture-choice', 'logo-choice', 'glass-wallpaper-picker')}
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
function launch(initial, initialPicture, initialLogo, glassEnabled, previousTheme = 'front-row', initialWallpaper,
                initialWallpaperChoice = initialWallpaper, nativeToolbar = true) {
  const state = {saved: initial, picture: initialPicture, logo: initialLogo, wallpaper: initialWallpaper,
                 wallpaperChoice: initialWallpaperChoice, wallpaperRequests: [], preference: glassEnabled, lastStandard: previousTheme,
                 location: 'inline', sent: [], art: null};
  const node = () => ({
    dataset: {}, innerHTML: '', hidden: false, children: [], text: '', listeners: {},
    addEventListener(type, listener) { (this.listeners[type] ||= []).push(listener); },
    dispatchEvent(event) { for (const handler of this.listeners[event.type] || []) handler(event); },
    choose() { this.dispatchEvent({type: 'change'}); },
    focus() {},
    get textContent() { return this.text; },
    set textContent(value) { this.text = value; this.children = []; },
    replaceChildren(...parts) {
      this.children = parts.filter(part => typeof part !== 'string');
      this.text = parts.filter(part => typeof part === 'string').join('');
    }
  });
  const ids = Object.fromEntries(requiredIDs.map(id => [id, node()]));
  ids['mac-visualizer'].hidden = true;
  ids['liquid-glass-control'].hidden = true;
  class Event { constructor(type) { this.type = type; } }
  class MutationObserver { constructor(sync) { state.syncChrome = sync; } observe() {} }
  ids['tool-logo'] = {viewBox: {baseVal: {width: 178, height: 71}}};
  ids['tool-logo-2006'] = {viewBox: {baseVal: {width: 930, height: 216}}};
  const picker = ids['theme-choice'];
  const pictures = ids['picture-choice'];
  const logos = ids['logo-choice'];
  const wallpapers = ids['glass-wallpaper-picker'];
  for (const [select, values] of [[picker, themes], [pictures, pictureIDs], [logos, logoIDs], [wallpapers, wallpaperChoices]]) {
    select.options = values.map(value => ({value}));
  }
  const glassOption = {value: 'liquid-glass', parentNode: null, remove() {
    picker.options = picker.options.filter(option => option !== this);
    this.parentNode = null;
  }};
  ids['glass-theme-option'].content = {firstElementChild: glassOption};
  picker.append = option => {
    assert(option === glassOption && !picker.options.includes(option), 'Duplicate exclusive theme');
    picker.options.push(option);
    option.parentNode = picker;
  };
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
  dialog.close = () => { dialog.open = false; dialog.onclose?.(); };
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
    querySelector: selector => selector === 'dialog[open]' ? (dialog.open ? dialog : null) : queries[selector],
    querySelectorAll: selector => selector === '.tool-logo' ? liveLogos() : []
  };
  const window = {
    toolMac: {theme: initial, lastStandardTheme: previousTheme, setTheme: id => {
                state.saved = id;
                if (themes.includes(id)) state.lastStandard = id;
              },
              picture: initialPicture, setPicture: id => { state.picture = id; },
              wallpaper: initialWallpaper, wallpaperChoice: initialWallpaperChoice,
              setWallpaper: id => {
                state.wallpaperRequests.push(id);
                state.wallpaperChoice = id;
                if (id !== 'shuffle') {
                  state.wallpaper = id;
                  window.macLiquidGlassEnabled(state.preference, state.saved, id, id);
                }
              },
              logo: initialLogo, setLogo: id => { state.logo = id; },
              liquidGlassAvailable: glassEnabled !== undefined, liquidGlassEnabled: glassEnabled === true, nativeGlassToolbar: nativeToolbar,
              glassChrome: chrome => { state.chrome = chrome; },
              setLiquidGlass: on => {
                state.preference = on;
                if (!on && state.saved === 'liquid-glass') state.saved = state.lastStandard;
                window.macLiquidGlassEnabled(on, state.saved);
              }},
    webkit: {messageHandlers: {updates: {postMessage: action => state.sent.push(action)}}},
    refreshNightShift() {}
  };
  // PACKAGED_PICKER
  const titles = {
    'front-row': '', 'night-shift': 'DRIVE',
    graphite: original[1],
    'laser-grid': 'Signal index', 'liquid-glass': ''
  };
  function checkTheme(id) {
    assert(document.documentElement.dataset.theme === id && picker.value === id, 'Picker mismatch: ' + id);
    assert(copy.h1.textContent.trim() === titles[id], 'Masthead mismatch: ' + id);
    const marks = copy.h1.children.filter(child => child.name === 'TOOL');
    assert(marks.length === Number(['front-row', 'night-shift', 'liquid-glass'].includes(id)), 'Unexpected number of masthead logos: ' + id);
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
  return {checkTheme, select, state, ids, window, root: document.documentElement};
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
assert(session.ids['liquid-glass-control'].hidden && !session.state.chrome, 'Older macOS should retain standard controls');
const hasGlassTheme = session => session.ids['theme-choice'].options.some(option => option.value === 'liquid-glass');
assert(!hasGlassTheme(session), 'Exclusive option must be absent on older macOS');
const exclusive = launch('night-shift', 'governors-ball', '2006', true, 'night-shift');
assert(hasGlassTheme(exclusive), 'Enabled mode should offer the exclusive theme');
exclusive.window.macGlassAction('theme', 'liquid-glass');
exclusive.checkTheme('liquid-glass');
assert(exclusive.state.saved === 'liquid-glass' && exclusive.state.chrome.theme === 'liquid-glass',
       'Glass theme must be selected and saved from the real menu');
assert(exclusive.root.dataset.glassWallpaper === wallpaperIDs[0], 'New installations start at Crimson Current');
for (const id of wallpaperIDs) {
  exclusive.window.macGlassAction('wallpaper', id);
  assert(exclusive.root.dataset.glassWallpaper === id && exclusive.state.wallpaper === id &&
         exclusive.state.chrome.wallpaper === id, 'Wallpaper and native menu must agree: ' + id);
  assert(exclusive.state.picture === 'governors-ball' && exclusive.state.logo === '2006', 'Wallpaper changed another choice');
}
exclusive.window.macGlassAction('wallpaper', 'unknown-wallpaper');
assert(exclusive.root.dataset.glassWallpaper === 'scarlet-star', 'Invalid action replaced selected wallpaper');
const recoveredWallpaper = launch('liquid-glass', 'governors-ball', '2006', true, 'night-shift', 'unknown-wallpaper');
assert(recoveredWallpaper.root.dataset.glassWallpaper === wallpaperIDs[0], 'Invalid saved wallpaper needs a valid fallback');
const shuffleSession = launch('liquid-glass', 'governors-ball', '2006', true, 'night-shift', 'emerald-lasers', 'shuffle');
function assertShuffle(view, actual) {
  assert(wallpaperIDs.includes(actual) && view.root.dataset.glassWallpaper === actual,
         'Only a real photo can be rendered while shuffling');
  assert(view.ids['glass-wallpaper-picker'].value === 'shuffle' && view.state.chrome.wallpaperChoice === 'shuffle' &&
         view.state.chrome.wallpaper === actual, 'Shuffle checkmark and rendered photo must be reported separately');
}
assertShuffle(shuffleSession, 'emerald-lasers');
shuffleSession.window.macLiquidGlassEnabled(true, 'liquid-glass', 'blue-heptagram', 'shuffle');
assertShuffle(shuffleSession, 'blue-heptagram');
shuffleSession.window.macLiquidGlassEnabled(true, 'liquid-glass', 'blue-heptagram', 'shuffle');
assert(shuffleSession.state.wallpaperRequests.length === 0, 'Native hydration should not write a new wallpaper');
shuffleSession.window.macGlassAction('wallpaper', 'prism-beams');
assert(shuffleSession.root.dataset.glassWallpaper === 'prism-beams' &&
       shuffleSession.state.chrome.wallpaperChoice === 'prism-beams', 'Choosing a fixed photo should leave Shuffle');
shuffleSession.window.macGlassAction('wallpaper', 'shuffle');
assert(shuffleSession.state.wallpaperRequests.at(-1) === 'shuffle' &&
       wallpaperIDs.includes(shuffleSession.root.dataset.glassWallpaper), 'Waiting for native Shuffle must retain a real photo');
shuffleSession.window.macLiquidGlassEnabled(true, 'liquid-glass', 'magenta-silhouette', 'shuffle');
assertShuffle(shuffleSession, 'magenta-silhouette');
assert(shuffleSession.state.picture === 'governors-ball' && shuffleSession.state.logo === '2006',
       'Shuffle changed the independent logo or Front Row picture');
shuffleSession.window.macLiquidGlassEnabled(true, 'night-shift', 'magenta-silhouette', 'shuffle');
assert(!shuffleSession.root.dataset.glassWallpaper, 'Standard theme received the shuffled photo');
shuffleSession.window.macLiquidGlassEnabled(true, 'liquid-glass', 'magenta-silhouette', 'shuffle');
assertShuffle(shuffleSession, 'magenta-silhouette');
const invalidEffective = launch('liquid-glass', undefined, undefined, true, 'front-row', 'shuffle', 'shuffle');
assert(wallpaperIDs.includes(invalidEffective.root.dataset.glassWallpaper), 'Shuffle cannot be used as an image ID');
const restoredExclusive = launch(exclusive.state.saved, exclusive.state.picture, exclusive.state.logo, true, 'night-shift', exclusive.state.wallpaper);
assert(restoredExclusive.root.dataset.glassWallpaper === 'scarlet-star', 'Wallpaper must survive relaunch');
restoredExclusive.checkTheme('liquid-glass');
restoredExclusive.ids['liquid-glass-choice'].checked = false;
restoredExclusive.ids['liquid-glass-choice'].choose();
restoredExclusive.checkTheme('night-shift');
assert(!hasGlassTheme(restoredExclusive), 'Turning glass off must remove the theme');
restoredExclusive.ids['liquid-glass-choice'].checked = true;
restoredExclusive.ids['liquid-glass-choice'].choose();
restoredExclusive.checkTheme('night-shift');
assert(hasGlassTheme(restoredExclusive) && restoredExclusive.state.picture === 'governors-ball' &&
       restoredExclusive.state.logo === '2006', 'Returning to glass must preserve all appearance choices');
assert(!restoredExclusive.root.dataset.glassWallpaper, 'A standard theme acquired the glass wallpaper');
restoredExclusive.window.macGlassAction('wallpaper', 'prism-beams');
assert(restoredExclusive.state.wallpaper === 'scarlet-star', 'Inactive wallpaper menu changed the saved choice');
restoredExclusive.window.macGlassAction('theme', 'front-row');
restoredExclusive.window.macGlassAction('picture', 'blue-silhouette');
restoredExclusive.window.macGlassAction('theme', 'liquid-glass');
assert(restoredExclusive.root.dataset.glassWallpaper === 'scarlet-star' && restoredExclusive.state.picture === 'blue-silhouette',
       'Front Row picture and Liquid Glass wallpaper must remain independent');
const staleExclusive = launch('liquid-glass', 'blue-silhouette', 'classic', false, 'laser-grid');
staleExclusive.checkTheme('laser-grid');
assert(!hasGlassTheme(staleExclusive), 'Stale settings must never offer a standard Liquid Glass variant');
const openUpdates = launch('graphite', 'blue-silhouette', 'classic', true, 'graphite');
openUpdates.window.macGlassAction('theme', 'liquid-glass');
openUpdates.ids['show-updates'].onclick();
openUpdates.ids['liquid-glass-choice'].checked = false;
openUpdates.ids['liquid-glass-choice'].choose();
assert(openUpdates.state.location === 'dialog', 'Changing appearance must preserve controls in an open Updates dialog');
openUpdates.ids['updates-dialog'].close();
openUpdates.checkTheme('graphite');
const legacy = launch('liquid-glass', undefined, undefined, true, 'front-row', 'crimson-current', undefined, false);
legacy.checkTheme('liquid-glass');
assert(legacy.root.dataset.nativeGlass === 'false' && !legacy.ids['glass-wallpaper-control'].hidden,
       'Earlier macOS needs the web wallpaper picker in Liquid Glass');
assert(!legacy.state.chrome, 'Earlier macOS cannot display a floating native toolbar');
legacy.ids['glass-wallpaper-picker'].value = 'prism-beams';
legacy.ids['glass-wallpaper-picker'].choose();
assert(legacy.root.dataset.glassWallpaper === 'prism-beams', 'Earlier macOS wallpaper selector must work');
legacy.select('laser-grid');
assert(legacy.ids['glass-wallpaper-control'].hidden, 'Hide the glass wallpaper selector on standard themes');
const glass = launch('front-row', 'governors-ball', '2006', true);
assert(glass.state.chrome.visible && glass.state.chrome.picture === 'governors-ball', 'Restore glass on launch');
for (const theme of themes) {
  glass.window.macGlassAction('theme', theme);
  assert(glass.state.saved === theme && glass.state.chrome.theme === theme && glass.state.chrome.logo === '2006',
         'Native Appearance menu and theme must agree: ' + theme);
}
glass.window.macGlassAction('theme', 'graphite');
glass.ids['show-updates'].onclick();
glass.state.syncChrome();
assert(!glass.state.chrome.visible && glass.state.location === 'dialog', 'Graphite update dialog needs its controls');
glass.ids['updates-dialog'].close();
glass.state.syncChrome();
assert(glass.state.chrome.visible && glass.state.location === 'inline', 'Restore toolbar and Graphite update cards');
glass.ids['mac-visualizer'].hidden = false;
glass.state.syncChrome();
assert(!glass.state.chrome.visible, 'Native toolbar must yield to the visualizer');
glass.ids['liquid-glass-choice'].checked = false;
glass.ids['liquid-glass-choice'].choose();
assert(glass.state.preference === false && glass.state.saved === 'graphite' && glass.state.picture === 'governors-ball',
       'Switching off glass must preserve theme and photo');
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
    html = path.read_text(encoding='utf-8')
    page.feed(html)
    themes = ['front-row', 'night-shift', 'graphite', 'laser-grid']
    assert page.ids.count('tool-logo') == 1, 'Expected one shared TOOL logo symbol'
    assert page.ids.count('tool-logo-2006') == 1, 'Expected one 2006 TOOL logo symbol'
    assert len(page.logos) == 1 and page.logos[0].get('aria-label') == 'TOOL', 'Missing accessible toolbar logo'
    assert '#tool-logo' in page.logo_links, 'Missing embedded logo reference'
    logo_mask = (mac / 'Themes/tool-logo-2006.png').read_bytes()
    embedded_mask = 'data:image/png;base64,' + base64.b64encode(logo_mask).decode('ascii')
    assert embedded_mask in page.logo_images, '2006 artwork must be embedded for offline use'
    assert page.select_options['theme-choice'] == themes, 'Unexpected theme list or default'
    wallpaper_manifest = json.loads((path.parent / 'glass-wallpapers.json').read_text())
    assert wallpaper_manifest == json.loads((mac / 'Themes/glass-wallpapers.json').read_text())
    wallpapers = [item['id'] for item in wallpaper_manifest]
    assert len(set(wallpapers)) == len(wallpapers) == 9 and wallpapers[0] == 'crimson-current'
    assert page.select_options['glass-wallpaper-picker'] == [*wallpapers, 'shuffle']
    assert '[data-glass-wallpaper="shuffle"]' not in html and 'Wallpapers/shuffle.jpg' not in html
    assert 'glass-fold' not in html
    for item in wallpaper_manifest:
        filename = item['file']
        data = (path.parent / 'Wallpapers' / filename).read_bytes()
        assert data.startswith(b'\xff\xd8') and data == (mac / 'Themes/Wallpapers' / filename).read_bytes()
        rule = (f':root[data-theme="liquid-glass"][data-liquid-glass="true"][data-glass-wallpaper="{item["id"]}"] '
                f'{{--glass-wallpaper-image: url("Wallpapers/{filename}"); }}')
        assert rule in html, f'Missing scoped offline wallpaper {filename}'
    pictures = ['blue-silhouette', 'governors-ball']
    logos = ['classic', '2006']
    assert page.select_options['picture-choice'] == pictures, 'Unexpected Front Row picture list or default'
    assert page.select_options['logo-choice'] == logos and 'sleeve-choice' not in page.ids
    required_ids = ['glass-wallpaper-control', 'glass-wallpaper-picker', 'theme-choice', 'picture-choice', 'picture-picker', 'logo-choice',
                    'liquid-glass-choice', 'liquid-glass-control', 'glass-theme-option', 'show-plex', 'show-library', 'mac-visualizer',
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
                        'const wallpaperIDs = ' + json.dumps(wallpapers) + ';\n'
                        'const wallpaperChoices = ' + json.dumps(page.select_options['glass-wallpaper-picker']) + ';\n'
                        'const logoIDs = ' + json.dumps(logos) + ';\n'
                        'const artwork = ' + json.dumps(list(page.art)) + ';\n'
                        'const requiredIDs = ' + json.dumps(required_ids) + ';\n' +
                        FIXTURE.replace('// PACKAGED_PICKER', scripts[0]))
        subprocess.run([engine, str(test)], check=True)
        host = next(s for s in page.scripts if 'window.mountMacVisualizer = function' in s)
        fixture = (mac / 'tests/test-visualizer.js').read_text()
        test.write_text(fixture.replace('// PLAYER_HOST', host))
        subprocess.run([engine, str(test)], check=True)
    print('PASS tunnel display cadence, context loss, restoration and switching presets while paused')
    print('PASS independent Liquid Glass state, native theme actions, modal and visualizer visibility')
    print('PASS all nine packaged concert wallpapers, menu selection, scope and independent persistence')
    print('PASS Shuffle menu checkmark, rendered photo, native synchronization and standard-theme isolation')
    print('PASS exclusive theme selection, offline artwork, saved theme recovery and mode gating')
    print('PASS independent theme, logo and picture choices, offline artwork, preference restoration, live counts and update controls')


if __name__ == '__main__':
    main()
