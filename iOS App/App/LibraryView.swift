import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.mobileTheme) private var theme
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var audio: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var plex = false
    @State private var removing: LibraryRecord?
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { importing = true } label: { Label("Import audio from Files", systemImage: "folder.badge.plus") }
                        .disabled(library.activity != nil)
                    Button { plex = true } label: { Label("Plex music library", systemImage: "server.rack") }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("On this device") {
                    if let name = library.activity {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(name).font(.headline)
                            ProgressView(value: library.progress).accessibilityLabel("Saving tracks")
                            Button("Cancel transfer", role: .cancel) { library.cancel() }
                        }
                    }
                    if library.records.isEmpty && library.activity == nil {
                        Text("Import audio from Files, or open a recording in the catalog and save its stream here.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 5)
                    }
                    ForEach(library.records) { record in
                        HStack(spacing: 12) {
                            Button {
                                audio.play(tracks: library.playable(record), title: record.title, context: record.context, startIndex: 0)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(theme.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title).font(.headline)
                                        Text(record.context).font(.subheadline).foregroundStyle(.secondary)
                                        Text("\(record.tracks.count) \(record.tracks.count == 1 ? "track" : "tracks")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.borderless).accessibilityLabel("Play \(record.title)")
                            Menu {
                                Button("Delete from device", systemImage: "trash", role: .destructive) { removing = record }
                            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Options for \(record.title)")
                        }
                    }
                    if !library.message.isEmpty { Text(library.message).font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("Offline catalog") {
                    LabeledContent("Snapshot", value: archive.snapshotDate)
                    LabeledContent("Shows", value: archive.shows.count.formatted())
                    if archive.updating {
                        HStack { ProgressView(); Spacer(); Button("Cancel refresh") { archive.cancelUpdate() } }
                    } else {
                        Button("Refresh catalog", systemImage: "arrow.clockwise") { Task { await archive.refresh() } }
                            .disabled(archive.shows.isEmpty)
                    }
                    if !archive.updateMessage.isEmpty { Text(archive.updateMessage).font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowBackground(ArchiveRowBackground())
                Section {
                    Link("Tool Drive Project", destination: URL(string: "https://tooldriveproject.net")!)
                } footer: {
                    Text("Concert metadata and archive streams are provided by the Tool Drive Project. Recordings are shared for personal, noncommercial listening.")
                }
                .listRowBackground(ArchiveRowBackground())
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Library")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $plex) { PlexView() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let files): library.importFiles(files)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .alert("Import audio", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
            .confirmationDialog("Delete this recording from your device?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { item in
                Button("Delete “\(item.title)”", role: .destructive) { library.delete(item) }
                Button("Keep recording", role: .cancel) {}
            }
        }
    }
}
