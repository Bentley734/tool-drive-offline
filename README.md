# Tool Drive Offline

A native Windows show browser for finding a Tool recording to hear in your own Plexamp library. The included catalog contains **1,299 documented shows**, captured on **November 21, 2026**.

The app works offline and contains metadata only: no audio files, players, streaming links, or download links. The Windows app can optionally check for catalog updates when you request them. An optional single-file HTML version is also included.

## Features

- Search dates, venues, locations, tapers, gear, and songs.
- Filter by minimum sound rating, year range, recording type, status, and rating availability.
- Sort by sound rating, date, or venue; pick a random show from the current results.
- Inspect every recording source, including taper, gear, lineage, length, and individual sound rating.
- Read documented setlists and save a personal listening shortlist.
- Copy a date or `Tool YYYY-MM-DD` to paste into Plexamp search.
- Check for new catalog entries and sound ratings, then keep the refreshed catalog available offline.

Sound ratings describe **recording quality out of 10**, rather than performance quality. A show qualifies only when one source meets all active source filters; its displayed rating is the highest rating among those matching sources. Unrated recordings are distinct from a zero score. Ratings reflect the bundled snapshot or your latest successful catalog update. Vote counts are unavailable.

The default status, **On the drive**, limits results to recordings marked available in the source archive. Other statuses include confirmed, unconfirmed, and shows without a known recording. The header reports on-drive recordings separately from all documented shows; the bundled snapshot contains **1,342 on-drive recordings**, and this count refreshes with catalog updates. This status does not scan or describe your Plex library.

## Run the Windows app

Requires Windows and **.NET Framework 4.8**. Download the Windows package from the [latest release](https://github.com/Bentley734/tool-drive-offline/releases/latest), extract it, and open `Tool Drive Offline.exe`. The executable embeds its catalog and needs no server or sidecar data files.

Use **Ctrl+F** to focus search. Double-click a row or press **Enter** on a selected row to open details. Drag column-header edges to adjust column widths. Type a minimum rating and press **Tab** to apply it, or use the numeric spinner.

Saved shows are stored in:

```text
%LOCALAPPDATA%\Tool Drive Offline\saved-shows.json
```

If the app cannot write that file, changes remain available for the current session and the app displays a notice.

## Catalog updates in Windows

Click **Check for catalog updates** near the top of the app while connected to the internet. The app downloads the Tool Drive Project's four public metadata files and reports new shows, newly available recordings, rating changes, and other changed show details. You can cancel a check while it runs.

Checks happen only when requested. Starting the app and browsing a previously downloaded catalog work offline. The updater reads the site's **published metadata snapshot**; a recent rating or recording may not appear until the site refreshes those files. **Last checked** records when your request succeeded, rather than promising that every entry was edited at that time.

A complete update is validated and saved before it replaces the active catalog. Failed, canceled, malformed, or suspiciously incomplete updates leave the working catalog unchanged. Your current filters, search, and saved show IDs are preserved.

The local catalog cache is separate from the executable and saved shows:

```text
%LOCALAPPDATA%\Tool Drive Offline\catalog-update.json
```

Later launches use this cache without contacting the site. If it cannot be read, the app falls back to its embedded catalog and displays a notice. The updater fetches metadata only: no audio, media links, account credentials, Plex library data, or application executables.

## Optional HTML version

Open `index.html` directly in a modern browser. Everything it needs is included in that file; no web server or internet connection is required.

The HTML version remains a static snapshot and does not include the Windows catalog-update control. It stores its shortlist in browser storage. That list is separate from the Windows app's saved shows and depends on the browser allowing local storage.

## Build and test

Run these commands in PowerShell from the repository root. Building uses the C# compiler included with .NET Framework and does not download dependencies.

```powershell
& ".\Windows App\build-app.ps1"
```

The executable is written to `Windows App\dist\Tool Drive Offline.exe`.

Run the 14 catalog/filter assertions and 29 updater assertions with:

```powershell
& ".\Windows App\test-app.ps1"
```

Validate that the HTML and native catalogs agree and contain no network or audio links with `python verify_catalog.py`. The Windows build and these checks also run in GitHub Actions.

The main application source is `Windows App/ToolDriveOffline.cs`; download, import, comparison, and cache code is in `Windows App/CatalogUpdates.cs`. `catalog.json` supplies the embedded metadata; `app.template.html` supplies the HTML interface.

## Rebuild the bundled metadata

To change the snapshot bundled with the source and HTML version, refreshing is an explicit maintenance step that **requires internet access** and Python 3.9 or newer. The builder requests four public metadata files; it does not request audio. It removes URLs from exported metadata and rejects network or media references in the generated HTML.

```powershell
python build_catalog.py --refresh
& ".\Windows App\build-app.ps1"
```

The filter checks contain expected counts for the bundled snapshot; review those expectations when intentionally updating the catalog.

This replaces `catalog.json` and `index.html` with a new snapshot, then embeds that snapshot in the Windows executable. To rebuild from previously saved public metadata instead, use `python build_catalog.py --cache PATH`.

## Attribution

Show and recording metadata comes from the [Tool Drive Project](https://tooldriveproject.net/). Setlist information originates from [setlist.fm](https://www.setlist.fm/) through the project's public catalog.

This is an independent offline companion and is not affiliated with Tool, the Tool Drive Project, Plex, or setlist.fm. Third-party catalog data remains subject to its providers' rights and terms; inclusion here does not grant a blanket license to that data.
