import AppKit
import AudioToolbox
import Foundation

enum LibraryOrigin: String, Codable {
    case officialStream
    case googleDrive
}

struct LibrarySourceDescriptor: Codable, Equatable {
    let sourceID: Int
    let showID: String
    let date: String
    let venue: String
    let version: String
}

struct LibraryTrackDownload: Equatable {
    let trackNumber: Int
    let title: String
    let durationSeconds: Int?
    let url: URL
}

extension LibraryTrackDownload {
    init(_ track: LiveTrack) {
        self.init(trackNumber: track.number,
                  title: track.title,
                  durationSeconds: track.duration.map { max(0, Int($0.rounded())) },
                  url: track.url)
    }
}

enum LibraryAudioCodec: String, Codable {
    case mp3
    case flac
    case alac
    case wav
    case aiff
    case aac
    case linearPCM = "pcm"
}

struct LibraryTrack: Codable, Equatable {
    let trackNumber: Int
    let title: String
    let durationSeconds: Int?
    let filename: String
    let codec: LibraryAudioCodec
    let byteCount: Int64
}

struct LibraryEntry: Codable, Equatable {
    let schemaVersion: Int
    let source: LibrarySourceDescriptor
    let origin: LibraryOrigin
    let importedAt: Date
    let tracks: [LibraryTrack]

    var totalBytes: Int64 { tracks.reduce(0) { $0 + max(0, $1.byteCount) } }
}

struct LibraryTransferProgress {
    let sourceID: Int
    let completedTracks: Int
    let totalTracks: Int
    let fraction: Double
    let message: String
}

enum LibraryError: LocalizedError {
    case invalidSource
    case invalidTrack
    case invalidURL
    case alreadyDownloading
    case canceled
    case server(String)
    case unsafeArchive(String)
    case unsupportedFile
    case missingAudio
    case damagedManifest

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "The recording source is invalid."
        case .invalidTrack: return "The recording track list is invalid."
        case .invalidURL: return "The media address is not an approved Tool Drive Project URL."
        case .alreadyDownloading: return "This recording is already being saved."
        case .canceled: return "Saving this recording was canceled."
        case .server(let message): return message
        case .unsafeArchive(let message): return "The downloaded archive was not imported. \(message)"
        case .unsupportedFile: return "The downloaded file is not a supported audio file or ZIP archive."
        case .missingAudio: return "The download did not contain any supported audio files."
        case .damagedManifest: return "The saved recording manifest is damaged."
        }
    }
}

private final class LibraryActiveTransfer {
    let source: LibrarySourceDescriptor
    let tracks: [LibraryTrackDownload]
    let stageURL: URL
    let progress: (LibraryTransferProgress) -> Void
    let completion: (Result<LibraryEntry, Error>) -> Void
    var index = 0
    var task: URLSessionDownloadTask?

    init(source: LibrarySourceDescriptor,
         tracks: [LibraryTrackDownload],
         stageURL: URL,
         progress: @escaping (LibraryTransferProgress) -> Void,
         completion: @escaping (Result<LibraryEntry, Error>) -> Void) {
        self.source = source
        self.tracks = tracks
        self.stageURL = stageURL
        self.progress = progress
        self.completion = completion
    }
}

final class LibraryController: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let schemaVersion = 2
    static let maximumTrackBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumArchiveBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumArchiveEntries = 2_000

    let rootURL: URL
    let sourcesURL: URL
    let stagingURL: URL
    let importsURL: URL

    private let fileManager: FileManager
    private var transfers = [Int: LibraryActiveTransfer]()
    private var taskSources = [Int: Int]()
    private var importsInProgress = Set<Int>()
    private(set) var entriesBySource = [Int: LibraryEntry]()

    private var session: URLSession?

    private func downloadSession() -> URLSession {
        if let session = session { return session }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60 * 60
        let created = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        session = created
        return created
    }

    init(baseURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let baseURL = baseURL {
            rootURL = baseURL.standardizedFileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            rootURL = support.appendingPathComponent("Tool Drive Offline/Library", isDirectory: true)
        }
        sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        stagingURL = rootURL.appendingPathComponent(".staging", isDirectory: true)
        importsURL = rootURL.appendingPathComponent(".imports", isDirectory: true)
        super.init()
        try createDirectories()
        try removeAbandonedStaging()
        _ = try scanLibrary()
    }

    deinit { session?.invalidateAndCancel() }

    private func createDirectories() throws {
        for directory in [rootURL, sourcesURL, stagingURL, importsURL] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func removeAbandonedStaging() throws {
        for parent in [stagingURL, importsURL] {
            let children = try fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            for child in children where Self.isDescendant(child, of: parent) {
                try fileManager.removeItem(at: child)
            }
        }
    }

    static func approvedMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "tooldriveproject.net",
              url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/mp3_2.0/"),
              url.pathExtension.lowercased() == "mp3" else { return false }
        return safeRemotePath(url.path)
    }

    static func approvedDriveFolderURL(_ candidate: URL) -> URL? {
        guard candidate.scheme?.lowercased() == "https",
              candidate.host?.lowercased() == "drive.google.com",
              candidate.user == nil, candidate.password == nil, candidate.fragment == nil else { return nil }
        let components = candidate.pathComponents
        guard components.count == 4, components[1] == "drive", components[2] == "folders" else { return nil }
        let folderID = components[3]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_") )
        guard folderID.count >= 8, folderID.count <= 128,
              folderID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        var result = URLComponents()
        result.scheme = "https"
        result.host = "drive.google.com"
        result.path = "/drive/folders/" + folderID
        return result.url
    }

    private static func safeRemotePath(_ path: String) -> Bool {
        guard !path.contains("\\"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func safeFilename(_ value: String, fallback: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var result = String(folded.unicodeScalars.map { forbidden.contains($0) ? " " : Character($0) })
        result = result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if result == "." || result == ".." || result.isEmpty { result = fallback }
        return String(result.prefix(100))
    }

    private func sourceFolderName(_ source: LibrarySourceDescriptor) -> String {
        let version = Self.safeFilename(source.version, fallback: "source").replacingOccurrences(of: " ", with: "-")
        return "source-\(source.sourceID)-\(source.date)-\(version)"
    }

    private func finalURL(for source: LibrarySourceDescriptor) -> URL {
        sourcesURL.appendingPathComponent(sourceFolderName(source), isDirectory: true)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @discardableResult
    func scanLibrary() throws -> [LibraryEntry] {
        try createDirectories()
        let properties: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let folders = try fileManager.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: properties, options: [.skipsHiddenFiles])
        var entries = [Int: LibraryEntry]()
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? folder.resourceValues(forKeys: Set(properties)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let entry = try? readEntry(at: folder), entries[entry.source.sourceID] == nil else { continue }
            entries[entry.source.sourceID] = entry
        }
        entriesBySource = entries
        return entries.values.sorted { ($0.source.date, $0.source.sourceID) < ($1.source.date, $1.source.sourceID) }
    }

    func listEntries() -> [LibraryEntry] {
        entriesBySource.values.sorted { ($0.source.date, $0.source.sourceID) < ($1.source.date, $1.source.sourceID) }
    }

    func entry(sourceID: Int) -> LibraryEntry? { entriesBySource[sourceID] }

    func sourceFolder(sourceID: Int) -> URL? {
        guard let entry = entriesBySource[sourceID] else { return nil }
        let folder = finalURL(for: entry.source)
        return Self.isDescendant(folder, of: sourcesURL) ? folder : nil
    }

    func trackURL(sourceID: Int, trackNumber: Int) -> URL? {
        guard let entry = entriesBySource[sourceID],
              let track = entry.tracks.first(where: { $0.trackNumber == trackNumber }) else { return nil }
        let folder = finalURL(for: entry.source)
        let url = folder.appendingPathComponent(track.filename).standardizedFileURL
        guard Self.isDescendant(url, of: folder), isSafeRegularFile(url) else { return nil }
        return url
    }

    func trackURLs(sourceID: Int) -> [URL] {
        guard let entry = entriesBySource[sourceID] else { return [] }
        let folder = finalURL(for: entry.source)
        return entry.tracks.sorted { ($0.trackNumber, $0.filename) < ($1.trackNumber, $1.filename) }
            .compactMap { track in
                let url = folder.appendingPathComponent(track.filename).standardizedFileURL
                return Self.isDescendant(url, of: folder) && isSafeRegularFile(url) ? url : nil
            }
    }

    func remove(sourceID: Int) throws {
        guard let folder = sourceFolder(sourceID: sourceID), fileManager.fileExists(atPath: folder.path) else { return }
        var trashed: NSURL?
        try fileManager.trashItem(at: folder, resultingItemURL: &trashed)
        entriesBySource.removeValue(forKey: sourceID)
    }

    func saveResolvedSource(_ source: LibrarySourceDescriptor,
                            tracks: [LibraryTrackDownload],
                            progress: @escaping (LibraryTransferProgress) -> Void,
                            completion: @escaping (Result<LibraryEntry, Error>) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.saveResolvedSource(source, tracks: tracks, progress: progress, completion: completion) }
            return
        }
        do {
            let checked = try validate(source: source, tracks: tracks)
            guard transfers[source.sourceID] == nil, !importsInProgress.contains(source.sourceID) else {
                throw LibraryError.alreadyDownloading
            }
            let stage = stagingURL.appendingPathComponent("save-\(source.sourceID)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
            let transfer = LibraryActiveTransfer(source: source, tracks: checked, stageURL: stage, progress: progress, completion: completion)
            transfers[source.sourceID] = transfer
            report(transfer, fileFraction: 0, message: "Preparing download…")
            startNextTrack(transfer)
        } catch {
            completion(.failure(error))
        }
    }

    func cancel(sourceID: Int) {
        if !Thread.isMainThread { DispatchQueue.main.async { self.cancel(sourceID: sourceID) }; return }
        guard let transfer = transfers.removeValue(forKey: sourceID) else { return }
        if let task = transfer.task { taskSources.removeValue(forKey: task.taskIdentifier); task.cancel() }
        try? fileManager.removeItem(at: transfer.stageURL)
        transfer.completion(.failure(LibraryError.canceled))
    }

    func cancelAll() {
        if !Thread.isMainThread { DispatchQueue.main.async { self.cancelAll() }; return }
        let pending = Array(transfers.values)
        transfers.removeAll()
        let tasks = pending.compactMap(\.task)
        tasks.forEach { taskSources.removeValue(forKey: $0.taskIdentifier) }
        pending.forEach { transfer in
            transfer.task?.cancel()
            try? fileManager.removeItem(at: transfer.stageURL)
        }
        pending.forEach { $0.completion(.failure(LibraryError.canceled)) }
    }

    private func validate(source: LibrarySourceDescriptor, tracks: [LibraryTrackDownload]) throws -> [LibraryTrackDownload] {
        try validateSource(source)
        guard !tracks.isEmpty, tracks.count <= 200 else { throw LibraryError.invalidTrack }
        let sorted = tracks.sorted { $0.trackNumber < $1.trackNumber }
        var numbers = Set<Int>()
        for track in sorted {
            guard track.trackNumber > 0, track.trackNumber <= 999,
                  numbers.insert(track.trackNumber).inserted,
                  track.title.count <= 500,
                  track.durationSeconds.map({ $0 >= 0 && $0 <= 24 * 60 * 60 }) ?? true,
                  Self.approvedMediaURL(track.url) else { throw LibraryError.invalidTrack }
        }
        return sorted
    }

    private func validateSource(_ source: LibrarySourceDescriptor) throws {
        guard source.sourceID > 0,
              source.showID.range(of: "^[1-9][0-9]{0,18}$", options: .regularExpression) != nil,
              Self.isValidDate(source.date),
              source.version.range(of: "^V\\.[0-9]{1,3}$", options: .regularExpression) != nil,
              source.venue.count <= 500,
              !source.venue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LibraryError.invalidSource
        }
    }

    private func startNextTrack(_ transfer: LibraryActiveTransfer) {
        guard transfers[transfer.source.sourceID] === transfer else { return }
        guard transfer.index < transfer.tracks.count else { finish(transfer); return }
        let item = transfer.tracks[transfer.index]
        var request = URLRequest(url: item.url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("ToolDriveOffline-macOS/Library", forHTTPHeaderField: "User-Agent")
        let task = downloadSession().downloadTask(with: request)
        transfer.task = task
        taskSources[task.taskIdentifier] = transfer.source.sourceID
        report(transfer, fileFraction: 0, message: "Downloading track \(transfer.index + 1) of \(transfer.tracks.count)…")
        task.resume()
    }

    private func report(_ transfer: LibraryActiveTransfer, fileFraction: Double, message: String) {
        let total = transfer.tracks.count
        let fraction = total == 0 ? 0 : min(1, (Double(transfer.index) + min(1, max(0, fileFraction))) / Double(total))
        transfer.progress(LibraryTransferProgress(sourceID: transfer.source.sourceID,
                                                  completedTracks: transfer.index,
                                                  totalTracks: total,
                                                  fraction: fraction,
                                                  message: message))
    }

    private func finish(_ transfer: LibraryActiveTransfer) {
        do {
            let tracks = transfer.tracks.map { item -> LibraryTrack in
                let filename = filename(for: item)
                let file = transfer.stageURL.appendingPathComponent(filename)
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return LibraryTrack(trackNumber: item.trackNumber, title: item.title,
                                    durationSeconds: item.durationSeconds, filename: filename,
                                    codec: .mp3, byteCount: size)
            }
            let entry = LibraryEntry(schemaVersion: Self.schemaVersion, source: transfer.source,
                                     origin: .officialStream, importedAt: Date(), tracks: tracks)
            try write(entry, into: transfer.stageURL)
            try installStagedDirectory(transfer.stageURL, entry: entry)
            entriesBySource[entry.source.sourceID] = entry
            transfers.removeValue(forKey: transfer.source.sourceID)
            report(transfer, fileFraction: 0, message: "Saved to Library")
            transfer.completion(.success(entry))
        } catch {
            fail(transfer, error)
        }
    }

    private func fail(_ transfer: LibraryActiveTransfer, _ error: Error) {
        guard transfers.removeValue(forKey: transfer.source.sourceID) != nil else { return }
        if let task = transfer.task { taskSources.removeValue(forKey: task.taskIdentifier) }
        try? fileManager.removeItem(at: transfer.stageURL)
        transfer.completion(.failure(error))
    }

    private func filename(for track: LibraryTrackDownload) -> String {
        let title = Self.safeFilename(track.title, fallback: "Track \(track.trackNumber)")
        return String(format: "%02d - %@.mp3", track.trackNumber, title)
    }

    private func write(_ entry: LibraryEntry, into directory: URL) throws {
        try encoder().encode(entry).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func installStagedDirectory(_ stage: URL, entry: LibraryEntry) throws {
        let final = finalURL(for: entry.source)
        guard Self.isDescendant(stage, of: stagingURL), Self.isDescendant(final, of: sourcesURL) else { throw LibraryError.invalidSource }
        var previous: URL?
        if fileManager.fileExists(atPath: final.path) {
            let backup = stagingURL.appendingPathComponent("previous-\(entry.source.sourceID)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: final, to: backup)
            previous = backup
        }
        do {
            try fileManager.moveItem(at: stage, to: final)
        } catch {
            if let previous = previous { try? fileManager.moveItem(at: previous, to: final) }
            throw error
        }
        if let previous = previous {
            var trashed: NSURL?
            try? fileManager.trashItem(at: previous, resultingItemURL: &trashed)
        }
    }

    private func readEntry(at folder: URL) throws -> LibraryEntry {
        do {
            let manifest = folder.appendingPathComponent("manifest.json")
            let values = try manifest.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let manifestSize = values.fileSize, manifestSize > 0, manifestSize <= 1024 * 1024 else {
                throw LibraryError.damagedManifest
            }
            let entry = try decoder().decode(LibraryEntry.self, from: Data(contentsOf: manifest, options: .mappedIfSafe))
            try validateSource(entry.source)
            let expectedFolder = finalURL(for: entry.source).standardizedFileURL
            guard entry.schemaVersion == Self.schemaVersion,
                  folder.standardizedFileURL == expectedFolder,
                  Self.isDescendant(folder, of: sourcesURL),
                  !entry.tracks.isEmpty, entry.tracks.count <= 999 else {
                throw LibraryError.damagedManifest
            }

            var numbers = Set<Int>()
            var filenames = Set<String>()
            for track in entry.tracks {
                guard (1...999).contains(track.trackNumber), numbers.insert(track.trackNumber).inserted,
                      !track.title.isEmpty, track.title.count <= 500,
                      !track.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      track.durationSeconds.map({ (0...24 * 60 * 60).contains($0) }) ?? true,
                      Self.isValidManifestFilename(track.filename),
                      filenames.insert(track.filename.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)).inserted,
                      track.byteCount > 0, track.byteCount <= Self.maximumTrackBytes else {
                    throw LibraryError.damagedManifest
                }
                let file = folder.appendingPathComponent(track.filename, isDirectory: false).standardizedFileURL
                guard Self.isDescendant(file, of: folder),
                      let fileValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      fileValues.isRegularFile == true, fileValues.isSymbolicLink != true,
                      Int64(fileValues.fileSize ?? -1) == track.byteCount,
                      try audioCodec(for: file) == track.codec,
                      entry.origin != .officialStream || track.codec == .mp3 else {
                    throw LibraryError.damagedManifest
                }
            }
            return entry
        } catch {
            throw LibraryError.damagedManifest
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    private static func isValidManifestFilename(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 160,
              value != ".", value != "..", value == (value as NSString).lastPathComponent,
              !value.hasPrefix("."), value == value.trimmingCharacters(in: CharacterSet(charactersIn: " .")),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              supportedAudioExtensions.contains((value as NSString).pathExtension.lowercased()) else { return false }
        return true
    }

    func makeImportStagingDirectory(sourceID: Int) throws -> URL {
        guard sourceID > 0 else { throw LibraryError.invalidSource }
        let directory = importsURL.appendingPathComponent("source-\(sourceID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func discardImportStagingDirectory(_ directory: URL) {
        guard Self.isDescendant(directory, of: importsURL) else { return }
        try? fileManager.removeItem(at: directory)
    }

    func importDownloadedFile(_ downloaded: URL,
                              source: LibrarySourceDescriptor,
                              progress: @escaping (LibraryTransferProgress) -> Void,
                              completion: @escaping (Result<LibraryEntry, Error>) -> Void) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                self.importDownloadedFile(downloaded, source: source, progress: progress, completion: completion)
            }
            return
        }
        guard Self.isDescendant(downloaded, of: importsURL) else {
            completion(.failure(LibraryError.invalidSource)); return
        }
        do {
            try validateSource(source)
            guard transfers[source.sourceID] == nil,
                  importsInProgress.insert(source.sourceID).inserted else { throw LibraryError.alreadyDownloading }
        } catch {
            discardImportStagingDirectory(downloaded.deletingLastPathComponent())
            completion(.failure(error)); return
        }
        DispatchQueue.global(qos: .utility).async {
            defer { self.discardImportStagingDirectory(downloaded.deletingLastPathComponent()) }
            do {
                DispatchQueue.main.async {
                    progress(LibraryTransferProgress(sourceID: source.sourceID, completedTracks: 0,
                                                     totalTracks: 0, fraction: 0, message: "Importing download…"))
                }
                let result = try self.importOnWorker(downloaded, source: source)
                DispatchQueue.main.async {
                    self.importsInProgress.remove(source.sourceID)
                    self.entriesBySource[source.sourceID] = result
                    progress(LibraryTransferProgress(sourceID: source.sourceID, completedTracks: result.tracks.count,
                                                     totalTracks: result.tracks.count, fraction: 1, message: "Saved to Library"))
                    completion(.success(result))
                }
            } catch {
                DispatchQueue.main.async {
                    self.importsInProgress.remove(source.sourceID)
                    completion(.failure(error))
                }
            }
        }
    }

    private func importOnWorker(_ downloaded: URL, source: LibrarySourceDescriptor) throws -> LibraryEntry {
        try validateSource(source)
        let work = stagingURL.appendingPathComponent("import-\(source.sourceID)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: false)
        do {
            let ext = downloaded.pathExtension.lowercased()
            var audioFiles: [URL]
            if ext == "zip" {
                let extracted = work.appendingPathComponent("extracted", isDirectory: true)
                try fileManager.createDirectory(at: extracted, withIntermediateDirectories: false)
                try validateArchive(downloaded)
                _ = try run("/usr/bin/ditto", ["-x", "-k", downloaded.path, extracted.path])
                audioFiles = try collectAudioFiles(in: extracted)
            } else {
                guard Self.supportedAudioExtensions.contains(ext), try audioCodec(for: downloaded) != nil else {
                    throw LibraryError.unsupportedFile
                }
                audioFiles = [downloaded]
            }
            guard !audioFiles.isEmpty else { throw LibraryError.missingAudio }
            let stage = work.appendingPathComponent("library", isDirectory: true)
            try fileManager.createDirectory(at: stage, withIntermediateDirectories: false)
            var used = Set<String>(), usedTrackNumbers = Set<Int>(), tracks = [LibraryTrack]()
            for (offset, file) in audioFiles.sorted(by: Self.naturalURLOrder).enumerated() {
                guard let codec = try audioCodec(for: file) else { throw LibraryError.unsupportedFile }
                var number = Self.trackNumber(from: file.deletingPathExtension().lastPathComponent) ?? offset + 1
                if number < 1 || number > 999 || usedTrackNumbers.contains(number) {
                    number = max(1, offset + 1)
                    while usedTrackNumbers.contains(number) && number < 999 { number += 1 }
                }
                guard number <= 999, usedTrackNumbers.insert(number).inserted else { throw LibraryError.invalidTrack }
                let fileExtension = file.pathExtension.lowercased()
                let baseName = Self.safeFilename(file.deletingPathExtension().lastPathComponent, fallback: "Track \(number)")
                let name = "\(baseName).\(fileExtension)"
                var unique = name, suffix = 2
                while used.contains(unique.lowercased()) {
                    unique = "\(name.deletingPathExtension)-\(suffix).\(name.pathExtension)"; suffix += 1
                }
                used.insert(unique.lowercased())
                let destination = stage.appendingPathComponent(unique)
                try fileManager.copyItem(at: file, to: destination)
                let byteCount = (try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let title = Self.safeFilename(file.deletingPathExtension().lastPathComponent, fallback: "Track \(number)")
                tracks.append(LibraryTrack(trackNumber: number, title: title, durationSeconds: nil,
                                           filename: unique, codec: codec, byteCount: byteCount))
            }
            tracks.sort { ($0.trackNumber, $0.filename) < ($1.trackNumber, $1.filename) }
            let entry = LibraryEntry(schemaVersion: Self.schemaVersion, source: source,
                                     origin: .googleDrive, importedAt: Date(), tracks: tracks)
            try write(entry, into: stage)
            try installStagedDirectory(stage, entry: entry)
            try? fileManager.removeItem(at: work)
            return entry
        } catch {
            try? fileManager.removeItem(at: work)
            throw error
        }
    }

    static let supportedAudioExtensions: Set<String> = [
        "mp3", "flac", "wav", "wave", "aif", "aiff", "aac", "m4a", "mp4", "caf"
    ]

    private func collectAudioFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { throw LibraryError.missingAudio }
        var result = [URL]()
        for case let url as URL in enumerator {
            guard Self.isDescendant(url, of: directory) else { throw LibraryError.unsafeArchive("A file escaped the import folder.") }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw LibraryError.unsafeArchive("Symbolic links are not accepted.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw LibraryError.unsafeArchive("Only regular files are accepted.") }
            if Self.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                guard let size = values.fileSize, size > 0, Int64(size) <= Self.maximumTrackBytes,
                      try audioCodec(for: url) != nil else {
                    throw LibraryError.unsafeArchive("An audio file is invalid or too large.")
                }
                result.append(url)
            }
        }
        return result
    }

    private func validateArchive(_ archive: URL) throws {
        let values = try archive.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Int64(values.fileSize ?? Int.max) <= Self.maximumArchiveBytes else { throw LibraryError.unsafeArchive("The ZIP is invalid or too large.") }
        let listing = try run("/usr/bin/zipinfo", ["-l", archive.path])
        var count = 0, total: Int64 = 0
        for line in listing.split(separator: "\n").map(String.init) {
            let fields = line.split(maxSplits: 9, omittingEmptySubsequences: true,
                                    whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 10, let kind = fields.first?.first, ["-", "d", "l"].contains(String(kind)), let size = Int64(fields[3]) else { continue }
            count += 1
            guard count <= Self.maximumArchiveEntries else { throw LibraryError.unsafeArchive("The ZIP contains too many entries.") }
            guard kind != "l" else { throw LibraryError.unsafeArchive("Symbolic links are not accepted.") }
            let name = fields[9]
            guard Self.safeArchivePath(name) else { throw LibraryError.unsafeArchive("The ZIP contains an unsafe path.") }
            guard size >= 0, size <= Self.maximumTrackBytes, total <= Self.maximumArchiveBytes - size else {
                throw LibraryError.unsafeArchive("The ZIP expands beyond the library size limit.")
            }
            total += size
        }
        guard count > 0 else { throw LibraryError.unsafeArchive("The ZIP directory could not be read.") }
    }

    private static func safeArchivePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return !parts.isEmpty && parts.allSatisfy { $0 != "." && $0 != ".." }
    }

    private func audioCodec(for url: URL, declaredExtension: String? = nil) throws -> LibraryAudioCodec? {
        let ext = (declaredExtension ?? url.pathExtension).lowercased()
        guard Self.supportedAudioExtensions.contains(ext) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 64 * 1024) ?? Data()
        guard bytes.count >= 12 else { return nil }
        let ascii = String(data: bytes, encoding: .isoLatin1) ?? ""
        let signatureIsValid: Bool
        switch ext {
        case "mp3":
            signatureIsValid = ascii.hasPrefix("ID3") || Self.hasMPEGAudioSync(bytes)
        case "flac":
            signatureIsValid = ascii.hasPrefix("fLaC")
        case "wav", "wave":
            signatureIsValid = ascii.hasPrefix("RIFF") && ascii.dropFirst(8).hasPrefix("WAVE")
        case "aif", "aiff":
            signatureIsValid = ascii.hasPrefix("FORM") &&
                (ascii.dropFirst(8).hasPrefix("AIFF") || ascii.dropFirst(8).hasPrefix("AIFC"))
        case "aac":
            signatureIsValid = Self.hasADTSFrameSync(bytes)
        case "m4a", "mp4":
            signatureIsValid = ascii.dropFirst(4).hasPrefix("ftyp")
        case "caf":
            signatureIsValid = ascii.hasPrefix("caff")
        default:
            signatureIsValid = false
        }
        guard signatureIsValid, let codec = Self.audioToolboxCodec(url, fileExtension: ext) else { return nil }
        switch ext {
        case "mp3": return codec == .mp3 ? codec : nil
        case "flac": return codec == .flac ? codec : nil
        case "wav", "wave": return codec == .wav ? codec : nil
        case "aif", "aiff": return codec == .aiff ? codec : nil
        case "aac": return codec == .aac ? codec : nil
        case "m4a", "mp4": return codec == .aac || codec == .alac ? codec : nil
        case "caf": return codec == .aac || codec == .alac || codec == .linearPCM ? codec : nil
        default: return nil
        }
    }

    private static func audioToolboxCodec(_ url: URL, fileExtension: String) -> LibraryAudioCodec? {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let audioFile = audioFile else { return nil }
        defer { AudioFileClose(audioFile) }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(audioFile, kAudioFilePropertyDataFormat, &size, &description) == noErr else { return nil }
        switch description.mFormatID {
        case kAudioFormatMPEGLayer3: return .mp3
        case kAudioFormatFLAC: return .flac
        case kAudioFormatAppleLossless: return .alac
        case kAudioFormatLinearPCM:
            if ["wav", "wave"].contains(fileExtension) { return .wav }
            if ["aif", "aiff"].contains(fileExtension) { return .aiff }
            return fileExtension == "caf" ? .linearPCM : nil
        default:
            let value = description.mFormatID
            let characters = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((value >> $0) & 0xff))) }
            return String(characters).lowercased().hasPrefix("aac") ? .aac : nil
        }
    }

    private static func hasMPEGAudioSync(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let searchLimit = min(data.count - 1, 16 * 1024)
        return (0..<searchLimit).contains { data[$0] == 0xff && data[$0 + 1] & 0xe0 == 0xe0 }
    }

    private static func hasADTSFrameSync(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        let searchLimit = min(data.count - 1, 16 * 1024)
        return (0..<searchLimit).contains { data[$0] == 0xff && data[$0 + 1] & 0xf6 == 0xf0 }
    }

    private func isSafeRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path == base || path.hasPrefix(base + "/")
    }

    private static func naturalURLOrder(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.compare(rhs.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedAscending
    }

    private static func trackNumber(from value: String) -> Int? {
        let patterns = [
            "(?:^|[._ -])t(?:rack)?[._ -]?0*([0-9]{1,3})$",
            "(?:^|[._ -])track[._ -]?0*([0-9]{1,3})$",
            "^0*([0-9]{1,3})(?:[._ -]|$)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value), let number = Int(value[range]) else { continue }
            return number
        }
        return nil
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LibraryError.unsafeArchive(String(data: data, encoding: .utf8) ?? "Archive inspection failed.")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(Self.approvedMediaURL) == true ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let sourceID = taskSources[downloadTask.taskIdentifier], let transfer = transfers[sourceID] else { return }
        let fileFraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        report(transfer, fileFraction: fileFraction, message: "Downloading track \(transfer.index + 1) of \(transfer.tracks.count)…")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let sourceID = taskSources.removeValue(forKey: downloadTask.taskIdentifier),
              let transfer = transfers[sourceID], transfer.index < transfer.tracks.count else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (response.statusCode == 200 || response.statusCode == 206),
                  response.url.map(Self.approvedMediaURL) == true,
                  response.expectedContentLength == NSURLSessionTransferSizeUnknown ||
                    response.expectedContentLength <= Self.maximumTrackBytes,
                  ["audio/mpeg", "audio/mp3", "application/octet-stream"].contains(response.mimeType?.lowercased() ?? "")
            else { throw LibraryError.server("The server returned an invalid audio response.") }
            let values = try location.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, Int64(size) <= Self.maximumTrackBytes,
                  try audioCodec(for: location, declaredExtension: "mp3") == .mp3 else {
                throw LibraryError.server("The server returned an invalid audio file.")
            }
            let destination = transfer.stageURL.appendingPathComponent(filename(for: transfer.tracks[transfer.index]))
            try fileManager.moveItem(at: location, to: destination)
            transfer.index += 1
            startNextTrack(transfer)
        } catch {
            fail(transfer, error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let sourceID = taskSources.removeValue(forKey: task.taskIdentifier),
              let transfer = transfers[sourceID] else { return }
        if (error as NSError).code == NSURLErrorCancelled && transfers[sourceID] == nil { return }
        fail(transfer, error)
    }
}

private extension String {
    var pathExtension: String { (self as NSString).pathExtension }
    var deletingPathExtension: String { (self as NSString).deletingPathExtension }
}
