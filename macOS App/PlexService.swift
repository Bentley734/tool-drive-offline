import Foundation
import Security

struct PlexServiceError: LocalizedError {
    let message: String
    let isCancellation: Bool
    let retryOtherConnection: Bool

    init(_ message: String, isCancellation: Bool = false, retryOtherConnection: Bool = false) {
        self.message = message
        self.isCancellation = isCancellation
        self.retryOtherConnection = retryOtherConnection
    }

    static var canceled: PlexServiceError {
        PlexServiceError("The Plex request was canceled.", isCancellation: true)
    }

    var errorDescription: String? { message }
}

struct PlexAuthorizationSession: Equatable {
    let pinID: Int
    let authorizationURL: URL
}

enum PlexAuthorizationPoll: Equatable {
    case pending
    case connected
}

struct PlexServer: Equatable {
    let id: String
    let name: String
    let owned: Bool
    let connectionCount: Int

    var summary: [String: Any] {
        ["id": id, "name": name, "owned": owned, "connectionCount": connectionCount]
    }
}

struct PlexLibrary: Equatable {
    let id: String
    let name: String

    static func restoredID(in libraries: [PlexLibrary], preferred: String?) -> String? {
        if let preferred = preferred, libraries.contains(where: { $0.id == preferred }) { return preferred }
        return libraries.count == 1 ? libraries[0].id : nil
    }
}

struct PlexTrackSummary: Equatable {
    let number: Int
    let title: String
    let duration: TimeInterval?

    var summary: [String: Any] {
        var value: [String: Any] = ["number": number, "title": title]
        if let duration = duration { value["duration"] = duration }
        return value
    }
}

struct PlexSearchResult {
    let showDate: String
    let version: Int
    let collection: String
    let tracks: [PlexTrackSummary]
    fileprivate let playbackTracks: [LiveTrack]

    var summary: [String: Any] {
        [
            "showDate": showDate,
            "version": version,
            "collection": collection,
            "tracks": tracks.map(\.summary)
        ]
    }

    // Native integration only. Do not serialize these URLs into WebKit messages.
    func withNativePlaybackTracks(_ body: ([LiveTrack]) -> Void) {
        body(playbackTracks)
    }
}

struct PlexStatus: Equatable {
    let phase: String
    let connected: Bool
    let serverCount: Int
    let selectedServerID: String?
    let selectedServerName: String?
    let selectedLibraryID: String?
    let selectedLibraryName: String?
    let message: String

    var summary: [String: Any] {
        var value: [String: Any] = [
            "phase": phase,
            "connected": connected,
            "serverCount": serverCount,
            "message": message
        ]
        if let selectedServerID = selectedServerID { value["selectedServerID"] = selectedServerID }
        if let selectedServerName = selectedServerName { value["selectedServerName"] = selectedServerName }
        if let selectedLibraryID = selectedLibraryID { value["selectedLibraryID"] = selectedLibraryID }
        if let selectedLibraryName = selectedLibraryName { value["selectedLibraryName"] = selectedLibraryName }
        return value
    }
}

protocol PlexCredentialStore: AnyObject {
    func contains(_ account: String) throws -> Bool
    func value(for account: String) throws -> String?
    func setValue(_ value: String, for account: String) throws
    func removeValue(for account: String) throws
    func removeValues(withPrefix prefix: String) throws
}

extension PlexCredentialStore {
    func contains(_ account: String) throws -> Bool { try value(for: account) != nil }
}

final class PlexKeychainStore: PlexCredentialStore {
    private let service = "net.bentley734.tooldriveoffline.plex"

    func contains(_ account: String) throws -> Bool {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw PlexServiceError("Keychain could not check the Plex account.") }
        return true
    }

    func value(for account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PlexServiceError("The Plex credential could not be read from Keychain.")
        }
        return value
    }

    func setValue(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw PlexServiceError("The Plex credential is invalid.")
        }
        let query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PlexServiceError("The Plex credential could not be updated in Keychain.")
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw PlexServiceError("The Plex credential could not be saved in Keychain.")
        }
    }

    func removeValue(for account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PlexServiceError("The Plex credential could not be removed from Keychain.")
        }
    }

    func removeValues(withPrefix prefix: String) throws {
        var query = baseQuery(account: nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else {
            throw PlexServiceError("The Plex credentials could not be listed in Keychain.")
        }
        for attributes in result as? [[String: Any]] ?? [] {
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  account.hasPrefix(prefix) else { continue }
            try removeValue(for: account)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account = account { query[kSecAttrAccount as String] = account }
        return query
    }
}

private struct PlexConnectionRecord: Equatable {
    let url: URL
    let local: Bool
    let relay: Bool

    var rank: Int {
        if relay { return 2 }
        return local ? 0 : 1
    }
}

private struct PlexServerRecord {
    let server: PlexServer
    let connections: [PlexConnectionRecord]
    let token: String
}

private struct PlexPinRecord {
    let id: Int
    let code: String
    let token: String?
}

private struct PlexPartRecord {
    let key: String
    let filePath: String
    let fileName: String
    let format: String
}

private struct PlexTrackRecord {
    let identity: String
    let albumIdentity: String
    let albumTitle: String
    let title: String
    let artist: String
    let duration: TimeInterval?
    let part: PlexPartRecord
}

enum PlexParser {
    private static let supportedFormats: Set<String> = [
        "flac", "alac", "wav", "wave", "aif", "aiff", "mp3", "aac", "m4a", "mp4", "caf"
    ]

    static func pin(_ data: Data) throws -> (id: Int, code: String, hasToken: Bool) {
        let record = try pinRecord(data)
        return (record.id, record.code, record.token != nil)
    }

    static func authorizationURL(clientIdentifier: String, code: String,
                                 product: String = "Tool Drive Offline") throws -> URL {
        guard validIdentifier(clientIdentifier, maximum: 200), validIdentifier(code, maximum: 200) else {
            throw PlexServiceError("Plex returned an invalid authorization code.")
        }
        let product = clean(product, maximum: 100)
        guard !product.isEmpty else { throw PlexServiceError("The Plex application name is invalid.") }
        var query = URLComponents()
        query.queryItems = [
            URLQueryItem(name: "clientID", value: clientIdentifier),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "context[device][product]", value: product)
        ]
        guard let encoded = query.percentEncodedQuery,
              let url = URL(string: "https://app.plex.tv/auth#?" + encoded),
              url.scheme == "https", url.host == "app.plex.tv" else {
            throw PlexServiceError("The Plex authorization page could not be created.")
        }
        return url
    }

    static func resources(_ data: Data) throws -> [PlexServer] {
        try resourceRecords(data).map(\.server)
    }

    static func libraries(_ data: Data) throws -> [PlexLibrary] {
        guard data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw PlexServiceError("Plex returned an invalid library list.")
        }
        if container["Directory"] == nil, integer(container["size"]) == 0 { return [] }
        guard let rows = container["Directory"] as? [[String: Any]], rows.count <= 2_000 else {
            throw PlexServiceError("Plex returned an invalid library list.")
        }
        var seen = Set<String>()
        return rows.compactMap { row -> PlexLibrary? in
            guard row["type"] as? String == "artist", let id = numericIdentifier(row["key"]),
                  let number = UInt(id), number > 0, String(number) == id,
                  let name = string(row["title"], maximum: 300), seen.insert(id).inserted else { return nil }
            return PlexLibrary(id: id, name: name)
        }.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    static func validatedConnection(_ value: String, local: Bool, relay: Bool) -> URL? {
        connection(value, local: local, relay: relay)?.url
    }

    static func validatedPartPath(_ value: String) -> String? {
        guard value.count <= 2_048,
              value.hasPrefix("/library/parts/"),
              !value.contains("\\"), !value.contains("?"), !value.contains("#"),
              let encoded = URLComponents(string: value),
              encoded.scheme == nil, encoded.host == nil, encoded.percentEncodedPath == value,
              let decoded = value.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.contains("//") else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 5,
              components[0].isEmpty,
              components[1] == "library", components[2] == "parts",
              components[3].count <= 20, !components[3].isEmpty,
              components[3].allSatisfy(\.isNumber),
              components.dropFirst(4).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 }) else {
            return nil
        }
        return value
    }

    static func albumKeys(_ data: Data, showDate: String, sectionID: String? = nil) throws -> [String] {
        try validateDate(showDate)
        let metadata = try metadataRows(data, sectionID: sectionID)
        var seen = Set<String>()
        return metadata.compactMap { row in
            guard (row["type"] as? String)?.lowercased() == "album",
                  let title = string(row["title"], maximum: 300), title.contains(showDate),
                  sectionID != nil || artistName(row).caseInsensitiveCompare("TOOL") == .orderedSame,
                  let key = numericIdentifier(row["ratingKey"]), seen.insert(key).inserted else { return nil }
            return key
        }.prefix(12).map { $0 }
    }

    static func search(_ data: Data, showDate: String, preferredVersion: Int?,
                       serverURL: URL, token: String, sectionID: String? = nil) throws -> PlexSearchResult {
        let records = try trackRecords(data, showDate: showDate, sectionID: sectionID)
        return try search(records, showDate: showDate, preferredVersion: preferredVersion,
                          serverURL: serverURL, token: token)
    }

    static func searchQueries(showDate: String, preferredVersion: Int?) throws -> [String] {
        try validateDate(showDate)
        guard preferredVersion == nil || (0...999).contains(preferredVersion!) else {
            throw PlexServiceError("The Plex recording version is invalid.")
        }
        var queries = [String]()
        if let preferredVersion = preferredVersion {
            queries.append("tool\(showDate).v\(preferredVersion)")
        }
        queries.append("Tool \(showDate)")
        queries.append(showDate)
        var seen = Set<String>()
        return queries.filter { seen.insert($0.lowercased()).inserted }
    }

    static func validatedPlaybackTracks(_ supplied: [LiveTrack]) throws -> [LiveTrack] {
        guard !supplied.isEmpty, supplied.count <= 250 else {
            throw PlexServiceError("A Plex recording must contain between 1 and 250 tracks.")
        }
        var numbers = Set<Int>()
        return try supplied.map { track in
            guard track.number > 0, track.number <= 999, numbers.insert(track.number).inserted else {
                throw PlexServiceError("The Plex recording contains a duplicate or invalid track number.")
            }
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 300,
                  track.duration == nil || (track.duration!.isFinite && (0...86_400).contains(track.duration!)),
                  var components = URLComponents(url: track.url, resolvingAgainstBaseURL: false),
                  components.user == nil, components.password == nil, components.fragment == nil,
                  validatedPartPath(components.percentEncodedPath) != nil,
                  supportedFormats.contains(track.url.pathExtension.lowercased()),
                  let query = components.queryItems, query.count == 1,
                  query[0].name == "X-Plex-Token", let token = query[0].value, validToken(token) else {
                throw PlexServiceError("A Plex playback track is invalid or unsupported.")
            }
            components.percentEncodedPath = ""
            components.query = nil
            guard let base = components.url,
                  connection(base.absoluteString, local: false, relay: false) != nil else {
                throw PlexServiceError("A Plex playback track uses an untrusted server address.")
            }
            // Preserve the original, already authenticated URL. UI callbacks use LiveTrack.summary, which omits it.
            return LiveTrack(number: track.number, title: title, duration: track.duration, url: track.url)
        }
    }

    fileprivate static func pinRecord(_ data: Data) throws -> PlexPinRecord {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = integer(root["id"]), id > 0,
              let code = string(root["code"], maximum: 200), validIdentifier(code, maximum: 200) else {
            throw PlexServiceError("Plex returned an invalid authorization response.")
        }
        let rawToken = root["authToken"] ?? root["auth_token"]
        let token: String?
        if rawToken == nil || rawToken is NSNull { token = nil }
        else {
            guard let value = rawToken as? String, validToken(value) else {
                throw PlexServiceError("Plex returned an invalid account credential.")
            }
            token = value
        }
        return PlexPinRecord(id: id, code: code, token: token)
    }

    fileprivate static func resourceRecords(_ data: Data) throws -> [PlexServerRecord] {
        guard data.count <= 2 * 1024 * 1024,
              let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              rows.count <= 100 else {
            throw PlexServiceError("Plex returned an invalid server list.")
        }
        var identifiers = Set<String>()
        var records = [PlexServerRecord]()
        for row in rows {
            let provides = (row["provides"] as? String ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard provides.contains("server"),
                  let identifier = string(row["clientIdentifier"], maximum: 200),
                  validIdentifier(identifier, maximum: 200), identifiers.insert(identifier).inserted,
                  let token = string(row["accessToken"], maximum: 8_192), validToken(token),
                  let rawConnections = row["connections"] as? [[String: Any]],
                  rawConnections.count <= 32 else { continue }
            let connections = rawConnections.compactMap { raw -> PlexConnectionRecord? in
                guard let uri = string(raw["uri"], maximum: 2_048) else { return nil }
                return connection(uri, local: boolean(raw["local"]), relay: boolean(raw["relay"]))
            }.sorted { lhs, rhs in
                lhs.rank == rhs.rank ? lhs.url.absoluteString < rhs.url.absoluteString : lhs.rank < rhs.rank
            }
            guard !connections.isEmpty else { continue }
            let name = string(row["name"], maximum: 200).flatMap { $0.isEmpty ? nil : $0 } ?? "Plex Media Server"
            let server = PlexServer(id: identifier, name: name, owned: boolean(row["owned"]),
                                    connectionCount: connections.count)
            records.append(PlexServerRecord(server: server, connections: connections, token: token))
        }
        guard !records.isEmpty else { throw PlexServiceError("No reachable Plex Media Server was found.") }
        return records.sorted {
            if $0.server.owned != $1.server.owned {
                return $0.server.owned && !$1.server.owned
            }
            return $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
        }
    }

    fileprivate static func trackRecords(_ data: Data, showDate: String, sectionID: String? = nil) throws -> [PlexTrackRecord] {
        try validateDate(showDate)
        return try metadataRows(data, sectionID: sectionID).compactMap { row in
            guard (row["type"] as? String)?.lowercased() == "track",
                  let identity = numericIdentifier(row["ratingKey"]),
                  let title = string(row["title"], maximum: 300), !title.isEmpty,
                  let mediaRows = row["Media"] as? [[String: Any]], mediaRows.count <= 16 else { return nil }
            let albumTitle = string(row["parentTitle"], maximum: 300) ?? ""
            let artist = artistName(row)
            let metadataMatches = albumTitle.contains(showDate)
                && artist.caseInsensitiveCompare("TOOL") == .orderedSame
            let albumIdentity = numericIdentifier(row["parentRatingKey"]) ?? albumTitle.lowercased()
            let duration = milliseconds(row["duration"])
            for media in mediaRows {
                guard let parts = media["Part"] as? [[String: Any]], parts.count <= 16 else { continue }
                for part in parts {
                    guard let keyValue = string(part["key"], maximum: 2_048),
                          let key = validatedPartPath(keyValue),
                          let file = string(part["file"], maximum: 8_192) else { continue }
                    let normalizedFile = file.replacingOccurrences(of: "\\", with: "/")
                    guard let fileName = normalizedFile.split(separator: "/").last.map(String.init),
                          !fileName.isEmpty,
                          metadataMatches || exactArchiveHierarchy(file, showDate: showDate) else { continue }
                    let format = (string(part["container"], maximum: 20)
                                  ?? string(media["container"], maximum: 20)
                                  ?? URL(fileURLWithPath: fileName).pathExtension).lowercased()
                    return PlexTrackRecord(identity: identity, albumIdentity: albumIdentity,
                                           albumTitle: albumTitle, title: title, artist: artist,
                                           duration: duration,
                                           part: PlexPartRecord(key: key, filePath: file,
                                                                fileName: fileName, format: format))
                }
            }
            return nil
        }
    }

    fileprivate static func search(_ records: [PlexTrackRecord], showDate: String,
                                   preferredVersion: Int?, serverURL: URL,
                                   token: String) throws -> PlexSearchResult {
        try validateDate(showDate)
        guard preferredVersion == nil || (0...999).contains(preferredVersion!),
              validToken(token),
              let trustedBase = connection(serverURL.absoluteString, local: false, relay: false)?.url else {
            throw PlexServiceError("The Plex playback request is invalid.")
        }
        let escaped = NSRegularExpression.escapedPattern(for: showDate)
        let expression = try NSRegularExpression(
            pattern: "(?i)^tool" + escaped + "\\.v([0-9]{1,3})\\.t([0-9]{1,3})\\.([a-z0-9]{2,8})$"
        )
        struct Candidate {
            let record: PlexTrackRecord
            let version: Int
            let number: Int
            let format: String
            let exactHierarchy: Bool
        }
        var exact = [Candidate]()
        var seenParts = Set<String>()
        var sawUnsupported = false
        for record in records {
            let name = record.part.fileName
            guard let match = expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let versionRange = Range(match.range(at: 1), in: name),
                  let numberRange = Range(match.range(at: 2), in: name),
                  let formatRange = Range(match.range(at: 3), in: name),
                  let version = Int(name[versionRange]), let number = Int(name[numberRange]),
                  version <= 999, number > 0, number <= 999 else { continue }
            let format = String(name[formatRange]).lowercased()
            if let preferredVersion = preferredVersion, version != preferredVersion { continue }
            guard supportedFormats.contains(format), supportedFormats.contains(record.part.format) else {
                sawUnsupported = true
                continue
            }
            guard seenParts.insert(record.identity + "|" + record.part.key).inserted else { continue }
            let normalizedPath = record.part.filePath.replacingOccurrences(of: "\\", with: "/")
            let pathComponents = normalizedPath.split(separator: "/").map(String.init)
            let folder = "tool\(showDate).v\(version)"
            let exactHierarchy = pathComponents.count >= 3
                && pathComponents[pathComponents.count - 1].caseInsensitiveCompare(name) == .orderedSame
                && pathComponents[pathComponents.count - 2].caseInsensitiveCompare(folder) == .orderedSame
                && pathComponents[pathComponents.count - 3] == String(showDate.prefix(4))
            exact.append(Candidate(record: record, version: version, number: number,
                                   format: format, exactHierarchy: exactHierarchy))
        }
        if exact.isEmpty {
            if sawUnsupported {
                throw PlexServiceError("This Plex recording uses a format that cannot be played directly. Transcoding is not enabled.")
            }
            if let preferredVersion = preferredVersion {
                throw PlexServiceError("Plex did not find the exact tool\(showDate).v\(preferredVersion) recording.")
            }
            throw PlexServiceError("Plex did not find audio whose filenames exactly match this show date.")
        }
        let grouped = Dictionary(grouping: exact) { "\($0.record.albumIdentity)|v\($0.version)" }
        let viable = grouped.compactMap { key, values -> (String, [Candidate])? in
            guard values.count <= 250,
                  Set(values.map(\.number)).count == values.count,
                  Set(values.map { $0.record.identity }).count == values.count else { return nil }
            return (key, values)
        }.sorted { lhs, rhs in
            let leftHierarchy = lhs.1.filter(\.exactHierarchy).count
            let rightHierarchy = rhs.1.filter(\.exactHierarchy).count
            if leftHierarchy != rightHierarchy { return leftHierarchy > rightHierarchy }
            if lhs.1.count != rhs.1.count { return lhs.1.count > rhs.1.count }
            let leftVersion = lhs.1.first?.version ?? Int.max
            let rightVersion = rhs.1.first?.version ?? Int.max
            return leftVersion == rightVersion ? lhs.0 < rhs.0 : leftVersion < rightVersion
        }
        guard let chosen = viable.first, !chosen.1.isEmpty else {
            throw PlexServiceError("The Plex recording contains duplicate or too many tracks.")
        }
        let ordered = chosen.1.sorted { $0.number == $1.number ? $0.record.identity < $1.record.identity : $0.number < $1.number }
        let version = ordered[0].version
        var playback = [LiveTrack]()
        var summaries = [PlexTrackSummary]()
        for candidate in ordered {
            let url = try playbackURL(base: trustedBase, partPath: candidate.record.part.key, token: token)
            let summary = PlexTrackSummary(number: candidate.number, title: candidate.record.title,
                                           duration: candidate.record.duration)
            summaries.append(summary)
            playback.append(LiveTrack(number: summary.number, title: summary.title,
                                      duration: summary.duration, url: url))
        }
        let album = ordered[0].record.albumTitle
        let collection = album.contains(showDate) ? album + " · v\(version)" : "TOOL \(showDate) · v\(version)"
        return PlexSearchResult(showDate: showDate, version: version, collection: collection,
                                tracks: summaries, playbackTracks: playback)
    }

    private static func playbackURL(base: URL, partPath: String, token: String) throws -> URL {
        guard let path = validatedPartPath(partPath), validToken(token),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PlexServiceError("A Plex media path is invalid.")
        }
        components.percentEncodedPath = path
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let url = components.url else { throw PlexServiceError("A Plex playback URL is invalid.") }
        return url
    }

    private static func exactArchiveHierarchy(_ file: String, showDate: String) -> Bool {
        let components = file.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[components.count - 3] == String(showDate.prefix(4)) else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: showDate)
        let folderPattern = "(?i)^tool" + escaped + "\\.v[0-9]{1,3}$"
        let filePattern = "(?i)^tool" + escaped + "\\.v[0-9]{1,3}\\.t[0-9]{1,3}\\.[a-z0-9]{2,8}$"
        let folder = components[components.count - 2]
        let fileName = components[components.count - 1]
        return folder.range(of: folderPattern, options: .regularExpression) != nil
            && fileName.range(of: filePattern, options: .regularExpression) != nil
            && fileName.lowercased().hasPrefix(folder.lowercased() + ".t")
    }

    private static func metadataRows(_ data: Data, sectionID: String?) throws -> [[String: Any]] {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = root["MediaContainer"] as? [String: Any] else {
            throw PlexServiceError("Plex returned invalid library results.")
        }
        // Section-scoped endpoints sometimes place the identifier only on the container.
        func belongsToSection(_ item: [String: Any]) -> Bool {
            guard let sectionID = sectionID, let supplied = item["librarySectionID"] else { return true }
            return numericIdentifier(supplied) == sectionID
        }
        guard belongsToSection(container) else { return [] }
        var rows = container["Metadata"] as? [[String: Any]] ?? []
        if let hubs = container["Hub"] as? [[String: Any]] {
            guard hubs.count <= 100 else { throw PlexServiceError("Plex returned too many search groups.") }
            for hub in hubs {
                guard belongsToSection(hub),
                      let metadata = hub["Metadata"] as? [[String: Any]], metadata.count <= 500 else { continue }
                rows.append(contentsOf: metadata)
            }
        }
        guard rows.count <= 2_000 else { throw PlexServiceError("Plex returned too many search results.") }
        return rows.filter(belongsToSection)
    }

    private static func connection(_ value: String, local: Bool, relay: Bool) -> PlexConnectionRecord? {
        guard value.count <= 2_048,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) != false else { return nil }
        guard scheme == "https", host == "plex.direct" || host.hasSuffix(".plex.direct") else { return nil }
        var canonical = components
        canonical.scheme = scheme
        canonical.host = host
        canonical.path = ""
        guard let url = canonical.url else { return nil }
        return PlexConnectionRecord(url: url, local: local, relay: relay)
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
            throw PlexServiceError("The Plex show date is invalid.")
        }
    }

    private static func numericIdentifier(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty, value.count <= 20, value.allSatisfy(\.isNumber) { return value }
        if let value = integer(value), value > 0 { return String(value) }
        return nil
    }

    private static func artistName(_ row: [String: Any]) -> String {
        for key in ["grandparentTitle", "originalTitle", "parentTitle"] {
            if let value = string(row[key], maximum: 300), value.caseInsensitiveCompare("TOOL") == .orderedSame {
                return value
            }
        }
        return ""
    }

    private static func clean(_ value: String, maximum: Int) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maximum,
              cleaned.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return "" }
        return cleaned
    }

    private static func string(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String else { return nil }
        let result = clean(value, maximum: maximum)
        return result.isEmpty ? nil : result
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func milliseconds(_ value: Any?) -> TimeInterval? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number.flatMap { $0.isFinite && (0...86_400_000).contains($0) ? $0 / 1_000 : nil }
    }

    private static func boolean(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }

    private static func validIdentifier(_ value: String, maximum: Int) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        return value.count >= 4 && value.count <= maximum
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func validToken(_ value: String) -> Bool {
        value.count >= 8 && value.count <= 8_192
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
            }
    }
}

final class PlexRequestOperation: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var canceled = false
    private var data = Data()
    private var error: Error?
    private var task: URLSessionDataTask?
    private var semaphore: DispatchSemaphore?
    private var limit = 0

    func cancel() {
        lock.lock(); canceled = true; let current = task; lock.unlock()
        current?.cancel()
    }

    func fetch(_ request: URLRequest, limit: Int, timeout: TimeInterval = 25) throws -> Data {
        lock.lock(); let wasCanceled = canceled; lock.unlock()
        if wasCanceled { throw PlexServiceError.canceled }
        self.limit = limit
        data = Data()
        error = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let done = DispatchSemaphore(value: 0)
        semaphore = done
        let task = session.dataTask(with: request)
        lock.lock(); self.task = task; let nowCanceled = canceled; lock.unlock()
        if nowCanceled { throw PlexServiceError.canceled }
        task.resume()
        guard done.wait(timeout: .now() + timeout + 10) == .success else {
            task.cancel()
            throw PlexServiceError("The Plex server did not respond in time.", retryOtherConnection: true)
        }
        lock.lock(); let finallyCanceled = canceled; lock.unlock()
        if finallyCanceled { throw PlexServiceError.canceled }
        if let error = error { throw error }
        return data
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            error = PlexServiceError("Plex returned an invalid response.")
            completionHandler(.cancel)
            return
        }
        let created = dataTask.originalRequest?.httpMethod == "POST" && http.statusCode == 201
        guard http.statusCode == 200 || created else {
            error = PlexServiceError("Plex returned HTTP \(http.statusCode).", retryOtherConnection: true)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(limit) else {
            error = PlexServiceError("The Plex response exceeded its size limit.")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > limit {
            error = PlexServiceError("The Plex response exceeded its size limit.")
            dataTask.cancel()
        } else { data.append(chunk) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError received: Error?) {
        if error == nil, let received = received {
            let message: String
            switch (received as? URLError)?.code {
            case .timedOut: message = "The Plex server timed out."
            case .cannotFindHost, .dnsLookupFailed: message = "The Plex server’s address could not be resolved."
            case .cannotConnectToHost: message = "The Plex server refused the connection or is unreachable."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                message = "A secure connection to the Plex server could not be verified."
            case .notConnectedToInternet, .dataNotAllowed:
                message = "Network access is unavailable. Check the network and this app’s Local Network permission."
            case .networkConnectionLost: message = "The connection to the Plex server was interrupted."
            default: message = "The Plex request failed. Check the server connection and try again."
            }
            error = PlexServiceError(message, retryOtherConnection: true)
        }
        semaphore?.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class PlexService {
    typealias StatusHandler = (PlexStatus) -> Void

    var onStatusChange: StatusHandler?

    private static let accountKey = "account"
    private static let serverKeyPrefix = "server:"
    private let clientIdentifier: String
    private let version: String
    private let credentials: PlexCredentialStore
    private var hasAccount: Bool
    private let work = DispatchQueue(label: "net.bentley734.tooldriveoffline.plex", qos: .utility)
    private let lock = NSLock()
    private var records = [String: PlexServerRecord]()
    private var selectedID: String?
    private var libraries = [PlexLibrary]()
    private var selectedLibraryID: String?
    private var workingConnection: URL?
    private var phase = "disconnected"
    private var message = ""
    private var generation = 0
    private var operation: PlexRequestOperation?
    private var cancellationHandler: (() -> Void)?

    init(clientIdentifier: String? = nil, version: String = "1.0",
         credentials: PlexCredentialStore = PlexKeychainStore()) {
        self.clientIdentifier = clientIdentifier ?? Self.persistentClientIdentifier()
        self.version = version
        self.credentials = credentials
        hasAccount = (try? credentials.contains(Self.accountKey)) == true
        phase = hasAccount ? "connected" : "disconnected"
    }

    deinit { cancelCurrentRequest(notify: false) }

    var status: PlexStatus {
        lock.lock(); defer { lock.unlock() }
        return statusLocked()
    }

    func beginConnection(_ completion: @escaping (Result<PlexAuthorizationSession, Error>) -> Void) {
        lock.lock()
        records.removeAll()
        selectedID = nil
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        lock.unlock()
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=true") else { return }
        let request = authorizedRequest(url: url, method: "POST", token: nil)
        run(phase: "authorizing", message: "Waiting for Plex sign-in…", request: request,
            limit: 256 * 1024) { [weak self] data -> PlexAuthorizationSession in
            guard let self = self else { throw PlexServiceError("The Plex connection was canceled.") }
            let pin = try PlexParser.pinRecord(data)
            let url = try PlexParser.authorizationURL(clientIdentifier: self.clientIdentifier, code: pin.code)
            return PlexAuthorizationSession(pinID: pin.id, authorizationURL: url)
        } completion: { [weak self] result in
            if case .failure(let error) = result,
               (error as? PlexServiceError)?.isCancellation != true {
                self?.setFailure(error.localizedDescription)
            }
            completion(result)
        }
    }

    func pollConnection(pinID: Int, completion: @escaping (Result<PlexAuthorizationPoll, Error>) -> Void) {
        guard pinID > 0,
              let url = URL(string: "https://plex.tv/api/v2/pins/\(pinID)") else {
            completion(.failure(PlexServiceError("The Plex authorization request is invalid.")))
            return
        }
        let request = authorizedRequest(url: url, method: "GET", token: nil)
        run(phase: "authorizing", message: "Waiting for Plex sign-in…", request: request,
            limit: 256 * 1024) { data -> PlexPinRecord in
            let pin = try PlexParser.pinRecord(data)
            guard pin.id == pinID else { throw PlexServiceError("Plex returned a mismatched authorization response.") }
            return pin
        } completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let pin):
                guard let token = pin.token else { completion(.success(.pending)); return }
                do {
                    try self.credentials.setValue(token, for: Self.accountKey)
                    self.lock.lock()
                    self.hasAccount = true
                    self.lock.unlock()
                    self.setPhase("connected", message: "Connected to Plex.")
                    completion(.success(.connected))
                } catch {
                    self.setFailure(error.localizedDescription)
                    completion(.failure(error))
                }
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true {
                    self.setFailure(error.localizedDescription)
                }
                completion(.failure(error))
            }
        }
    }

    func refreshServers(_ completion: @escaping (Result<[PlexServer], Error>) -> Void) {
        cancelCurrentRequest()
        lock.lock()
        records.removeAll()
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        lock.unlock()
        let token: String
        do {
            guard let stored = try credentials.value(for: Self.accountKey) else {
                throw PlexServiceError("Connect a Plex account first.")
            }
            token = stored
        } catch {
            lock.lock()
            hasAccount = false
            lock.unlock()
            setFailure(error.localizedDescription)
            completion(.failure(error)); return
        }
        var components = URLComponents(string: "https://clients.plex.tv/api/v2/resources")!
        components.queryItems = [
            URLQueryItem(name: "includeHttps", value: "1"),
            URLQueryItem(name: "includeRelay", value: "1"),
            URLQueryItem(name: "includeIPv6", value: "1")
        ]
        let request = authorizedRequest(url: components.url!, method: "GET", token: token)
        run(phase: "loadingServers", message: "Finding Plex servers…", request: request,
            limit: 2 * 1024 * 1024) { data -> [PlexServerRecord] in
            try PlexParser.resourceRecords(data)
        } completion: { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let parsed):
                self.lock.lock()
                self.records = Dictionary(uniqueKeysWithValues: parsed.map { ($0.server.id, $0) })
                self.hasAccount = true
                if self.selectedID.flatMap({ self.records[$0] }) == nil {
                    self.selectedID = parsed.first?.server.id
                }
                self.lock.unlock()
                self.setPhase("connected", message: "Plex servers are ready.")
                completion(.success(parsed.map(\.server)))
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true {
                    self.setFailure(error.localizedDescription)
                }
                completion(.failure(error))
            }
        }
    }

    func selectServer(id: String) throws {
        lock.lock()
        let available = records[id] != nil
        lock.unlock()
        guard available else { throw PlexServiceError("That Plex server is unavailable.") }
        cancelCurrentRequest()
        lock.lock()
        guard records[id] != nil else { lock.unlock(); throw PlexServiceError("That Plex server is unavailable.") }
        selectedID = id
        libraries = []
        selectedLibraryID = nil
        workingConnection = nil
        phase = "connected"
        message = "Plex server selected."
        let value = statusLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
    }

    func refreshLibraries(_ completion: @escaping (Result<[PlexLibrary], Error>) -> Void) {
        cancelCurrentRequest()
        let record: PlexServerRecord
        do { record = try selectedServerAccess() }
        catch { completion(.failure(error)); return }
        lock.lock()
        libraries = []
        selectedLibraryID = nil
        lock.unlock()
        run(phase: "loadingLibraries", message: "Finding music libraries…", perform: { operation in
            try self.withConnection(record: record) { base -> ([PlexLibrary], URL) in
                let request = try self.serverRequest(base: base, path: "/library/sections", query: [], token: record.token)
                return (try PlexParser.libraries(operation.fetch(request, limit: 2 * 1024 * 1024, timeout: 8)), base)
            }
        }) { result in
            switch result {
            case .success(let (available, base)):
                let preference = UserDefaults.standard.string(forKey: "PlexMusicLibrary." + record.server.id)
                self.lock.lock()
                self.workingConnection = base
                self.libraries = available
                self.selectedLibraryID = PlexLibrary.restoredID(in: available, preferred: preference)
                self.lock.unlock()
                self.setPhase("connected", message: available.isEmpty ? "No music libraries are available on this server." : "Music libraries are ready.")
                completion(.success(available))
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true { self.setFailure(error.localizedDescription) }
                completion(.failure(error))
            }
        }
    }

    func selectLibrary(id: String) throws {
        lock.lock()
        guard let serverID = selectedID, let library = libraries.first(where: { $0.id == id }) else {
            lock.unlock()
            throw PlexServiceError("Choose a music library available on this server.")
        }
        lock.unlock()
        cancelCurrentRequest()
        lock.lock()
        selectedLibraryID = id
        lock.unlock()
        UserDefaults.standard.set(id, forKey: "PlexMusicLibrary." + serverID)
        setPhase("connected", message: "Using " + library.name + ".")
    }

    private func selectedServerAccess() throws -> PlexServerRecord {
        lock.lock()
        let record = selectedID.flatMap { records[$0] }
        lock.unlock()
        guard let record = record else { throw PlexServiceError("Choose a Plex server first.") }
        return record
    }

    private func withConnection<T>(record: PlexServerRecord, _ attempt: (URL) throws -> T) throws -> T {
        lock.lock()
        let working = workingConnection
        lock.unlock()
        let urls = record.connections.map(\.url)
        let ordered = urls.filter { $0 == working } + urls.filter { $0 != working }
        var tried = Set<URL>()
        var messages = [String]()
        for url in ordered where tried.insert(url).inserted {
            do { return try attempt(url) }
            catch let error as PlexServiceError where error.retryOtherConnection {
                if !messages.contains(error.message) { messages.append(error.message) }
            }
        }
        throw PlexServiceError(messages.isEmpty ? "No secure Plex server connection is available." : messages.joined(separator: " "))
    }

    func search(showDate: String, preferredVersion: Int? = nil,
                completion: @escaping (Result<PlexSearchResult, Error>) -> Void) {
        cancelCurrentRequest()
        let record: PlexServerRecord
        let section: PlexLibrary
        do {
            _ = try PlexParser.searchQueries(showDate: showDate, preferredVersion: preferredVersion)
            record = try selectedServerAccess()
            lock.lock()
            let selection = libraries.first { $0.id == selectedLibraryID }
            lock.unlock()
            guard let selection = selection else { throw PlexServiceError("Choose a Plex music library first.") }
            section = selection
        } catch {
            setFailure(error.localizedDescription)
            completion(.failure(error))
            return
        }

        run(phase: "searching", message: "Searching \(section.name)…", perform: { operation in
            try self.withConnection(record: record) { base in
                let token = record.token
                func read(_ path: String, _ query: [URLQueryItem]) throws -> Data {
                    let request = try self.serverRequest(base: base, path: path, query: query, token: token)
                    return try operation.fetch(request, limit: 8 * 1024 * 1024, timeout: 12)
                }
                let sectionPath = "/library/sections/\(section.id)/all"
                let albums = try read(sectionPath, [URLQueryItem(name: "type", value: "9"),
                                                   URLQueryItem(name: "title", value: showDate),
                                                   URLQueryItem(name: "limit", value: "100")])
                let albumIDs = try PlexParser.albumKeys(albums, showDate: showDate, sectionID: section.id)
                var tracks = [PlexTrackRecord]()
                for albumID in albumIDs {
                    let children = try read("/library/metadata/\(albumID)/children", [])
                    tracks += try PlexParser.trackRecords(children, showDate: showDate, sectionID: section.id)
                }
                // Some archives expose the original file stem as the track title instead of tagging the album.
                if let match = try? PlexParser.search(tracks, showDate: showDate, preferredVersion: preferredVersion,
                                                       serverURL: base, token: token) { return match }
                let trackRows = try read(sectionPath, [URLQueryItem(name: "type", value: "10"),
                                                       URLQueryItem(name: "title", value: showDate),
                                                       URLQueryItem(name: "limit", value: "500")])
                tracks += try PlexParser.trackRecords(trackRows, showDate: showDate, sectionID: section.id)
                return try PlexParser.search(tracks, showDate: showDate, preferredVersion: preferredVersion,
                                             serverURL: base, token: token)
            }
        }) { result in
            switch result {
            case .success: self.setPhase("connected", message: "Plex recording found in \(section.name).")
            case .failure(let error):
                if (error as? PlexServiceError)?.isCancellation != true { self.setFailure(error.localizedDescription) }
            }
            completion(result)
        }
    }

    @discardableResult
    func cancelSearch() -> Bool {
        let canceled = cancelCurrentRequest()
        if canceled { setPhase("connected", message: "Plex search canceled.") }
        return canceled
    }

    func disconnect() throws {
        cancelCurrentRequest()
        var removalError: Error?
        do { try credentials.removeValue(for: Self.accountKey) } catch { removalError = error }
        do { try credentials.removeValues(withPrefix: Self.serverKeyPrefix) } catch {
            if removalError == nil { removalError = error }
        }
        lock.lock()
        hasAccount = false
        records.removeAll()
        libraries = []
        selectedID = nil
        selectedLibraryID = nil
        workingConnection = nil
        phase = "disconnected"
        message = ""
        let value = statusLocked()
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
        if let removalError = removalError { throw removalError }
    }

    private func run<T>(phase: String, message: String, request: URLRequest, limit: Int,
                        transform: @escaping (Data) throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        run(phase: phase, message: message, perform: { operation in
            try transform(operation.fetch(request, limit: limit))
        }, completion: completion)
    }

    private func run<T>(phase: String, message: String, perform: @escaping (PlexRequestOperation) throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        cancelCurrentRequest()
        lock.lock(); generation += 1; let currentGeneration = generation; self.phase = phase; self.message = message
        let operation = PlexRequestOperation(); self.operation = operation
        cancellationHandler = { completion(.failure(PlexServiceError.canceled)) }
        let value = statusLocked(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
        work.async { [weak self] in
            let result: Result<T, Error>
            do { result = .success(try perform(operation)) }
            catch { result = .failure(error) }
            guard let self = self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let current = self.operation === operation && self.generation == currentGeneration
                if current {
                    self.operation = nil
                    self.cancellationHandler = nil
                }
                self.lock.unlock()
                if current { completion(result) }
            }
        }
    }


    @discardableResult
    private func cancelCurrentRequest(notify: Bool = true) -> Bool {
        lock.lock()
        generation += 1
        let current = operation
        let handler = cancellationHandler
        operation = nil
        cancellationHandler = nil
        lock.unlock()
        current?.cancel()
        if notify, let handler = handler { DispatchQueue.main.async(execute: handler) }
        return current != nil
    }

    private func authorizedRequest(url: URL, method: String, token: String?) -> URLRequest {
        precondition(url.scheme == "https" && (url.host == "plex.tv" || url.host == "clients.plex.tv"))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        applyHeaders(to: &request, token: token)
        return request
    }

    private func serverRequest(base: URL, path: String, query: [URLQueryItem], token: String) throws -> URLRequest {
        guard path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw PlexServiceError("The Plex server request is invalid.")
        }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw PlexServiceError("The Plex server request is invalid.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        applyHeaders(to: &request, token: token)
        return request
    }

    private func applyHeaders(to request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tool Drive Offline", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        #if os(iOS)
        let platform = "iOS"
        #else
        let platform = "macOS"
        #endif
        request.setValue(platform, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("Tool Drive Offline", forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue(platform, forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(ProcessInfo.processInfo.operatingSystemVersionString, forHTTPHeaderField: "X-Plex-Platform-Version")
        if let token = token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    private func setPhase(_ phase: String, message: String) {
        lock.lock(); self.phase = phase; self.message = message; let value = statusLocked(); lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onStatusChange?(value) }
    }

    private func setFailure(_ message: String) { setPhase("failed", message: message) }

    private func statusLocked() -> PlexStatus {
        let server = selectedID.flatMap { records[$0]?.server }
        let library = libraries.first { $0.id == selectedLibraryID }
        return PlexStatus(phase: phase,
                          connected: phase != "disconnected" && hasAccount,
                          serverCount: records.count,
                          selectedServerID: server?.id,
                          selectedServerName: server?.name,
                          selectedLibraryID: library?.id,
                          selectedLibraryName: library?.name,
                          message: message)
    }

    private static func persistentClientIdentifier() -> String {
        let key = "PlexClientIdentifier"
        if let value = UserDefaults.standard.string(forKey: key), value.count >= 8 { return value }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
