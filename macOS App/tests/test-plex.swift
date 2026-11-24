import Foundation

final class TestPlexCredentialStore: PlexCredentialStore {
    private var values = ["account": "test-account-token"]

    func value(for account: String) throws -> String? { values[account] }
    func setValue(_ value: String, for account: String) throws { values[account] = value }
    func removeValue(for account: String) throws { values.removeValue(forKey: account) }
    func removeValues(withPrefix prefix: String) throws {
        values.keys.filter { $0.hasPrefix(prefix) }.forEach { values.removeValue(forKey: $0) }
    }
}

@main
struct PlexTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PlexServiceError(message) }
    }

    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw PlexServiceError(message)
    }

    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func testMusicSections() throws {
        let listing = Data(#"""
        {"MediaContainer":{"Directory":[
          {"key":"3","type":"movie","title":"Films"},
          {"key":"7","type":"artist","title":"TOOL Archive"},
          {"key":"9","type":"artist","title":"Music"},
          {"key":"../11","type":"artist","title":"Invalid key"}
        ]}}
        """#.utf8)
        let libraries = try PlexParser.libraries(listing)
        try require(libraries.count == 2 &&
                    Set(libraries.map(\.id)) == ["7", "9"] &&
                    Set(libraries.map(\.name)) == ["TOOL Archive", "Music"],
                    "Only valid music libraries are offered")
        let empty = try PlexParser.libraries(Data(#"{"MediaContainer":{"size":0}}"#.utf8))
        try require(empty.isEmpty, "A server with no libraries has an empty list")
        try rejects("A malformed response should surface an error instead of an empty selector") {
            _ = try PlexParser.libraries(Data(#"{"MediaContainer":{"size":1}}"#.utf8))
        }
        try require(PlexLibrary.restoredID(in: libraries, preferred: "9") == "9",
                    "Restore a still-available music library")
        try require(PlexLibrary.restoredID(in: libraries, preferred: "42") == nil &&
                    PlexLibrary.restoredID(in: libraries, preferred: nil) == nil,
                    "Request a choice when multiple libraries are available")
        try require(PlexLibrary.restoredID(in: [libraries[0]], preferred: nil) == libraries[0].id,
                    "Select the only available music library")
        try require(PlexLibrary.restoredID(in: empty, preferred: "7") == nil,
                    "Clear a previously selected library when none are accessible")
    }

    static func testScopedTracks() throws {
        let date = "1991-09-05"
        let file = "tool\(date).v1.t01.flac"
        func track(_ title: String, key: String, section: Any?) -> [String: Any] {
            var row: [String: Any] = [
                "type": "track", "ratingKey": key, "title": title,
                "grandparentTitle": "TOOL", "parentTitle": date,
                "Media": [["container": "flac", "Part": [[
                    "key": "/library/parts/\(key)/1/\(file)",
                    "file": "/1991/tool\(date).v1/\(file)"
                ]]]]
            ]
            row["librarySectionID"] = section
            return row
        }
        func metadata(_ rows: [[String: Any]], section: Any? = nil) throws -> Data {
            var container: [String: Any] = ["Metadata": rows]
            container["librarySectionID"] = section
            return try JSONSerialization.data(withJSONObject: ["MediaContainer": container])
        }
        let mixedTracks = try metadata([
            track("Archive copy", key: "771", section: 7),
            track("Music copy", key: "991", section: "9")
        ])
        func search(_ data: Data, in section: String) throws -> PlexSearchResult {
            try PlexParser.search(data, showDate: date, preferredVersion: 1,
                                  serverURL: URL(string: "https://test.plex.direct:32400")!,
                                  token: "test-plex-token", sectionID: section)
        }
        for (section, title, key) in [("7", "Archive copy", "771"), ("9", "Music copy", "991")] {
            let match = try search(mixedTracks, in: section)
            try require(match.tracks.map(\.title) == [title],
                        "Playing a duplicated show uses the selected library")
            var paths = [String]()
            match.withNativePlaybackTracks { tracks in paths = tracks.map { $0.url.path } }
            try require(paths == ["/library/parts/\(key)/1/\(file)"],
                        "Native audio belongs to the chosen library")
        }
        try rejects("A different library must not supply a missing recording") {
            _ = try search(mixedTracks, in: "14")
        }
        let sectionResponse = try metadata([track("Inherited library", key: "71", section: nil)], section: "7")
        let inherited = try search(sectionResponse, in: "7")
        try require(inherited.tracks.map(\.title) == ["Inherited library"],
                    "Section-level metadata scopes rows without a library ID")
        try rejects("A mismatched response container must not supply a recording") {
            _ = try search(sectionResponse, in: "9")
        }
        let albumRows: [[String: Any]] = [("7", "670"), ("9", "690")].map { section, key in
            ["librarySectionID": section, "ratingKey": key, "title": date,
             "parentTitle": "TOOL", "type": "album"]
        }
        let selectedAlbums = try PlexParser.albumKeys(metadata(albumRows), showDate: date, sectionID: "7")
        try require(selectedAlbums == ["670"], "Only fetch album children from the chosen library")
    }

    static func main() throws {
        try testMusicSections()
        try testScopedTracks()
        let pinEndpoint = URL(string: "https://plex.tv/api/v2/pins")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (method, status, allowed) in [("POST", 201, true), ("GET", 200, true),
                                          ("GET", 201, false), ("POST", 403, false)] {
            var request = URLRequest(url: pinEndpoint)
            request.httpMethod = method
            let response = HTTPURLResponse(url: pinEndpoint, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            var disposition: URLSession.ResponseDisposition?
            PlexRequestOperation().urlSession(session, dataTask: session.dataTask(with: request),
                                               didReceive: response) { disposition = $0 }
            try require(disposition == (allowed ? .allow : .cancel),
                        "Unexpected Plex response disposition for \(method) HTTP \(status)")
        }
        let pending = Data(#"{"id":4412,"code":"strong-pin-code-1234","authToken":null}"#.utf8)
        let parsedPending = try PlexParser.pin(pending)
        try require(parsedPending.id == 4412 && !parsedPending.hasToken, "Pending PIN parser")
        try require(PlexServiceError.canceled.isCancellation,
                    "Cancellation errors are recognizable by lifecycle callers")
        let claimed = Data(#"{"id":4412,"code":"strong-pin-code-1234","authToken":"secret-token-value"}"#.utf8)
        let parsedClaimed = try PlexParser.pin(claimed)
        try require(parsedClaimed.hasToken, "Claimed PIN parser")
        try rejects("Reject malformed PIN") { _ = try PlexParser.pin(Data(#"{"id":0,"code":"bad"}"#.utf8)) }

        let authorization = try PlexParser.authorizationURL(clientIdentifier: "client-identifier-1234",
                                                             code: "strong-pin-code-1234")
        try require(authorization.scheme == "https" && authorization.host == "app.plex.tv",
                    "Official authorization host")
        try require(authorization.fragment?.contains("clientID=client-identifier-1234") == true
                    && authorization.fragment?.contains("context%5Bdevice%5D%5Bproduct%5D") == true,
                    "Encoded authorization fragment")
        let versionQueries = try PlexParser.searchQueries(showDate: "1991-09-05", preferredVersion: 2)
        let dateQueries = try PlexParser.searchQueries(showDate: "1991-09-05", preferredVersion: nil)
        try require(versionQueries == ["tool1991-09-05.v2", "Tool 1991-09-05", "1991-09-05"],
                    "Version, title, and bare-date discovery queries")
        try require(dateQueries == ["Tool 1991-09-05", "1991-09-05"],
                    "Bounded discovery queries without a version")

        let resources = Data(#"""
        [
          {
            "name":"Studio Plex", "provides":"server", "clientIdentifier":"server-abc-123",
            "accessToken":"server-secret-token", "owned":true,
            "connections":[
              {"uri":"https://192-168-1-4.0123456789abcdef.plex.direct:32400","local":true,"relay":false},
              {"uri":"http://192.168.1.4:32400","local":true,"relay":false},
              {"uri":"https://relay.0123456789abcdef.plex.direct:443","local":false,"relay":true},
              {"uri":"https://evil.example:32400","local":false,"relay":false}
            ]
          },
          {"name":"Player", "provides":"player", "clientIdentifier":"not-a-server",
           "accessToken":"irrelevant-token", "connections":[]}
        ]
        """#.utf8)
        let servers = try PlexParser.resources(resources)
        try require(servers == [PlexServer(id: "server-abc-123", name: "Studio Plex", owned: true,
                                          connectionCount: 2)], "HTTPS-only resource parser")
        try require(servers[0].summary.values.allSatisfy { !String(describing: $0).contains("secret") },
                    "Server summaries omit credentials")

        try require(PlexParser.validatedConnection("http://10.0.0.3:32400", local: true, relay: false) == nil,
                    "Reject token-bearing private LAN HTTP")
        try require(PlexParser.validatedConnection("http://media.local:32400", local: true, relay: false) == nil,
                    "Reject token-bearing local-name HTTP")
        try require(PlexParser.validatedConnection("https://10-0-0-3.hash.plex.direct:32400", local: true, relay: false) != nil,
                    "Plex Direct HTTPS")
        try require(PlexParser.validatedConnection("https://relay.hash.plex.direct:443", local: false, relay: true) != nil,
                    "Plex relay HTTPS")
        for unsafe in [
            ("http://203.0.113.5:32400", true, false),
            ("http://10.0.0.3:32400", false, false),
            ("http://10.0.0.3:32400", true, true),
            ("https://plex.direct.evil.example:32400", false, false),
            ("https://user:pass@hash.plex.direct:32400", false, false),
            ("https://hash.plex.direct:32400/path", false, false),
            ("https://hash.plex.direct:32400?token=leak", false, false)
        ] {
            try require(PlexParser.validatedConnection(unsafe.0, local: unsafe.1, relay: unsafe.2) == nil,
                        "Reject unsafe server connection: \(unsafe.0)")
        }

        try require(PlexParser.validatedPartPath("/library/parts/123/456/tool1991-09-05.v1.t01.flac") != nil,
                    "Official media part path")
        for unsafePath in [
            "https://evil.example/library/parts/1/file.flac",
            "/library/metadata/1",
            "/library/parts/not-a-number/file.flac",
            "/library/parts/1/%2e%2e/file.flac",
            "/library/parts/1/file.flac?X-Plex-Token=leak",
            "/library/parts/1//file.flac"
        ] {
            try require(PlexParser.validatedPartPath(unsafePath) == nil,
                        "Reject unsafe media part path: \(unsafePath)")
        }

        let search = Data(#"""
        {"MediaContainer":{"Hub":[
          {"type":"album","Metadata":[
            {"type":"album","ratingKey":"900","title":"1991-09-05 The Jello Loft, Los Angeles, CA, USA","parentTitle":"TOOL"}
          ]},
          {"type":"track","Metadata":[
            {
              "type":"track","ratingKey":"101","parentRatingKey":"901","title":"Cold and Ugly",
              "parentTitle":"1991-09-05 The Jello Loft, Los Angeles, CA, USA","grandparentTitle":"TOOL",
              "duration":392000,"Media":[{"container":"flac","Part":[{
                "key":"/library/parts/101/1001/tool1991-09-05.v1.t01.flac","container":"flac",
                "file":"/archive/1991/tool1991-09-05.v1/tool1991-09-05.v1.t01.flac"
              }]}]
            },
            {
              "type":"track","ratingKey":"201","parentRatingKey":"902","title":"Intolerance",
              "parentTitle":"1991-09-05 The Jello Loft, Los Angeles, CA, USA","grandparentTitle":"Tool",
              "duration":305000,"Media":[{"container":"flac","Part":[{
                "key":"/library/parts/201/2001/tool1991-09-05.v2.t01.flac","container":"flac",
                "file":"/archive/1991/tool1991-09-05.v2/tool1991-09-05.v2.t01.flac"
              }]}]
            },
            {
              "type":"track","ratingKey":"202","parentRatingKey":"902","title":"Undertow",
              "parentTitle":"1991-09-05 The Jello Loft, Los Angeles, CA, USA","grandparentTitle":"TOOL",
              "duration":348000,"Media":[{"container":"flac","Part":[{
                "key":"/library/parts/202/2002/tool1991-09-05.v2.t02.flac","container":"flac",
                "file":"/archive/1991/tool1991-09-05.v2/tool1991-09-05.v2.t02.flac"
              }]}]
            },
            {
              "type":"track","ratingKey":"301","parentRatingKey":"903","title":"Windows Archive",
              "parentTitle":"Imported audio","grandparentTitle":"Unknown Artist",
              "duration":123000,"Media":[{"container":"flac","Part":[{
                "key":"/library/parts/301/3001/tool1991-09-05.v3.t01.flac","container":"flac",
                "file":"D:\\archive\\1991\\tool1991-09-05.v3\\tool1991-09-05.v3.t01.flac"
              }]}]
            },
            {
              "type":"track","ratingKey":"999","parentRatingKey":"999","title":"Wrong Date",
              "parentTitle":"1992-01-01 Somewhere Else","grandparentTitle":"TOOL",
              "Media":[{"container":"flac","Part":[{
                "key":"/library/parts/999/9999/tool1992-01-01.v1.t01.flac","container":"flac",
                "file":"/archive/1992/tool1992-01-01.v1/tool1992-01-01.v1.t01.flac"
              }]}]
            }
          ]}
        ]}}
        """#.utf8)
        let albums = try PlexParser.albumKeys(search, showDate: "1991-09-05")
        try require(albums == ["900"],
                    "Exact show album key")
        let base = URL(string: "https://10-0-0-3.hash.plex.direct:32400")!
        let token = "native-server-token"
        let best = try PlexParser.search(search, showDate: "1991-09-05", preferredVersion: nil,
                                         serverURL: base, token: token)
        try require(best.version == 2 && best.tracks.map(\.number) == [1, 2],
                    "Best complete exact-hierarchy version")
        try require(best.tracks.map(\.title) == ["Intolerance", "Undertow"]
                    && best.tracks.map(\.duration) == [305, 348], "Track metadata")
        try require(best.summary["tracks"] != nil && !String(describing: best.summary).contains(token),
                    "Safe search summary")
        var native = [LiveTrack]()
        best.withNativePlaybackTracks { native = $0 }
        try require(native.count == 2
                    && native[0].url.host?.hasSuffix(".plex.direct") == true
                    && URLComponents(url: native[0].url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "X-Plex-Token" })?.value == token,
                    "Native token-authenticated direct-play URL")
        let validatedNative = try PlexParser.validatedPlaybackTracks(native)
        try require(validatedNative.count == 2,
                    "Native player accepts parser-created Plex tracks")
        let unsafeRemote = LiveTrack(number: 1, title: "Unsafe", duration: 1,
                                     url: URL(string: "https://evil.example/library/parts/1/file.flac?X-Plex-Token=secret-token")!)
        try rejects("Native player rejects an arbitrary remote URL") {
            _ = try PlexParser.validatedPlaybackTracks([unsafeRemote])
        }
        try require(!String(describing: best.summary).contains(native[0].url.absoluteString),
                    "Playback URL omitted from summary")

        let firstVersion = try PlexParser.search(search, showDate: "1991-09-05", preferredVersion: 1,
                                                 serverURL: base, token: token)
        try require(firstVersion.version == 1 && firstVersion.tracks.map(\.number) == [1],
                    "Exact preferred recording version")
        let windowsVersion = try PlexParser.search(search, showDate: "1991-09-05", preferredVersion: 3,
                                                   serverURL: base, token: token)
        try require(windowsVersion.version == 3 && windowsVersion.tracks[0].title == "Windows Archive",
                    "Windows exact-folder archive path overrides imperfect metadata")
        try rejects("Reject unavailable preferred version") {
            _ = try PlexParser.search(search, showDate: "1991-09-05", preferredVersion: 4,
                                      serverURL: base, token: token)
        }
        try rejects("Reject unsafe server URL") {
            _ = try PlexParser.search(search, showDate: "1991-09-05", preferredVersion: nil,
                                      serverURL: URL(string: "https://evil.example:32400")!, token: token)
        }
        try rejects("Reject wrong show date") {
            _ = try PlexParser.search(search, showDate: "1993-01-01", preferredVersion: nil,
                                      serverURL: base, token: token)
        }

        let unsupported = Data(#"""
        {"MediaContainer":{"Metadata":[{
          "type":"track","ratingKey":"301","parentRatingKey":"903","title":"Unsupported",
          "parentTitle":"1991-09-05 The Jello Loft","grandparentTitle":"TOOL",
          "Media":[{"container":"ogg","Part":[{
            "key":"/library/parts/301/3001/tool1991-09-05.v1.t01.ogg","container":"ogg",
            "file":"/archive/1991/tool1991-09-05.v1/tool1991-09-05.v1.t01.ogg"
          }]}]
        }]}}
        """#.utf8)
        try rejects("Reject unsupported direct play") {
            _ = try PlexParser.search(unsupported, showDate: "1991-09-05", preferredVersion: 1,
                                      serverURL: base, token: token)
        }

        let lifecycle = PlexService(clientIdentifier: "test-client-identifier", version: "1.0",
                                    credentials: TestPlexCredentialStore())
        var cancellations = 0
        var nonCancellation = false
        lifecycle.refreshServers { result in
            if case .failure(let error) = result,
               (error as? PlexServiceError)?.isCancellation == true { cancellations += 1 }
            else { nonCancellation = true }
        }
        lifecycle.refreshServers { result in
            if case .failure(let error) = result,
               (error as? PlexServiceError)?.isCancellation == true { cancellations += 1 }
            else { nonCancellation = true }
        }
        try require(lifecycle.cancelSearch(), "Explicit cancellation reports an active request")
        try require(waitUntil({ cancellations == 2 }), "Superseded and canceled requests complete")
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        try require(cancellations == 2 && !nonCancellation,
                    "Each canceled request completes exactly once without a stale result")

        print("PASS Plex sign-in, music library selection, library-scoped playback, archive matching, and URL validation")
    }
}
