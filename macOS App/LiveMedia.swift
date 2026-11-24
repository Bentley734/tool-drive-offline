import Foundation

struct LiveTrack: Equatable {
    let number: Int
    let title: String
    let duration: TimeInterval?
    let url: URL

    var summary: [String: Any] {
        var value: [String: Any] = ["number": number, "title": title]
        if let duration = duration { value["duration"] = duration }
        return value
    }
}

enum LiveMediaParser {
    static let sourceURL = URL(string: "https://tooldriveproject.net/data/02-sources.js")!
    static let streamBaseURL = URL(string: "https://tooldriveproject.net")!

    static func downloadLinks(_ data: Data) throws -> [Int: [Int: URL]] {
        guard let raw = try CatalogUpdate.constant(data, "SOURCES_DATA") as? [String: [[String: Any]]] else {
            throw UpdateError("The live download-link data is not in the expected format.")
        }
        var result = [Int: [Int: URL]]()
        var sourceIDs = Set<Int>()
        for (showKey, sources) in raw {
            guard let showID = Int(showKey), showID > 0 else {
                throw UpdateError("The live download-link data contains an invalid show ID.")
            }
            for source in sources {
                guard let sourceID = source["id"] as? Int, sourceID > 0, sourceIDs.insert(sourceID).inserted else {
                    throw UpdateError("The live download-link data contains a duplicate or invalid source ID.")
                }
                guard let value = source["driveUrl"] as? String,
                      let url = canonicalDownloadURL(value) else { continue }
                result[showID, default: [:]][sourceID] = url
            }
        }
        guard !result.isEmpty else {
            throw UpdateError("The Tool Drive Project did not publish any usable download links.")
        }
        return result
    }

    static func canonicalDownloadURL(_ value: String) -> URL? {
        guard value.count <= 2_048,
              let supplied = URLComponents(string: value),
              supplied.scheme?.lowercased() == "https",
              supplied.host?.lowercased() == "drive.google.com",
              supplied.port == nil, supplied.user == nil, supplied.password == nil,
              supplied.fragment == nil else { return nil }
        let pattern = "^/drive/folders/([A-Za-z0-9_-]{8,128})/?$"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: supplied.path, range: NSRange(supplied.path.startIndex..., in: supplied.path)),
              match.range.location != NSNotFound,
              let folderRange = Range(match.range(at: 1), in: supplied.path) else { return nil }
        var canonical = URLComponents()
        canonical.scheme = "https"
        canonical.host = "drive.google.com"
        canonical.path = "/drive/folders/" + supplied.path[folderRange]
        return canonical.url
    }

    static func tracks(_ data: Data, date: String, version: Int) throws -> [LiveTrack] {
        try validateDate(date)
        guard (0...999).contains(version),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool == true,
              let payload = root["data"] as? [String: Any],
              let rows = payload["tracks"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= 250 else {
            throw UpdateError("The live track list is missing or invalid.")
        }
        let year = String(date.prefix(4))
        let escapedDate = NSRegularExpression.escapedPattern(for: date)
        let pattern = "^/mp3_2\\.0/" + year + "/tool" + escapedDate + "\\.v" + String(version)
            + "/tool" + escapedDate + "\\.v" + String(version) + "\\.t([0-9]{1,3})\\.mp3$"
        let expression = try NSRegularExpression(pattern: pattern)
        var numbers = Set<Int>()
        var tracks = [LiveTrack]()
        for row in rows {
            guard let number = integer(row["trackNumber"]), number > 0, number <= 999,
                  numbers.insert(number).inserted,
                  let path = row["url"] as? String, path.count <= 2_048,
                  let match = expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
                  match.range.location != NSNotFound,
                  let pathNumberRange = Range(match.range(at: 1), in: path),
                  Int(path[pathNumberRange]) == number else {
                throw UpdateError("The live track list contains an unsafe or mismatched audio path.")
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "tooldriveproject.net"
            components.path = path
            guard let url = components.url else { throw UpdateError("The live track URL is invalid.") }
            let rawTitle = (row["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawTitle.count <= 300 else { throw UpdateError("A live track title is too long.") }
            let title = rawTitle.isEmpty ? "Track \(number)" : rawTitle
            let duration = finiteDouble(row["durationSeconds"]).flatMap { (0...8 * 60 * 60).contains($0) ? $0 : nil }
            tracks.append(LiveTrack(number: number, title: title, duration: duration, url: url))
        }
        return tracks
    }

    static func streamURL(date: String, version: Int) throws -> URL {
        try validateDate(date)
        guard (0...999).contains(version) else { throw UpdateError("The recording version is invalid.") }
        var components = URLComponents(url: streamBaseURL.appendingPathComponent("api/stream/resolve.php"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "date", value: date), URLQueryItem(name: "ver", value: String(version))]
        guard let url = components.url else { throw UpdateError("The live track-list address is invalid.") }
        return url
    }

    private static func validateDate(_ value: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let date = formatter.date(from: value), formatter.string(from: date) == value else {
            throw UpdateError("The show date is invalid.")
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? NSNumber { number = value.doubleValue }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
}

final class LiveMediaService {
    typealias DownloadLinks = [Int: [Int: URL]]
    typealias LinkCompletion = (Result<DownloadLinks, Error>) -> Void
    typealias TrackCompletion = (Result<[LiveTrack], Error>) -> Void

    private struct TrackKey: Hashable { let date: String; let version: Int }
    private let lock = NSLock()
    private let work = DispatchQueue(label: "net.bentley734.tooldriveoffline.live-media", qos: .utility)
    private var linkCache: DownloadLinks?
    private var linkOperation: UpdateOperation?
    private var linkWaiters = [LinkCompletion]()
    private var trackCache = [TrackKey: [LiveTrack]]()
    private var trackOperation: UpdateOperation?
    private var trackGeneration = 0

    func loadDownloadLinks(_ completion: @escaping LinkCompletion) {
        lock.lock()
        if let cached = linkCache {
            lock.unlock()
            DispatchQueue.main.async { completion(.success(cached)) }
            return
        }
        linkWaiters.append(completion)
        if linkOperation != nil { lock.unlock(); return }
        let operation = UpdateOperation()
        linkOperation = operation
        lock.unlock()
        work.async { [weak self] in
            let result: Result<DownloadLinks, Error>
            do {
                let data = try operation.fetch(LiveMediaParser.sourceURL, limit: 4 * 1024 * 1024)
                result = .success(try LiveMediaParser.downloadLinks(data))
            } catch { result = .failure(error) }
            self?.finishLinks(operation, result)
        }
    }

    @discardableResult
    func resolveTracks(showID: Int, sourceID: Int, date: String, version: Int,
                       completion: @escaping TrackCompletion) -> Int {
        lock.lock()
        trackGeneration += 1
        let generation = trackGeneration
        trackOperation?.cancel()
        trackOperation = nil
        let key = TrackKey(date: date, version: version)
        if let cached = trackCache[key] {
            lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard self?.isCurrent(generation) == true else { return }
                completion(.success(cached))
            }
            return generation
        }
        guard showID > 0, sourceID > 0 else {
            lock.unlock()
            DispatchQueue.main.async { completion(.failure(UpdateError("The requested recording is invalid."))) }
            return generation
        }
        let operation = UpdateOperation()
        trackOperation = operation
        lock.unlock()
        work.async { [weak self] in
            let result: Result<[LiveTrack], Error>
            do {
                let url = try LiveMediaParser.streamURL(date: date, version: version)
                let data = try operation.fetch(url, limit: 512 * 1024)
                result = .success(try LiveMediaParser.tracks(data, date: date, version: version))
            } catch { result = .failure(error) }
            self?.finishTracks(operation, generation, key, result, completion)
        }
        return generation
    }

    func cancelTrackResolution() {
        lock.lock()
        trackGeneration += 1
        let operation = trackOperation
        trackOperation = nil
        lock.unlock()
        operation?.cancel()
    }

    func cancelAll() {
        cancelTrackResolution()
        lock.lock()
        let operation = linkOperation
        let waiters = linkWaiters
        linkOperation = nil
        linkWaiters = []
        lock.unlock()
        operation?.cancel()
        if !waiters.isEmpty {
            DispatchQueue.main.async {
                let error = UpdateError("The live-media request was canceled.")
                waiters.forEach { $0(.failure(error)) }
            }
        }
    }

    private func finishLinks(_ operation: UpdateOperation, _ result: Result<DownloadLinks, Error>) {
        lock.lock()
        guard linkOperation === operation else { lock.unlock(); return }
        if case .success(let value) = result { linkCache = value }
        linkOperation = nil
        let waiters = linkWaiters
        linkWaiters = []
        lock.unlock()
        DispatchQueue.main.async { waiters.forEach { $0(result) } }
    }

    private func finishTracks(_ operation: UpdateOperation, _ generation: Int, _ key: TrackKey,
                              _ result: Result<[LiveTrack], Error>, _ completion: @escaping TrackCompletion) {
        lock.lock()
        guard trackOperation === operation, trackGeneration == generation else { lock.unlock(); return }
        if case .success(let tracks) = result { trackCache[key] = tracks }
        trackOperation = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrent(generation) == true else { return }
            completion(result)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return trackGeneration == generation
    }
}
