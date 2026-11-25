import Foundation
import SwiftUI

struct SetlistEntry: Decodable, Hashable {
    let title: String
}

struct RecordingSource: Decodable, Identifiable, Hashable {
    let id: Int
    let rating: Double?
    let version, taper, gear, generation, length, status, lineage, recordingType, codec, lossless: String
    var searchText = ""
    enum CodingKeys: String, CodingKey {
        case id, rating, version, taper, gear, generation, length, status, lineage, recordingType, codec, lossless
    }
}

struct Concert: Decodable, Identifiable, Hashable {
    let id: Int
    let date, venue, city, state, country, status, festival, tour: String
    let setlist: [SetlistEntry]
    let songs: [String]
    let setlistOmitted: Int
    var sources: [RecordingSource]
    var dateLabel = ""
    var searchText = ""
    var year: Int { Int(date.prefix(4)) ?? 0 }
    var location: String { [city, state, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    enum CodingKeys: String, CodingKey {
        case id, date, venue, city, state, country, status, festival, tour, setlist, songs, setlistOmitted, sources
    }
}

struct ArchiveSnapshot: Decodable {
    let snapshotDate: String
    var shows: [Concert]

    static func read(_ url: URL) throws -> Self {
        var catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard !catalog.shows.isEmpty else { throw UpdateError("This snapshot contains no shows.") }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(secondsFromGMT: 0)
        input.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter()
        display.timeZone = input.timeZone
        display.dateStyle = .medium
        func index(_ values: [String]) -> String {
            values.joined(separator: " ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased().replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "œ", with: "oe")
        }
        for i in catalog.shows.indices {
            var show = catalog.shows[i]
            show.dateLabel = input.date(from: show.date).map(display.string(from:)) ?? show.date
            show.searchText = index([show.date, show.dateLabel, show.venue, show.location, show.status, show.festival, show.tour] + show.songs + show.setlist.map(\.title))
            for j in show.sources.indices {
                let s = show.sources[j]
                show.sources[j].searchText = index([String(s.id), s.version, s.taper, s.gear, s.generation, s.length, s.lineage, s.recordingType, s.codec, s.lossless, s.status])
            }
            catalog.shows[i] = show
        }
        return catalog
    }
}

@MainActor
final class ArchiveStore: ObservableObject {
    @Published private(set) var shows: [Concert] = []
    @Published private(set) var savedIDs: Set<Int>
    @Published private(set) var onDriveCount = 0
    @Published private(set) var snapshotDate = ""
    @Published private(set) var loadError: String?
    @Published private(set) var isLoading = true
    @Published private(set) var updating = false
    @Published private(set) var updateMessage = ""
    @Published private(set) var wallpaperID: String
    @Published private(set) var wallpaperChoice: String
    @Published private(set) var theme: MobileTheme
    @Published private(set) var logo: MobileLogo
    @Published private(set) var picture: FrontRowPicture
    @Published private(set) var glassEnabled: Bool
    private var lastStandard: MobileTheme
    private let appearance: GlassWallpaperPreferences
    private let defaults: UserDefaults
    private var loading = false
    private var activeUpdate: UpdateOperation?
    private var currentFile: URL?
    #if os(tvOS)
    private let cacheURL = URL.cachesDirectory.appending(path: "Archive/catalog.json")
    #else
    private let cacheURL = URL.applicationSupportDirectory.appending(path: "Archive/catalog.json")
    #endif

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedIDs = Set(defaults.array(forKey: "savedConcertIDs") as? [Int] ?? [])
        // Keep the wallpaper-based appearance of the original mobile release on upgrade.
        let initialTheme = defaults.string(forKey: "catalogTheme").flatMap(MobileTheme.init(rawValue:)) ?? .liquidGlass
        theme = initialTheme
        let remembered = defaults.string(forKey: "catalogLastStandardTheme").flatMap(MobileTheme.init(rawValue:))
        lastStandard = initialTheme == .liquidGlass ? (remembered == .liquidGlass ? .frontRow : remembered ?? .frontRow) : initialTheme
        logo = defaults.string(forKey: "catalogLogo").flatMap(MobileLogo.init(rawValue:)) ?? .classic
        picture = defaults.string(forKey: "catalogFrontRowPicture").flatMap(FrontRowPicture.init(rawValue:)) ?? .blueSilhouette
        glassEnabled = initialTheme == .liquidGlass || defaults.bool(forKey: "catalogLiquidGlass")
        let prefs = GlassWallpaperPreferences(defaults: defaults, wallpaperIDs: GlassWallpaper.choices.map(\.id))
        if initialTheme == .liquidGlass { prefs.enterTheme() }
        appearance = prefs
        wallpaperID = prefs.wallpaper
        wallpaperChoice = prefs.choice
    }

    func selectTheme(_ selection: MobileTheme) {
        if selection == .liquidGlass {
            glassEnabled = true
            defaults.set(true, forKey: "catalogLiquidGlass")
            appearance.enterTheme()
            wallpaperID = appearance.wallpaper
        } else {
            lastStandard = selection
            defaults.set(selection.rawValue, forKey: "catalogLastStandardTheme")
        }
        theme = selection
        defaults.set(selection.rawValue, forKey: "catalogTheme")
    }

    func setGlassEnabled(_ enabled: Bool) {
        if !enabled && theme == .liquidGlass { selectTheme(lastStandard) }
        glassEnabled = enabled
        defaults.set(enabled, forKey: "catalogLiquidGlass")
    }

    func selectLogo(_ selection: MobileLogo) {
        logo = selection
        defaults.set(selection.rawValue, forKey: "catalogLogo")
    }

    func selectPicture(_ selection: FrontRowPicture) {
        picture = selection
        defaults.set(selection.rawValue, forKey: "catalogFrontRowPicture")
    }

    func selectWallpaper(_ id: String) {
        guard theme == .liquidGlass, appearance.select(id) else { return }
        wallpaperID = appearance.wallpaper
        wallpaperChoice = appearance.choice
    }

    func toggleSaved(_ id: Int) {
        if savedIDs.contains(id) { savedIDs.remove(id) } else { savedIDs.insert(id) }
        defaults.set(Array(savedIDs), forKey: "savedConcertIDs")
    }

    func load() async {
        guard shows.isEmpty, !loading else { return }
        guard let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json") else {
            isLoading = false
            loadError = "The bundled catalog is missing."
            return
        }
        loading = true
        isLoading = true
        loadError = nil
        defer { loading = false; isLoading = false }
        do {
            let cache = cacheURL
            let (snapshot, file) = try await Task.detached(priority: .userInitiated) {
                if let saved = try? ArchiveSnapshot.read(cache) { return (saved, cache) }
                return (try ArchiveSnapshot.read(bundled), bundled)
            }.value
            apply(snapshot, file: file)
        } catch { loadError = error.localizedDescription }
    }

    private func apply(_ snapshot: ArchiveSnapshot, file: URL) {
        snapshotDate = snapshot.snapshotDate
        onDriveCount = snapshot.shows.reduce(0) { $0 + $1.sources.filter { $0.status == "OTD" }.count }
        shows = snapshot.shows
        currentFile = file
    }

    func cancelUpdate() { activeUpdate?.cancel() }

    func refresh() async {
        guard let previousFile = currentFile, !updating else { return }
        updating = true
        updateMessage = "Checking the Tool Drive Project…"
        let operation = UpdateOperation()
        activeUpdate = operation
        defer { updating = false; activeUpdate = nil }
        do {
            let cache = cacheURL
            let (snapshot, summary) = try await Task.detached(priority: .utility) {
                let blobs = try CatalogUpdate.files.map { name in
                    try operation.fetch(LiveMediaParser.streamBaseURL.appending(path: "data/" + name), limit: 16 * 1024 * 1024)
                }
                let today = ISO8601DateFormatter()
                today.formatOptions = [.withFullDate]
                let candidate = try CatalogUpdate.compile(blobs, date: today.string(from: Date()))
                let bytes = try Data(contentsOf: previousFile)
                guard let old = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                    throw UpdateError("The previous catalog could not be checked.")
                }
                try CatalogUpdate.validate(candidate)
                try CatalogUpdate.protect(old, candidate)
                try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temp = cache.deletingLastPathComponent().appending(path: UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temp) }
                let data = try CatalogUpdate.serialize(candidate)
                try data.write(to: temp)
                let updated = try ArchiveSnapshot.read(temp)
                try operation.check()
                try data.write(to: cache, options: .atomic)
                return (updated, CatalogUpdate.summary(old, candidate))
            }.value
            apply(snapshot, file: cache)
            updateMessage = summary
        } catch { updateMessage = error.localizedDescription }
    }
}
