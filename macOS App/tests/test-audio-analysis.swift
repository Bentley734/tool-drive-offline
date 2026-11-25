import AVFoundation
import Foundation

@main
enum AudioAnalysisChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func writeFixture(_ url: URL) throws {
        let rate = 44_100
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2)!
        let disk = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: disk.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = AVAudioFrameCount(rate)
        for frequency in [80, 1000, 6500, 0] {
            for n in 0..<rate {
                let sample = Float(0.2 * sin(2 * .pi * Double(n * frequency) / Double(rate)))
                buffer.floatChannelData![0][n] = sample
                buffer.floatChannelData![1][n] = -sample
            }
            try file.write(from: buffer)
        }
    }

    static func decode(_ asset: AVAsset, track: AVAssetTrack, mix: AVAudioMix?) throws -> Data {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.audioMix = mix
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure(description: "Cannot start the fixture reader") }
        var samples = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let data = CMSampleBufferGetDataBuffer(sample) else { throw Failure(description: "No decoded PCM") }
            var block = Data(count: CMBlockBufferGetDataLength(data))
            let size = block.count
            let result = block.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            try require(result == noErr, "Cannot copy decoded PCM")
            samples.append(block)
        }
        try require(reader.status == .completed && !samples.isEmpty, "Fixture decode failed")
        return samples
    }

    static func encodeFLAC(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 4096)!
        while input.framePosition < input.length {
            try input.read(into: buffer)
            try output.write(from: buffer)
        }
    }

    static func main() throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("bands.caf")
        try writeFixture(fixture)
        let asset = AVURLAsset(url: fixture)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure(description: "No PCM track") }
        let analysis = AudioAnalysis()
        analysis.configure(settings: .flat, levels: true)
        guard analysis.mix(for: track) != nil else { throw Failure(description: "Cannot create PCM tap") }
        // AVAudioFile uses the same decoded PCM as the render callback and can
        // exercise DSP even on machines where system media mixing is unavailable.
        let file = try AVAudioFile(forReading: fixture)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        analysis.prepare(file.processingFormat.streamDescription.pointee)
        while file.framePosition < file.length {
            let position = file.framePosition
            try file.read(into: buffer)
            let bytes = Int(buffer.frameLength) * MemoryLayout<Float>.size
            let before = Data(bytes: buffer.floatChannelData![0], count: bytes)
            analysis.process(buffer.mutableAudioBufferList, frames: Int(buffer.frameLength),
                             start: Double(position) / file.processingFormat.sampleRate, discontinuity: position == 0)
            try require(before == Data(bytes: buffer.floatChannelData![0], count: bytes), "Flat DSP modified a channel")
        }
        try require(analysis.equalizerAvailable == true, "Float32 output must support the equalizer")
        for (band, time) in [0.5, 1.5, 2.5].enumerated() {
            let levels = analysis.levels(at: time)
            try require(levels[band] > 0.6 && levels.enumerated().allSatisfy { $0.offset == band || $0.element < 0.15 },
                        "Incorrect band for tone at \(time)s: \(levels)")
        }
        try require(analysis.levels(at: 3.5) == [0, 0, 0], "Silence produced activity")
        try require(analysis.levels(at: 10) == [0, 0, 0], "Outdated levels remained after playback")
        print("PASS stereo bass/mid/treble separation, timestamp alignment, true silence and flat playback")

        let filtered = AudioAnalysis()
        var settings = PlaybackEQSettings.flat
        settings.bass = 9
        filtered.prepare(file.processingFormat.streamDescription.pointee)
        // Turn on analysis halfway through the bass tone. The EQ must already
        // be acting on playback before that, and later meters should reflect it.
        file.framePosition = 0
        var heardBoostWhileHidden = false
        while Double(file.framePosition) < file.processingFormat.sampleRate {
            let time = Double(file.framePosition) / file.processingFormat.sampleRate
            let visible = time > 0.4
            filtered.configure(settings: settings, levels: visible)
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            filtered.process(buffer.mutableAudioBufferList, frames: count, start: time, discontinuity: time == 0)
            if !visible && time > 0 {
                let channel = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)
                heardBoostWhileHidden = heardBoostWhileHidden || channel.contains { abs($0) > 0.4 }
            }
        }
        try require(heardBoostWhileHidden && filtered.levels(at: 0.2) == [0, 0, 0],
                    "Hiding analysis stopped the EQ or kept collecting levels")
        try require(filtered.levels(at: 0.8)[0] > analysis.levels(at: 0.8)[0] + 0.1,
                    "The visualizer analyzed the signal before equalization")
        print("PASS audible EQ with the visualizer closed and post-EQ analysis with it open")
        let original: Data
        do { original = try decode(asset, track: track, mix: nil) }
        catch {
            if ProcessInfo.processInfo.environment["TOOL_DRIVE_REQUIRE_AUDIO_MIX"] == "1" { throw error }
            print("SKIP AVAssetReader audio mix: the system could not run its unmodified reference mixer")
            return
        }
        let tapped = AudioAnalysis()
        tapped.configure(settings: .flat, levels: true)
        guard let tappedMix = tapped.mix(for: track) else { throw Failure(description: "Cannot attach system tap") }
        let flat = try decode(asset, track: track, mix: tappedMix)
        try require(flat == original, "Flat system tap changed the decoded recording")
        try require(tapped.equalizerAvailable == true && tapped.levels(at: 1.5)[1] > 0.6,
                    "AVFoundation did not process audio through the tap")
        print("PASS AVFoundation mixed audio passes unchanged through the flat system tap")
        let flacURL = fixture.deletingLastPathComponent().appendingPathComponent("bands.flac")
        try encodeFLAC(fixture, to: flacURL)
        let losslessAsset = AVURLAsset(url: flacURL)
        guard let losslessTrack = losslessAsset.tracks(withMediaType: .audio).first else {
            throw Failure(description: "Cannot open the FLAC fixture")
        }
        let lossless = AudioAnalysis()
        lossless.configure(settings: settings, levels: true)
        guard let losslessMix = lossless.mix(for: losslessTrack) else { throw Failure(description: "Cannot attach FLAC tap") }
        _ = try decode(losslessAsset, track: losslessTrack, mix: losslessMix)
        try require(lossless.equalizerAvailable == true && lossless.levels(at: 0.5)[0] > tapped.levels(at: 0.5)[0] + 0.1 &&
                    lossless.levels(at: 1.5)[1] > 0.6 && lossless.levels(at: 2.5)[2] > 0.6,
                    "The native FLAC decoder did not drive the equalizer and visualizer")
        print("PASS native lossless FLAC decoder, equalizer and frequency analysis")
    }
}
