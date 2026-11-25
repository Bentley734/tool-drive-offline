# Tool Drive Offline 2.0

A Windows, macOS, iPhone, iPad and Apple TV show browser for finding a Tool recording. The included catalog contains **1,299 documented shows**, captured on **November 21, 2026**.

Windows, Mac, iPhone, iPad, and Apple TV share release version **2.0.0**. Each opens in Liquid Glass on first launch and remembers the theme you choose. All five themes, concert photography, the catalog, search, and bookmarks work offline. All five devices can stream archive recordings or save them for offline listening. Windows, Mac, iPhone, and iPad also support a personal Plex library. The separate single-file HTML edition is an offline metadata browser.

## Features

- Search dates, venues, locations, tapers, gear, and songs.
- Filter by minimum sound rating, year range, recording type, status, and rating availability.
- Sort by sound rating, date, or venue; pick a random show from the current results.
- Inspect every recording source, including taper, gear, lineage, length, and individual sound rating.
- Read documented setlists and save a personal listening shortlist.
- Copy a date or `Tool YYYY-MM-DD` to paste into Plexamp search.
- Check for new catalog entries and sound ratings at startup, then keep the refreshed catalog available offline.
- Keep resized column widths between launches, including when moving to another display scale.
- Choose the Windows column view or themed show cards.
- Download verified GitHub app updates and install them with **Restart to update**, without replacing the EXE by hand.
- Choose Liquid Glass, Front Row, Night Shift, Graphite, or Laser Grid. Pick a concert wallpaper or shuffle it on launch.
- Stream available recordings with seeking, a track queue, a tone equalizer, and an audio-reactive visualizer.
- Save a stream to the offline Library or import original audio from the in-app download browser; keep the original audio files. Codec support depends on the platform.
- Optionally connect a Plex account, select a personal server, and play an exact show/source match from that server without exposing the Plex token to the page.

Sound ratings describe **recording quality out of 10**, rather than performance quality. A show qualifies only when one source meets all active source filters; its displayed rating is the highest rating among those matching sources. Unrated recordings are distinct from a zero score. Ratings reflect the bundled snapshot or your latest successful catalog update. Vote counts are unavailable.

The default status, **On the drive**, limits results to recordings marked available in the source archive. Other statuses include confirmed, unconfirmed, and shows without a known recording. The header reports on-drive recordings separately from all documented shows; the bundled snapshot contains **1,342 on-drive recordings**, and this count refreshes with catalog updates. This status does not scan or describe your Plex library.

## Run the iPhone and iPad app

Open the project in **iOS App** with Xcode 26 or later. The native app supports iOS and iPadOS 17 and later. It includes the offline catalog, bookmarks, archive streams, local audio imports, Plex, equalizer, visualizers, all five Mac themes and nine concert wallpapers. On a wide iPad, the catalog and the selected recording appear side by side. The standalone project download includes its resources and shared source files. [iPhone and iPad setup and controls](iOS%20App/README.md)

## Run the Apple TV app

Open the project in **tvOS App** with Xcode 26 or later. Use the Siri Remote to explore the catalog, play or save a recording, and change themes in Appearance. The app supports tvOS 17 and later. [Apple TV setup and controls](tvOS%20App/README.md)

## Run the macOS app

The Mac app supports **macOS 11 or later on Apple silicon and Intel**. Download the Mac ZIP from [GitHub Releases](https://github.com/Bentley734/tool-drive-offline/releases/latest), extract it, and move `Tool Drive Offline.app` to Applications or another writable folder. The local development build is ad-hoc signed and is not notarized by Apple. macOS may ask for approval on first launch.

The Mac version uses AppKit, the system WebKit engine, and AVFoundation. In addition to the offline catalog, it resolves current download availability when a show is opened and offers **Stream**, **Open download**, **Save to Library**, and optional **Play from Plex** actions. The native player supports queues, seeking, track selection, automatic track advance, retry handling, and macOS media keys. Local playback accepts FLAC, Apple Lossless, WAV, AIFF, MP3, AAC, M4A/MP4, and CAF audio.

Finder and the Dock use the multicolor TOOL icon by default. On macOS 26 and later its layered artwork follows the system icon appearance, including Dark, Clear, and Tinted. In the Mac menu bar, **View → App Icon** lets you choose Multicolor, Classic, or 2006 for the running app’s Dock icon. The toolbar’s Logo picker controls the artwork inside the catalog. During playback, open **Tracklist** and use **Position** to place the list at the bottom, left, or right of the app window. Both preferences are saved on the Mac.

On macOS 26 or later, **View → Use Liquid Glass** gives every theme a native floating toolbar for Library, Plex, and Updates. Its **Appearance** menu includes the theme, logo, and photo choices for the active theme. The app remembers the glass setting independently. The player and tracklist follow the selected appearance and honor Reduce Transparency.

New Mac installations open with a concert photo behind the catalog and its translucent controls. After switching themes, return to **Liquid Glass** using the theme picker. Older supported Macs offer glass-style panels and the wallpaper picker in the catalog toolbar. Open **Appearance → Wallpaper** to choose from nine bundled concert photos. Crimson Current is the default. Choose **Shuffle** for a different concert photo each time you open the app in Liquid Glass. The photo stays in place for that session. Choose a photo by name to keep it across launches. The wallpaper works offline and is remembered separately from the Front Row picture. Switching off glass returns to the preceding standard theme. The logo selection carries across both.

On the Mac, **Visualizer** opens four original, locally rendered animations. **Infinite Filigree** takes a 48-second looping flight through a toroidal tunnel of ultraviolet crystal, emerald veins, and gold geometric tracery. The tunnel targets 60 frames per second and adjusts its rendering resolution during playback. A Canvas version is available on Macs without WebGL. **Ember Bloom**, **Tidal Glass**, and **Prism Veil** explore flowing fractal forms inspired by Electric Sheep. Each preset responds to bass, midrange, and treble when audio analysis is available. Pause holds the current frame. Reduce Motion uses a still image. The tracklist and transport are available in full screen.

**EQ** provides the Tool Drive Project’s Bass Boost, Vocal, and Bright settings, three manual bands, and an independent eight-filter Magik effect. Magik layers with any tone preset, or it can run on its own. Flat resets all filters. Settings follow the current recording across tracks. The player starts the next recording flat and indicates when a track cannot use EQ.

**Save to Library** downloads the site's stream tracks into a hidden staging area and publishes the recording only after every track and its manifest are complete. **Open download** uses an isolated in-app Google Drive browser on macOS 11.3 or later; a downloaded audio file or ZIP is validated before its supported audio files are imported. Removing a Library recording moves it to the Trash. The original files are preserved and are not transcoded.

Plex is optional. Connecting opens Plex's own sign-in page, discovers the user's accessible servers, and stores credentials in the macOS Keychain. Choose the music library containing the archive in the Plex panel. The app remembers the library for each server and uses it for search and **Play from Plex**. Show matching uses the exact `toolYYYY-MM-DD.vN` archive convention, embedded album/date metadata, and media-part folder paths so multiple source versions remain distinct. The token and playable URLs stay in native code and are never sent to the catalog page. Direct playback accepts only Plex's authenticated HTTPS connections; it never sends the server token or audio over plaintext HTTP. Playback depends on the selected Plex server being reachable and permitting access to the media.

The app also checks catalog metadata and GitHub releases at startup, supports cancellation, caches validated metadata, and offers **Restart to update** after verifying a newer Mac package. Saved shows, downloaded audio, and filters survive catalog refreshes. Failed updates keep the current catalog; the restart helper restores the previous app if the new app cannot finish loading.

Mac data lives in `~/Library/Application Support/Tool Drive Offline/`, with downloaded recordings under `Library/Sources/`; Plex credentials live separately in the macOS Keychain. The app needs no Python or separate web server at runtime.

Build and check on a Mac with Xcode 26 or later and Python 3. The build uses the Xcode asset catalog compiler for the layered app icon.

```sh
bash "macOS App/build-app.sh"
bash "macOS App/test-app.sh"
# Optional integration checks against the public metadata and GitHub:
bash "macOS App/test-app.sh" --live
```

Builds appear in `macOS App/dist/`. For a notarized build, set `MAC_SIGN_IDENTITY` to a Developer ID Application identity, notarize the app, staple the ticket, and recreate the ZIP. Use the same version in `macOS App/VERSION` and the stable GitHub tag. Publish **Tool.Drive.Offline.macOS.zip** alongside the Windows assets. The Mac updater verifies GitHub’s SHA-256 asset digest. See `macOS App/READ ME.txt` for storage, build, update, and distribution details.

## Run the Windows app

Open **Tool.Drive.Offline.exe** on Windows 10 or 11 with .NET Framework 4.8 and the Microsoft Edge WebView2 Runtime. The single executable includes the catalog, concert photos, themes and visualizer artwork. It also accepts the verified Windows executable updates offered by earlier versions.

Open **Appearance** to choose a theme, concert photo, logo, or app icon. In Liquid Glass, **Wallpaper → Shuffle** changes the photo at launch. Use **Ctrl+F** to search and choose a show to open its recording sources. In the player, choose a tracklist position, EQ preset or visualizer. Use **Plex** to link your account in your browser and select a server and music library. The app stores Plex credentials under your Windows account using Windows data protection.

Windows keeps bookmarks, cached catalog data, and saved column widths in their original files under `%LOCALAPPDATA%\Tool Drive Offline`. The player and Library also use that profile for new recordings and preferences. The standalone HTML page stores its own bookmarks in the browser.

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

Run these commands in PowerShell from the repository root. The Windows build uses Python 3.9 or newer, the .NET Framework C# compiler, and a pinned Microsoft WebView2 SDK. The first build downloads the SDK if it is not already cached. Use `-WebView2Package` to supply the pinned NuGet package for an offline build.

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

The Windows entry point is in `Windows App/ToolDriveOffline.cs`. `ArchiveWindow.cs` hosts the embedded catalog and connects it to the Windows media, library, Plex, and update services. The Windows page shares the Mac theme and visualizer resources. `CatalogUpdates.cs` handles metadata, and `AppUpdates.cs` verifies and installs executable updates.

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
