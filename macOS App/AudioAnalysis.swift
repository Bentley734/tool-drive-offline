import Accelerate
import AVFoundation
import MediaToolbox

// One instance belongs to one player item. AVFoundation can decode ahead, so the
// main thread reads levels at the playhead rather than at the latest decode time.
final class AudioAnalysis {
    private struct Window {
        let start: Double
        let duration: Double
        let levels: SIMD3<Double>
    }

    private let lock = NSLock()
    private var windows = Array(repeating: Window(start: -.infinity, duration: 0, levels: .zero), count: 512)
    private var next = 0
    private var spectrum: Spectrum?
    private var equalizer: PlaybackEqualizer?
    private var interleaved = false
    private var requestedSettings = PlaybackEQSettings.flat
    private var requestedLevels = false
    private var renderSettings = PlaybackEQSettings.flat
    private var renderLevels = false
    private var eqCapability: Bool?

    func configure(settings: PlaybackEQSettings, levels: Bool) {
        lock.lock()
        requestedSettings = settings
        requestedLevels = levels
        lock.unlock()
    }

    var equalizerAvailable: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return eqCapability
    }

    func mix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passUnretained(self).toOpaque(),
            init: { _, info, storage in
                guard let info = info else { return }
                // The system may retain a tap after the item is replaced.
                storage.pointee = Unmanaged<AudioAnalysis>.fromOpaque(info).retain().toOpaque()
            },
            finalize: { tap in
                Unmanaged<AudioAnalysis>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                AudioAnalysis.owner(tap).prepare(format.pointee)
            },
            unprepare: { tap in
                let owner = AudioAnalysis.owner(tap)
                owner.spectrum = nil
                owner.equalizer = nil
            },
            process: { tap, frames, _, buffers, renderedFrames, flags in
                var time = CMTimeRange.invalid
                let result = MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &time, renderedFrames)
                guard result == noErr else { renderedFrames.pointee = 0; return }
                // Preserve the source buffers and frame count, including for unsupported formats.
                let owner = AudioAnalysis.owner(tap)
                owner.process(buffers, frames: renderedFrames.pointee, start: time.start.seconds,
                              discontinuity: flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0)
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(nil, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr,
              let tap = tap else { return nil }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }

    private static func owner(_ tap: MTAudioProcessingTap) -> AudioAnalysis {
        Unmanaged<AudioAnalysis>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    }

    func prepare(_ format: AudioStreamBasicDescription) {
        spectrum = Spectrum(format: format)
        var description = format
        if let audio = AVAudioFormat(streamDescription: &description), audio.commonFormat == .pcmFormatFloat32,
           format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
           format.mSampleRate.isFinite, format.mSampleRate > 0, (1...8).contains(format.mChannelsPerFrame) {
            interleaved = audio.isInterleaved
            equalizer = PlaybackEqualizer(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame))
        } else {
            equalizer = nil
        }
    }

    func process(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double, discontinuity: Bool) {
        guard frames > 0 else { return }
        if lock.try() {
            renderSettings = requestedSettings
            renderLevels = requestedLevels
            eqCapability = equalizer != nil
            lock.unlock()
        }
        if let equalizer = equalizer {
            equalizer.process(UnsafeMutableAudioBufferListPointer(buffers), frames: frames,
                              interleaved: interleaved, settings: renderSettings)
        }
        if discontinuity || !renderLevels { spectrum?.reset() }
        if renderLevels { spectrum?.consume(buffers, frames: frames, start: start, sink: self) }
    }

    fileprivate func record(_ levels: SIMD3<Double>, start: Double, duration: Double) {
        // Dropping a visual frame is preferable to blocking the audio render thread.
        guard lock.try() else { return }
        windows[next] = Window(start: start, duration: duration, levels: levels)
        next = (next + 1) % windows.count
        lock.unlock()
    }

    func levels(at time: Double) -> [Double] {
        lock.lock()
        var index = next
        var levels = SIMD3<Double>.zero
        for _ in windows.indices {
            index = (index + windows.count - 1) % windows.count
            let window = windows[index]
            if window.start <= time && time < window.start + window.duration {
                levels = window.levels
                break
            }
        }
        lock.unlock()
        return [levels.x, levels.y, levels.z]
    }
}

// All FFT storage is allocated in the tap's prepare callback. Keeping channels
// separate preserves stereo recordings whose left and right channels are out of phase.
private final class Spectrum {
    private let rate: Double
    private let size: Int
    private let logSize: vDSP_Length
    private let channels: Int
    private let encoding: AVAudioCommonFormat
    private let setup: FFTSetup
    private let samples: UnsafeMutablePointer<Float>
    private var hann: [Float]
    private var tapered: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var power: [Float]
    private let edges: (Int, Int, Int, Int)
    private var filled = 0

    init?(format: AudioStreamBasicDescription) {
        var description = format
        guard description.mFormatID == kAudioFormatLinearPCM,
              let audio = AVAudioFormat(streamDescription: &description),
              [.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32].contains(audio.commonFormat),
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (1...8).contains(format.mChannelsPerFrame),
              (8_000...384_000).contains(format.mSampleRate) else { return nil }
        encoding = audio.commonFormat
        rate = format.mSampleRate
        channels = Int(format.mChannelsPerFrame)
        let exponent = Int(log2(rate / 28).rounded())
        logSize = vDSP_Length(exponent)
        size = 1 << exponent
        guard let fft = vDSP_create_fftsetup(logSize, FFTRadix(kFFTRadix2)) else { return nil }
        setup = fft
        samples = .allocate(capacity: size * channels)
        hann = Array(repeating: 0, count: size)
        tapered = Array(repeating: 0, count: size)
        real = Array(repeating: 0, count: size / 2)
        imaginary = Array(repeating: 0, count: size / 2)
        power = Array(repeating: 0, count: size / 2)
        let binWidth = rate / Double(size)
        edges = (1, Int(ceil(220 / binWidth)), Int(ceil(2_400 / binWidth)),
                 min(size / 2, Int(ceil(18_000 / binWidth))))
        vDSP_hann_window(&hann, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        samples.deallocate()
    }

    func reset() { filled = 0 }

    func consume(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double, sink: AudioAnalysis) {
        guard frames > 0, start.isFinite else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var offset = 0
        while offset < frames {
            let count = min(size - filled, frames - offset)
            var channel = 0
            for buffer in buffers {
                let stride = Int(buffer.mNumberChannels)
                let width = encoding == .pcmFormatFloat64 ? 8 : (encoding == .pcmFormatInt16 ? 2 : 4)
                guard let data = buffer.mData, stride > 0, channel + stride <= channels,
                      (offset + count) * stride * width <= Int(buffer.mDataByteSize) else { reset(); return }
                for lane in 0..<stride {
                    let dest = samples + channel * size + filled
                    let source = offset * stride + lane
                    switch encoding {
                    case .pcmFormatFloat32:
                        let input = data.assumingMemoryBound(to: Float.self) + source
                        if stride == 1 { dest.update(from: input, count: count) }
                        else { for i in 0..<count { dest[i] = input[i * stride] } }
                    case .pcmFormatFloat64:
                        let input = data.assumingMemoryBound(to: Double.self) + source
                        for i in 0..<count { dest[i] = Float(input[i * stride]) }
                    case .pcmFormatInt16:
                        let input = data.assumingMemoryBound(to: Int16.self) + source
                        for i in 0..<count { dest[i] = Float(input[i * stride]) / 32768 }
                    case .pcmFormatInt32:
                        let input = data.assumingMemoryBound(to: Int32.self) + source
                        for i in 0..<count { dest[i] = Float(input[i * stride]) / 2147483648 }
                    default: return
                    }
                    channel += 1
                }
            }
            guard channel == channels else { reset(); return }
            offset += count
            filled += count
            if filled == size {
                let duration = Double(size) / rate
                sink.record(analyze(), start: start + Double(offset) / rate - duration, duration: duration)
                filled = 0
            }
        }
    }

    private func analyze() -> SIMD3<Double> {
        var energy = SIMD3<Double>.zero
        for channel in 0..<channels {
            vDSP_vmul(samples + channel * size, 1, hann, 1, &tapered, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { re in
                imaginary.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    tapered.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(size / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, logSize, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
                }
            }
            power.withUnsafeBufferPointer { spectrum in
                func sum(_ low: Int, _ high: Int) -> Double {
                    var value: Float = 0
                    vDSP_sve(spectrum.baseAddress! + low, 1, &value, vDSP_Length(high - low))
                    return Double(value)
                }
                energy += SIMD3(sum(edges.0, edges.1), sum(edges.1, edges.2), sum(edges.2, edges.3))
            }
        }
        // Real FFT power with a Hann window and channel averaging; -60 dBFS is the display floor.
        let factor = 4.0 / (3.0 * Double(size * size * channels))
        func level(_ power: Double) -> Double {
            guard power.isFinite && power * factor > 0.000001 else { return 0 }
            return min(1, 1 + log10(power * factor) / 6)
        }
        return SIMD3(level(energy.x), level(energy.y), level(energy.z))
    }
}
