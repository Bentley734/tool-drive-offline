import SwiftUI

struct MobileVisualizerView: View {
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("visualizerPreset") private var preset = "tunnel"
    private let styles = [("tunnel", "Infinite Filigree"), ("ember", "Ember Bloom"), ("tidal", "Tidal Glass"), ("prism", "Prism Veil")]
    private var animating: Bool { player.phase == .playing && !reduceMotion && scene == .active }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VisualizerCanvas(preset: preset, animate: animating, player: player)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(player.currentTrack?.title ?? player.collection).font(.headline)
                        .multilineTextAlignment(.center).lineLimit(2)
                    HStack(spacing: 34) {
                        Button { player.previous() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Previous track").disabled(player.tracks.isEmpty)
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                        }.accessibilityLabel(player.isPlaying ? "Pause" : "Play").disabled(!player.canToggle)
                        Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("Next track").disabled(player.index + 1 >= player.tracks.count)
                    }.font(.title3)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: 580)
                .archiveControl()
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Visualizer").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("Visualizer", selection: $preset) {
                            ForEach(styles, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    } label: { Label("Choose visualizer", systemImage: "sparkles") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .onChange(of: animating, initial: true) { _, active in player.setVisualizerActive(active) }
        .onDisappear { player.setVisualizerActive(false) }
    }
}

private struct VisualizerCanvas: UIViewRepresentable {
    let preset: String
    let animate: Bool
    let player: AudioPlayer

    @MainActor
    final class Coordinator {
        var preset: String?
        var animate: Bool?
        var updates: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> TDVisualizerSurface { TDVisualizerSurface(frame: .zero) }

    func updateUIView(_ view: TDVisualizerSurface, context: Context) {
        let coordinator = context.coordinator
        guard preset != coordinator.preset || animate != coordinator.animate else { return }
        coordinator.preset = preset
        coordinator.animate = animate
        view.configurePreset(preset, animating: animate)
        coordinator.updates?.cancel()
        if animate {
            coordinator.updates = Task { [weak view, weak player] in
                while !Task.isCancelled {
                    guard let player, let view else { return }
                    view.updateBands(player.visualizerLevels().map(NSNumber.init(value:)))
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                }
            }
        }
    }

    static func dismantleUIView(_ view: TDVisualizerSurface, coordinator: Coordinator) {
        coordinator.updates?.cancel()
        view.invalidate()
    }
}
