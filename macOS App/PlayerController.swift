import AVFoundation
import Foundation
import MediaPlayer

final class PlayerController {
    typealias EventHandler = ([String: Any]) -> Void

    static let supportedLocalExtensions: Set<String> = [
        "flac", "alac", "wav", "wave", "aif", "aiff", "mp3", "aac", "m4a", "mp4", "caf"
    ]

    var onStateChange: EventHandler?
    var onTrackListChange: EventHandler?
    var onVisualizerLevels: (([Double]) -> Void)?
    var onEqualizerAvailability: ((Bool?) -> Void)?

    private let media: LiveMediaService
    private let player = AVPlayer()
    private var tracks = [LiveTrack]()
    private var index = 0
    private var showID: Int?
    private var sourceID: Int?
    private var date = ""
    private var venue = ""
    private var versionLabel = ""
    private var collectionLabel = ""
    private var status = "idle"
    private var message = ""
    private var userWantsPlayback = false
    private var retryCount = 0
    private var retryWork: DispatchWorkItem?
    private var healthySince: Date?
    private var itemStatusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var notificationObservers = [NSObjectProtocol]()
    private var remoteTargets = [(MPRemoteCommand, Any)]()
    private var lastNowPlayingSecond = -1
    private var visualizerTimer: Timer?
    private var audioAnalysis: AudioAnalysis?
    private var lastLevels: [Double] = []
    private var equalizerSettings = PlaybackEQSettings.flat
    private var equalizerAvailability: Bool?
    private var analysisPlayingSince: TimeInterval?

    init(media: LiveMediaService = LiveMediaService()) {
        self.media = media
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.playerStatusChanged() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            self?.periodicUpdate()
        }
        installRemoteCommands()
    }

    deinit {
        visualizerTimer?.invalidate()
        media.cancelAll()
        retryWork?.cancel()
        itemStatusObservation?.invalidate()
        timeControlObservation?.invalidate()
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setVisualizerActive(_ enabled: Bool) {
        onMain { [weak self] in
            guard let self = self, enabled != (self.visualizerTimer != nil) else { return }
            if enabled {
                let timer = Timer(timeInterval: 1.0 / 16, repeats: true) { [weak self] _ in self?.publishVisualizerLevels() }
                self.visualizerTimer = timer
                RunLoop.main.add(timer, forMode: .common)
                self.lastLevels = []
            } else {
                self.visualizerTimer?.invalidate()
                self.visualizerTimer = nil
            }
            self.configureAudioProcessing()
            self.publishVisualizerLevels()
        }
    }

    func setEqualizer(_ settings: PlaybackEQSettings) {
        onMain { [weak self] in
            guard let self = self, settings != self.equalizerSettings else { return }
            self.equalizerSettings = settings
            self.configureAudioProcessing()
        }
    }

    private func configureAudioProcessing() {
        let wantsLevels = visualizerTimer != nil
        guard wantsLevels || !equalizerSettings.isFlat else { detachAudioProcessing(); return }
        if let analysis = audioAnalysis {
            analysis.configure(settings: equalizerSettings, levels: wantsLevels)
            return
        }
        guard let item = player.currentItem else { return }
        let analysis = AudioAnalysis()
        audioAnalysis = analysis
        analysis.configure(settings: equalizerSettings, levels: wantsLevels)
        let asset = item.asset
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self, weak item, weak analysis] in
            DispatchQueue.main.async {
                guard let self = self, let analysis = analysis, let item = item,
                      self.player.currentItem === item, self.audioAnalysis === analysis else { return }
                guard asset.statusOfValue(forKey: "tracks", error: nil) == .loaded else {
                    self.emitEqualizerAvailability(false)
                    return
                }
                let selected = item.tracks.first { $0.isEnabled && $0.assetTrack?.mediaType == .audio }?.assetTrack
                guard let track = selected ?? asset.tracks(withMediaType: .audio).first,
                      let mix = analysis.mix(for: track) else {
                    self.emitEqualizerAvailability(false)
                    return
                }
                item.audioMix = mix
            }
        }
    }

    private func detachAudioProcessing() {
        guard audioAnalysis != nil else { return }
        audioAnalysis = nil
        player.currentItem?.audioMix = nil
        analysisPlayingSince = nil
        emitEqualizerAvailability(nil)
        publishVisualizerLevels()
    }

    private func emitEqualizerAvailability(_ value: Bool?) {
        guard value != equalizerAvailability else { return }
        equalizerAvailability = value
        onEqualizerAvailability?(value)
    }

    private func publishVisualizerLevels() {
        let levels: [Double]
        if visualizerTimer != nil, player.timeControlStatus == .playing, userWantsPlayback, let analysis = audioAnalysis {
            levels = analysis.levels(at: player.currentTime().seconds)
        } else {
            levels = [0, 0, 0]
        }
        guard levels != lastLevels else { return }
        lastLevels = levels
        onVisualizerLevels?(levels)
    }

    func loadLiveSource(showID: Int, sourceID: Int, date: String, version: Int,
                        venue: String, versionLabel: String, startTrack: Int = 0,
                        autoplay: Bool = true) {
        onMain { [weak self] in
            guard let self = self else { return }
            self.cancelRetry()
            self.player.pause()
            self.clearItemObservers()
            self.player.replaceCurrentItem(with: nil)
            self.tracks = []
            self.index = 0
            self.showID = showID
            self.sourceID = sourceID
            self.date = date
            self.venue = venue
            self.versionLabel = versionLabel
            self.collectionLabel = ""
            self.status = "loading"
            self.message = "Loading tracks from the Tool Drive Project…"
            self.userWantsPlayback = autoplay
            self.emitTracks()
            self.emitState()
            self.media.resolveTracks(showID: showID, sourceID: sourceID, date: date, version: version) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let tracks):
                    self.tracks = tracks
                    self.index = min(max(startTrack, 0), tracks.count - 1)
                    self.retryCount = 0
                    self.message = ""
                    self.emitTracks()
                    self.loadCurrentTrack(autoplay: autoplay)
                case .failure:
                    self.fail("Streaming playback could not be loaded. Try again.")
                }
            }
        }
    }

    func loadLocalFiles(_ urls: [URL], collection: String = "Local audio",
                        startTrack: Int = 0, autoplay: Bool = false) {
        onMain { [weak self] in
            guard let self = self else { return }
            do {
                self.loadPreparedTracks(try Self.localTracks(urls), collection: collection,
                                        startTrack: startTrack, autoplay: autoplay)
            } catch {
                self.fail("The selected audio files could not be loaded.")
            }
        }
    }

    func loadTracks(_ supplied: [LiveTrack], collection: String = "Local audio",
                    startTrack: Int = 0, autoplay: Bool = false) {
        onMain { [weak self] in
            guard let self = self else { return }
            do {
                self.loadPreparedTracks(try Self.validatedLocalTracks(supplied), collection: collection,
                                        startTrack: startTrack, autoplay: autoplay)
            } catch {
                self.fail("The selected audio files could not be loaded.")
            }
        }
    }

    // PlexSearchResult is sealed by PlexService: web content cannot construct it or supply a URL.
    func loadPlexResult(_ result: PlexSearchResult, startTrack: Int = 0, autoplay: Bool = true) {
        result.withNativePlaybackTracks { [weak self] tracks in
            self?.loadRemoteTracks(tracks, collection: result.collection,
                                   startTrack: startTrack, autoplay: autoplay)
        }
    }

    // Native-only bridge for PlexService results. WebKit never supplies these URLs.
    func loadRemoteTracks(_ supplied: [LiveTrack], collection: String,
                          startTrack: Int = 0, autoplay: Bool = true) {
        onMain { [weak self] in
            guard let self = self else { return }
            do {
                let tracks = try PlexParser.validatedPlaybackTracks(supplied)
                self.loadPreparedTracks(tracks, collection: collection,
                                        startTrack: startTrack, autoplay: autoplay)
            } catch {
                self.fail("The Plex recording could not be opened.")
            }
        }
    }

    static func localTracks(_ urls: [URL]) throws -> [LiveTrack] {
        guard !urls.isEmpty, urls.count <= 500 else {
            throw UpdateError("Choose between 1 and 500 audio files.")
        }
        let provisional = urls.enumerated().map { offset, supplied in
            let url = supplied.standardizedFileURL.resolvingSymlinksInPath()
            let title = url.deletingPathExtension().lastPathComponent
            return LiveTrack(number: offset + 1, title: title.isEmpty ? "Track \(offset + 1)" : title,
                             duration: nil, url: url)
        }
        return try validatedLocalTracks(provisional)
    }

    static func validatedLocalTracks(_ supplied: [LiveTrack]) throws -> [LiveTrack] {
        guard !supplied.isEmpty, supplied.count <= 500 else {
            throw UpdateError("Choose between 1 and 500 audio files.")
        }
        var numbers = Set<Int>()
        return try supplied.map { track in
            guard track.number > 0, numbers.insert(track.number).inserted else {
                throw UpdateError("The library contains a duplicate or invalid track number.")
            }
            guard track.url.isFileURL else { throw UpdateError("Only local audio files can be added to the library.") }
            let url = track.url.standardizedFileURL.resolvingSymlinksInPath()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable != false else {
                throw UpdateError("An audio file is missing or unreadable: \(url.lastPathComponent)")
            }
            let ext = url.pathExtension.lowercased()
            guard supportedLocalExtensions.contains(ext) else {
                throw UpdateError("Unsupported audio format: .\(ext.isEmpty ? "unknown" : ext). Choose FLAC, ALAC, WAV, AIFF, MP3, AAC, M4A, MP4, or CAF.")
            }
            let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 300 else { throw UpdateError("A library track title is missing or too long.") }
            guard track.duration == nil || (track.duration!.isFinite && track.duration! >= 0 && track.duration! <= 24 * 60 * 60) else {
                throw UpdateError("A library track duration is invalid.")
            }
            return LiveTrack(number: track.number, title: title, duration: track.duration, url: url)
        }
    }

    func selectTrack(_ requestedIndex: Int) {
        onMain { [weak self] in
            guard let self = self, self.tracks.indices.contains(requestedIndex) else { return }
            self.index = requestedIndex
            self.retryCount = 0
            self.loadCurrentTrack(autoplay: true)
        }
    }

    func play() {
        onMain { [weak self] in
            guard let self = self, !self.tracks.isEmpty else { return }
            self.userWantsPlayback = true
            if Self.requiresFreshItemForPlay(status: self.status,
                                             itemFailed: self.player.currentItem?.status == .failed) {
                self.retryCount = 0
                self.loadCurrentTrack(autoplay: true)
            }
            else { self.player.play() }
        }
    }

    static func requiresFreshItemForPlay(status: String, itemFailed: Bool) -> Bool {
        status == "finished" || itemFailed
    }

    static func safePlaybackFailureMessage(_ error: Error?) -> String {
        _ = error
        return "Playback failed. Press Play to retry."
    }

    func pause() {
        onMain { [weak self] in
            self?.userWantsPlayback = false
            self?.cancelRetry()
            self?.player.pause()
            self?.emitState()
        }
    }

    func toggle() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.player.timeControlStatus == .playing ? self.pause() : self.play()
        }
    }

    func next() { onMain { [weak self] in self?.advance(autoplay: true) } }

    func previous() {
        onMain { [weak self] in
            guard let self = self, !self.tracks.isEmpty else { return }
            let elapsed = Self.seconds(self.player.currentTime()) ?? 0
            if elapsed >= 2.5 || self.index == 0 { self.seek(to: 0) }
            else {
                self.index -= 1
                self.retryCount = 0
                self.loadCurrentTrack(autoplay: true)
            }
        }
    }

    func seek(to seconds: Double) {
        onMain { [weak self] in
            guard let self = self, seconds.isFinite else { return }
            let duration = Self.seconds(self.player.currentItem?.duration)
            let target = max(0, duration.map { min(seconds, $0) } ?? seconds)
            self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                DispatchQueue.main.async { self.emitState(); self.updateNowPlaying() }
            }
        }
    }

    func stop() {
        onMain { [weak self] in
            guard let self = self else { return }
            self.media.cancelTrackResolution()
            self.cancelRetry()
            self.userWantsPlayback = false
            self.clearItemObservers()
            self.player.pause()
            self.player.replaceCurrentItem(with: nil)
            self.tracks = []
            self.index = 0
            self.showID = nil
            self.sourceID = nil
            self.status = "idle"
            self.message = ""
            self.emitTracks()
            self.emitState()
            self.updateNowPlaying()
        }
    }

    private func loadPreparedTracks(_ preparedTracks: [LiveTrack], collection: String,
                                    startTrack: Int, autoplay: Bool) {
        media.cancelTrackResolution()
        cancelRetry()
        player.pause()
        tracks = preparedTracks
        index = min(max(startTrack, 0), preparedTracks.count - 1)
        showID = nil
        sourceID = nil
        date = ""
        venue = ""
        versionLabel = ""
        collectionLabel = collection
        retryCount = 0
        message = ""
        userWantsPlayback = autoplay
        emitTracks()
        loadCurrentTrack(autoplay: autoplay)
    }

    private func loadCurrentTrack(autoplay: Bool) {
        guard tracks.indices.contains(index) else { fail("The selected track is unavailable."); return }
        cancelRetry()
        clearItemObservers()
        let item = AVPlayerItem(url: tracks[index].url)
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self = self, self.player.currentItem === item else { return }
                if item?.status == .failed { self.handlePlaybackFailure(item?.error) }
                else { self.emitState() }
            }
        }
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self, weak item] _ in
            guard let self = self, self.player.currentItem === item else { return }
            self.advance(autoplay: true)
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in self?.handlePlaybackFailure(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) })
        player.replaceCurrentItem(with: item)
        configureAudioProcessing()
        status = autoplay ? "buffering" : "ready"
        userWantsPlayback = autoplay
        lastNowPlayingSecond = -1
        emitState()
        updateNowPlaying()
        updateRemoteAvailability()
        if autoplay { player.play() }
    }

    private func advance(autoplay: Bool) {
        guard !tracks.isEmpty else { return }
        guard index + 1 < tracks.count else {
            userWantsPlayback = false
            player.pause()
            status = "finished"
            emitState()
            updateNowPlaying()
            return
        }
        index += 1
        retryCount = 0
        loadCurrentTrack(autoplay: autoplay)
    }

    private func playerStatusChanged() {
        guard !tracks.isEmpty else { return }
        switch player.timeControlStatus {
        case .playing:
            status = "playing"
            message = ""
            if healthySince == nil { healthySince = Date() }
        case .waitingToPlayAtSpecifiedRate:
            status = "buffering"
        case .paused:
            if status != "failed" && status != "finished" { status = player.currentItem == nil ? "idle" : "paused" }
            healthySince = nil
        @unknown default:
            status = "paused"
        }
        emitState()
        updateNowPlaying()
    }

    private func periodicUpdate() {
        if let analysis = audioAnalysis {
            if let available = analysis.equalizerAvailable {
                emitEqualizerAvailability(available)
            } else if player.timeControlStatus == .playing {
                let now = ProcessInfo.processInfo.systemUptime
                if let since = analysisPlayingSince {
                    if now - since >= 2 { emitEqualizerAvailability(false) }
                } else { analysisPlayingSince = now }
            } else { analysisPlayingSince = nil }
        }
        if let healthy = healthySince, Date().timeIntervalSince(healthy) >= 5 {
            retryCount = 0
            healthySince = nil
        }
        emitState()
        let second = Int(Self.seconds(player.currentTime()) ?? 0)
        if second != lastNowPlayingSecond { lastNowPlayingSecond = second; updateNowPlaying() }
    }

    private func handlePlaybackFailure(_ error: Error?) {
        guard userWantsPlayback else { return }
        healthySince = nil
        guard retryCount < 2 else {
            fail(Self.safePlaybackFailureMessage(error))
            return
        }
        retryCount += 1
        status = "buffering"
        message = "Retrying playback…"
        emitState()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.userWantsPlayback else { return }
            self.loadCurrentTrack(autoplay: true)
        }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount), execute: work)
    }

    private func fail(_ text: String) {
        userWantsPlayback = false
        cancelRetry()
        player.pause()
        status = "failed"
        message = text
        emitState()
        updateNowPlaying()
    }

    private func clearItemObservers() {
        detachAudioProcessing()
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers = []
    }

    private func cancelRetry() { retryWork?.cancel(); retryWork = nil }

    private func emitTracks() {
        var event: [String: Any] = ["kind": "tracks", "tracks": tracks.map(\.summary)]
        if let showID = showID { event["showID"] = showID }
        if let sourceID = sourceID { event["sourceID"] = sourceID }
        onTrackListChange?(event)
    }

    private func emitState() {
        let elapsed = Self.seconds(player.currentTime()) ?? 0
        let measured = Self.seconds(player.currentItem?.duration)
        let declared = tracks.indices.contains(index) ? tracks[index].duration : nil
        let durationValue: Any = (measured ?? declared).map { $0 as Any } ?? NSNull()
        var event: [String: Any] = [
            "kind": "state", "status": status, "message": message,
            "playing": player.timeControlStatus == .playing,
            "trackIndex": tracks.isEmpty ? NSNull() : index,
            "trackCount": tracks.count, "elapsed": elapsed,
            "duration": durationValue,
            "canPrevious": !tracks.isEmpty, "canNext": index + 1 < tracks.count
        ]
        if tracks.indices.contains(index) {
            event["trackNumber"] = tracks[index].number
            event["title"] = tracks[index].title
        }
        if let showID = showID { event["showID"] = showID }
        if let sourceID = sourceID { event["sourceID"] = sourceID }
        onStateChange?(event)
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        addRemote(center.playCommand) { [weak self] _ in self?.play(); return .success }
        addRemote(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        addRemote(center.togglePlayPauseCommand) { [weak self] _ in self?.toggle(); return .success }
        addRemote(center.nextTrackCommand) { [weak self] _ in self?.next(); return .success }
        addRemote(center.previousTrackCommand) { [weak self] _ in self?.previous(); return .success }
        addRemote(center.changePlaybackPositionCommand) { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: position.positionTime)
            return .success
        }
        updateRemoteAvailability()
    }

    private func addRemote(_ command: MPRemoteCommand, _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        remoteTargets.append((command, command.addTarget(handler: handler)))
    }

    private func updateRemoteAvailability() {
        let center = MPRemoteCommandCenter.shared()
        let loaded = !tracks.isEmpty
        center.playCommand.isEnabled = loaded
        center.pauseCommand.isEnabled = loaded
        center.togglePlayPauseCommand.isEnabled = loaded
        center.previousTrackCommand.isEnabled = loaded
        center.nextTrackCommand.isEnabled = index + 1 < tracks.count
        center.changePlaybackPositionCommand.isEnabled = loaded
    }

    private func updateNowPlaying() {
        guard tracks.indices.contains(index) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            updateRemoteAvailability()
            return
        }
        let elapsed = Self.seconds(player.currentTime()) ?? 0
        let measured = Self.seconds(player.currentItem?.duration)
        let duration = measured ?? tracks[index].duration
        let album = collectionLabel.isEmpty
            ? [date, venue, versionLabel].filter { !$0.isEmpty }.joined(separator: " · ")
            : collectionLabel
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tracks[index].title,
            MPMediaItemPropertyArtist: "Tool",
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.timeControlStatus == .playing ? 1.0 : 0.0
        ]
        if let duration = duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = player.timeControlStatus == .playing ? .playing : .paused
        updateRemoteAvailability()
    }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private static func seconds(_ time: CMTime?) -> Double? {
        guard let time = time else { return nil }
        let value = time.seconds
        return value.isFinite && value >= 0 ? value : nil
    }
}
