# Tool Drive Offline

A Windows and macOS show browser for finding a Tool recording. The included catalog contains **1,299 documented shows**, captured on **November 21, 2026**.

The catalog, themes, search, and saved shows work offline. The macOS app can optionally resolve current Tool Drive Project streams and original download folders, play audio, keep downloaded recordings in a private local Library, and connect to a user's own Plex server. The Windows and single-file HTML editions remain metadata-only. All editions can check for catalog updates without replacing the working offline snapshot when a request fails.

## Features

- Search dates, venues, locations, tapers, gear, and songs.
- Filter by minimum sound rating, year range, recording type, status, and rating availability.
- Sort by sound rating, date, or venue; pick a random show from the current results.
- Inspect every recording source, including taper, gear, lineage, length, and individual sound rating.
- Read documented setlists and save a personal listening shortlist.
- Copy a date or `Tool YYYY-MM-DD` to paste into Plexamp search.
- Check for new catalog entries and sound ratings at startup, then keep the refreshed catalog available offline.
- Keep resized column widths between launches, including when moving to another display scale.
- Browse large result lists using virtual rows and cell values supplied as needed.
- Download verified GitHub app updates and install them with **Restart to update**, without replacing the EXE by hand.
- Use matching dark dropdowns, scrollbars, rating controls, checkboxes, and recording-detail tabs.
- On macOS, stream available recordings through a native player with a queue, seeking, track selection, and system media controls.
- Save a stream to the offline Library or import original audio from the in-app download browser; play FLAC, ALAC, WAV, AIFF, MP3, AAC, M4A/MP4, and CAF files without conversion.
- Optionally connect a Plex account, select a personal server, and play an exact show/source match from that server without exposing the Plex token to the page.

Sound ratings describe **recording quality out of 10**, rather than performance quality. A show qualifies only when one source meets all active source filters; its displayed rating is the highest rating among those matching sources. Unrated recordings are distinct from a zero score. Ratings reflect the bundled snapshot or your latest successful catalog update. Vote counts are unavailable.

The default status, **On the drive**, limits results to recordings marked available in the source archive. Other statuses include confirmed, unconfirmed, and shows without a known recording. The header reports on-drive recordings separately from all documented shows; the bundled snapshot contains **1,342 on-drive recordings**, and this count refreshes with catalog updates. This status does not scan or describe your Plex library.

## Run the macOS app

The Mac app supports **macOS 11 or later on Apple silicon and Intel**. Download the Mac ZIP from [GitHub Releases](https://github.com/Bentley734/tool-drive-offline/releases/latest), extract it, and move `Tool Drive Offline.app` to Applications or another writable folder. The 1.7.0 Mac build uses an ad-hoc signature and has no Apple notarization ticket. macOS may ask for approval on first launch.

The Mac version uses AppKit, the system WebKit engine, and AVFoundation. In addition to the offline catalog, it resolves current download availability when a show is opened and offers **Stream**, **Open download**, **Save to Library**, and optional **Play from Plex** actions. The native player supports queues, seeking, track selection, automatic track advance, retry handling, and macOS media keys. Local playback accepts FLAC, Apple Lossless, WAV, AIFF, MP3, AAC, M4A/MP4, and CAF audio.

In the Mac menu bar, **View → App Icon** switches the running app’s Dock icon between Classic and 2006. The toolbar’s Logo picker controls the artwork inside the catalog. During playback, open **Tracklist** and use **Position** to place the list at the bottom, left, or right of the app window. Both preferences are saved on the Mac.

**Save to Library** downloads the site's stream tracks into a hidden staging area and publishes the recording only after every track and its manifest are complete. **Open download** uses an isolated in-app Google Drive browser on macOS 11.3 or later; a downloaded audio file or ZIP is validated before its supported audio files are imported. Removing a Library recording moves it to the Trash. The original files are preserved and are not transcoded.

Plex is optional. Connecting opens Plex's own sign-in page, discovers the user's accessible servers, and stores credentials in the macOS Keychain. Choose the music library containing the archive in the Plex panel. The app remembers the library for each server and uses it for search and **Play from Plex**. Show matching uses the exact `toolYYYY-MM-DD.vN` archive convention, embedded album/date metadata, and media-part folder paths so multiple source versions remain distinct. The token and playable URLs stay in native code and are never sent to the catalog page. Direct playback accepts only Plex's authenticated HTTPS connections; it never sends the server token or audio over plaintext HTTP. Playback depends on the selected Plex server being reachable and permitting access to the media.

The app also checks catalog metadata and GitHub releases at startup, supports cancellation, caches validated metadata, and offers **Restart to update** after verifying a newer Mac package. Saved shows, downloaded audio, and filters survive catalog refreshes. Failed updates keep the current catalog; the restart helper restores the previous app if the new app cannot finish loading.

Mac data lives in `~/Library/Application Support/Tool Drive Offline/`, with downloaded recordings under `Library/Sources/`; Plex credentials live separately in the macOS Keychain. The app needs no Python or separate web server at runtime.

Build and check on a Mac with Xcode Command Line Tools and Python 3:

```sh
bash "macOS App/build-app.sh"
bash "macOS App/test-app.sh"
# Optional integration checks against the public metadata and GitHub:
bash "macOS App/test-app.sh" --live
```

Builds appear in `macOS App/dist/`. For a notarized build, set `MAC_SIGN_IDENTITY` to a Developer ID Application identity, notarize the app, staple the ticket, and recreate the ZIP. Use the same version in `macOS App/VERSION` and the stable GitHub tag. Publish **Tool.Drive.Offline.macOS.zip** alongside the Windows assets. The Mac updater verifies GitHub’s SHA-256 asset digest. See `macOS App/READ ME.txt` for storage, build, update, and distribution details.

## Run the Windows app

Requires Windows and **.NET Framework 4.8**. Download the Windows package from the [latest release](https://github.com/Bentley734/tool-drive-offline/releases/latest), extract it, and open `Tool Drive Offline.exe`. The executable embeds its catalog and needs no server or sidecar data files.

Use **Ctrl+F** to focus search. Double-click a row or press **Enter** on a selected row to open details. Drag column-header edges to adjust column widths; changes are remembered between launches. All seven columns remain available through horizontal scrolling when needed. Type a minimum rating and press **Tab** to apply it, or use the minus/plus controls.

The Windows app draws its dropdowns, scrollbars, rating controls, checkboxes, and detail tabs in the same graphite and amber palette. Dropdowns support arrow keys, typing to find an item, **F4** or **Alt+Down** to open, **Enter** to choose, and **Escape** to cancel. Scrollbar thumbs can be dragged; **Shift+wheel** scrolls the results horizontally. Use **Ctrl+Tab** to switch recording-detail sections.

Saved shows are stored in:

```text
%LOCALAPPDATA%\Tool Drive Offline\saved-shows.json
```

If the app cannot write that file, changes remain available for the current session and the app displays a notice.

Column widths are stored separately in `%LOCALAPPDATA%\Tool Drive Offline\column-layout.json`. Widths are stored in logical display units and scaled for the monitor when restored. The app saves after a short pause in resizing and again on normal close; unreadable settings fall back to defaults.

## Catalog updates in Windows

The saved catalog is displayed immediately, then a background update check starts once per launch. Click **Check for catalog updates** near the top to check again later while connected to the internet. The app downloads the Tool Drive Project's four public metadata files and reports new shows, newly available recordings, rating changes, and other changed show details. You can cancel a check while it runs.

The automatic check does not block browsing. You can cancel it; if there is no connection, the saved catalog remains usable. Additional checks happen only when requested. The updater reads the site's **published metadata snapshot**; a recent rating or recording may not appear until the site refreshes those files. **Last checked** records when your request succeeded, rather than promising that every entry was edited at that time.

A complete update is validated and saved before it replaces the active catalog. Failed, canceled, malformed, or suspiciously incomplete updates leave the working catalog unchanged. Your current filters, search, and saved show IDs are preserved.

The local catalog cache is separate from the executable and saved shows:

```text
%LOCALAPPDATA%\Tool Drive Offline\catalog-update.json
```

Later launches first load this cache, then check the site in the background. If it cannot be read, the app falls back to its embedded catalog and displays a notice. The catalog updater fetches metadata only: no audio, media links, account credentials, or Plex library data. App executable updates are handled separately below.

## App updates from GitHub

Version 1.3.0 and later check the public [GitHub releases](https://github.com/Bentley734/tool-drive-offline/releases) at startup. A newer stable release is downloaded in the background. The app verifies its GitHub SHA-256 digest, size, executable identity, and version before offering **Restart to update**. The **Check app updates** button can check again; while checking or downloading, it can cancel the operation.

You choose when to restart. A copied helper waits for the running app to close, replaces its EXE atomically, and starts the new version. Saved shows, downloaded catalog metadata, and column widths stay in their separate Windows profile files. If replacement or launch fails, the helper keeps or restores the previous executable. Updating needs write access to the EXE's folder and no other instance using that same EXE.

Staged app updates and helper files live under `%LOCALAPPDATA%\Tool Drive Offline\AppUpdates`. Only this repository's stable Windows EXE release asset is accepted; ZIP files, prereleases, and older versions are not installed. No account login is needed.

**One-time upgrade:** versions before 1.3.0 do not contain the self-updater. Replace their EXE with the latest release once; later versions can update from inside the app.

## Optional HTML version

Open `index.html` directly in a modern browser. Everything it needs is included in that file; no web server or internet connection is required.

The HTML version remains a static snapshot and does not include the Windows catalog-update control. It stores its shortlist in browser storage. That list is separate from the Windows app's saved shows and depends on the browser allowing local storage.

## Build and test

Run these commands in PowerShell from the repository root. Building uses the C# compiler included with .NET Framework and does not download dependencies.

```powershell
& ".\Windows App\build-app.ps1"
```

The executable is written to `Windows App\dist\Tool Drive Offline.exe`.

Run the catalog/filter, updater, column-layout, hidden-grid, and custom-control checks with:

```powershell
& ".\Windows App\test-app.ps1"
```

Validate that the HTML and native catalogs agree and contain no network or audio links with `python verify_catalog.py`. The Windows build and these checks also run in GitHub Actions.

The local hidden-control benchmark also checks all 1,299 results, virtual cell values, selected-row actions, and width conversions at different display scales. It does not open a window or perform startup update requests.

The main application source is `Windows App/ToolDriveOffline.cs`; catalog download/import/cache code is in `Windows App/CatalogUpdates.cs`; executable download, verification, helper handoff, and replacement code is in `Windows App/AppUpdates.cs`. Custom control painting, input, and scroll hosts are in `Windows App/ThemedInputs.cs`, `Windows App/ThemedScrollBar.cs`, and `Windows App/ThemedScrollHosts.cs`. `catalog.json` supplies the embedded metadata; `app.template.html` supplies the HTML interface.

App-update checks also reject invalid digests, wrong repositories, old releases, and invalid executable versions. File-replacement fixtures verify that a failed restart restores the previous EXE without touching installed app data.

## Publishing a self-update-compatible release

Bump both version attributes in `Windows App/AssemblyInfo.cs`, build and test, and tag a stable `vMAJOR.MINOR.PATCH` release. Upload the standalone Windows executable as `Tool.Drive.Offline.exe` (GitHub also normalizes the build's spaced filename to this name). Publish it as the latest non-prerelease after all assets have uploaded and GitHub has generated the EXE's SHA-256 digest. The updater needs that executable asset; a ZIP alone is not sufficient.

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
