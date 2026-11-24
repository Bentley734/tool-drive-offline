import AVFoundation
import Foundation

@main
struct LiveMediaTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw UpdateError(message) }
    }

    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { return }
        throw UpdateError(message)
    }

    static func main() throws {
        let links = Data(#"""
        const SOURCES_DATA = {
          "1991090501": [
            {"id":3,"driveUrl":"https://drive.google.com/drive/folders/Folder_12345678?usp=sharing"},
            {"id":4,"driveUrl":"Recording known to exist, not OTD"},
            {"id":5,"driveUrl":"https://example.com/drive/folders/unsafe"}
          ]
        };
        """#.utf8)
        let parsedLinks = try LiveMediaParser.downloadLinks(links)
        try require(parsedLinks[1991090501]?[3]?.absoluteString == "https://drive.google.com/drive/folders/Folder_12345678", "Canonical download link")
        try require(parsedLinks[1991090501]?[4] == nil && parsedLinks[1991090501]?[5] == nil, "Unsafe and sentinel links are ignored")
        try require(LiveMediaParser.canonicalDownloadURL("http://drive.google.com/drive/folders/Folder_12345678") == nil, "Reject non-HTTPS download")
        try require(LiveMediaParser.canonicalDownloadURL("https://drive.google.com.evil/drive/folders/Folder_12345678") == nil, "Reject lookalike host")
        try rejects("Duplicate source IDs") {
            _ = try LiveMediaParser.downloadLinks(Data(#"const SOURCES_DATA={"1":[{"id":9,"driveUrl":"https://drive.google.com/drive/folders/Folder_12345678"}],"2":[{"id":9,"driveUrl":"https://drive.google.com/drive/folders/Folder_87654321"}]};"#.utf8))
        }

        let response = Data(#"""
        {"ok":true,"data":{"tracks":[
          {"url":"/mp3_2.0/1991/tool1991-09-05.v1/tool1991-09-05.v1.t01.mp3","trackNumber":1,"title":"Cold and Ugly","durationSeconds":392},
          {"url":"/mp3_2.0/1991/tool1991-09-05.v1/tool1991-09-05.v1.t02.mp3","trackNumber":2,"title":"Undertow","durationSeconds":348}
        ]}}
        """#.utf8)
        let tracks = try LiveMediaParser.tracks(response, date: "1991-09-05", version: 1)
        try require(tracks.count == 2 && tracks[0].url.absoluteString.hasPrefix("https://tooldriveproject.net/mp3_2.0/"), "Official stream URLs")
        try require(tracks[0].summary["url"] == nil && tracks[0].title == "Cold and Ugly", "Safe UI track summary")
        try rejects("Reject mismatched stream path") {
            let bad = Data(#"{"ok":true,"data":{"tracks":[{"url":"/mp3_2.0/1992/tool1992-01-01.v1/other.mp3","trackNumber":1,"title":"Bad"}]}}"#.utf8)
            _ = try LiveMediaParser.tracks(bad, date: "1991-09-05", version: 1)
        }
        try rejects("Reject absolute stream URL") {
            let bad = Data(#"{"ok":true,"data":{"tracks":[{"url":"https://evil.invalid/a.mp3","trackNumber":1,"title":"Bad"}]}}"#.utf8)
            _ = try LiveMediaParser.tracks(bad, date: "1991-09-05", version: 1)
        }
        try rejects("Reject duplicate track number") {
            let bad = Data(#"{"ok":true,"data":{"tracks":[{"url":"/mp3_2.0/1991/tool1991-09-05.v1/tool1991-09-05.v1.t01.mp3","trackNumber":1},{"url":"/mp3_2.0/1991/tool1991-09-05.v1/tool1991-09-05.v1.t01.mp3","trackNumber":1}]}}"#.utf8)
            _ = try LiveMediaParser.tracks(bad, date: "1991-09-05", version: 1)
        }
        let endpoint = try LiveMediaParser.streamURL(date: "1991-09-05", version: 1)
        try require(endpoint.host == "tooldriveproject.net" && endpoint.query == "date=1991-09-05&ver=1", "Fixed resolver endpoint")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tool-live-media-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let flac = scratch.appendingPathComponent("fixture.flac")
        try Data("fLaC".utf8).write(to: flac)
        let local = try PlayerController.localTracks([flac])
        try require(local.count == 1 && local[0].url.pathExtension.lowercased() == "flac", "FLAC library import")
        let aiff = URL(fileURLWithPath: "/System/Library/Sounds/Pop.aiff")
        let playable = try PlayerController.localTracks([aiff])
        try require(playable.count == 1 && playable[0].url.pathExtension.lowercased() == "aiff", "Real AIFF library import")
        let manifest = try PlayerController.validatedLocalTracks([
            LiveTrack(number: 7, title: "Preserved title", duration: 0.7, url: aiff)
        ])
        try require(manifest[0].number == 7 && manifest[0].title == "Preserved title" && manifest[0].duration == 0.7,
                    "Library manifest metadata is preserved")
        let asset = AVURLAsset(url: aiff)
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["playable"]) { ready.signal() }
        try require(ready.wait(timeout: .now() + 10) == .success, "Audio asset timed out")
        var assetError: NSError?
        try require(asset.statusOfValue(forKey: "playable", error: &assetError) == .loaded && asset.isPlayable,
                    "Real AIFF fixture is not playable: \(assetError?.localizedDescription ?? "unknown error")")
        let unsupported = scratch.appendingPathComponent("fixture.ogg")
        try Data().write(to: unsupported)
        try rejects("Unsupported library audio") { _ = try PlayerController.localTracks([unsupported]) }
        try require(["flac", "alac", "wav", "aiff", "mp3", "aac", "m4a"].allSatisfy(PlayerController.supportedLocalExtensions.contains), "Required audio extensions")
        let secretError = NSError(domain: "playback", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "https://server.plex.direct/file.flac?X-Plex-Token=never-show-this"
        ])
        let safeMessage = PlayerController.safePlaybackFailureMessage(secretError)
        try require(!safeMessage.contains("http") && !safeMessage.contains("Token") && !safeMessage.contains("never-show-this"),
                    "Playback errors never expose remote URLs or tokens")
        try require(PlayerController.requiresFreshItemForPlay(status: "finished", itemFailed: false),
                    "Play reloads a completed final track from zero")
        try require(PlayerController.requiresFreshItemForPlay(status: "paused", itemFailed: true),
                    "Play reloads a failed item")
        try require(!PlayerController.requiresFreshItemForPlay(status: "paused", itemFailed: false),
                    "Play resumes a paused healthy item")
        print("PASS live download links, strict stream resolver, safe track summaries, required local formats and real AIFF asset")
    }
}
