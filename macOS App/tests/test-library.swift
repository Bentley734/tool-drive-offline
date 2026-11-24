import AudioToolbox
import Foundation

@main
enum LibraryControllerTests {
    static func main() throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("tool-drive-library-tests-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }

        precondition(LibraryController.approvedMediaURL(URL(string: "https://tooldriveproject.net/mp3_2.0/2024/a.mp3")!))
        precondition(!LibraryController.approvedMediaURL(URL(string: "https://example.com/a.mp3")!))
        precondition(LibraryController.approvedDriveFolderURL(URL(string: "https://drive.google.com/drive/folders/abcdefgh")!) != nil)
        precondition(LibraryController.approvedDriveFolderURL(URL(string: "https://drive.google.com/drive/folders/../../bad")!) == nil)

        let fixtures = temporary.appendingPathComponent("fixtures", isDirectory: true)
        try manager.createDirectory(at: fixtures, withIntermediateDirectories: false)
        let wav = fixtures.appendingPathComponent("01 Real PCM.wav")
        try makeWAV().write(to: wav)
        let flac = fixtures.appendingPathComponent("02 Real FLAC.flac")
        try makeFLAC().write(to: flac)
        let systemALAC = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-es-US.m4a")
        let alac: URL?
        if manager.fileExists(atPath: systemALAC.path), isALAC(systemALAC) {
            let copied = fixtures.appendingPathComponent("03 Real ALAC.m4a")
            try manager.copyItem(at: systemALAC, to: copied)
            alac = copied
        } else {
            alac = nil
            print("Skipping ALAC fixture: this macOS installation has no available ALAC sample or encoder")
        }

        let controller = try LibraryController(baseURL: temporary.appendingPathComponent("Library", isDirectory: true))
        try importFixture(wav, expected: .wav, sourceID: 1, controller: controller)
        try importFixture(flac, expected: .flac, sourceID: 2, controller: controller)
        if let alac = alac { try importFixture(alac, expected: .alac, sourceID: 3, controller: controller) }

        let zipInput = temporary.appendingPathComponent("zip-input", isDirectory: true)
        try manager.createDirectory(at: zipInput, withIntermediateDirectories: false)
        try manager.copyItem(at: wav, to: zipInput.appendingPathComponent("tool1991-09-05.v12.t01.wav"))
        try manager.copyItem(at: flac, to: zipInput.appendingPathComponent("tool1991-09-05.v12.t02.flac"))
        if let alac = alac {
            try manager.copyItem(at: alac, to: zipInput.appendingPathComponent("tool1991-09-05.v12.t12.m4a"))
        }
        try Data("ignored junk".utf8).write(to: zipInput.appendingPathComponent("notes.txt"))
        let archive = temporary.appendingPathComponent("fixtures.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", zipInput.path, archive.path])
        let zipEntry = try importFile(archive, sourceID: 4, controller: controller)
        let expectedCodecs: Set<LibraryAudioCodec> = alac == nil ? Set([.wav, .flac]) : Set([.wav, .flac, .alac])
        precondition(Set(zipEntry.tracks.map(\.codec)) == expectedCodecs)
        precondition(zipEntry.tracks.count == expectedCodecs.count)
        precondition(zipEntry.tracks.map(\.trackNumber) == (alac == nil ? [1, 2] : [1, 2, 12]))

        precondition(controller.listEntries().count == (alac == nil ? 3 : 4))
        precondition(controller.trackURLs(sourceID: 4).count == expectedCodecs.count)
        try verifyManifestHardening(controller: controller, sourceID: 4)
        try verifyRejectedImportCleanup(controller: controller, fixture: wav)
        print("LibraryController fixtures passed")
    }

    private static func importFixture(_ fixture: URL, expected: LibraryAudioCodec,
                                      sourceID: Int, controller: LibraryController) throws {
        let original = try Data(contentsOf: fixture)
        let entry = try importFile(fixture, sourceID: sourceID, controller: controller)
        precondition(entry.tracks.count == 1)
        precondition(entry.tracks[0].codec == expected)
        precondition(entry.tracks[0].byteCount == Int64(original.count))
        guard let saved = controller.trackURLs(sourceID: sourceID).first else { throw LibraryError.missingAudio }
        let savedData = try Data(contentsOf: saved)
        precondition(savedData == original, "Lossless/source bytes must be preserved without transcoding")
    }

    private static func importFile(_ fixture: URL, sourceID: Int,
                                   controller: LibraryController) throws -> LibraryEntry {
        let importDirectory = try controller.makeImportStagingDirectory(sourceID: sourceID)
        let downloaded = importDirectory.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: downloaded)
        let descriptor = LibrarySourceDescriptor(sourceID: sourceID, showID: "100",
                                                 date: "2024-01-01", venue: "Fixture Hall", version: "V.1")
        var outcome: Result<LibraryEntry, Error>?
        controller.importDownloadedFile(downloaded, source: descriptor, progress: { _ in }, completion: { outcome = $0 })
        let deadline = Date().addingTimeInterval(15)
        while outcome == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        guard let result = outcome else { throw LibraryError.server("Fixture import timed out.") }
        return try result.get()
    }

    private static func verifyManifestHardening(controller: LibraryController, sourceID: Int) throws {
        guard let folder = controller.sourceFolder(sourceID: sourceID) else { throw LibraryError.damagedManifest }
        let manifest = folder.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifest)

        func expectRejected(_ label: String, _ mutate: (inout [String: Any]) -> Void) throws {
            guard var object = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw LibraryError.damagedManifest
            }
            mutate(&object)
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: manifest, options: .atomic)
            _ = try controller.scanLibrary()
            precondition(controller.entry(sourceID: sourceID) == nil, "Manifest mutation was accepted: \(label)")
            try original.write(to: manifest, options: .atomic)
            _ = try controller.scanLibrary()
            precondition(controller.entry(sourceID: sourceID) != nil, "Valid manifest did not recover after: \(label)")
        }

        try expectRejected("source does not match folder") { object in
            var source = object["source"] as! [String: Any]
            source["date"] = "2024-01-02"
            object["source"] = source
        }
        try expectRejected("invalid source fields") { object in
            var source = object["source"] as! [String: Any]
            source["showID"] = "0"
            object["source"] = source
        }
        try expectRejected("duplicate track numbers") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[1]["trackNumber"] = tracks[0]["trackNumber"]
            object["tracks"] = tracks
        }
        try expectRejected("non-positive track number") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[0]["trackNumber"] = 0
            object["tracks"] = tracks
        }
        try expectRejected("codec does not match file") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[0]["codec"] = tracks[0]["codec"] as? String == "mp3" ? "flac" : "mp3"
            object["tracks"] = tracks
        }
        try expectRejected("declared byte size does not match file") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[0]["byteCount"] = (tracks[0]["byteCount"] as! NSNumber).int64Value + 1
            object["tracks"] = tracks
        }
        try expectRejected("unsafe filename") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[0]["filename"] = "../manifest.json"
            object["tracks"] = tracks
        }
        try expectRejected("duplicate filename") { object in
            var tracks = object["tracks"] as! [[String: Any]]
            tracks[1]["filename"] = tracks[0]["filename"]
            object["tracks"] = tracks
        }
    }

    private static func verifyRejectedImportCleanup(controller: LibraryController, fixture: URL) throws {
        let directory = try controller.makeImportStagingDirectory(sourceID: 99)
        let downloaded = directory.appendingPathComponent(fixture.lastPathComponent)
        try FileManager.default.copyItem(at: fixture, to: downloaded)
        let invalid = LibrarySourceDescriptor(sourceID: 99, showID: "0", date: "2024-01-01",
                                              venue: "Fixture Hall", version: "V.1")
        var outcome: Result<LibraryEntry, Error>?
        controller.importDownloadedFile(downloaded, source: invalid, progress: { _ in }, completion: { outcome = $0 })
        guard case .failure? = outcome else { throw LibraryError.server("Invalid import was not rejected.") }
        precondition(!FileManager.default.fileExists(atPath: directory.path), "Rejected import staging was leaked")
    }

    private static func makeWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let frames: UInt32 = 8_000
        let dataBytes = frames * 2
        var result = Data("RIFF".utf8)
        result.appendLE(UInt32(36) + dataBytes)
        result.append(Data("WAVEfmt ".utf8))
        result.appendLE(UInt32(16))
        result.appendLE(UInt16(1))
        result.appendLE(UInt16(1))
        result.appendLE(sampleRate)
        result.appendLE(sampleRate * 2)
        result.appendLE(UInt16(2))
        result.appendLE(UInt16(16))
        result.append(Data("data".utf8))
        result.appendLE(dataBytes)
        result.append(Data(repeating: 0, count: Int(dataBytes)))
        return result
    }

    private static func makeFLAC() -> Data {
        let blockSize: UInt16 = 192
        var frame = Data([0xff, 0xf8, 0x60, 0x08, 0x00, UInt8(blockSize - 1)])
        frame.append(crc8(frame))
        frame.append(contentsOf: [0x00, 0x00, 0x00]) // constant, silent 16-bit mono subframe
        frame.appendBE(crc16(frame))

        var streamInfo = Data()
        streamInfo.appendBE(blockSize)
        streamInfo.appendBE(blockSize)
        streamInfo.appendUInt24(UInt32(frame.count))
        streamInfo.appendUInt24(UInt32(frame.count))
        let packed = (UInt64(44_100) << 44) | (UInt64(15) << 36) | UInt64(blockSize)
        streamInfo.appendBE(packed)
        streamInfo.append(Data(repeating: 0, count: 16))
        precondition(streamInfo.count == 34)

        var result = Data("fLaC".utf8)
        result.append(0x80) // final STREAMINFO metadata block
        result.appendUInt24(UInt32(streamInfo.count))
        result.append(streamInfo)
        result.append(frame)
        return result
    }

    private static func crc8(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0
        for byte in data {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    private static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }

    private static func isALAC(_ url: URL) -> Bool {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file = file else { return false }
        defer { AudioFileClose(file) }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &description) == noErr &&
            description.mFormatID == kAudioFormatAppleLossless
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
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
            throw LibraryError.server(String(data: data, encoding: .utf8) ?? "Fixture command failed.")
        }
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    mutating func appendUInt24(_ value: UInt32) {
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
