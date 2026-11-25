import AudioToolbox
import CoreAudio
import Foundation

struct PlaybackEQSettings: Equatable {
    var bass = 0.0
    var mid = 0.0
    var treble = 0.0
    var magik = false
    static let flat = PlaybackEQSettings()
    var isFlat: Bool { self == .flat }
}

// The three tone controls and Magik's eight serial bells follow the Tool Drive
// Project player's published frequency, Q and gain settings. Filter history is
// private to each channel. Only the audio-render thread touches this processor.
final class PlaybackEqualizer {
    private enum Kind { case lowShelf, bell, highShelf }
    private struct Band {
        let kind: Kind
        let hz: Double
        let q: Double
        let magikGain: Double
        init(_ kind: Kind, _ hz: Double, _ q: Double = 1, _ magikGain: Double = 0) {
            self.kind = kind; self.hz = hz; self.q = q; self.magikGain = magikGain
        }
    }
    private static let bands = [
        Band(.lowShelf, 200), Band(.bell, 1000), Band(.highShelf, 4000),
        Band(.bell, 315, 4.3, -0.75), Band(.bell, 400, 4.3, -2.6),
        Band(.bell, 500, 4.3, -4.75), Band(.bell, 630, 4.3, -7.65),
        Band(.bell, 800, 4.3, -4.75), Band(.bell, 1000, 4.3, -2.6),
        Band(.bell, 1250, 4.3, -0.75), Band(.bell, 10000, 4.3, 0.15)
    ]
    private struct Coefficients {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        mutating func approach(_ goal: Self, by f: Double) {
            b0 += f * (goal.b0 - b0); b1 += f * (goal.b1 - b1); b2 += f * (goal.b2 - b2)
            a1 += f * (goal.a1 - a1); a2 += f * (goal.a2 - a2)
        }
    }
    private struct History {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        mutating func filter(_ x: Double, _ c: Coefficients) -> Double {
            let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
    private struct Filter {
        var current = Coefficients(), target = Coefficients()
    }
    private let sampleRate: Double
    private let channels: Int
    private let attack, release: Double
    private var filters = Array(repeating: Filter(), count: bands.count)
    private var histories: [History]
    private var previous = PlaybackEQSettings.flat
    private var rampLeft = 0
    private var limiterGain = 1.0

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        histories = Array(repeating: History(), count: Self.bands.count * channels)
        attack = 1 - exp(-1 / (0.001 * sampleRate))
        release = 1 - exp(-1 / (0.1 * sampleRate))
    }

    // RBJ biquads with Web Audio's shelf slope of one. A band above Nyquist
    // is bypassed, so low-rate archival material cannot destabilize a filter.
    private func coefficients(_ band: Band, gain: Double) -> Coefficients {
        guard gain != 0, band.hz < sampleRate * 0.5 else { return Coefficients() }
        let a = pow(10, gain / 40)
        let w = 2 * Double.pi * band.hz / sampleRate
        let c = cos(w), s = sin(w)
        let plus = a + 1, minus = a - 1, beta = sqrt(2 * a) * s
        let a0, a1, a2, b0, b1, b2: Double
        switch band.kind {
        case .bell:
            let alpha = s / (2 * band.q)
            b0 = 1 + alpha*a; b1 = -2*c; b2 = 1 - alpha*a
            a0 = 1 + alpha/a; a1 = -2*c; a2 = 1 - alpha/a
        case .lowShelf:
            b0 = a*(plus - minus*c + beta); b1 = 2*a*(minus - plus*c); b2 = a*(plus - minus*c - beta)
            a0 = plus + minus*c + beta; a1 = -2*(minus + plus*c); a2 = plus + minus*c - beta
        case .highShelf:
            b0 = a*(plus + minus*c + beta); b1 = -2*a*(minus + plus*c); b2 = a*(plus + minus*c - beta)
            a0 = plus - minus*c + beta; a1 = 2*(minus - plus*c); a2 = plus - minus*c - beta
        }
        return Coefficients(b0: b0/a0, b1: b1/a0, b2: b2/a0, a1: a1/a0, a2: a2/a0)
    }

    func process(_ data: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool, settings: PlaybackEQSettings) {
        guard frames > 0, channels > 0, data.count == (interleaved ? 1 : channels) else { return }
        let stride = interleaved ? channels : 1
        for buffer in data {
            guard buffer.mData != nil, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride / stride >= frames else { return }
        }
        if settings != previous {
            for i in filters.indices {
                let band = Self.bands[i]
                let gain: Double
                switch i {
                case 0: gain = settings.bass
                case 1: gain = settings.mid
                case 2: gain = settings.treble
                default: gain = settings.magik ? band.magikGain : 0
                }
                filters[i].target = coefficients(band, gain: gain)
            }
            rampLeft = max(1, Int(0.015 * sampleRate))
            previous = settings
        }
        if settings.isFlat && rampLeft == 0 { return }
        let count = filters.count
        filters.withUnsafeMutableBufferPointer { bank in
            histories.withUnsafeMutableBufferPointer { state in
                for frame in 0..<frames {
                    if rampLeft > 0 && frame % 32 == 0 {
                        let step = min(32, rampLeft)
                        let fraction = Double(step) / Double(rampLeft)
                        for band in bank.indices {
                            let goal = bank[band].target
                            bank[band].current.approach(goal, by: fraction)
                        }
                        rampLeft -= step
                    }
                    var peak = 0.0
                    for channel in 0..<channels {
                        let ptr = data[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                        let i = frame * stride + (interleaved ? channel : 0)
                        var sample = Double(ptr[i])
                        for band in bank.indices {
                            sample = state[channel * count + band].filter(sample, bank[band].current)
                        }
                        ptr[i] = Float(sample)
                        peak = max(peak, abs(sample))
                    }
                    // Stereo-linked output protection: -1 dB threshold, 20:1 ratio,
                    // 1 ms attack, 100 ms release. Flat passes original PCM untouched.
                    let threshold = 0.8912509381
                    let target = peak > threshold ? pow(threshold / peak, 0.95) : 1.0
                    limiterGain += (target - limiterGain) * (target < limiterGain ? attack : release)
                    for channel in 0..<channels {
                        let ptr = data[interleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                        let i = frame * stride + (interleaved ? channel : 0)
                        ptr[i] = min(1, max(-1, ptr[i] * Float(limiterGain)))
                    }
                }
            }
        }
        if settings.isFlat && rampLeft == 0 {
            limiterGain = 1
            for i in histories.indices { histories[i] = History() }
        }
    }
}
