import Foundation
import CryptoKit

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class UpdateOperation: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var stopped = false
    private var task: URLSessionDataTask?
    private var bytes = Data()
    private var failure: Error?
    private var done: DispatchSemaphore?
    private var limit = 0
    private var redirects = false
    func cancel() { lock.lock(); stopped = true; let active = task; lock.unlock(); active?.cancel() }
    func check() throws { lock.lock(); let canceled = stopped; lock.unlock(); if canceled { throw UpdateError("Update canceled. Your current files were kept.") } }
    func fetch(_ url: URL, limit: Int, redirects: Bool = false) throws -> Data {
        try check()
        self.limit = limit; self.redirects = redirects; bytes = Data(); failure = nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("ToolDriveOffline-macOS/1.6", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0); done = semaphore
        let download = session.dataTask(with: request)
        lock.lock(); task = download; let canceled = stopped; lock.unlock()
        if canceled { throw UpdateError("Update canceled.") }
        download.resume()
        guard semaphore.wait(timeout: .now() + 190) == .success else { download.cancel(); throw UpdateError("The download timed out. Try again later.") }
        try check()
        if let error = failure { throw error }
        return bytes
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            failure = UpdateError("The server returned an unsuccessful or oversized response."); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if bytes.count + data.count > limit { failure = UpdateError("The download exceeded its size limit."); dataTask.cancel() } else { bytes.append(data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { if failure == nil { failure = error }; done?.signal() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let host = request.url?.host ?? ""
        let allowed = redirects && request.url?.scheme == "https" && (host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com")
        completionHandler(allowed ? request : nil)
    }
}

enum CatalogUpdate {
    static let files = ["01-shows.js", "02-sources.js", "03-songs.js", "09-setlist-history.js"]
    static func constant(_ data: Data, _ name: String) throws -> Any {
        guard let text = String(data: data, encoding: .utf8) else { throw UpdateError("Metadata is not valid UTF-8.") }
        let regex = try NSRegularExpression(pattern: "(?m)^\\s*const\\s+" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*")
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 1, let range = Range(matches[0].range, in: text) else { throw UpdateError("Missing or duplicate metadata: \(name)") }
        let tail = text[range.upperBound...]
        var depth = 0, quoted = false, escaped = false
        for index in tail.indices {
            let c = tail[index]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 {
                    let after = tail[tail.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard after.isEmpty || after.hasPrefix(";") else { throw UpdateError("Unexpected metadata suffix.") }
                    return try JSONSerialization.jsonObject(with: Data(tail[...index].utf8))
                }
            }
        }
        throw UpdateError("Incomplete metadata: \(name)")
    }
    static func clean(_ value: Any?) -> String {
        guard let value = value, !(value is NSNull) else { return "" }
        return String(describing: value).replacingOccurrences(of: "(?i)(?:(?:[a-z][a-z0-9+.-]*:)?//|www\\.)\\S+", with: "[link removed]", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func serialize(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func compile(_ blobs: [Data], date: String) throws -> [String: Any] {
        guard blobs.count == 4,
              let rawShows = try constant(blobs[0], "SHOWS") as? [[String: Any]],
              let sources = try constant(blobs[1], "SOURCES_DATA") as? [String: [[String: Any]]],
              let songs = try constant(blobs[2], "SONGS") as? [[String: Any]],
              let history = try constant(blobs[3], "SETLIST_HISTORY") as? [String: [String: Any]],
              let songIDs = try constant(blobs[3], "SETLIST_SONG_IDS") as? [String],
              !rawShows.isEmpty, !songs.isEmpty, !history.isEmpty, !songIDs.isEmpty,
              sources.count == rawShows.count else { throw UpdateError("The public metadata files are incomplete or do not match.") }
        var titles = [String: String](), known = [Int: [String]]()
        for song in songs {
            let id = clean(song["id"]); guard !id.isEmpty, titles[id] == nil else { throw UpdateError("Invalid song IDs.") }
            titles[id] = clean(song["title"])
            for show in song["appearances"] as? [Int] ?? [] { known[show, default: []].append(clean(song["title"])) }
        }
        var shows = [[String: Any]](), ids = Set<Int>(), sourceIDs = Set<Int>(), dates = Set<String>()
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        for show in rawShows {
            guard let id = show["id"] as? Int, id > 0, ids.insert(id).inserted, let date = show["date"] as? String,
                  let parsed = formatter.date(from: date), formatter.string(from: parsed) == date, dates.insert(date).inserted,
                  let rawSources = sources[String(id)] else { throw UpdateError("Invalid or duplicate show, date, or recording reference.") }
            var row = [String: Any](); row["id"] = id
            for key in ["date", "venue", "city", "state", "country", "status", "festival"] { row[key] = clean(show[key]) }
            var recordings = [[String: Any]]()
            for source in rawSources {
                guard let sourceID = source["id"] as? Int, sourceID > 0, sourceIDs.insert(sourceID).inserted else { throw UpdateError("Invalid or duplicate recording ID.") }
                let rating = Double(clean(source["rating"]))
                var recording: [String: Any] = ["id": sourceID, "rating": rating.flatMap { $0.isFinite && $0 > 0 && $0 <= 10 ? $0 : nil } as Any? ?? NSNull()]
                for (target, key) in [("version", "ver"), ("taper", "taper"), ("gear", "gear"), ("generation", "generation"), ("length", "len"), ("status", "status"), ("lineage", "lineage"), ("recordingType", "recordingType"), ("codec", "fileCodec"), ("lossless", "fileLossless")] { recording[target] = clean(source[key]) }
                guard ["OTD", "Confirmed", "Unconfirmed", "Unknown"].contains(recording["status"] as! String) else { throw UpdateError("Unknown recording status.") }
                recordings.append(recording)
            }
            row["sources"] = recordings
            let entry = history[date] ?? [:]
            let indices = entry["s"] as? [Int] ?? []
            guard indices.allSatisfy({ songIDs.indices.contains($0) }) else { throw UpdateError("Invalid setlist song reference.") }
            let setlist = indices.map { ["title": titles[songIDs[$0]] ?? songIDs[$0].replacingOccurrences(of: "-", with: " ").capitalized] }
            row["setlist"] = setlist; row["setlistOmitted"] = entry["d"] as? Int ?? 0; row["tour"] = clean(entry["t"])
            var seen = Set<String>()
            row["songs"] = ((known[id] ?? []) + setlist.map { $0["title"]! }).filter { seen.insert($0).inserted }
            shows.append(row)
        }
        return ["snapshotDate": date, "source": "Tool Drive Project · setlists from setlist.fm", "ratingDescription": "Sound quality out of 10. Vote counts are unavailable.", "shows": shows]
    }
    static func validate(_ catalog: [String: Any]) throws {
        guard let shows = catalog["shows"] as? [[String: Any]], !shows.isEmpty, catalog["snapshotDate"] is String else { throw UpdateError("Invalid saved catalog.") }
        var ids = Set<Int>(), sourceIDs = Set<Int>()
        for show in shows {
            guard let id = show["id"] as? Int, ids.insert(id).inserted, show["date"] is String, show["venue"] is String,
                  let sources = show["sources"] as? [[String: Any]], show["songs"] is [String], show["setlist"] is [[String: Any]] else { throw UpdateError("Invalid saved show.") }
            for source in sources {
                guard let id = source["id"] as? Int, sourceIDs.insert(id).inserted, source["status"] is String, source["recordingType"] is String else { throw UpdateError("Invalid saved recording.") }
            }
        }
    }
    static func protect(_ old: [String: Any], _ new: [String: Any]) throws {
        guard let previous = old["shows"] as? [[String: Any]], let candidate = new["shows"] as? [[String: Any]], !candidate.isEmpty else { throw UpdateError("Invalid catalog.") }
        func count(_ a: Int, _ b: Int, _ fraction: Double = 0.95) throws { if a >= 20 && Double(b) < ceil(Double(a) * fraction) { throw UpdateError("The snapshot unexpectedly lost metadata. Your current catalog was kept.") } }
        let before = previous.flatMap { $0["sources"] as? [[String: Any]] ?? [] }, after = candidate.flatMap { $0["sources"] as? [[String: Any]] ?? [] }
        try count(previous.count, candidate.count); try count(before.count, after.count)
        let showIDs = Set(candidate.compactMap { $0["id"] as? Int }), recordingIDs = Set(after.compactMap { $0["id"] as? Int })
        try count(previous.count, previous.filter { showIDs.contains($0["id"] as? Int ?? -1) }.count)
        try count(before.count, before.filter { recordingIDs.contains($0["id"] as? Int ?? -1) }.count)
        try count(before.filter { $0["status"] as? String == "OTD" }.count, after.filter { $0["status"] as? String == "OTD" }.count)
        try count(before.filter { $0["rating"] is NSNumber }.count, after.filter { $0["rating"] is NSNumber }.count, 0.8)
        try count(previous.filter { !($0["setlist"] as? [Any] ?? []).isEmpty }.count, candidate.filter { !($0["setlist"] as? [Any] ?? []).isEmpty }.count, 0.8)
    }
    static func summary(_ old: [String: Any], _ new: [String: Any]) -> String {
        let oldShows = old["shows"] as? [[String: Any]] ?? [], newShows = new["shows"] as? [[String: Any]] ?? []
        let oldMap = Dictionary(uniqueKeysWithValues: oldShows.map { ($0["id"] as! Int, $0) })
        let oldSources = oldShows.flatMap { $0["sources"] as? [[String: Any]] ?? [] }
        let sourceMap = Dictionary(uniqueKeysWithValues: oldSources.map { ($0["id"] as! Int, $0) })
        let newSources = newShows.flatMap { $0["sources"] as? [[String: Any]] ?? [] }
        let added = newShows.filter { oldMap[$0["id"] as! Int] == nil }.count
        let recordings = newSources.filter { sourceMap[$0["id"] as! Int] == nil }.count
        let ratings = newSources.filter { source in guard let old = sourceMap[source["id"] as! Int] else { return false }; return (old["rating"] as? NSNumber)?.doubleValue != (source["rating"] as? NSNumber)?.doubleValue }.count
        let changed = newShows.filter { row in guard let old = oldMap[row["id"] as! Int] else { return false }; return (try? serialize(old)) != (try? serialize(row)) }.count
        return added + recordings + ratings + changed == 0 ? "Your catalog is up to date." : "\(added) new shows · \(recordings) new recordings · \(ratings) rating changes · \(changed) updated shows"
    }
}

struct MacRelease {
    let version: String
    let url: URL
    let digest: String
    let size: Int
}
enum AppUpdate {
    static let repository = "https://github.com/Bentley734/tool-drive-offline"
    static let assetName = "Tool.Drive.Offline.macOS.zip"
    static func parse(_ data: Data, current: String) throws -> MacRelease? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["draft"] as? Bool == false, root["prerelease"] as? Bool == false,
              let tag = root["tag_name"] as? String, tag.range(of: "^v?[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              root["html_url"] as? String == repository + "/releases/tag/" + tag,
              let assets = root["assets"] as? [[String: Any]] else { throw UpdateError("Invalid GitHub release metadata.") }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.compare(current, options: .numeric) == .orderedDescending else { return nil }
        let matching = assets.filter { $0["name"] as? String == assetName }
        guard matching.count == 1 else { throw UpdateError("A newer release exists, but its macOS package has not been published yet.") }
        let asset = matching[0]
        guard let address = asset["browser_download_url"] as? String, address == repository + "/releases/download/" + tag + "/" + assetName,
              let url = URL(string: address), let digest = asset["digest"] as? String,
              digest.range(of: "^sha256:[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              let size = asset["size"] as? Int, size > 0, size <= 128 * 1024 * 1024 else { throw UpdateError("The Mac package is missing a valid digest, URL, or size.") }
        return MacRelease(version: version, url: url, digest: String(digest.dropFirst(7)).lowercased(), size: size)
    }
    static func verify(_ data: Data, release: MacRelease) throws {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == release.size, hash == release.digest else { throw UpdateError("The download did not match GitHub's SHA-256 digest and size.") }
    }
    @discardableResult static func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        let out = Pipe(); process.standardOutput = out; process.standardError = out
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Package verification failed: " + String(data: data, encoding: .utf8)!) }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func team(_ app: URL) throws -> String? {
        let details = try run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        let value = details.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }.map { String($0.dropFirst("TeamIdentifier=".count)) }
        return value == "not set" ? nil : value
    }
    static func stage(_ data: Data, release: MacRelease, directory: URL) throws -> URL {
        try verify(data, release: release)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("update.zip")
        try data.write(to: archive, options: .atomic)
        let listing = try run("/usr/bin/zipinfo", ["-1", archive.path])
        for entry in listing.split(separator: "\n").map(String.init) {
            guard !entry.hasPrefix("/"), !entry.split(separator: "/").contains(".."), entry.hasPrefix("Tool Drive Offline.app/") || entry.hasPrefix("__MACOSX/") else { throw UpdateError("Unexpected archive path.") }
        }
        let details = try run("/usr/bin/zipinfo", ["-l", archive.path])
        var uncompressed = 0
        for line in details.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.first?.hasPrefix("l") == true { throw UpdateError("Symbolic links are not accepted in Mac updates.") }
            if let first = fields.first, first.hasPrefix("-") || first.hasPrefix("d") {
                guard fields.count > 3, let size = Int(fields[3]) else { throw UpdateError("Invalid archive entry.") }
                uncompressed += size
                guard uncompressed <= 512 * 1024 * 1024 else { throw UpdateError("Expanded package exceeded its size limit.") }
            }
        }
        let extracted = directory.appendingPathComponent("extracted")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let candidate = extracted.appendingPathComponent("Tool Drive Offline.app")
        if let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved.hasPrefix(extracted.standardizedFileURL.path + "/") else { throw UpdateError("Archive link escaped the package.") }
            }
        }
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "net.bentley734.tooldriveoffline",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version,
              let executable = bundle.executableURL, executable.standardizedFileURL == candidate.appendingPathComponent("Contents/MacOS/ToolDriveOffline").standardizedFileURL, fm.isExecutableFile(atPath: executable.path) else { throw UpdateError("The update has the wrong app identity or version.") }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
        return candidate
    }
}
