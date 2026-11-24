(() => {
  const themePicker = document.getElementById('theme-choice');
  const picturePicker = document.getElementById('picture-choice');
  const pictureControl = document.getElementById('picture-picker');
  const logoPicker = document.getElementById('logo-choice');
  const hero = document.querySelector('.hero');
  const heroArt = document.querySelector('.hero-art');

  const logo = document.querySelector('.wordmark .tool-logo');
  const heroCopy = document.querySelector('.hero-copy');
  const eyebrow = heroCopy.querySelector('.eyebrow');
  const heading = heroCopy.querySelector('h1');
  const subtitle = heroCopy.querySelector('p:last-child');
  const graphiteCopy = [eyebrow.textContent, heading.textContent, subtitle.innerHTML];
  const copy = {
    'front-row': ['Live recordings', 'TOOL', 'The live archive'],
    'night-shift': ['Live recording index', 'TOOL DRIVE', ''],
    graphite: graphiteCopy,
    'laser-grid': ['Live recordings', 'Signal index', '']
  };
  const total = heroCopy.querySelector('.theme-total');
  const years = heroCopy.querySelector('.theme-years');
  const updates = document.querySelector('.updates');
  const workspace = document.querySelector('.workspace');
  const updateDialog = document.getElementById('updates-dialog');
  const updateButton = document.getElementById('show-updates');
  updateButton.onclick = () => updateDialog.showModal();
  document.getElementById('close-updates').onclick = () => updateDialog.close();

  window.refreshMacTheme = () => {
    total.textContent = document.getElementById('total-shows').textContent;
    years.textContent = document.getElementById('year-span').textContent;
    window.refreshNightShift();
  };

  function availableValue(picker, id) {
    return Array.from(picker.options).some(option => option.value === id) ? id : picker.options[0].value;
  }

  function applyLogo(id) {
    const variant = availableValue(logoPicker, id);
    const symbolId = variant === '2006' ? 'tool-logo-2006' : 'tool-logo';
    const {width, height} = document.getElementById(symbolId).viewBox.baseVal;
    logoPicker.value = variant;
    document.documentElement.dataset.logo = variant;
    for (const mark of document.querySelectorAll('.tool-logo')) {
      mark.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
      mark.querySelector('use').setAttribute('href', '#' + symbolId);
    }
  }

  function showArt() {
    const theme = themePicker.value;
    const id = theme === 'front-row' ? picturePicker.value : theme;
    if (id !== theme) hero.dataset.picture = id;
    else delete hero.dataset.picture;
    const previous = heroArt.querySelector('.theme-art');
    if (previous) previous.remove();
    const template = document.getElementById('art-' + id);
    if (template) heroArt.appendChild(template.content.cloneNode(true));
  }

  function applyTheme(id) {
    const theme = availableValue(themePicker, id);
    themePicker.value = theme;
    const [label, title, description] = copy[theme];
    eyebrow.textContent = label;
    heading.textContent = title;
    if (theme === 'front-row') heading.replaceChildren(logo.cloneNode(true));
    if (theme === 'night-shift') heading.replaceChildren(logo.cloneNode(true), ' DRIVE');
    subtitle.innerHTML = description;
    const graphite = theme === 'graphite';
    updateButton.hidden = graphite;
    if (graphite) workspace.before(updates);
    else updateDialog.append(updates);
    document.documentElement.dataset.theme = theme;
    pictureControl.hidden = theme !== 'front-row';
    showArt();
    window.refreshMacTheme();
  }

  picturePicker.value = availableValue(picturePicker, window.toolMac.picture);
  if (window.toolMac.picture && window.toolMac.picture !== picturePicker.value) {
    window.toolMac.setPicture(picturePicker.value);
  }
  picturePicker.addEventListener('change', () => {
    showArt();
    window.toolMac.setPicture(picturePicker.value);
  });
  applyLogo(window.toolMac.logo);
  if (window.toolMac.logo && logoPicker.value !== window.toolMac.logo) {
    window.toolMac.setLogo(logoPicker.value);
  }
  logoPicker.addEventListener('change', () => {
    applyLogo(logoPicker.value);
    window.toolMac.setLogo(logoPicker.value);
  });
  const retiredPhotoThemes = ['plasma-bloom', 'lightfall', 'violet-hour', 'solar-flare'];
  applyTheme(retiredPhotoThemes.includes(window.toolMac.theme) ? 'laser-grid' : window.toolMac.theme);
  if (window.toolMac.theme && themePicker.value !== window.toolMac.theme) {
    window.toolMac.setTheme(themePicker.value);
  }
  themePicker.addEventListener('change', () => {
    applyTheme(themePicker.value);
    window.toolMac.setTheme(themePicker.value);
  });

  const post = action => window.webkit.messageHandlers.updates.postMessage(action);
  document.getElementById('catalog-update').onclick = () => post('catalog');
  document.getElementById('app-update').onclick = () => post('app');
  window.macUpdateState = (kind, text, button, busy, ready) => {
    document.getElementById(kind + '-status').textContent = text;
    document.getElementById(kind + '-update').textContent = button;
    if (kind === 'app') {
      updateButton.dataset.ready = String(ready);
      updateButton.textContent = ready ? 'Update ready' : 'Updates';
    }
    const card = document.getElementById(kind + '-card');
    card.dataset.busy = String(busy); card.dataset.ready = String(ready);
  };
})();

(() => {
  const player = document.getElementById('mac-player');
  const libraryDialog = document.getElementById('library-dialog');
  if (!player || !libraryDialog) return;

  const liveLinks = new Map();
  const pendingLiveShows = new Set();
  const savedSourceIDs = new Set();
  const downloadStates = new Map();
  let playerState = {visible: false, status: 'idle', tracks: [], trackIndex: -1};
  let libraryState = {loading: false, error: '', items: []};
  let plexState = {status: 'disconnected', servers: [], libraries: [], matches: []};
  let trackSignature = '';

  const byID = id => document.getElementById(id);
  const playerTitle = byID('mac-player-title');
  const playerContext = byID('mac-player-context');
  const playerStatus = byID('mac-player-status');
  const playerToggle = byID('mac-player-toggle');
  const playerPrevious = byID('mac-player-previous');
  const playerNext = byID('mac-player-next');
  const playerSeek = byID('mac-player-seek');
  const playerElapsed = byID('mac-player-elapsed');
  const playerDuration = byID('mac-player-duration');
  const tracklistToggle = byID('mac-player-tracklist');
  const tracklistPanel = byID('mac-tracklist-panel');
  const tracklistPosition = byID('mac-tracklist-position');
  const catalogToolbar = document.querySelector('.topbar');
  const savedPosition = window.toolMac.tracklistPosition;
  tracklistPosition.value = ['left', 'right'].includes(savedPosition) ? savedPosition : 'bottom';
  const playerTracks = byID('mac-player-tracks');
  const libraryStatus = byID('library-status');
  const libraryDownloads = byID('library-downloads');
  const libraryList = byID('library-list');
  const plexDialog = byID('plex-dialog');
  const plexStatusTitle = byID('plex-status-title');
  const plexStatusMessage = byID('plex-status-message');
  const plexBrowser = byID('plex-browser');
  const plexServer = byID('plex-server');
  const plexLibrary = byID('plex-library');
  const plexSearch = byID('plex-search');
  const plexMatches = byID('plex-matches');

  function bridge(name, payload) {
    const handler = window.toolMac && window.toolMac[name];
    if (typeof handler !== 'function') return false;
    handler(payload);
    return true;
  }

  function escaped(value) {
    return String(value ?? '').replace(/[&<>"']/g, character => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    })[character]);
  }

  function number(value, fallback = 0) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  }

  function formatTime(value) {
    const seconds = Math.max(0, Math.floor(number(value)));
    return Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
  }

  function formatBytes(value) {
    let bytes = Math.max(0, number(value));
    if (!bytes) return '';
    const units = ['B', 'KB', 'MB', 'GB'];
    let unit = 0;
    while (bytes >= 1024 && unit < units.length - 1) { bytes /= 1024; unit += 1; }
    return (bytes >= 10 || unit === 0 ? bytes.toFixed(0) : bytes.toFixed(1)) + ' ' + units[unit];
  }

  function sourcePayload(card) {
    return {
      showId: number(card.dataset.showId),
      date: card.dataset.showDate,
      venue: card.dataset.showVenue,
      sourceId: number(card.dataset.sourceId),
      version: card.dataset.sourceVersion
    };
  }

  function addSourceButton(row, label, action, options = {}) {
    const button = document.createElement('button');
    button.type = 'button';
    button.textContent = label;
    button.className = options.primary ? 'primary' : '';
    button.disabled = Boolean(options.disabled);
    if (options.title) button.title = options.title;
    button.addEventListener('click', action);
    row.appendChild(button);
    return button;
  }

  function renderSourceActions() {
    const cards = [...document.querySelectorAll('.source-card[data-source-id]')];
    for (const card of cards) {
      const payload = sourcePayload(card);
      const sourceID = String(payload.sourceId);
      const onDrive = String(card.dataset.sourceStatus).toLowerCase() === 'otd';
      const download = downloadStates.get(sourceID);
      const link = liveLinks.get(sourceID);
      let row = card.querySelector('.mac-source-actions');
      if (!row) {
        row = document.createElement('div');
        row.className = 'mac-source-actions';
        card.appendChild(row);
      }
      row.replaceChildren();

      addSourceButton(row, 'Stream', () => {
        bridge('player', {action: 'load', ...payload});
      }, {
        primary: onDrive,
        disabled: !onDrive,
        title: onDrive ? 'Stream this recording' : 'Streaming is unavailable for this source'
      });

      addSourceButton(row, 'Play from Plex', () => {
        bridge('plex', {action: 'play', ...payload});
      }, {
        disabled: !plexLibraryReady(),
        title: plexLibraryReady() ? 'Play this recording from your selected Plex library'
          : plexState.status === 'connected' ? 'Choose a music library in the Plex panel first'
          : 'Connect Plex from the toolbar first'
      });

      if (link && link.downloadAvailable) {
        addSourceButton(row, 'Open download', () => {
          bridge('live', {action: 'openDownload', sourceId: payload.sourceId});
        });
      }

      if (savedSourceIDs.has(sourceID)) {
        addSourceButton(row, 'In Library', () => {}, {disabled: true});
      } else if (download && ['queued', 'resolving', 'downloading'].includes(download.status)) {
        const percent = Math.round(Math.max(0, Math.min(1, number(download.progress))) * 100);
        addSourceButton(row, download.status === 'downloading' ? `Saving ${percent}%` : 'Preparing…', () => {}, {disabled: true});
        addSourceButton(row, 'Cancel', () => {
          bridge('download', {action: 'cancel', sourceId: payload.sourceId});
        });
      } else {
        addSourceButton(row, 'Save to Library', () => {
          bridge('download', {action: 'save', ...payload});
        }, {
          disabled: !onDrive,
          title: onDrive ? 'Download this recording for offline playback' : 'This source is not available to save'
        });
      }

      const note = document.createElement('span');
      note.className = 'mac-live-status';
      note.setAttribute('role', 'status');
      if (!liveLinks.has(sourceID)) note.textContent = 'Checking live links…';
      else if (!link.downloadAvailable) note.textContent = link.message || 'No live download link';
      row.appendChild(note);
    }
  }

  window.refreshMacLiveActions = () => {
    renderSourceActions();
    const cards = [...document.querySelectorAll('.source-card[data-source-id]')];
    if (!cards.length) return;
    const first = cards[0];
    const showID = first.dataset.showId;
    const unresolved = cards.filter(card => !liveLinks.has(card.dataset.sourceId));
    if (!unresolved.length || pendingLiveShows.has(showID)) return;
    pendingLiveShows.add(showID);
    const sent = bridge('live', {
      action: 'resolve',
      showId: number(showID),
      date: first.dataset.showDate,
      sources: unresolved.map(card => ({
        id: number(card.dataset.sourceId),
        version: card.dataset.sourceVersion
      }))
    });
    if (!sent) {
      pendingLiveShows.delete(showID);
      for (const card of unresolved) liveLinks.set(card.dataset.sourceId, {downloadAvailable: false, message: 'Live services unavailable'});
      renderSourceActions();
    }
  };

  window.macLiveLinks = payload => {
    const response = payload && typeof payload === 'object' ? payload : {};
    if (response.showId != null) pendingLiveShows.delete(String(response.showId));
    const entries = Array.isArray(response.sources) ? response.sources : [];
    for (const entry of entries) {
      if (!entry || entry.sourceId == null) continue;
      liveLinks.set(String(entry.sourceId), {
        downloadAvailable: entry.downloadAvailable === true,
        message: typeof entry.message === 'string' ? entry.message : ''
      });
    }
    renderSourceActions();
  };

  function renderPlayerTracks() {
    const tracks = Array.isArray(playerState.tracks) ? playerState.tracks : [];
    const signature = tracks.map((track, index) => `${track.title || ''}\u0000${track.durationSeconds || ''}\u0000${index}`).join('\u0001');
    if (signature !== trackSignature) {
      trackSignature = signature;
      playerTracks.innerHTML = tracks.map((track, index) => `
        <button type="button" data-player-track="${index}">
          <span class="mono">${String(index + 1).padStart(2, '0')}</span>
          <span>${escaped(track.title || `Track ${index + 1}`)}</span>
          <span class="mono">${track.durationSeconds == null ? '' : formatTime(track.durationSeconds)}</span>
        </button>`).join('');
    }
    for (const button of playerTracks.querySelectorAll('[data-player-track]')) {
      const active = number(button.dataset.playerTrack, -1) === number(playerState.trackIndex, -1);
      button.classList.toggle('active', active);
      if (active) button.setAttribute('aria-current', 'true');
      else button.removeAttribute('aria-current');
    }
  }

  let layoutFrame = 0;
  function updatePlayerClearance() {
    if (layoutFrame) return;
    layoutFrame = requestAnimationFrame(() => {
      layoutFrame = 0;
      const style = document.documentElement.style;
      style.setProperty('--mac-player-height', `${player.offsetHeight}px`);
      if (document.body.dataset.tracklistSide) {
        const top = Math.max(0, catalogToolbar.getBoundingClientRect().bottom);
        style.setProperty('--mac-tracklist-top', `${top}px`);
      }
    });
  }

  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let desiredTracklist = null;
  let tracklistAnimation = null;

  function layoutTracklist(finishImmediately = false) {
    const available = !player.hidden && !tracklistToggle.disabled;
    const expanded = tracklistToggle.getAttribute('aria-expanded') === 'true';
    const desired = available && expanded ? tracklistPosition.value : null;
    if (desired === desiredTracklist && !(tracklistAnimation && (finishImmediately || !available))) return;
    desiredTracklist = desired;

    const body = document.body;
    const oldEdge = tracklistPanel.hidden ? null : body.dataset.tracklistSide || 'bottom';
    const edge = desired || oldEdge;
    const vertical = edge === 'bottom';
    // Start reversals at the current presentation position, including mid-frame clicks.
    let interruptedFrame;
    if (tracklistAnimation) {
      if (edge === oldEdge) {
        interruptedFrame = vertical ? {height: getComputedStyle(tracklistPanel).height}
          : {transform: getComputedStyle(tracklistPanel).transform};
      }
      tracklistAnimation.cancel();
      tracklistAnimation = null;
    }

    if (!desired && tracklistPanel.contains(document.activeElement) && available) {
      tracklistToggle.focus({preventScroll: true});
    }
    tracklistPanel.inert = !desired;
    tracklistPanel.setAttribute('aria-hidden', String(!desired));
    const settle = () => {
      tracklistPanel.hidden = !desired;
      if (!desired) delete body.dataset.tracklistSide;
      body.classList.remove('mac-tracklist-closing');
      updatePlayerClearance();
    };

    if (desired) {
      tracklistPanel.hidden = false;
      if (vertical) delete body.dataset.tracklistSide;
      else body.dataset.tracklistSide = edge;
    }
    body.classList.toggle('mac-tracklist-closing', !desired && !vertical);
    if (!edge || !available || finishImmediately || reducedMotion.matches) {
      settle();
      return;
    }

    // A bottom drawer reveals its natural height so the transport rises with it.
    // Side drawers slide independently while the catalog makes room beside them.
    const shown = vertical ? {height: tracklistPanel.offsetHeight + 'px'} : {transform: 'translateX(0)'};
    const tucked = vertical ? {height: '0px'} : {transform: edge === 'left' ? 'translateX(-100%)' : 'translateX(100%)'};
    const from = interruptedFrame || (desired ? tucked : shown);
    const animation = tracklistPanel.animate([from, desired ? shown : tucked], {
      duration: 240, easing: 'cubic-bezier(.22,.75,.22,1)', fill: 'both'
    });
    tracklistAnimation = animation;
    animation.onfinish = () => {
      if (tracklistAnimation !== animation) return;
      tracklistAnimation = null;
      settle();
      animation.cancel();
    };
    updatePlayerClearance();
  }

  reducedMotion.addListener(() => {
    if (reducedMotion.matches) layoutTracklist(true);
  });

  const playerSizeObserver = new ResizeObserver(updatePlayerClearance);
  playerSizeObserver.observe(player);
  playerSizeObserver.observe(catalogToolbar);
  window.addEventListener('scroll', () => {
    if (document.body.dataset.tracklistSide) updatePlayerClearance();
  }, {passive: true});

  function renderPlayer() {
    const status = playerState.status || 'idle';
    const visible = playerState.visible === true || !['idle', 'closed'].includes(status);
    const playing = status === 'playing';
    const loading = ['loading', 'resolving'].includes(status);
    const failed = status === 'error';
    const elapsed = Math.max(0, number(playerState.elapsed));
    const duration = Math.max(0, number(playerState.duration));
    const tracks = Array.isArray(playerState.tracks) ? playerState.tracks : [];

    player.hidden = !visible;
    player.dataset.state = status;
    document.body.classList.toggle('mac-player-open', visible);
    playerTitle.textContent = playerState.title || (loading ? 'Loading recording…' : 'Nothing playing');
    playerContext.textContent = playerState.context || '';
    playerStatus.hidden = !loading && !failed && !playerState.message;
    playerStatus.textContent = failed ? (playerState.error || playerState.message || 'Playback unavailable') : (playerState.message || (loading ? 'Loading…' : ''));
    playerToggle.textContent = playing ? '❚❚' : '▶';
    playerToggle.setAttribute('aria-label', playing ? 'Pause' : 'Play');
    playerToggle.disabled = loading || failed || !tracks.length;
    const index = number(playerState.trackIndex, -1);
    playerPrevious.disabled = loading || failed || (playerState.canPrevious === false) || index <= 0;
    playerNext.disabled = loading || failed || (playerState.canNext === false) || index >= tracks.length - 1;
    playerSeek.max = String(Math.max(0, Math.floor(duration)));
    playerSeek.value = String(Math.min(Math.floor(elapsed), Math.floor(duration)));
    playerSeek.disabled = loading || failed || duration <= 0;
    playerElapsed.textContent = formatTime(elapsed);
    playerDuration.textContent = formatTime(duration);
    tracklistToggle.disabled = !tracks.length;
    renderPlayerTracks();
    layoutTracklist();
  }

  playerToggle.addEventListener('click', () => bridge('player', {action: 'toggle'}));
  playerPrevious.addEventListener('click', () => bridge('player', {action: 'previous'}));
  playerNext.addEventListener('click', () => bridge('player', {action: 'next'}));
  byID('mac-player-close').addEventListener('click', () => bridge('player', {action: 'close'}));
  playerSeek.addEventListener('input', () => { playerElapsed.textContent = formatTime(playerSeek.value); });
  playerSeek.addEventListener('change', () => bridge('player', {action: 'seek', seconds: number(playerSeek.value)}));
  tracklistToggle.addEventListener('click', () => {
    const open = tracklistToggle.getAttribute('aria-expanded') !== 'true';
    tracklistToggle.setAttribute('aria-expanded', String(open));
    layoutTracklist();
  });
  tracklistPosition.addEventListener('change', () => {
    layoutTracklist();
    window.toolMac.setTracklistPosition(tracklistPosition.value);
  });
  playerTracks.addEventListener('click', event => {
    const button = event.target.closest('[data-player-track]');
    if (button) bridge('player', {action: 'playTrack', index: number(button.dataset.playerTrack)});
  });

  window.macPlayerState = state => {
    if (!state || typeof state !== 'object') return;
    playerState = {...playerState, ...state};
    if (Array.isArray(state.tracks)) playerState.tracks = state.tracks;
    renderPlayer();
  };

  function libraryItemTitle(item) {
    return [item.date, item.venue, item.version].filter(Boolean).join(' · ') || 'Saved recording';
  }

  function renderDownloads() {
    const states = [...downloadStates.values()].filter(state => state.status && state.status !== 'removed');
    libraryDownloads.innerHTML = states.map(state => {
      const progress = Math.max(0, Math.min(1, number(state.progress)));
      const active = ['queued', 'resolving', 'downloading'].includes(state.status);
      const label = state.message || ({complete: 'Saved to Library', failed: 'Download failed', cancelled: 'Download cancelled'}[state.status]) || 'Preparing download…';
      const size = state.totalBytes ? `${formatBytes(state.receivedBytes)} of ${formatBytes(state.totalBytes)}` : '';
      return `<div class="library-download" data-download-source="${escaped(state.sourceId)}">
        <div><strong>${escaped(state.title || 'Recording download')}</strong><span>${escaped(label)}${size ? ` · ${escaped(size)}` : ''}</span></div>
        <progress max="1" value="${progress}" aria-label="Download progress for ${escaped(state.title || 'recording')}">${Math.round(progress * 100)}%</progress>
        ${active ? `<button type="button" data-download-cancel="${escaped(state.sourceId)}">Cancel</button>` : ''}
      </div>`;
    }).join('');
    libraryDownloads.hidden = !states.length;
  }

  function renderLibrary() {
    const items = Array.isArray(libraryState.items) ? libraryState.items : [];
    if (libraryState.loading) libraryStatus.textContent = 'Loading your library…';
    else if (libraryState.error) libraryStatus.textContent = libraryState.error;
    else if (!items.length) libraryStatus.textContent = 'No recordings saved yet. Open a show and choose Save to Library.';
    else libraryStatus.textContent = `${items.length} saved recording${items.length === 1 ? '' : 's'}`;

    libraryList.innerHTML = items.map(item => {
      const tracks = Array.isArray(item.tracks) ? item.tracks : [];
      const detail = [tracks.length ? `${tracks.length} tracks` : '', formatBytes(item.sizeBytes)].filter(Boolean).join(' · ');
      return `<article class="library-item" data-library-item="${escaped(item.id)}">
        <div class="library-item-head"><div><strong>${escaped(libraryItemTitle(item))}</strong>
        <span>${escaped(detail || 'Saved recording')}</span></div><div class="library-item-actions">
        <button type="button" class="primary" data-library-action="play">Play</button>
        <button type="button" data-library-action="open" ${item.folderAvailable === false ? 'disabled' : ''}>Open folder</button>
        <button type="button" data-library-action="remove">Remove</button></div></div>
        ${tracks.length ? `<details><summary>Tracklist</summary><ol>${tracks.map((track, index) => `
          <li><span class="mono">${String(index + 1).padStart(2, '0')}</span><span>${escaped(track.title || `Track ${index + 1}`)}</span>
          <span class="mono">${track.durationSeconds == null ? '' : formatTime(track.durationSeconds)}</span>
          <button type="button" data-library-action="track" data-track-index="${index}" aria-label="Play ${escaped(track.title || `track ${index + 1}`)}">▶</button></li>`).join('')}</ol></details>` : ''}
      </article>`;
    }).join('');
    renderDownloads();
  }

  function requestLibrary(action = 'list') {
    libraryState = {...libraryState, loading: true, error: ''};
    renderLibrary();
    if (!bridge('library', {action})) {
      libraryState = {...libraryState, loading: false, error: 'Library services unavailable'};
      renderLibrary();
    }
  }

  byID('show-library').addEventListener('click', () => {
    if (!libraryDialog.open) libraryDialog.showModal();
    byID('close-library').focus();
    requestLibrary();
  });
  byID('close-library').addEventListener('click', () => libraryDialog.close());
  byID('refresh-library').addEventListener('click', () => requestLibrary('refresh'));
  libraryDialog.addEventListener('click', event => {
    if (event.target !== libraryDialog) return;
    const bounds = libraryDialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) libraryDialog.close();
  });
  libraryList.addEventListener('click', event => {
    const button = event.target.closest('[data-library-action]');
    const itemElement = event.target.closest('[data-library-item]');
    if (!button || !itemElement) return;
    const itemID = itemElement.dataset.libraryItem;
    const item = (libraryState.items || []).find(candidate => String(candidate.id) === itemID);
    if (!item) return;
    if (button.dataset.libraryAction === 'play') bridge('player', {action: 'playLibrary', itemId: item.id});
    if (button.dataset.libraryAction === 'track') bridge('player', {action: 'playLibrary', itemId: item.id, trackIndex: number(button.dataset.trackIndex)});
    if (button.dataset.libraryAction === 'open') bridge('library', {action: 'openFolder', itemId: item.id});
    if (button.dataset.libraryAction === 'remove' && confirm(`Remove ${libraryItemTitle(item)} from your Library?`)) {
      bridge('library', {action: 'remove', itemId: item.id});
    }
  });
  libraryDownloads.addEventListener('click', event => {
    const button = event.target.closest('[data-download-cancel]');
    if (button) bridge('download', {action: 'cancel', sourceId: number(button.dataset.downloadCancel)});
  });

  window.macLibraryState = state => {
    if (!state || typeof state !== 'object') return;
    libraryState = {
      loading: state.loading === true,
      error: typeof state.error === 'string' ? state.error : '',
      items: Array.isArray(state.items) ? state.items : []
    };
    savedSourceIDs.clear();
    for (const item of libraryState.items) {
      if (item && item.sourceId != null) savedSourceIDs.add(String(item.sourceId));
    }
    renderLibrary();
    renderSourceActions();
  };

  window.macDownloadState = state => {
    if (!state || state.sourceId == null) return;
    const sourceID = String(state.sourceId);
    downloadStates.set(sourceID, {...state, sourceId: state.sourceId});
    if (state.status === 'complete') {
      savedSourceIDs.add(sourceID);
      if (libraryDialog.open) bridge('library', {action: 'list'});
    }
    renderDownloads();
    renderSourceActions();
  };

  function plexLibraryReady() {
    return plexState.status === 'connected' && Boolean(plexState.serverId) && !plexState.loadingLibraries
      && plexState.libraries.some(library => String(library.id) === String(plexState.libraryId));
  }

  function renderPlexMatches() {
    if (!plexLibraryReady()) {
      plexMatches.replaceChildren();
      return;
    }
    const matches = Array.isArray(plexState.matches) ? plexState.matches : [];
    if (plexState.searching) {
      plexMatches.innerHTML = '<p class="plex-empty">Searching your library…</p>';
      return;
    }
    if (!matches.length) {
      plexMatches.innerHTML = '<p class="plex-empty">Search by date or venue, or use Play from Plex in a show’s recording details.</p>';
      return;
    }
    plexMatches.innerHTML = matches.map(match => `
      <article class="plex-match" data-plex-match="${escaped(match.id)}">
        <div><strong>${escaped(match.title || 'Plex recording')}</strong>
        <span>${escaped(match.subtitle || '')}${match.durationSeconds == null ? '' : ` · ${formatTime(match.durationSeconds)}`}</span></div>
        <button type="button" class="primary" data-plex-play>Play</button>
      </article>`).join('');
  }

  function renderPlex() {
    const status = plexState.status || 'disconnected';
    const connected = status === 'connected';
    const connecting = status === 'connecting';
    const statusTitles = {
      disconnected: 'Not connected', connecting: 'Connecting…', connected: plexState.serverName || 'Connected', error: 'Connection needs attention'
    };
    byID('show-plex').dataset.connected = String(connected);
    plexDialog.dataset.state = status;
    plexStatusTitle.textContent = statusTitles[status] || 'Not connected';
    plexStatusMessage.textContent = plexState.message || (connected ? '' : 'Connect when you are ready.');
    byID('connect-plex').hidden = connected;
    byID('connect-plex').disabled = connecting;
    byID('connect-plex').textContent = connecting ? 'Connecting…' : 'Connect Plex';
    byID('disconnect-plex').hidden = !connected;
    plexBrowser.hidden = !connected;
    const servers = Array.isArray(plexState.servers) ? plexState.servers : [];
    plexServer.innerHTML = servers.map(server => `<option value="${escaped(server.id)}" ${(server.selected || String(server.id) === String(plexState.serverId)) ? 'selected' : ''}>${escaped(server.name || 'Plex server')}</option>`).join('');
    plexServer.disabled = servers.length < 2;
    const libraries = plexState.libraries;
    const hasServer = connected && Boolean(plexState.serverId);
    const loading = plexState.loadingLibraries === true;
    const ready = plexLibraryReady();
    const prompt = !hasServer ? 'Choose a server first' : loading ? 'Loading music libraries…'
      : libraries.length ? 'Choose a music library…' : 'No library available';
    const options = libraries.map(library => `<option value="${escaped(library.id)}">${escaped(library.name)}</option>`).join('');
    plexLibrary.innerHTML = (ready ? '' : `<option value="" disabled>${prompt}</option>`) + options;
    plexLibrary.value = ready ? String(plexState.libraryId) : '';
    plexLibrary.disabled = !hasServer || loading || !libraries.length;
    byID('refresh-plex-libraries').disabled = !hasServer || loading;
    byID('plex-library-status').textContent = plexState.libraryMessage ||
      (hasServer && !loading && !libraries.length ? 'No music libraries found on this server. Refresh libraries to check again.' : '');
    plexSearch.disabled = !ready;
    byID('plex-search-submit').disabled = !ready;
    renderPlexMatches();
    renderSourceActions();
  }

  byID('show-plex').addEventListener('click', () => {
    if (!plexDialog.open) plexDialog.showModal();
    byID('close-plex').focus();
    bridge('plex', {action: 'status'});
  });
  byID('close-plex').addEventListener('click', () => plexDialog.close());
  byID('connect-plex').addEventListener('click', () => {
    plexState = {...plexState, status: 'connecting', message: 'Complete sign-in in the secure Plex window.'};
    renderPlex();
    if (!bridge('plex', {action: 'connect'})) {
      plexState = {...plexState, status: 'error', message: 'Plex services are unavailable.'};
      renderPlex();
    }
  });
  byID('disconnect-plex').addEventListener('click', () => {
    if (confirm('Disconnect Plex from this Mac?')) bridge('plex', {action: 'disconnect'});
  });
  byID('refresh-plex-servers').addEventListener('click', () => bridge('plex', {action: 'servers'}));
  plexServer.addEventListener('change', () => bridge('plex', {action: 'selectServer', serverId: plexServer.value}));
  byID('refresh-plex-libraries').addEventListener('click', () => bridge('plex', {action: 'refreshLibraries'}));
  plexLibrary.addEventListener('change', () => {
    if (plexLibrary.value) bridge('plex', {action: 'selectLibrary', libraryId: plexLibrary.value});
  });
  byID('plex-search-form').addEventListener('submit', event => {
    event.preventDefault();
    if (!plexLibraryReady()) return;
    const query = plexSearch.value.trim();
    if (!query) { plexSearch.focus(); return; }
    plexState = {...plexState, searching: true, matches: []};
    renderPlexMatches();
    bridge('plex', {action: 'search', query});
  });
  plexMatches.addEventListener('click', event => {
    const button = event.target.closest('[data-plex-play]');
    const match = event.target.closest('[data-plex-match]');
    if (button && match && plexLibraryReady()) bridge('plex', {action: 'playMatch', matchId: match.dataset.plexMatch});
  });
  plexDialog.addEventListener('click', event => {
    if (event.target !== plexDialog) return;
    const bounds = plexDialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) plexDialog.close();
  });

  window.macPlexState = state => {
    if (!state || typeof state !== 'object') return;
    plexState = {...state, libraries: Array.isArray(state.libraries) ? state.libraries : []};
    renderPlex();
  };

  renderPlayer();
  renderLibrary();
  renderPlex();
  bridge('plex', {action: 'status'});
})();
