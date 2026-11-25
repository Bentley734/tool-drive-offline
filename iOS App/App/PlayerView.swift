import AVKit
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.mobileTheme) private var theme

    var body: some View {
        if player.isVisible {
            HStack(spacing: 6) {
                Button {
                    player.isExpanded = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.tint)
                            .frame(width: 38, height: 38)
                            .background(theme.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: min(10, theme.cornerRadius)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.currentTrack?.title ?? player.collection).font(.subheadline.weight(.semibold))
                            Text(player.errorMessage ?? (player.currentTrack == nil ? "Finding recording…" : player.collection))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open player, " + (player.currentTrack?.title ?? player.collection))
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(!player.canToggle)
                Button { player.next() } label: {
                    Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Next track")
                .disabled(player.index + 1 >= player.tracks.count)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .archiveControl()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .accessibilityHidden(player.isExpanded)
            .sheet(isPresented: $player.isExpanded) {
                PlayerView().presentationDragIndicator(.visible)
            }
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.mobileTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var solid
    @State private var scrubValue: Double?
    @State private var showingVisualizer = false
    @State private var showingEqualizer = false
    @Environment(\.dismiss) private var dismiss

    private func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? max(0, Int(seconds)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
                             : String(format: "%d:%02d", value / 60, value % 60)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ZStack(alignment: .bottomLeading) {
                        if theme != .liquidGlass || solid {
                            ArchiveThemeArtwork(theme: theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
                                .accessibilityHidden(true)
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(player.collection).font(.title2.bold())
                            if !player.context.isEmpty {
                                Text(player.context).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
                            }
                        }.padding(16).foregroundStyle(.white)
                    }
                    .aspectRatio(2.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        if let track = player.currentTrack {
                            Text("Track \(player.index + 1) of \(player.tracks.count)").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                            Text(track.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
                        }
                        if player.phase == .resolving {
                            ProgressView("Finding recording…")
                        } else if let error = player.errorMessage {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                        } else if player.phase == .buffering {
                            Text("Buffering…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if player.currentTrack != nil {
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { min(player.duration, scrubValue ?? player.elapsed) },
                                                  set: { scrubValue = $0 }),
                                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                                if !editing, let target = scrubValue { player.seek(to: target); scrubValue = nil }
                            })
                            .disabled(player.duration <= 0)
                            .accessibilityLabel("Playback position")
                            .accessibilityValue(clock(scrubValue ?? player.elapsed))
                            HStack {
                                Text(clock(scrubValue ?? player.elapsed))
                                Spacer()
                                Text(player.duration > 0 ? clock(player.duration) : "—")
                            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 2) {
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 48, height: 48) }
                            .accessibilityLabel("Previous track").disabled(player.tracks.isEmpty)
                        Spacer()
                        Button { player.toggle() } label: {
                            Image(systemName: player.phase == .failed ? "arrow.clockwise" : (player.isPlaying ? "pause.fill" : "play.fill"))
                                .font(.system(size: 26, weight: .semibold)).frame(width: 64, height: 64)
                                .foregroundStyle(theme.ink).background(theme.accent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(player.phase == .failed ? "Retry playback" : (player.isPlaying ? "Pause" : "Play"))
                        .accessibilityIdentifier("player.transportToggle")
                        .disabled(!player.canToggle).opacity(player.canToggle ? 1 : 0.5)
                        Spacer()
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 48, height: 48) }
                            .accessibilityLabel("Next track").disabled(player.index + 1 >= player.tracks.count)
                    }
                    .font(.title2).foregroundStyle(theme.text)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .archiveControl()
                    if !player.tracks.isEmpty {
                        HStack(spacing: 10) {
                            Button("Equalizer", systemImage: "slider.horizontal.3") { showingEqualizer = true }
                            Button("Visualizer", systemImage: "waveform.path.ecg") { showingVisualizer = true }
                        }.buttonStyle(.bordered).controlSize(.regular)
                    }
                    if !player.tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Tracklist").font(.headline).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
                            ForEach(player.tracks) { track in
                                Button {
                                    player.selectTrack(track.id)
                                } label: {
                                    HStack(spacing: 12) {
                                        Group {
                                            if track.id == player.index { Image(systemName: "waveform") }
                                            else { Text(String(format: "%02d", track.id + 1)) }
                                        }
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26)
                                        Text(track.title).font(.body.weight(track.id == player.index ? .semibold : .regular))
                                        Spacer()
                                        if let duration = track.duration { Text(clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    }.frame(minHeight: 46).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(track.id == player.index ? theme.accent : theme.text)
                                .accessibilityAddTraits(track.id == player.index ? [.isSelected] : [])
                                Divider().opacity(0.6)
                            }
                        }
                        .padding(16)
                        .archivePanel()
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .onChange(of: player.index) { _, _ in scrubValue = nil }
            .sheet(isPresented: $showingEqualizer) { EqualizerPanel() }
            .sheet(isPresented: $showingVisualizer) { MobileVisualizerView() }
            .navigationTitle("Now Playing").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    AudioOutputPicker().frame(width: 36, height: 36).accessibilityLabel("Choose audio output")
                    Menu {
                        Button("Close player", systemImage: "stop.circle") { player.stop() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Playback options")
                }
            }
        }
    }
}

private struct EqualizerPanel: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    private let presets = [("Flat", 0.0, 0.0, 0.0), ("Bass Boost", 8, 0, 2),
                           ("Vocal", -3, 6, 1), ("Bright", -1, 1, 7)]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Menu("Tone preset") {
                        ForEach(presets, id: \.0) { name, bass, mid, treble in
                            Button(name) {
                                player.setEqualizer(PlaybackEQSettings(bass: bass, mid: mid, treble: treble, magik: player.equalizer.magik))
                            }
                        }
                    }
                    band("Bass", \.bass)
                    band("Mid", \.mid)
                    band("Treble", \.treble)
                    Toggle("Magik", isOn: Binding(get: { player.equalizer.magik }, set: {
                        var settings = player.equalizer
                        settings.magik = $0
                        player.setEqualizer(settings)
                    }))
                } footer: {
                    if player.equalizerAvailable == false {
                        Text("This track or audio output doesn’t support equalization.")
                    } else { Text("These settings apply to this recording.") }
                }
                .listRowBackground(ArchiveRowBackground())
                Button("Reset equalizer") { player.setEqualizer(.flat) }
                    .disabled(player.equalizer.isFlat)
                    .listRowBackground(ArchiveRowBackground())
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Equalizer").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large])
    }

    private func band(_ name: String, _ key: WritableKeyPath<PlaybackEQSettings, Double>) -> some View {
        VStack {
            HStack {
                Text(name)
                Spacer()
                Text(String(format: "%+.0f dB", player.equalizer[keyPath: key])).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { player.equalizer[keyPath: key] }, set: {
                var settings = player.equalizer
                settings[keyPath: key] = $0
                player.setEqualizer(settings)
            }), in: -10...10, step: 1).accessibilityLabel(name)
        }
    }
}

private struct AudioOutputPicker: UIViewRepresentable {
    @Environment(\.mobileTheme) private var theme
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    func updateUIView(_ picker: AVRoutePickerView, context: Context) {
        picker.tintColor = UIColor(theme.text)
        picker.activeTintColor = UIColor(theme.accent)
    }
}
