import SwiftUI

@main
struct TVArchiveApp: App {
    @StateObject private var archive = ArchiveStore()
    @StateObject private var player = AudioPlayer()
    @StateObject private var library = MobileLibrary(directory: URL.cachesDirectory.appending(path: "Recordings", directoryHint: .isDirectory))
    @StateObject private var downloads = TVLibraryTransfers()

    var body: some Scene {
        WindowGroup {
            TVCatalogView()
                .environmentObject(archive)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(downloads)
                .environment(\.mobileTheme, archive.theme)
                .environment(\.mobileGlassControls, archive.glassEnabled)
                .tint(archive.theme.accent)
                .preferredColorScheme(.dark)
                .task { await archive.load() }
        }
    }
}

private enum TVRoute: Hashable { case show(Int), library }

private struct TVCatalogView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @State private var query = ""
    @State private var savedOnly = false
    @State private var filters = CatalogFilters()
    @State private var sort: CatalogSort = .highest
    @State private var path: [TVRoute] = []
    @State private var showingFilters = false
    @State private var showingAppearance = false

    var body: some View {
        let matches = filters.matches(archive.shows, query: query, savedOnly: savedOnly, savedIDs: archive.savedIDs, sort: sort)
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 60) {
                    VStack(alignment: .leading, spacing: 24) {
                        TVArtworkHeader(title: catalogTitle, subtitle: "\(archive.shows.count.formatted()) documented shows",
                                        count: archive.shows.count)
                            .frame(height: min(330, geometry.size.height * 0.34))

                        TextField("Search venues, songs or dates", text: $query)
                            .accessibilityLabel("Search shows")
                            .accessibilityIdentifier("tv.search")

                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 16) {
                                Button {
                                    savedOnly.toggle()
                                } label: {
                                    Label(savedOnly ? "All shows" : "Saved", systemImage: savedOnly ? "list.bullet" : "bookmark")
                                }
                                Button { showingFilters = true } label: { Label("Filters", systemImage: "line.3.horizontal.decrease") }
                            }
                            HStack(spacing: 16) {
                                Button {
                                    if let show = matches.randomElement() { path.append(.show(show.id)) }
                                } label: { Label("Pick a show", systemImage: "shuffle") }
                                .disabled(matches.isEmpty)
                                Button { showingAppearance = true } label: { Label("Appearance", systemImage: "paintpalette") }
                                    .accessibilityIdentifier("tv.appearance")
                            }
                            HStack(spacing: 16) {
                                Button { path.append(.library) } label: { Label("Library", systemImage: "books.vertical") }
                                    .accessibilityIdentifier("tv.library")
                                if player.isVisible {
                                    Button { player.isExpanded = true } label: { Label("Now Playing", systemImage: "waveform") }
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .labelStyle(TVShelfLabelStyle(ink: archive.theme.ink))
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .archiveControl()
                        Spacer(minLength: 0)
                    }
                    .frame(width: min(625, geometry.size.width * 0.38), alignment: .leading)
                    .focusSection()

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(savedOnly ? "Saved shows" : "Shows").font(.title.bold()).accessibilityIdentifier("tv.catalog")
                            Spacer()
                            Text(matches.count.formatted()).font(.headline.monospacedDigit()).foregroundStyle(archive.theme.accent)
                        }
                        if archive.isLoading && archive.shows.isEmpty {
                            ProgressView("Loading the archive")
                        } else if let error = archive.loadError, archive.shows.isEmpty {
                            Text(error).foregroundStyle(archive.theme.muted)
                        } else if matches.isEmpty {
                            Text(savedOnly ? "Bookmark a show to find it here, or adjust your filters." : "No matching shows. Try a different search or filter.")
                                .foregroundStyle(archive.theme.muted)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 16) {
                                    ForEach(matches) { match in
                                        Button { path.append(.show(match.id)) } label: {
                                            TVShowRow(match: match, saved: archive.savedIDs.contains(match.id))
                                        }
                                        .buttonStyle(.card)
                                        .accessibilityIdentifier("tv.show.\(match.id)")
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }.focusSection()
                }
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationDestination(for: TVRoute.self) { route in
                switch route {
                case .show(let id):
                    if let show = archive.shows.first(where: { $0.id == id }) { TVShowView(show: show) }
                case .library:
                    TVLibraryView()
                }
            }
            .fullScreenCover(isPresented: $showingAppearance) { TVAppearanceView() }
            .sheet(isPresented: $showingFilters) { TVFiltersView(filters: $filters, sort: $sort) }
        }
        .fullScreenCover(isPresented: $player.isExpanded) { TVPlayerView() }
    }

    private var catalogTitle: String {
        switch archive.theme {
        case .laserGrid: return "Signal index"
        case .nightShift: return "Live recording index"
        case .graphite: return "Find your next live listen."
        default: return "The live archive"
        }
    }
}

struct TVArtworkHeader: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.accessibilityReduceTransparency) private var solid
    let title: String
    let subtitle: String
    var count: Int? = nil

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if archive.theme != .liquidGlass || solid {
                ArchiveThemeArtwork(theme: archive.theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
            }
            LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.28), .black.opacity(0.91)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ArchiveBrandLogo(logo: archive.logo)
                        .foregroundStyle(.white)
                        .frame(width: 195, height: 52, alignment: .leading)
                    if archive.theme == .nightShift, let count {
                        Spacer()
                        ArchiveNumberDisplay(value: String(count))
                            .frame(height: 34)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(9)
                            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityHidden(true)
                    }
                }
                .padding(.bottom, 8)
                Text(title).font(.title.bold()).foregroundStyle(.white).lineLimit(2)
                Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            }
            .padding(28)
        }
        .clipShape(RoundedRectangle(cornerRadius: archive.theme.cornerRadius))
        .accessibilityElement(children: .combine)
    }
}

private struct TVShelfLabelStyle: LabelStyle {
    let ink: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
            configuration.title
        }
        .foregroundStyle(ink)
    }
}

private struct TVShowRow: View {
    @Environment(\.mobileTheme) private var theme
    let match: CatalogMatch
    let saved: Bool

    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text(match.show.dateLabel).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                Text(match.show.venue.isEmpty ? "Unknown venue" : match.show.venue)
                    .font(.headline).foregroundStyle(theme.text).lineLimit(1)
                Text(match.show.location).font(.callout).foregroundStyle(theme.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            if saved { Image(systemName: "bookmark.fill").foregroundStyle(theme.accent).accessibilityLabel("Saved") }
            if let score = match.rating {
                Label(score.formatted(.number.precision(.fractionLength(0...1))), systemImage: "star.fill")
                    .font(.caption).foregroundStyle(theme.muted)
                    .accessibilityLabel("Rating \(score.formatted()) out of ten")
            }
            Image(systemName: "chevron.right").foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .archivePanel()
        .accessibilityElement(children: .combine)
    }
}

struct TVActionStyle: PrimitiveButtonStyle {
    @Environment(\.mobileTheme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(theme.ink)
        }
        .buttonStyle(.borderedProminent)
    }
}

private struct TVShowView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var library: MobileLibrary
    @EnvironmentObject private var downloads: TVLibraryTransfers
    let show: Concert

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 58) {
                VStack(alignment: .leading, spacing: 26) {
                    TVArtworkHeader(title: show.venue.isEmpty ? "Unknown venue" : show.venue,
                                    subtitle: [show.dateLabel, show.location].filter { !$0.isEmpty }.joined(separator: " · "))
                        .frame(height: 330)
                    Button {
                        archive.toggleSaved(show.id)
                    } label: {
                        Label(archive.savedIDs.contains(show.id) ? "Remove saved show" : "Save show",
                              systemImage: archive.savedIDs.contains(show.id) ? "bookmark.fill" : "bookmark")
                    }
                    if !show.tour.isEmpty { Text(show.tour).font(.headline) }
                    if !show.setlist.isEmpty {
                        Text("Setlist").font(.title3.bold())
                        ForEach(Array(show.setlist.enumerated()), id: \.offset) { offset, item in
                            HStack(alignment: .firstTextBaseline, spacing: 22) {
                                Text(String(format: "%02d", offset + 1)).font(.caption.monospacedDigit()).foregroundStyle(archive.theme.muted)
                                Text(item.title)
                            }.focusable()
                        }
                        if show.setlistOmitted > 0 { Text("\(show.setlistOmitted) additional entries omitted").font(.caption) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()

                VStack(alignment: .leading, spacing: 24) {
                    Text("Recordings").font(.title.bold())
                    if show.sources.isEmpty { Text("No recording sources are listed.") }
                    ForEach(show.sources) { source in
                        VStack(alignment: .leading, spacing: 14) {
                            Text([source.version, source.recordingType.capitalized].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.headline)
                            Text([source.status == "OTD" ? "On the drive" : source.status, source.codec.uppercased(), source.length]
                                .filter { !$0.isEmpty }.joined(separator: " · ")).font(.callout).foregroundStyle(archive.theme.muted)
                            if let rating = source.rating { Text("Sound rating \(rating.formatted()) / 10").font(.caption) }
                            if !source.taper.isEmpty { Text("Taper · " + source.taper).font(.caption) }
                            if !source.gear.isEmpty { Text("Equipment · " + source.gear).font(.caption) }
                            if source.streamVersion != nil {
                                Button { player.stream(show: show, source: source) } label: {
                                    Label(player.isVisible && player.sourceID == source.id ? "Now Playing" : "Stream", systemImage: "play.fill")
                                }.accessibilityIdentifier("tv.stream.\(source.id)")
                                NavigationLink(value: TVRoute.library) {
                                    Label("Open library", systemImage: "books.vertical")
                                }
                                Button {
                                    downloads.save(show: show, source: source, to: library)
                                } label: {
                                    let saved = library.records.contains { $0.key == TVLibraryTransfers.key(show, source) }
                                    Label(saved ? "Saved offline" : "Save stream offline", systemImage: saved ? "checkmark.circle" : "arrow.down.circle")
                                }
                                .accessibilityIdentifier("tv.save.\(source.id)")
                                .disabled(downloads.preparing != nil || library.activity != nil ||
                                          library.records.contains { $0.key == TVLibraryTransfers.key(show, source) })
                                if downloads.preparing == source.id {
                                    ProgressView("Finding tracks")
                                } else if downloads.lastSource == source.id {
                                    Text(downloads.message ?? library.activity.map { "Saving “" + $0 + "” to Library." } ?? library.message)
                                        .font(.caption).foregroundStyle(archive.theme.muted)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(28).archivePanel()
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            }
            .padding(18)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
    }
}

private struct TVFiltersView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: CatalogFilters
    @Binding var sort: CatalogSort

    var body: some View {
        let years = Set(archive.shows.map(\.year).filter { $0 > 0 }).sorted()
        let types = Set(archive.shows.flatMap { $0.sources.map(\.recordingType) }.filter { !$0.isEmpty }).sorted()
        NavigationStack {
            Form {
                Section("Catalog") {
                    Picker("Sort", selection: $sort) { ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Status", selection: $filters.status) {
                        ForEach(CatalogFilters.statusOptions, id: \.0) { option in Text(option.1).tag(option.0) }
                    }
                    Picker("Recording type", selection: $filters.type) {
                        Text("All types").tag("all")
                        ForEach(types, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                Section("Sound quality") {
                    Picker("Rating availability", selection: $filters.rating) {
                        ForEach(CatalogFilters.Rating.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if filters.rating != .unrated {
                        Picker("Minimum rating", selection: $filters.minimum) {
                            Text("Any").tag(0)
                            ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                        }
                    }
                }
                Section("Show years") {
                    Picker("From", selection: $filters.firstYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.lastYear.map { year <= $0 } ?? true }, id: \.self) { Text(String($0)).tag(Optional($0)) }
                    }
                    Picker("Through", selection: $filters.lastYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.firstYear.map { year >= $0 } ?? true }, id: \.self) { Text(String($0)).tag(Optional($0)) }
                    }
                }
                Button("Clear filters") { filters = CatalogFilters(status: "all") }
                Button("Done") { dismiss() }
            }
            .navigationTitle("Filters")
            .archivePage(wallpaperID: archive.wallpaperID)
        }
    }
}
