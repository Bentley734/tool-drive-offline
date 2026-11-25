import SwiftUI

@MainActor
final class TVLibraryTransfers: ObservableObject {
    @Published private(set) var preparing: Int?
    @Published private(set) var lastSource: Int?
    @Published private(set) var message: String?
    private let resolver = LiveMediaService()
    private var request = UUID()

    static func key(_ show: Concert, _ source: RecordingSource) -> String {
        "archive-\(show.id)-\(source.id)"
    }

    func save(show: Concert, source: RecordingSource, to library: MobileLibrary) {
        guard let version = source.streamVersion, preparing == nil, library.activity == nil else { return }
        let token = UUID()
        request = token
        preparing = source.id
        lastSource = source.id
        message = nil
        resolver.resolveTracks(showID: show.id, sourceID: source.id, date: show.date, version: version) { [weak self] result in
            Task { @MainActor in
                guard let self, self.request == token else { return }
                self.preparing = nil
                switch result {
                case .success(let tracks):
                    library.download(tracks: tracks, title: show.venue.isEmpty ? show.date : show.venue,
                                     context: [show.date, show.location, source.version].filter { !$0.isEmpty }.joined(separator: " · "),
                                     key: Self.key(show, source))
                case .failure:
                    self.message = "The tracks could not be loaded. Check your connection and try again."
                }
            }
        }
    }

    func cancel() {
        request = UUID()
        resolver.cancelTrackResolution()
        preparing = nil
        message = "Transfer canceled."
    }
}

struct TVLibraryView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var downloads: TVLibraryTransfers
    @State private var pendingDeletion: LibraryRecord?
    @State private var unavailable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Library").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text("Saved recordings play offline. Apple TV can reclaim this space when storage runs low.")
                    .font(.callout).foregroundStyle(archive.theme.muted)

                if downloads.preparing != nil || library.activity != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        if let title = library.activity {
                            Text("Saving “\(title)”").font(.headline)
                            ProgressView(value: library.progress).accessibilityLabel("Saving tracks")
                        } else { ProgressView("Finding tracks") }
                        Button("Cancel transfer", role: .cancel) {
                            if downloads.preparing != nil { downloads.cancel() } else { library.cancel() }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(22).archivePanel()
                }
                if let status = downloads.message ?? (library.message.isEmpty ? nil : library.message) {
                    Text(status).font(.callout).foregroundStyle(archive.theme.muted)
                }

                Text("On this Apple TV").font(.title3.bold())
                if library.records.isEmpty {
                    Text("Choose Save stream offline on a recording to add it here.")
                        .font(.callout).foregroundStyle(archive.theme.muted)
                }
                ForEach(library.records) { record in
                    HStack(spacing: 22) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.title).font(.headline)
                            Text(record.context).foregroundStyle(archive.theme.muted)
                            Text("\(record.tracks.count) \(record.tracks.count == 1 ? "track" : "tracks")")
                                .font(.caption).foregroundStyle(archive.theme.muted)
                        }
                        Spacer()
                        Button { play(record) } label: { Label("Play", systemImage: "play.fill") }
                            .accessibilityLabel("Play " + record.title)
                        Button(role: .destructive) { pendingDeletion = record } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Delete " + record.title)
                    }
                    .padding(22).archivePanel()
                }
                Text("Offline catalog").font(.title3.bold())
                HStack(spacing: 20) {
                    Text("\(archive.shows.count.formatted()) shows · \(archive.snapshotDate)").font(.callout)
                    if archive.updating {
                        ProgressView().accessibilityLabel("Refreshing catalog")
                        Button("Cancel refresh") { archive.cancelUpdate() }
                    } else {
                        Button("Refresh catalog") { Task { await archive.refresh() } }
                            .disabled(archive.shows.isEmpty)
                    }
                }
                if !archive.updateMessage.isEmpty { Text(archive.updateMessage).font(.callout) }
            }
            .padding(32)
            .frame(maxWidth: 1450, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .confirmationDialog("Delete this recording from your Apple TV?", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { record in
            Button("Delete recording", role: .destructive) { library.delete(record) }
            Button("Keep recording", role: .cancel) {}
        }
        .alert("Recording is no longer on this Apple TV", isPresented: $unavailable) {
            Button("OK") {}
        } message: { Text("Open the original show and choose Save stream offline to download it again.") }
    }

    private func play(_ record: LibraryRecord) {
        let tracks = library.playable(record)
        guard !tracks.isEmpty, tracks.allSatisfy({ FileManager.default.isReadableFile(atPath: $0.url.path) }) else {
            library.delete(record)
            unavailable = true
            return
        }
        player.play(tracks: tracks, title: record.title, context: record.context, startIndex: 0, expandPlayer: true)
    }
}
