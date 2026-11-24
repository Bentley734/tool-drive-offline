import AppKit
import WebKit

struct CatalogSourceContext {
    let showID: Int
    let sourceID: Int
    let date: String
    let venue: String
    let city: String
    let versionLabel: String
    let version: Int
    let isOnDrive: Bool

    var displayContext: String {
        [date, venue, versionLabel].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var libraryDescriptor: LibrarySourceDescriptor {
        LibrarySourceDescriptor(sourceID: sourceID, showID: String(showID), date: date,
                                venue: venue, version: versionLabel)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var activeCatalog = [String: Any]()
    var catalogOperation: UpdateOperation?
    var appOperation: UpdateOperation?
    var stagedApp: URL?
    var updateAcknowledgment: URL?
    var cacheNotice = "Bundled catalog · available offline"
    var window: NSWindow!
    var web: WKWebView!
    let liveLinkService = LiveMediaService()
    let playerMediaService = LiveMediaService()
    lazy var playerController = PlayerController(media: playerMediaService)
    lazy var plexService = PlexService(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    )
    var libraryController: LibraryController?
    var liveDownloadLinks = LiveMediaService.DownloadLinks()
    var downloadResolvers = [Int: LiveMediaService]()
    var downloadBrowsers = [Int: AnyObject]()
    var playerTracks = [[String: Any]]()
    var lastPlayerState = [String: Any]()
    var playerContextLabel = ""
    var playerClosed = true
    var playerUsesPlex = false
    var plexServers = [PlexServer]()
    var plexLibraries = [PlexLibrary]()
    var plexLoadingLibraries = false
    var plexLibraryMessage = ""
    var plexLibraryGeneration = 0
    var plexMatches = [String: PlexSearchResult]()
    var plexMatchOrder = [String]()
    var plexSearching = false
    var plexAutoplaySearch = false
    var plexSearchGeneration = 0
    var plexAuthorizationGeneration = 0
    var plexAuthorizationDeadline = Date.distantPast
    let testing = CommandLine.arguments.contains("--self-test")
    var dataURL: URL {
        if let path = ProcessInfo.processInfo.environment["TOOL_DRIVE_DATA_DIR"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Tool Drive Offline", isDirectory: true)
    }
    var savedURL: URL { dataURL.appendingPathComponent("saved-shows.json") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--update-ack"), CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
            let updates = dataURL.appendingPathComponent("AppUpdates").standardizedFileURL.path + "/ack-"
            if url.path.hasPrefix(updates), url.deletingLastPathComponent() == dataURL.appendingPathComponent("AppUpdates").standardizedFileURL {
                updateAcknowledgment = url
                try? String(ProcessInfo.processInfo.processIdentifier).write(to: URL(fileURLWithPath: url.path + ".pid"), atomically: true, encoding: .utf8)
            }
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        AppIconController.restore()
        makeMenu()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let controller = config.userContentController
        controller.add(self, name: "savedShows")
        controller.add(self, name: "clipboard")
        controller.add(self, name: "updates")
        controller.add(self, name: "theme")
        controller.add(self, name: "picture")
        controller.add(self, name: "logo")
        controller.add(self, name: "tracklistPosition")
        controller.add(self, name: "live")
        controller.add(self, name: "player")
        controller.add(self, name: "download")
        controller.add(self, name: "library")
        controller.add(self, name: "plex")
        let bundled = try! Data(contentsOf: Bundle.main.url(forResource: "catalog", withExtension: "json")!)
        activeCatalog = try! JSONSerialization.jsonObject(with: bundled) as! [String: Any]
        let cachedURL = dataURL.appendingPathComponent("catalog-update.json")
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            do {
                let data = try Data(contentsOf: cachedURL)
                guard data.count <= 64 * 1024 * 1024,
                      let cache = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let catalog = cache["catalog"] as? [String: Any] else { throw UpdateError("Invalid saved catalog.") }
                try CatalogUpdate.validate(catalog)
                try CatalogUpdate.protect(activeCatalog, catalog)
                activeCatalog = catalog
                cacheNotice = "Last checked " + (cache["checkedAt"] as? String ?? "previously")
            } catch { cacheNotice = "Saved catalog unreadable. Using the bundled snapshot." }
        }
        var saved = "[]"
        var storageWarning = false
        if FileManager.default.fileExists(atPath: savedURL.path) {
            do {
                let data = try Data(contentsOf: savedURL)
                guard let values = try JSONSerialization.jsonObject(with: data) as? [String] else { throw CocoaError(.fileReadCorruptFile) }
                saved = String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
            } catch { storageWarning = true }
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [saved]), encoding: .utf8)!
        let theme = UserDefaults.standard.string(forKey: "catalogTheme") ?? "front-row"
        let picture = UserDefaults.standard.string(forKey: "frontRowPicture") ?? "blue-silhouette"
        let logo = UserDefaults.standard.string(forKey: "catalogLogo") ?? "classic"
        let tracklistPosition = UserDefaults.standard.string(forKey: "tracklistPosition") ?? "bottom"
        controller.addUserScript(WKUserScript(source: """
        (() => {
          let saved = (\(encoded))[0];
          window.toolMac = {
            theme: (\(javascriptJSON([theme])))[0],
            setTheme: id => window.webkit.messageHandlers.theme.postMessage(id),
            picture: (\(javascriptJSON([picture])))[0],
            setPicture: id => window.webkit.messageHandlers.picture.postMessage(id),
            logo: (\(javascriptJSON([logo])))[0],
            setLogo: id => window.webkit.messageHandlers.logo.postMessage(id),
            tracklistPosition: (\(javascriptJSON([tracklistPosition])))[0],
            setTracklistPosition: id => window.webkit.messageHandlers.tracklistPosition.postMessage(id),
            catalog: \(javascriptJSON(activeCatalog)),
            load: () => saved,
            save: value => { saved = value; window.webkit.messageHandlers.savedShows.postMessage(value); },
            copy: value => window.webkit.messageHandlers.clipboard.postMessage(value),
            live: value => window.webkit.messageHandlers.live.postMessage(JSON.stringify(value)),
            player: value => window.webkit.messageHandlers.player.postMessage(JSON.stringify(value)),
            download: value => window.webkit.messageHandlers.download.postMessage(JSON.stringify(value)),
            library: value => window.webkit.messageHandlers.library.postMessage(JSON.stringify(value)),
            plex: value => window.webkit.messageHandlers.plex.postMessage(JSON.stringify(value))
          };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tool Drive Offline"
        window.minSize = NSSize(width: 720, height: 520)
        window.contentView = web
        window.setFrameAutosaveName("ToolDriveMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            libraryController = try LibraryController(baseURL: dataURL.appendingPathComponent("Library", isDirectory: true))
        } catch {
            DispatchQueue.main.async { self.alert("Library unavailable", "The catalog and streaming player still work, but the offline Library could not be opened. \(error.localizedDescription)") }
        }
        configurePlayerCallbacks()
        configurePlexCallbacks()
        guard let html = Bundle.main.url(forResource: "index", withExtension: "html") else { fatalError("Missing bundled catalog") }
        web.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        if storageWarning {
            DispatchQueue.main.async { self.alert("Saved shows could not be read", "The catalog is still available. Your saved-shows file has not been changed.") }
        }
        if testing { DispatchQueue.main.asyncAfter(deadline: .now() + 30) { self.finish(false, "Timed out loading catalog") } }
    }
    func makeMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Tool Drive Offline", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tool Drive Offline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); menu.addItem(edit); edit.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        let find = edit.submenu!.addItem(withTitle: "Find a Show", action: #selector(findShow), keyEquivalent: "f"); find.target = self
        let view = NSMenuItem(); menu.addItem(view); view.submenu = NSMenu(title: "View")
        for (title, action, key) in [("Zoom In", #selector(zoomIn), "+"), ("Zoom Out", #selector(zoomOut), "-"), ("Actual Size", #selector(resetZoom), "0")] {
            let item = view.submenu!.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        view.submenu!.addItem(.separator())
        let iconItem = view.submenu!.addItem(withTitle: "App Icon", action: nil, keyEquivalent: "")
        let icons = NSMenu(title: "App Icon")
        iconItem.submenu = icons
        for (id, title) in [("classic", "Classic"), ("2006", "2006")] {
            let item = icons.addItem(withTitle: title, action: #selector(chooseAppIcon(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = AppIconController.selectedID == id ? .on : .off
            let thumbnail = AppIconController.image(for: id)?.copy() as? NSImage
            thumbnail?.size = NSSize(width: 24, height: 24)
            item.image = thumbnail
        }
        let win = NSMenuItem(); menu.addItem(win); win.submenu = NSMenu(title: "Window")
        win.submenu!.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.submenu!.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = win.submenu
        NSApp.mainMenu = menu
    }
    @objc func chooseAppIcon(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        guard AppIconController.select(id) else {
            alert("App icon unavailable", "The selected icon could not be loaded.")
            return
        }
        for item in sender.menu?.items ?? [] {
            item.state = (item.representedObject as? String) == id ? .on : .off
        }
    }
    @objc func findShow() { web.evaluateJavaScript("document.getElementById('search').focus()", completionHandler: nil) }
    @objc func zoomIn() { web.pageZoom = min(2, web.pageZoom + 0.1) }
    @objc func zoomOut() { web.pageZoom = max(0.6, web.pageZoom - 0.1) }
    @objc func resetZoom() { web.pageZoom = 1 }
    func alert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.beginSheetModal(for: window)
    }
    func catalogSource(showID requestedShowID: Int? = nil, sourceID: Int) -> CatalogSourceContext? {
        guard sourceID > 0, let shows = activeCatalog["shows"] as? [[String: Any]] else { return nil }
        for show in shows {
            guard let showID = integer(show["id"]), requestedShowID == nil || showID == requestedShowID,
                  let sources = show["sources"] as? [[String: Any]] else { continue }
            for source in sources where integer(source["id"]) == sourceID {
                let label = source["version"] as? String ?? ""
                guard label.range(of: "^V\\.[0-9]{1,3}$", options: .regularExpression) != nil,
                      let version = Int(label.dropFirst(2)) else { return nil }
                return CatalogSourceContext(
                    showID: showID, sourceID: sourceID,
                    date: show["date"] as? String ?? "",
                    venue: show["venue"] as? String ?? "",
                    city: [show["city"] as? String, show["state"] as? String, show["country"] as? String]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                    versionLabel: label, version: version,
                    isOnDrive: (source["status"] as? String)?.caseInsensitiveCompare("OTD") == .orderedSame
                )
            }
        }
        return nil
    }
    func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
    func payload(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8), data.count <= 128 * 1024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func evaluateCallback(_ name: String, _ value: [String: Any]) {
        guard ["macLiveLinks", "macPlayerState", "macLibraryState", "macDownloadState", "macPlexState"].contains(name) else { return }
        web?.evaluateJavaScript("window.\(name)?.(\(javascriptJSON(value)))", completionHandler: nil)
    }
    func configurePlayerCallbacks() {
        playerController.onTrackListChange = { [weak self] event in
            guard let self = self else { return }
            let rows = event["tracks"] as? [[String: Any]] ?? []
            self.playerTracks = rows.map { row in
                var item: [String: Any] = ["title": row["title"] as? String ?? "Track"]
                if let duration = row["duration"] { item["durationSeconds"] = duration }
                return item
            }
            self.publishPlayerState()
        }
        playerController.onStateChange = { [weak self] event in
            self?.lastPlayerState = event
            self?.publishPlayerState()
        }
    }
    func configurePlexCallbacks() {
        plexService.onStatusChange = { [weak self] _ in self?.publishPlexState() }
    }
    func publishPlexState(statusOverride: String? = nil,
                          messageOverride: String? = nil) {
        let status = plexService.status
        let uiStatus: String
        if let statusOverride = statusOverride { uiStatus = statusOverride }
        else if status.phase == "authorizing" || status.phase == "loadingServers" { uiStatus = "connecting" }
        else if status.phase == "failed" { uiStatus = status.connected ? "connected" : "error" }
        else { uiStatus = status.connected ? "connected" : "disconnected" }
        let serverRows = plexServers.map { server in
            ["id": server.id, "name": server.name,
             "selected": server.id == status.selectedServerID] as [String: Any]
        }
        let matchRows = plexMatchOrder.compactMap { id -> [String: Any]? in
            guard let match = plexMatches[id] else { return nil }
            let duration = match.tracks.compactMap(\.duration).reduce(0, +)
            var row: [String: Any] = [
                "id": id, "title": match.collection,
                "subtitle": "\(match.tracks.count) tracks · archive v\(match.version)"
            ]
            if duration > 0 { row["durationSeconds"] = duration }
            return row
        }
        var value: [String: Any] = [
            "status": uiStatus, "message": messageOverride ?? status.message,
            "searching": plexSearching, "servers": serverRows, "matches": matchRows,
            "libraries": plexLibraries.map { ["id": $0.id, "name": $0.name, "selected": $0.id == status.selectedLibraryID] as [String: Any] },
            "loadingLibraries": plexLoadingLibraries, "libraryMessage": plexLibraryMessage
        ]
        if let selected = status.selectedLibraryID, plexLibraries.contains(where: { $0.id == selected }) {
            value["libraryId"] = selected
        }
        if let id = status.selectedServerID { value["serverId"] = id }
        if let name = status.selectedServerName { value["serverName"] = name }
        evaluateCallback("macPlexState", value)
    }
    func beginPlexConnection() {
        cancelPlexSearch()
        clearPlexLibraries()
        plexAuthorizationGeneration += 1
        let generation = plexAuthorizationGeneration
        plexAuthorizationDeadline = Date().addingTimeInterval(5 * 60)
        plexServers = []; plexMatches = [:]; plexMatchOrder = []; plexSearching = false
        publishPlexState(statusOverride: "connecting", messageOverride: "Opening Plex sign-in…")
        plexService.beginConnection { [weak self] result in
            guard let self = self, generation == self.plexAuthorizationGeneration else { return }
            switch result {
            case .failure(let error):
                guard (error as? PlexServiceError)?.isCancellation != true else { return }
                let state = self.plexService.status.connected ? "connected" : "error"
                self.publishPlexState(statusOverride: state, messageOverride: error.localizedDescription)
            case .success(let session):
                guard NSWorkspace.shared.open(session.authorizationURL) else {
                    let state = self.plexService.status.connected ? "connected" : "error"
                    self.publishPlexState(statusOverride: state, messageOverride: "The Plex sign-in page could not be opened.")
                    return
                }
                self.publishPlexState(statusOverride: "connecting", messageOverride: "Finish signing in with Plex in your browser…")
                self.pollPlexConnection(pinID: session.pinID, generation: generation)
            }
        }
    }
    func pollPlexConnection(pinID: Int, generation: Int) {
        guard generation == plexAuthorizationGeneration else { return }
        guard Date() < plexAuthorizationDeadline else {
            let state = plexService.status.connected ? "connected" : "error"
            publishPlexState(statusOverride: state, messageOverride: "Plex sign-in timed out. Choose Connect Plex to try again.")
            return
        }
        plexService.pollConnection(pinID: pinID) { [weak self] result in
            guard let self = self, generation == self.plexAuthorizationGeneration else { return }
            switch result {
            case .failure(let error):
                guard (error as? PlexServiceError)?.isCancellation != true else { return }
                let state = self.plexService.status.connected ? "connected" : "error"
                self.publishPlexState(statusOverride: state, messageOverride: error.localizedDescription)
            case .success(.pending):
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.pollPlexConnection(pinID: pinID, generation: generation)
                }
            case .success(.connected): self.refreshPlexServers()
            }
        }
    }
    func refreshPlexServers() {
        cancelPlexSearch()
        clearPlexLibraries()
        plexService.refreshServers { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let servers):
                self.plexServers = servers
                self.refreshPlexLibraries()
            case .failure(let error):
                guard (error as? PlexServiceError)?.isCancellation != true else { return }
                let state = self.plexService.status.connected ? "connected" : "error"
                self.publishPlexState(statusOverride: state, messageOverride: error.localizedDescription)
            }
        }
    }
    func clearPlexLibraries() {
        plexLibraryGeneration += 1
        plexLibraries = []
        plexLibraryMessage = ""
        plexLoadingLibraries = false
        plexMatches = [:]
        plexMatchOrder = []
    }
    func refreshPlexLibraries() {
        guard let server = plexService.status.selectedServerID else { return }
        cancelPlexSearch()
        clearPlexLibraries()
        let generation = plexLibraryGeneration
        plexLoadingLibraries = true
        publishPlexState()
        plexService.refreshLibraries { [weak self] result in
            guard let self = self, self.plexLibraryGeneration == generation,
                  self.plexService.status.selectedServerID == server else { return }
            self.plexLoadingLibraries = false
            switch result {
            case .success(let libraries):
                self.plexLibraries = libraries
                if libraries.isEmpty {
                    self.plexLibraryMessage = "No music libraries are available to this Plex account on this server."
                }
            case .failure(let error):
                self.plexLibraryMessage = error.localizedDescription
            }
            self.publishPlexState()
        }
    }
    func stopPlexPlayback() {
        guard playerUsesPlex else { return }
        playerUsesPlex = false
        playerClosed = true
        playerController.stop()
        publishPlayerState(overrideStatus: "closed")
    }
    func plexDateAndVersion(_ rawQuery: String) -> (date: String, version: Int?)? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 300 else { return nil }
        let range = NSRange(query.startIndex..., in: query)
        let dateExpression = try! NSRegularExpression(pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}")
        var date: String?
        if let match = dateExpression.firstMatch(in: query, range: range),
           let matchRange = Range(match.range, in: query) { date = String(query[matchRange]) }
        if date == nil, let shows = activeCatalog["shows"] as? [[String: Any]] {
            let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let dates = Set(shows.compactMap { show -> String? in
                let fields = [show["venue"], show["city"], show["state"], show["country"]]
                    .compactMap { $0 as? String }.joined(separator: " ")
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return fields.contains(needle) ? show["date"] as? String : nil
            })
            if dates.count == 1 { date = dates.first }
        }
        guard let date = date else { return nil }
        let versionExpression = try! NSRegularExpression(pattern: "(?i)(?:\\.v|\\bv\\.?|version\\s*)([0-9]{1,3})")
        var version: Int?
        if let match = versionExpression.firstMatch(in: query, range: range),
           let versionRange = Range(match.range(at: 1), in: query) { version = Int(query[versionRange]) }
        return (date, version)
    }
    func cancelPlexSearch(closePendingPlayer: Bool = true) {
        plexSearchGeneration += 1
        let pendingPlayer = plexAutoplaySearch
        plexService.cancelSearch()
        plexSearching = false
        plexAutoplaySearch = false
        if closePendingPlayer && pendingPlayer && !playerUsesPlex {
            playerClosed = true
            playerController.stop()
            publishPlayerState(overrideStatus: "closed")
        }
    }
    func rememberPlexMatch(_ result: PlexSearchResult) -> String {
        let id = UUID().uuidString
        plexMatches[id] = result
        plexMatchOrder.removeAll { $0 == id }
        plexMatchOrder.insert(id, at: 0)
        if plexMatchOrder.count > 20 {
            for expired in plexMatchOrder.dropFirst(20) { plexMatches.removeValue(forKey: expired) }
            plexMatchOrder = Array(plexMatchOrder.prefix(20))
        }
        return id
    }
    func searchPlex(date: String, preferredVersion: Int?, autoplay: Bool, context: String? = nil) {
        guard plexService.status.connected else {
            publishPlexState(statusOverride: "disconnected", messageOverride: "Connect Plex before searching your archive.")
            return
        }
        guard !plexLoadingLibraries, let libraryID = plexService.status.selectedLibraryID,
              plexLibraries.contains(where: { $0.id == libraryID }) else {
            publishPlexState(messageOverride: "Choose a Plex music library before searching.")
            return
        }
        cancelPlexSearch()
        plexSearchGeneration += 1
        let searchGeneration = plexSearchGeneration
        if autoplay {
            playerController.stop()
            playerClosed = false
            playerUsesPlex = false
            playerContextLabel = context ?? "TOOL \(date) · Plex"
            playerTracks = []
            lastPlayerState = ["status": "loading", "message": "Searching your Plex archive…"]
            publishPlayerState()
        }
        plexSearching = true
        plexAutoplaySearch = autoplay
        if !autoplay { plexMatches = [:]; plexMatchOrder = [] }
        let versionText = preferredVersion.map { ".v\($0)" } ?? ""
        publishPlexState(messageOverride: "Searching Plex for tool\(date)\(versionText)…")
        plexService.search(showDate: date, preferredVersion: preferredVersion) { [weak self] result in
            guard let self = self, searchGeneration == self.plexSearchGeneration else { return }
            self.plexSearching = false
            self.plexAutoplaySearch = false
            switch result {
            case .failure(let error):
                self.publishPlexState(messageOverride: error.localizedDescription)
                if autoplay {
                    self.lastPlayerState = ["status": "failed", "message": error.localizedDescription]
                    self.playerClosed = false
                    self.publishPlayerState()
                }
            case .success(let match):
                _ = self.rememberPlexMatch(match)
                self.publishPlexState(messageOverride: "Found the exact archive recording on Plex.")
                if autoplay { self.playPlexMatch(match, context: context) }
            }
        }
    }
    func playPlexMatch(_ match: PlexSearchResult, context: String? = nil) {
        playerClosed = false
        playerUsesPlex = true
        playerContextLabel = context ?? match.collection
        playerTracks = []
        lastPlayerState = ["status": "loading", "message": "Opening direct audio from Plex…"]
        publishPlayerState()
        match.withNativePlaybackTracks { tracks in
            playerController.loadRemoteTracks(tracks, collection: match.collection, autoplay: true)
        }
    }
    func handlePlex(_ request: [String: Any]) {
        guard let action = request["action"] as? String else { return }
        switch action {
        case "status":
            let status = plexService.status
            if status.connected && status.phase != "loadingServers" && status.phase != "authorizing" {
                if plexServers.isEmpty { refreshPlexServers(); return }
                if status.selectedServerID != nil && plexLibraries.isEmpty && !plexLoadingLibraries && plexLibraryMessage.isEmpty {
                    refreshPlexLibraries()
                    return
                }
            }
            publishPlexState()
        case "connect": beginPlexConnection()
        case "disconnect":
            clearPlexLibraries()
            plexAuthorizationGeneration += 1
            plexSearchGeneration += 1
            let shouldClosePlexPlayer = playerUsesPlex || plexAutoplaySearch
            plexSearching = false; plexServers = []; plexMatches = [:]; plexMatchOrder = []
            plexAutoplaySearch = false
            plexService.cancelSearch()
            if shouldClosePlexPlayer {
                playerUsesPlex = false
                playerClosed = true
                playerController.stop()
                publishPlayerState(overrideStatus: "closed")
            }
            do { try plexService.disconnect(); publishPlexState() }
            catch { publishPlexState(statusOverride: "error", messageOverride: error.localizedDescription) }
        case "servers": refreshPlexServers()
        case "selectServer":
            guard let id = request["serverId"] as? String, id != plexService.status.selectedServerID,
                  plexServers.contains(where: { $0.id == id }) else { return }
            cancelPlexSearch()
            do {
                try plexService.selectServer(id: id)
                stopPlexPlayback()
                refreshPlexLibraries()
            } catch {
                publishPlexState(statusOverride: plexService.status.connected ? "connected" : "error",
                                 messageOverride: error.localizedDescription)
            }
        case "refreshLibraries":
            refreshPlexLibraries()
        case "selectLibrary":
            guard !plexLoadingLibraries, let id = request["libraryId"] as? String,
                  id != plexService.status.selectedLibraryID, plexLibraries.contains(where: { $0.id == id }) else { return }
            cancelPlexSearch()
            do {
                try plexService.selectLibrary(id: id)
                plexMatches = [:]
                plexMatchOrder = []
                plexLibraryMessage = ""
                stopPlexPlayback()
            } catch {
                plexLibraryMessage = error.localizedDescription
            }
            publishPlexState()
        case "search":
            guard let query = request["query"] as? String, let parsed = plexDateAndVersion(query) else {
                plexSearching = false
                publishPlexState(messageOverride: "Enter a show date such as 1993-06-23. A venue works when it identifies one catalog show.")
                return
            }
            searchPlex(date: parsed.date, preferredVersion: parsed.version, autoplay: false)
        case "play":
            guard let showID = integer(request["showId"]), let sourceID = integer(request["sourceId"]),
                  let source = catalogSource(showID: showID, sourceID: sourceID) else { return }
            searchPlex(date: source.date, preferredVersion: source.version, autoplay: true,
                       context: source.displayContext + " · Plex")
        case "playMatch":
            guard let id = request["matchId"] as? String, let match = plexMatches[id] else { return }
            playPlexMatch(match)
        default: break
        }
    }
    func publishPlayerState(overrideStatus: String? = nil) {
        let nativeStatus = lastPlayerState["status"] as? String ?? "idle"
        let mappedStatus: String
        if let overrideStatus = overrideStatus { mappedStatus = overrideStatus }
        else if playerClosed || nativeStatus == "idle" { mappedStatus = "closed" }
        else if nativeStatus == "failed" { mappedStatus = "error" }
        else if nativeStatus == "buffering" && playerTracks.isEmpty { mappedStatus = "loading" }
        else { mappedStatus = nativeStatus }
        var state: [String: Any] = [
            "visible": !playerClosed && mappedStatus != "closed",
            "status": mappedStatus,
            "title": lastPlayerState["title"] as? String ?? (mappedStatus == "loading" ? "Loading recording…" : "Nothing playing"),
            "context": playerContextLabel,
            "message": lastPlayerState["message"] as? String ?? "",
            "elapsed": lastPlayerState["elapsed"] ?? 0,
            "duration": lastPlayerState["duration"] ?? NSNull(),
            "trackIndex": lastPlayerState["trackIndex"] ?? -1,
            "canPrevious": lastPlayerState["canPrevious"] ?? false,
            "canNext": lastPlayerState["canNext"] ?? false,
            "tracks": playerTracks
        ]
        if mappedStatus == "error" { state["error"] = lastPlayerState["message"] as? String ?? "Playback unavailable" }
        evaluateCallback("macPlayerState", state)
    }
    func handleLive(_ request: [String: Any]) {
        guard let action = request["action"] as? String else { return }
        if action == "resolve" {
            guard let showID = integer(request["showId"]),
                  let requested = request["sources"] as? [[String: Any]], requested.count <= 100 else { return }
            let contexts = requested.compactMap { source -> CatalogSourceContext? in
                guard let sourceID = integer(source["id"]) else { return nil }
                return catalogSource(showID: showID, sourceID: sourceID)
            }
            if testing {
                let rows = contexts.map { ["sourceId": $0.sourceID, "downloadAvailable": false,
                                           "message": "Live links disabled during the offline self-test"] as [String: Any] }
                evaluateCallback("macLiveLinks", ["showId": showID, "sources": rows])
                return
            }
            liveLinkService.loadDownloadLinks { [weak self] result in
                guard let self = self else { return }
                var rows = [[String: Any]]()
                switch result {
                case .success(let links):
                    self.liveDownloadLinks = links
                    rows = contexts.map { context in
                        ["sourceId": context.sourceID,
                         "downloadAvailable": links[context.showID]?[context.sourceID] != nil,
                         "message": links[context.showID]?[context.sourceID] == nil ? "No original download link published" : ""]
                    }
                case .failure(let error):
                    rows = contexts.map { ["sourceId": $0.sourceID, "downloadAvailable": false,
                                           "message": "Live links unavailable: \(error.localizedDescription)"] }
                }
                self.evaluateCallback("macLiveLinks", ["showId": showID, "sources": rows])
            }
        } else if action == "openDownload", let sourceID = integer(request["sourceId"]),
                  let context = catalogSource(sourceID: sourceID) {
            openDownloadLink(context)
        }
    }
    func openDownloadLink(_ context: CatalogSourceContext) {
        let open: (LiveMediaService.DownloadLinks) -> Void = { [weak self] links in
            guard let url = links[context.showID]?[context.sourceID] else {
                self?.alert("Download unavailable", "The Tool Drive Project has not published an original download link for this source.")
                return
            }
            guard let self = self else { return }
            if #available(macOS 11.3, *), let library = self.libraryController {
                if let existing = self.downloadBrowsers[context.sourceID] as? DownloadBrowser {
                    existing.show()
                    return
                }
                do {
                    let browser = try DownloadBrowser(library: library, source: context.libraryDescriptor, folderURL: url)
                    browser.onProgress = { [weak self] progress in
                        self?.publishDownload(sourceID: context.sourceID, status: "downloading",
                                              progress: progress.fraction, message: progress.message,
                                              title: context.displayContext)
                    }
                    browser.onCompletion = { [weak self] result in
                        switch result {
                        case .success:
                            self?.publishDownload(sourceID: context.sourceID, status: "complete", progress: 1,
                                                  message: "Saved original audio to Library", title: context.displayContext)
                            self?.publishLibrary()
                        case .failure(let error):
                            let status: String
                            if case LibraryError.canceled = error { status = "cancelled" } else { status = "failed" }
                            self?.publishDownload(sourceID: context.sourceID, status: status, progress: 0,
                                                  message: error.localizedDescription, title: context.displayContext)
                        }
                    }
                    browser.onClose = { [weak self, weak browser] in
                        guard let self = self, let browser = browser,
                              self.downloadBrowsers[context.sourceID] === browser else { return }
                        self.downloadBrowsers.removeValue(forKey: context.sourceID)
                    }
                    self.downloadBrowsers[context.sourceID] = browser
                    browser.show()
                } catch {
                    self.alert("Download unavailable", error.localizedDescription)
                }
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        if !liveDownloadLinks.isEmpty { open(liveDownloadLinks); return }
        liveLinkService.loadDownloadLinks { [weak self] result in
            switch result {
            case .success(let links): self?.liveDownloadLinks = links; open(links)
            case .failure(let error): self?.alert("Download unavailable", error.localizedDescription)
            }
        }
    }
    func handlePlayer(_ request: [String: Any]) {
        guard let action = request["action"] as? String else { return }
        switch action {
        case "load":
            guard let showID = integer(request["showId"]), let sourceID = integer(request["sourceId"]),
                  let context = catalogSource(showID: showID, sourceID: sourceID), context.isOnDrive else {
                lastPlayerState = ["status": "failed", "message": "This recording is not currently streamable."]
                playerClosed = false; publishPlayerState(); return
            }
            if plexAutoplaySearch { cancelPlexSearch() }
            playerClosed = false
            playerUsesPlex = false
            playerContextLabel = context.displayContext
            playerTracks = []
            lastPlayerState = ["status": "loading", "message": "Loading tracks from the Tool Drive Project…"]
            publishPlayerState()
            playerController.loadLiveSource(showID: context.showID, sourceID: context.sourceID,
                                             date: context.date, version: context.version,
                                             venue: context.venue, versionLabel: context.versionLabel)
        case "toggle": playerController.toggle()
        case "previous": playerController.previous()
        case "next": playerController.next()
        case "seek":
            if let seconds = (request["seconds"] as? NSNumber)?.doubleValue, seconds.isFinite { playerController.seek(to: seconds) }
        case "playTrack":
            if let index = integer(request["index"]) { playerController.selectTrack(index) }
        case "close":
            if plexAutoplaySearch { cancelPlexSearch(closePendingPlayer: false) }
            playerClosed = true; playerUsesPlex = false
            playerController.stop(); publishPlayerState(overrideStatus: "closed")
        case "playLibrary":
            guard let sourceID = itemSourceID(request) else { return }
            playLibrary(sourceID: sourceID, startTrack: integer(request["trackIndex"]) ?? 0)
        default: break
        }
    }
    func playLibrary(sourceID: Int, startTrack: Int) {
        guard let library = libraryController, let entry = library.entry(sourceID: sourceID) else {
            alert("Recording unavailable", "This recording is no longer in the Library."); publishLibrary(); return
        }
        if plexAutoplaySearch { cancelPlexSearch() }
        let sorted = entry.tracks.sorted { ($0.trackNumber, $0.filename) < ($1.trackNumber, $1.filename) }
        let urls = sorted.compactMap { library.trackURL(sourceID: sourceID, trackNumber: $0.trackNumber) }
        guard urls.count == sorted.count, !urls.isEmpty else {
            alert("Recording unavailable", "One or more audio files are missing from this Library recording."); return
        }
        playerClosed = false
        playerUsesPlex = false
        playerContextLabel = [entry.source.date, entry.source.venue, entry.source.version].filter { !$0.isEmpty }.joined(separator: " · ")
        playerTracks = []
        lastPlayerState = ["status": "loading", "message": "Opening lossless local audio…"]
        publishPlayerState()
        let tracks = zip(sorted, urls).map { track, url in
            LiveTrack(number: track.trackNumber, title: track.title,
                      duration: track.durationSeconds.map(TimeInterval.init), url: url)
        }
        playerController.loadTracks(tracks, collection: playerContextLabel,
                                    startTrack: max(0, min(startTrack, urls.count - 1)), autoplay: true)
    }
    func handleLibrary(_ request: [String: Any]) {
        guard let action = request["action"] as? String, let library = libraryController else {
            evaluateCallback("macLibraryState", ["loading": false, "error": "The Library could not be opened.", "items": []]); return
        }
        switch action {
        case "list": publishLibrary()
        case "refresh":
            do { _ = try library.scanLibrary(); publishLibrary() }
            catch { publishLibrary(error: error.localizedDescription) }
        case "openFolder":
            guard let sourceID = itemSourceID(request), let folder = library.sourceFolder(sourceID: sourceID) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        case "remove":
            guard let sourceID = itemSourceID(request) else { return }
            do { try library.remove(sourceID: sourceID); publishLibrary() }
            catch { publishLibrary(error: "The recording could not be removed. \(error.localizedDescription)") }
        default: break
        }
    }
    func itemSourceID(_ request: [String: Any]) -> Int? {
        if let value = request["itemId"] as? String { return Int(value) }
        return integer(request["itemId"])
    }
    func publishLibrary(error: String = "") {
        guard let library = libraryController else {
            evaluateCallback("macLibraryState", ["loading": false, "error": "The Library could not be opened.", "items": []]); return
        }
        let items = library.listEntries().reversed().map { entry -> [String: Any] in
            let folder = library.sourceFolder(sourceID: entry.source.sourceID)
            let size = entry.tracks.reduce(Int64(0)) { total, track in
                guard let url = library.trackURL(sourceID: entry.source.sourceID, trackNumber: track.trackNumber),
                      let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else { return total }
                return total + Int64(values.fileSize ?? 0)
            }
            return [
                "id": String(entry.source.sourceID), "showId": entry.source.showID,
                "sourceId": entry.source.sourceID, "date": entry.source.date,
                "venue": entry.source.venue, "version": entry.source.version,
                "sizeBytes": size, "folderAvailable": folder != nil,
                "tracks": entry.tracks.sorted { $0.trackNumber < $1.trackNumber }.map { track in
                    var value: [String: Any] = ["title": track.title]
                    if let duration = track.durationSeconds { value["durationSeconds"] = duration }
                    return value
                }
            ]
        }
        evaluateCallback("macLibraryState", ["loading": false, "error": error, "items": Array(items)])
    }
    func handleDownload(_ request: [String: Any]) {
        guard let action = request["action"] as? String, let sourceID = integer(request["sourceId"]) else { return }
        if action == "cancel" {
            downloadResolvers.removeValue(forKey: sourceID)?.cancelAll()
            libraryController?.cancel(sourceID: sourceID)
            publishDownload(sourceID: sourceID, status: "cancelled", progress: 0, message: "Download cancelled")
            return
        }
        guard action == "save", let showID = integer(request["showId"]),
              let context = catalogSource(showID: showID, sourceID: sourceID), context.isOnDrive,
              let library = libraryController else {
            publishDownload(sourceID: sourceID, status: "failed", progress: 0, message: "This recording cannot be saved."); return
        }
        if library.entry(sourceID: sourceID) != nil {
            publishDownload(sourceID: sourceID, status: "complete", progress: 1, message: "Already in Library"); publishLibrary(); return
        }
        guard downloadResolvers[sourceID] == nil else { return }
        let resolver = LiveMediaService()
        downloadResolvers[sourceID] = resolver
        publishDownload(sourceID: sourceID, status: "resolving", progress: 0,
                        message: "Finding tracks…", title: context.displayContext)
        resolver.resolveTracks(showID: showID, sourceID: sourceID, date: context.date, version: context.version) { [weak self, weak resolver] result in
            guard let self = self, let resolver = resolver,
                  self.downloadResolvers[sourceID] === resolver else { return }
            self.downloadResolvers.removeValue(forKey: sourceID)
            switch result {
            case .failure(let error):
                self.publishDownload(sourceID: sourceID, status: "failed", progress: 0,
                                     message: error.localizedDescription, title: context.displayContext)
            case .success(let tracks):
                let downloads = tracks.map {
                    LibraryTrackDownload(trackNumber: $0.number, title: $0.title,
                                         durationSeconds: $0.duration.map { Int($0.rounded()) }, url: $0.url)
                }
                library.saveResolvedSource(context.libraryDescriptor, tracks: downloads, progress: { [weak self] progress in
                    self?.publishDownload(sourceID: sourceID, status: "downloading", progress: progress.fraction,
                                          message: progress.message, title: context.displayContext)
                }, completion: { [weak self] result in
                    switch result {
                    case .success:
                        self?.publishDownload(sourceID: sourceID, status: "complete", progress: 1,
                                              message: "Saved to Library", title: context.displayContext)
                        self?.publishLibrary()
                    case .failure(let error):
                        let status: String
                        if case LibraryError.canceled = error { status = "cancelled" } else { status = "failed" }
                        self?.publishDownload(sourceID: sourceID, status: status, progress: 0,
                                              message: error.localizedDescription, title: context.displayContext)
                    }
                })
            }
        }
    }
    func publishDownload(sourceID: Int, status: String, progress: Double, message: String, title: String = "") {
        evaluateCallback("macDownloadState", ["sourceId": sourceID, "status": status,
                                               "progress": min(1, max(0, progress)),
                                               "message": message, "title": title])
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let value = message.body as? String else { return }
        if ["live", "player", "download", "library", "plex"].contains(message.name) {
            guard let request = payload(value) else { return }
            if message.name == "live" { handleLive(request) }
            else if message.name == "player" { handlePlayer(request) }
            else if message.name == "download" { handleDownload(request) }
            else if message.name == "library" { handleLibrary(request) }
            else { handlePlex(request) }
        } else if message.name == "theme" {
            guard ["graphite", "front-row", "night-shift", "laser-grid"].contains(value) else { return }
            UserDefaults.standard.set(value, forKey: "catalogTheme")
        } else if message.name == "picture" {
            guard ["blue-silhouette", "governors-ball"].contains(value) else { return }
            UserDefaults.standard.set(value, forKey: "frontRowPicture")
        } else if message.name == "logo" {
            guard ["classic", "2006"].contains(value) else { return }
            UserDefaults.standard.set(value, forKey: "catalogLogo")
        } else if message.name == "tracklistPosition" {
            guard ["bottom", "left", "right"].contains(value) else { return }
            UserDefaults.standard.set(value, forKey: "tracklistPosition")
        } else if message.name == "updates" {
            if value == "catalog" { startCatalogUpdate() } else if value == "app" { startAppUpdate() }
        } else if message.name == "clipboard" {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } else if message.name == "savedShows" {
            do {
                guard let data = value.data(using: .utf8), let ids = try JSONSerialization.jsonObject(with: data) as? [String] else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.createDirectory(at: dataURL, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: ids, options: [.prettyPrinted, .sortedKeys]).write(to: savedURL, options: .atomic)
            } catch { alert("Could not save shows", "Your changes are available for this session, but could not be saved to disk. \(error.localizedDescription)") }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let bundled = Bundle.main.url(forResource: "index", withExtension: "html")?.standardizedFileURL
        decisionHandler(navigationAction.request.url?.standardizedFileURL == bundled ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let ack = updateAcknowledgment { try? Data("ready".utf8).write(to: ack, options: .atomic) }
        guard testing else {
            updateState("catalog", cacheNotice)
            startCatalogUpdate(); startAppUpdate()
            return
        }
        web.evaluateJavaScript("""
        (() => {
          const assert = (value, message) => { if (!value) throw Error(message); };
          const $ = id => document.getElementById(id);
          assert(window.CATALOG.shows.length === 1299, 'Catalog count');
          assert(document.querySelectorAll('.show-row').length === 40, 'Initial page');
          $('search').value = 'THIS_SHOW_DOES_NOT_EXIST'; $('search').dispatchEvent(new Event('input'));
          assert(document.querySelectorAll('.show-row').length === 0, 'Search filter');
          $('reset-filters').click();
          const save = document.querySelector('[data-save]'); const id = save.dataset.save;
          save.click();
          assert(JSON.parse(window.toolMac.load()).includes(id), 'Save bridge');
          document.querySelector('[data-open]').click();
          assert($('show-dialog').open && document.querySelector('.source-card'), 'Details');
          assert(document.querySelector('.mac-source-actions button'), 'Live source actions');
          assert($('mac-player') && $('library-dialog') && $('plex-dialog'), 'Player, Library and Plex surfaces');
          window.macPlayerState({visible:true,status:'paused',title:'Fixture track',context:'Fixture show',
            elapsed:12,duration:120,trackIndex:0,canPrevious:false,canNext:false,tracks:[{title:'Fixture track',durationSeconds:120}]});
          assert(!$('mac-player').hidden && $('mac-player-title').textContent === 'Fixture track', 'Native player state');
          window.macPlayerState({visible:false,status:'closed',tracks:[]});
          $('close-dialog').click();
          $('year-from').value = '2020'; $('year-to').value = '1990'; $('year-to').dispatchEvent(new Event('change'));
          assert(document.querySelectorAll('.show-row').length === 0, 'Invalid year range');
          $('reset-filters').click(); $('random-show').click(); assert($('show-dialog').open, 'Random show');
          return 'Catalog, search, save, details, year filters, random show passed';
        })()
        """) { result, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let persisted = (try? Data(contentsOf: self.savedURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }
                self.finish(error == nil && persisted?.isEmpty == false, error?.localizedDescription ?? String(describing: result))
            }
        }
    }
    func finish(_ success: Bool, _ message: String) { print("\(success ? "PASS" : "FAIL") macOS: \(message)"); fflush(stdout); exit(success ? 0 : 1) }
    func applicationWillTerminate(_ notification: Notification) {
        plexAuthorizationGeneration += 1
        liveLinkService.cancelAll()
        playerMediaService.cancelAll()
        downloadResolvers.values.forEach { $0.cancelAll() }
        libraryController?.cancelAll()
        if #available(macOS 11.3, *) {
            downloadBrowsers.values.compactMap { $0 as? DownloadBrowser }.forEach { $0.close() }
        }
        playerController.stop()
        plexService.cancelSearch()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
