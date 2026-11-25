import AVFoundation
import Foundation

@main
enum PlaybackEqualizerChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static let rate = 48_000.0
    static let bright = PlaybackEQSettings(bass: -1, mid: 1, treble: 7)
    static let vocal = PlaybackEQSettings(bass: -3, mid: 6, treble: 1)
    static let bassBoost = PlaybackEQSettings(bass: 8, mid: 0, treble: 2)
    static let magik = PlaybackEQSettings(magik: true)

    static func tone(_ hz: Double, rate: Double = rate, amplitude: Double = 0.05) -> [Float] {
        (0..<Int(rate / 2)).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    static func buffer(_ channels: [[Float]], rate: Double, interleaved: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: interleaved)!
        let frames = channels[0].count
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for (channel, samples) in channels.enumerated() {
            let ptr = data[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            for frame in samples.indices {
                ptr[interleaved ? frame * channels.count + channel : frame] = samples[frame]
            }
        }
        return pcm
    }

    static func render(_ channels: [[Float]], _ settings: PlaybackEQSettings, rate: Double = rate,
                       interleaved: Bool = false, processor: PlaybackEqualizer? = nil) -> [[Float]] {
        let pcm = buffer(channels, rate: rate, interleaved: interleaved)
        let data = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let eq = processor ?? PlaybackEqualizer(sampleRate: rate, channels: channels.count)
        eq.process(data, frames: Int(pcm.frameLength), interleaved: interleaved, settings: settings)
        return channels.indices.map { channel in
            let ptr = data[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
            return channels[channel].indices.map { ptr[interleaved ? $0 * channels.count + channel : $0] }
        }
    }

    static func checkFlat() throws {
        let samples = (0..<2048).map { n in
            [Float(-0.0), 0, .leastNonzeroMagnitude, -0.83, Float(n) / 2048][n % 5]
        }
        let inputs = [samples, samples.map { -$0 }]
        for interleaved in [false, true] {
            let processor = PlaybackEqualizer(sampleRate: rate, channels: inputs.count)
            for pass in 0..<2 {
                if pass == 1 {
                    _ = render(inputs, bassBoost, interleaved: interleaved, processor: processor)
                    _ = render(inputs, .flat, interleaved: interleaved, processor: processor) // gain ramp
                }
                let result = render(inputs, .flat, interleaved: interleaved, processor: processor)
                for i in inputs.indices {
                    try require(inputs[i].map(\.bitPattern) == result[i].map(\.bitPattern),
                                "Flat changed PCM samples (interleaved=\(interleaved), pass=\(pass))")
                }
            }
        }
    }

    static func response(_ hz: Double, _ settings: PlaybackEQSettings, rate: Double = rate) -> Double {
        let input = tone(hz, rate: rate)
        let output = render([input], settings, rate: rate)[0]
        // Measure only the settled portion, after the startup ramp and filter transients.
        func power(_ channel: [Float]) -> Double {
            channel.suffix(channel.count / 2).reduce(0) { $0 + Double($1) * Double($1) }
        }
        return 10 * log10(power(output) / power(input))
    }

    static func checkResponse() throws {
        for settings in [bright, vocal, bassBoost] {
            for (hz, expected) in [(40.0, settings.bass), (1000.0, settings.mid), (12000.0, settings.treble)] {
                let actual = response(hz, settings)
                try require(abs(actual - expected) < 0.5,
                            "\(settings) produced \(actual) dB at \(hz) Hz, expected \(expected)")
            }
        }
        let notch = response(630, magik)
        try require(notch < -8 && notch > -15, "Magik centre response was \(notch) dB")
        try require(abs(response(40, magik)) < 0.3 && abs(response(12000, magik)) < 0.5,
                    "Magik changed the bass or treble far from its notch")
        var combined = vocal
        combined.magik = true
        for hz in [40.0, 630.0, 1000.0, 12000.0] {
            let expected = response(hz, vocal) + response(hz, magik)
            try require(abs(response(hz, combined) - expected) < 0.2,
                        "Magik and Vocal did not combine correctly at \(hz) Hz")
        }
    }

    static func checkChannelsAndProtection() throws {
        let left = tone(75), right = tone(4900)
        let isolated = [render([left], bright)[0], render([right], bright)[0]]
        for interleaved in [false, true] {
            let stereo = render([left, right], bright, interleaved: interleaved)
            try require(stereo == isolated, "Channels shared filter history (interleaved=\(interleaved))")
            let loud = tone(60, amplitude: 0.96)
            let boosted = render([loud, loud.map { -$0 }], PlaybackEQSettings(bass: 10, mid: 10, treble: 10),
                                 interleaved: interleaved)
            try require(boosted.allSatisfy { $0.allSatisfy { $0.isFinite && abs($0) <= 1 } },
                        "Overdriven EQ exceeded the PCM output range")
            try require(zip(boosted[0], boosted[1]).allSatisfy { abs($0 + $1) < 1e-6 },
                        "Output protection shifted the stereo balance")
            try require(boosted[0].contains { abs($0) > 0.75 }, "Overdriven audio became silent")
        }
        let lowRate = 8000.0
        let beyondNyquist = PlaybackEQSettings(treble: 10)
        try require(abs(response(1200, beyondNyquist, rate: lowRate)) < 0.001,
                    "The 4 kHz shelf should be bypassed at an 8 kHz sample rate")
        try require(response(630, magik, rate: lowRate) < -8, "Low-rate audio lost its valid Magik filters")
    }

    static func checkThroughput() throws {
        let frames = 512, iterations = 450
        let input = (0..<frames).map { Float(0.1 * sin(Double($0) * 0.24)) }
        let pcm = buffer([input, input], rate: rate, interleaved: true)
        let data = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        let eq = PlaybackEqualizer(sampleRate: rate, channels: 2)
        var settings = bassBoost
        settings.magik = true
        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<iterations {
            eq.process(data, frames: frames, interleaved: true, settings: settings)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let duration = Double(frames * iterations) / rate
        try require(elapsed < duration, "The optimized DSP processed \(duration) s of stereo in \(elapsed) s")
        print(String(format: "EQ processed %.1f s of stereo in %.3f s", duration, elapsed))
    }

    static func main() throws {
        try checkFlat()
        try checkResponse()
        try checkChannelsAndProtection()
        try checkThroughput()
        print("PASS flat PCM bypass, tone presets, Magik, stereo isolation and output protection")
    }
}
