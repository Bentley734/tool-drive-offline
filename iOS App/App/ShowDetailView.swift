import SafariServices
import SwiftUI

struct ShowDetailView: View {
    let show: Concert
    @Environment(\.mobileTheme) private var theme
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @StateObject private var actions = RecordingActions()
    @State private var plexRequest: PlexRequest?
    @State private var copiedSource: Int?
    @State private var showingSetlist = true

    private var saved: Bool { archive.savedIDs.contains(show.id) }
    private var shareText: String { ["TOOL", show.date, show.venue, show.location].filter { !$0.isEmpty }.joined(separator: " · ") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(show.dateLabel).font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent)
                    Text(show.venue.isEmpty ? "Unknown venue" : show.venue)
                        .font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    if !show.location.isEmpty {
                        Label(show.location, systemImage: "mappin.and.ellipse").font(.callout).foregroundStyle(theme.muted)
                    }
                    let tour = [show.tour, show.festival].filter(informative).joined(separator: " · ")
                    if !tour.isEmpty { Text(tour).font(.subheadline).foregroundStyle(theme.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .archivePanel()
                VStack(alignment: .leading, spacing: 12) {
                    Text("Recordings").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if show.sources.isEmpty { Text("No recording sources are listed.").foregroundStyle(.secondary) }
                    ForEach(show.sources, id: \.id) { source in recording(source) }
                }
                if !show.setlist.isEmpty || show.setlistOmitted > 0 {
                    DisclosureGroup(isExpanded: $showingSetlist) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(show.setlist.enumerated()), id: \.offset) { offset, entry in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(String(format: "%02d", offset + 1))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24)
                                    Text(entry.title)
                                    Spacer()
                                }.padding(.vertical, 9)
                                Divider()
                            }
                            if show.setlistOmitted > 0 {
                                Text("\(show.setlistOmitted) additional setlist entries omitted in the archive snapshot.")
                                    .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                            }
                        }.padding(.top, 6)
                    } label: { Text("Setlist").font(.title2.bold()).foregroundStyle(.primary) }
                    .padding(16)
                    .archivePanel()
                }
            }
            .padding(20).frame(maxWidth: 700, alignment: .leading).frame(maxWidth: .infinity)
        }
        .archivePage(wallpaperID: archive.wallpaperID, sharesWindow: true)
        .navigationTitle("Show details").navigationBarTitleDisplayMode(.inline)
        .onChange(of: show.id) { _, _ in
            actions.reset()
            plexRequest = nil
            copiedSource = nil
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { archive.toggleSaved(show.id) } label: { Image(systemName: saved ? "bookmark.fill" : "bookmark") }
                    .accessibilityLabel(saved ? "Remove saved show" : "Save show")
                ShareLink(item: shareText)
            }
        }
        .sheet(item: $actions.originalFolder) { folder in SourceBrowser(url: folder.url).ignoresSafeArea() }
        .sheet(item: $plexRequest) { request in PlexView(initialDate: show.date, version: request.version) }
    }

    private func informative(_ value: String) -> Bool {
        !["", "unknown", "—", "n/a"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func recording(_ source: RecordingSource) -> some View {
        let kind = informative(source.recordingType) ? source.recordingType.capitalized : "Recording"
        let summary = [source.codec.uppercased(), source.lossless.capitalized, source.length].filter(informative)
        let version = Int(source.version.dropFirst(2))
        let folder = version.map { "tool\(show.date).v\($0)" } ?? "tool\(show.date)"
        let active = player.sourceID == source.id && player.isVisible
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text([source.version, kind].filter(informative).joined(separator: " · ")).font(.headline)
                    Text(([source.status == "OTD" ? "On the drive" : source.status] + summary).filter(informative)
                            .joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let rating = source.rating {
                    Label(rating.formatted(.number.precision(.fractionLength(0...1))), systemImage: "star.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(theme.accent).accessibilityLabel("Rating \(rating) out of 10")
                }
            }
            HStack(spacing: 8) {
                if source.streamVersion != nil {
                    Button { player.stream(show: show, source: source) } label: {
                        Label(active ? "Open player" : "Stream", systemImage: active ? "waveform" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(theme.ink)
                }
                Menu {
                    if source.streamVersion != nil {
                        Button("Save stream offline", systemImage: "arrow.down.circle") {
                            actions.saveStream(show: show, source: source, library: library)
                        }
                        .disabled(actions.preparingSource != nil)
                    }
                    Button("Open original files", systemImage: "folder") { actions.openOriginal(showID: show.id, sourceID: source.id) }
                    Button("Find on Plex", systemImage: "server.rack") { plexRequest = PlexRequest(id: source.id, version: version) }
                    Button("Copy folder name", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = folder
                        copiedSource = source.id
                        UIAccessibility.post(notification: .announcement, argument: "Folder name copied")
                    }
                    ShareLink(item: shareText + "\n" + folder) { Label("Share recording", systemImage: "square.and.arrow.up") }
                } label: { Label("Source", systemImage: "ellipsis.circle") }
                .buttonStyle(.bordered)
            }
            if actions.preparingSource == source.id || actions.findingSource == source.id {
                ProgressView(actions.preparingSource == source.id ? "Preparing offline tracks…" : "Finding original files…").font(.caption)
            }
            if let message = actions.messages[source.id] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if copiedSource == source.id {
                Text("Copied \(folder)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            let metadata = [("Taper", source.taper), ("Equipment", source.gear),
                            ("Generation", source.generation), ("Lineage", source.lineage)].filter { informative($0.1) }
            if !metadata.isEmpty {
                DisclosureGroup("Recording notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(metadata, id: \.0) { key, value in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                Text(value).font(.subheadline).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                }.font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .archivePanel()
    }
}

private struct PlexRequest: Identifiable { let id: Int; let version: Int? }
private struct OriginalFolder: Identifiable { let url: URL; var id: URL { url } }

@MainActor
private final class RecordingActions: ObservableObject {
    private let media = LiveMediaService()
    @Published var originalFolder: OriginalFolder?
    @Published var findingSource: Int?
    @Published var preparingSource: Int?
    @Published var messages = [Int: String]()

    deinit { media.cancelAll() }

    func reset() {
        media.cancelAll()
        findingSource = nil
        preparingSource = nil
        originalFolder = nil
        messages.removeAll()
    }

    func openOriginal(showID: Int, sourceID: Int) {
        findingSource = sourceID
        messages[sourceID] = nil
        media.loadDownloadLinks { [weak self] result in
            Task { @MainActor in
                guard let self, self.findingSource == sourceID else { return }
                self.findingSource = nil
                switch result {
                case .success(let links):
                    if let url = links[showID]?[sourceID] { self.originalFolder = OriginalFolder(url: url) }
                    else { self.messages[sourceID] = "The archive has no original download link for this source." }
                case .failure:
                    self.messages[sourceID] = "Couldn’t check the archive. Try Open original files again when connected."
                }
            }
        }
    }

    func saveStream(show: Concert, source: RecordingSource, library: MobileLibrary) {
        guard let version = source.streamVersion, preparingSource == nil else { return }
        preparingSource = source.id
        messages[source.id] = nil
        // Finish a requested download even when its show has left the screen.
        Task { [weak self] in
            let resolver = LiveMediaService()
            defer { resolver.cancelAll() }
            let result = await withCheckedContinuation { continuation in
                resolver.resolveTracks(showID: show.id, sourceID: source.id, date: show.date, version: version) {
                    continuation.resume(returning: $0)
                }
            }
            let message: String
            switch result {
            case .success(let tracks):
                library.download(tracks: tracks, title: show.venue.isEmpty ? show.date : show.venue,
                                 context: [show.date, show.location, source.version].filter { !$0.isEmpty }.joined(separator: " · "),
                                 key: "archive-\(show.id)-\(source.id)")
                message = "Check Library for download progress."
            case .failure:
                message = "The archive couldn’t provide tracks for this recording. Try again when connected."
            }
            guard let self, self.preparingSource == source.id else { return }
            self.preparingSource = nil
            self.messages[source.id] = message
        }
    }
}

private struct SourceBrowser: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.mobileTheme) private var theme
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        controller.preferredBarTintColor = UIColor(theme.panel)
        controller.preferredControlTintColor = UIColor(theme.accent)
    }
}
