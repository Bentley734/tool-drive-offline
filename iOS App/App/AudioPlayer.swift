import AVFoundation
import Combine
import MediaPlayer

@MainActor
final class AudioPlayer: ObservableObject {
    enum Phase: Equatable { case idle, resolving, buffering, playing, paused, finished, failed }
    struct Track: Identifiable {
        let id: Int
        let title: String
        let duration: TimeInterval?
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var tracks = [Track]()
    @Published private(set) var index = 0
    @Published private(set) var collection = ""
    @Published private(set) var context = ""
    @Published private(set) var sourceID: Int?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var equalizer = PlaybackEQSettings.flat
    @Published private(set) var equalizerAvailable: Bool?
    @Published var isExpanded = false

    private let transport = AVPlayer()
    private let media = LiveMediaService()
    private var audio = [LiveTrack]()
    private var retryLive: (() -> Void)?
    private var requestID = UUID()
    private var wantsPlayback = false
    private var resumeAfterInterruption = false
    private var wantsLevels = false
    private var analysis: AudioAnalysis?
    private var analysisPlayingSince: TimeInterval?
    private var itemObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var itemObservers = [NSObjectProtocol]()
    private var sessionObservers = [NSObjectProtocol]()
    private var commands = [(MPRemoteCommand, Any)]()

    var isVisible: Bool { phase != .idle }
    var currentTrack: Track? { tracks.indices.contains(index) ? tracks[index] : nil }
    var isPlaying: Bool { phase == .playing || (phase == .buffering && wantsPlayback) }
    var canToggle: Bool { !tracks.isEmpty || phase == .failed }

    init() {
        transportObservation = transport.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updatePlaybackStatus() }
        }
        timeObserver = transport.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                         queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateTime() }
        }
        let session = AVAudioSession.sharedInstance()
        let notifications = NotificationCenter.default
        sessionObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: session, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleInterruption(rawType, options: options) }
        })
        sessionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                          object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        })
        installRemoteCommands()
    }

    deinit {
        if let timeObserver { transport.removeTimeObserver(timeObserver) }
        (itemObservers + sessionObservers).forEach(NotificationCenter.default.removeObserver)
        for (command, target) in commands { command.removeTarget(target) }
        media.cancelAll()
    }

    func stream(show: Concert, source: RecordingSource) {
        guard source.streamVersion != nil else { return }
        if sourceID == source.id && isVisible && phase != .failed {
            isExpanded = true
            return
        }
        resolve(show: show, source: source)
    }

    private func resolve(show: Concert, source: RecordingSource) {
        guard let version = source.streamVersion else { return }
        clearItem()
        equalizer = .flat
        audio = []
        tracks = []
        index = 0
        sourceID = source.id
        collection = show.venue.isEmpty ? show.date : show.venue
        context = [show.date, show.location, source.version].filter { !$0.isEmpty }.joined(separator: " · ")
        errorMessage = nil
        phase = .resolving
        wantsPlayback = true
        isExpanded = true
        updateNowPlaying()
        retryLive = { [weak self] in self?.resolve(show: show, source: source) }
        let request = UUID()
        requestID = request
        media.resolveTracks(showID: show.id, sourceID: source.id, date: show.date, version: version) { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestID == request else { return }
                switch result {
                case .success(let found):
                    self.install(found, startIndex: 0, autoplay: self.wantsPlayback)
                case .failure:
                    self.fail("The archive couldn’t provide this recording. Check your connection and try again.")
                }
            }
        }
    }

    func play(tracks: [LiveTrack], title: String, context: String, startIndex: Int = 0, expandPlayer: Bool = false) {
        guard !tracks.isEmpty else { return }
        requestID = UUID()
        media.cancelTrackResolution()
        retryLive = nil
        sourceID = nil
        equalizer = .flat
        collection = title
        self.context = context
        if expandPlayer { isExpanded = true }
        install(tracks, startIndex: startIndex)
    }

    private func install(_ found: [LiveTrack], startIndex: Int, autoplay: Bool = true) {
        guard !found.isEmpty else { fail("The recording contains no playable tracks."); return }
        audio = found
        tracks = found.enumerated().map { index, track in
            let length = track.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return Track(id: index, title: track.title, duration: length)
        }
        retryLive = nil
        selectTrack(min(max(0, startIndex), found.count - 1), autoplay: autoplay)
    }

    func selectTrack(_ requested: Int, autoplay: Bool = true) {
        guard audio.indices.contains(requested) else { return }
        clearItem()
        index = requested
        errorMessage = nil
        duration = tracks[requested].duration ?? 0
        wantsPlayback = autoplay
        phase = autoplay ? .buffering : .paused
        let item = AVPlayerItem(url: audio[requested].url)
        transport.replaceCurrentItem(with: item)
        configureProcessing()
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.transport.currentItem === item else { return }
                if item.status == .failed { self.fail("This track couldn’t be played. Retry it or choose another track.") }
                else if item.status == .readyToPlay { self.updateTime(); self.updatePlaybackStatus() }
            }
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.transport.currentItem === item else { return }
                if self.index + 1 < self.audio.count { self.selectTrack(self.index + 1, autoplay: self.wantsPlayback) }
                else {
                    self.wantsPlayback = false
                    self.phase = .finished
                    self.updateTime()
                    self.updateNowPlaying()
                    self.deactivateSession()
                }
            }
        })
        itemObservers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let self, let item, self.transport.currentItem === item else { return }
                self.fail("Playback stopped before the end of this track.")
            }
        })
        if autoplay { resume() } else { updateNowPlaying() }
    }

    func toggle() {
        if isPlaying { pause() }
        else if phase == .failed, let retryLive { retryLive() }
        else if phase == .failed { selectTrack(index) }
        else if phase == .finished { selectTrack(0) }
        else { resume() }
    }

    private func resume() {
        guard transport.currentItem != nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch { fail("The audio output is unavailable. Check the selected output and try again."); return }
        wantsPlayback = true
        resumeAfterInterruption = false
        phase = .buffering
        transport.play()
        updatePlaybackStatus()
    }

    func pause() {
        resumeAfterInterruption = false
        wantsPlayback = false
        guard !tracks.isEmpty else { return }
        transport.pause()
        if phase != .failed && phase != .finished { phase = .paused }
        updateNowPlaying()
    }

    func previous() {
        if elapsed > 3 || index == 0 { seek(to: 0) }
        else { selectTrack(index - 1, autoplay: wantsPlayback) }
    }

    func next() { if index + 1 < tracks.count { selectTrack(index + 1, autoplay: wantsPlayback) } }

    func seek(to value: Double) {
        guard value.isFinite, duration > 0, transport.currentItem != nil else { return }
        let target = max(0, min(value, duration))
        transport.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target
        if phase == .finished { phase = .paused }
        updateNowPlaying()
    }

    func stop() {
        requestID = UUID()
        media.cancelTrackResolution()
        clearItem()
        equalizer = .flat
        wantsLevels = false
        wantsPlayback = false
        sourceID = nil
        retryLive = nil
        errorMessage = nil
        tracks = []
        audio = []
        isExpanded = false
        phase = .idle
        updateNowPlaying()
        deactivateSession()
    }

    private func clearItem() {
        resumeAfterInterruption = false
        detachProcessing()
        itemObservation?.invalidate()
        itemObservation = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        transport.pause()
        transport.replaceCurrentItem(with: nil)
        elapsed = 0
        duration = 0
    }

    private func deactivateSession() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

    private func updateTime() {
        guard let item = transport.currentItem else { return }
        let time = item.currentTime().seconds
        if time.isFinite { elapsed = max(0, time) }
        let length = item.duration.seconds
        if length.isFinite && length > 0 { duration = length }
        if let analysis {
            if let available = analysis.equalizerAvailable {
                if equalizerAvailable != available { equalizerAvailable = available }
                analysisPlayingSince = nil
            } else if transport.timeControlStatus == .playing {
                let now = ProcessInfo.processInfo.systemUptime
                if let start = analysisPlayingSince {
                    if now - start > 2 && equalizerAvailable != false { equalizerAvailable = false }
                } else { analysisPlayingSince = now }
            } else { analysisPlayingSince = nil }
        }
    }

    func setVisualizerActive(_ active: Bool) {
        guard wantsLevels != active else { return }
        wantsLevels = active
        configureProcessing()
    }

    func visualizerLevels() -> [Double] {
        guard wantsLevels, phase == .playing, let analysis else { return [0, 0, 0] }
        return analysis.levels(at: transport.currentTime().seconds)
    }

    func setEqualizer(_ settings: PlaybackEQSettings) {
        guard settings != equalizer else { return }
        equalizer = settings
        configureProcessing()
    }

    private func configureProcessing() {
        guard wantsLevels || !equalizer.isFlat else { detachProcessing(); return }
        guard let item = transport.currentItem else { return }
        if let analysis { analysis.configure(settings: equalizer, levels: wantsLevels); return }
        let tap = AudioAnalysis()
        analysis = tap
        tap.configure(settings: equalizer, levels: wantsLevels)
        Task { [weak self, weak item, weak tap] in
            guard let item, let tap else { return }
            let tracks = try? await item.asset.loadTracks(withMediaType: .audio)
            guard let self, self.transport.currentItem === item, self.analysis === tap else { return }
            guard let track = tracks?.first, let mix = tap.mix(for: track) else {
                self.equalizerAvailable = false
                return
            }
            item.audioMix = mix
        }
    }

    private func detachProcessing() {
        guard analysis != nil else { return }
        analysis = nil
        transport.currentItem?.audioMix = nil
        analysisPlayingSince = nil
        equalizerAvailable = nil
    }

    private func updatePlaybackStatus() {
        guard transport.currentItem != nil, phase != .failed, phase != .finished else { return }
        let next: Phase = !wantsPlayback ? .paused : (transport.timeControlStatus == .playing ? .playing : .buffering)
        if phase != next { phase = next }
        updateNowPlaying()
    }

    private func fail(_ message: String) {
        wantsPlayback = false
        transport.pause()
        phase = .failed
        errorMessage = message
        updateNowPlaying()
        deactivateSession()
    }

    private func handleInterruption(_ raw: UInt?, options: UInt) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            let shouldResume = isPlaying
            pause()
            resumeAfterInterruption = shouldResume
        } else if type == .ended, resumeAfterInterruption {
            resumeAfterInterruption = false
            if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { resume() }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (AudioPlayer) -> Void) {
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
            commands.append((command, token))
        }
        bind(center.playCommand) { if !$0.isPlaying { $0.toggle() } }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }
        bind(center.nextTrackCommand) { $0.next() }
        bind(center.previousTrackCommand) { $0.previous() }
        let seekCommand = center.changePlaybackPositionCommand
        commands.append((seekCommand, seekCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }))
        updateNowPlaying()
    }

    private func updateNowPlaying() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = canToggle && !isPlaying
        center.pauseCommand.isEnabled = isPlaying
        center.togglePlayPauseCommand.isEnabled = canToggle
        center.nextTrackCommand.isEnabled = index + 1 < tracks.count
        center.previousTrackCommand.isEnabled = currentTrack != nil
        center.changePlaybackPositionCommand.isEnabled = duration > 0
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyAlbumTitle: collection,
                                   MPMediaItemPropertyArtist: "TOOL", MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
                                   MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
                                   MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
                                   MPNowPlayingInfoPropertyPlaybackQueueCount: tracks.count]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension RecordingSource {
    var streamVersion: Int? {
        guard status.caseInsensitiveCompare("OTD") == .orderedSame,
              version.range(of: "^V\\.[0-9]{1,3}$", options: .regularExpression) != nil else { return nil }
        return Int(version.dropFirst(2))
    }
}
