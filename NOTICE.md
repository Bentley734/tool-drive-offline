# Catalog provenance

The bundled catalog is a November 21, 2026 snapshot of public show, recording-source, song, and setlist metadata from the [Tool Drive Project](https://tooldriveproject.net/). Setlists originate from [setlist.fm](https://www.setlist.fm/).

The metadata importer reads these public metadata files:

- `data/01-shows.js`
- `data/02-sources.js`
- `data/03-songs.js`
- `data/09-setlist-history.js`

It keeps an explicit set of metadata fields, removes URLs (including links inside recording notes), and maps the ordered setlist indexes to song titles. It never requests audio. The original metadata is represented in both `catalog.json` and the generated `index.html`; the Windows build embeds `catalog.json`. On request, the Windows catalog updater reads the same four metadata endpoints and stores a validated, URL-free local snapshot. These runtime updates do not change the repository files or the separate HTML snapshot.

Sound ratings are source-level averages out of 10 from the snapshot. They describe recording quality. Missing or zero ratings are treated as unrated. Vote counts are not present in the public snapshot.

The app is an independent companion and is not affiliated with Tool, the Tool Drive Project, Plex, or setlist.fm. Third-party metadata and contributions retain their respective rights. This repository does not assign a new license to that imported material.
