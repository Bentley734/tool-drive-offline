import SwiftUI
import UIKit

struct CatalogView: View {
    @EnvironmentObject private var store: ArchiveStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var query = ""
    @State private var savedOnly = false
    @State private var filters = CatalogFilters()
    @State private var sort: CatalogSort = .highest
    @State private var selectedID: Int?
    @State private var phonePath: [Int] = []
    @State private var sidebarVisible = true
    @State private var sheet: CatalogSheet?

    private enum CatalogSheet: String, Identifiable {
        case filters, library, appearance
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            archive(width: geometry.size.width)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayerView() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .filters:
                CatalogFilterSheet(filters: $filters, years: Set(store.shows.map(\.year).filter { $0 > 0 }).sorted(),
                                   types: Set(store.shows.flatMap { $0.sources.map(\.recordingType) }.filter { !$0.isEmpty }).sorted())
            case .appearance: AppearanceView()
            case .library: LibraryView()
            }
        }
    }

    private func archive(width: CGFloat) -> some View {
        let split = UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular && width >= 720
        let matches = filters.matches(store.shows, query: query, savedOnly: savedOnly, savedIDs: store.savedIDs, sort: sort)
        let selected = matches.first { $0.id == selectedID } ?? matches.first
        return Group {
            if split {
                HStack(spacing: 0) {
                    if sidebarVisible {
                        NavigationStack {
                            catalog(matches, highlighted: selected?.id) { selectedID = $0.id }
                                .toolbar { ToolbarItem(placement: .topBarLeading) { sidebarToggle } }
                        }
                        .frame(width: min(450, max(310, (width / 3).rounded())))
                        Divider()
                    }
                    NavigationStack {
                        Group {
                            if let selected {
                                ShowDetailView(show: selected.show).id(selected.id)
                            } else if store.isLoading {
                                ProgressView("Loading archive")
                            } else {
                                ContentUnavailableView("No show selected", systemImage: "music.note.list")
                            }
                        }
                        .toolbar {
                            if !sidebarVisible {
                                ToolbarItem(placement: .topBarLeading) { sidebarToggle }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                NavigationStack(path: $phonePath) {
                    catalog(matches, highlighted: nil) { match in
                        selectedID = match.id
                        phonePath = [match.id]
                    }
                    .navigationDestination(for: Int.self) { id in
                        if let show = store.shows.first(where: { $0.id == id }) {
                            ShowDetailView(show: show)
                        } else {
                            ContentUnavailableView("Show unavailable", systemImage: "music.note.list")
                        }
                    }
                }
            }
        }
        .onChange(of: split) { _, isSplit in
            if isSplit {
                if let id = phonePath.last { selectedID = id }
            } else if let selectedID {
                phonePath = [selectedID]
            }
        }
    }

    private var sidebarToggle: some View {
        Button {
            sidebarVisible.toggle()
        } label: {
            Label(sidebarVisible ? "Hide sidebar" : "Show sidebar", systemImage: "sidebar.leading")
        }
        .accessibilityIdentifier("catalog.sidebar")
    }

    private func catalog(_ matches: [CatalogMatch], highlighted: Int?, open: @escaping (CatalogMatch) -> Void) -> some View {
        List {
            VStack(alignment: .leading, spacing: 14) {
                ArchiveThemeMasthead(theme: store.theme, logo: store.logo, picture: store.picture,
                                     wallpaperID: store.wallpaperID, count: store.shows.count) {
                    if let show = matches.randomElement() { open(show) }
                }
                .disabled(matches.isEmpty)
                collectionPicker
                searchField
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 9)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)

            Section {
                if store.isLoading && store.shows.isEmpty {
                    ProgressView("Loading archive")
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .listRowSeparator(.hidden)
                } else if let error = store.loadError, store.shows.isEmpty {
                    ContentUnavailableView("Archive unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                        .listRowSeparator(.hidden)
                } else if matches.isEmpty {
                    emptyState
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(matches) { match in
                        Button {
                            open(match)
                        } label: {
                            CatalogRow(match: match, saved: store.savedIDs.contains(match.id))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens show details")
                        .accessibilityIdentifier("catalog.show.\(match.id)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 16))
                        .listRowBackground(ArchiveRowBackground(selected: match.id == highlighted))
                        .listRowSeparatorTint(store.theme.line)
                        .swipeActions(edge: .trailing) { saveButton(match) }
                        .contextMenu { saveButton(match) }
                    }
                }
            } header: {
                resultsHeader(matches.count)
            }
        }
        .listStyle(.plain)
        .archivePage(wallpaperID: store.wallpaperID, sharesWindow: true)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Tool Drive")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .library } label: { Label("Library", systemImage: "books.vertical") }
                    .accessibilityIdentifier("catalog.library")
                Button { sheet = .appearance } label: { Label("Appearance", systemImage: "paintpalette") }
                    .accessibilityIdentifier("catalog.appearance")
            }
        }
    }

    private var collectionPicker: some View {
        Picker("Collection", selection: $savedOnly) {
            Text("All shows").tag(false)
            Text("Saved").tag(true)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("catalog.collection")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Venue, city, song or date", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search shows")
                .accessibilityIdentifier("catalog.search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Clear search")
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 13)
        .frame(minHeight: 46)
        .archiveControl()
    }

    private func resultsHeader(_ count: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                resultCount(count)
                Spacer(minLength: 8)
                resultTools
            }
            VStack(alignment: .leading, spacing: 4) {
                resultCount(count)
                resultTools
            }
        }
        .padding(.vertical, 2)
        .textCase(nil)
    }

    private func resultCount(_ count: Int) -> some View {
        Text("\(count.formatted()) \(count == 1 ? "show" : "shows")")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .accessibilityIdentifier("catalog.resultCount")
            .fixedSize(horizontal: true, vertical: false)
    }

    private var resultTools: some View {
        HStack(spacing: 13) {
            Button {
                sheet = .filters
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    Text("Filters")
                    if filters.activeCount > 0 {
                        Text("\(filters.activeCount)").font(.caption2.weight(.bold)).monospacedDigit()
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(store.theme.accent.opacity(0.17), in: Capsule())
                    }
                }
                .frame(minHeight: 44)
            }
            .accessibilityValue("\(filters.activeCount) active")
            .accessibilityIdentifier("catalog.filters")
            Menu {
                Picker("Sort shows", selection: $sort) {
                    ForEach(CatalogSort.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down").frame(minWidth: 32, minHeight: 44)
            }
            .accessibilityLabel("Sort shows")
            .accessibilityValue(sort.rawValue)
            .accessibilityIdentifier("catalog.sort")
        }
        .buttonStyle(.borderless)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(store.theme.accent)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(savedOnly && store.savedIDs.isEmpty ? "No saved shows" : "No matching shows",
                  systemImage: savedOnly && store.savedIDs.isEmpty ? "bookmark" : "magnifyingglass")
        } description: {
            Text(savedOnly && store.savedIDs.isEmpty ? "Save a show from its details to find it here." : "Try another search or adjust your filters.")
        } actions: {
            if savedOnly && store.savedIDs.isEmpty {
                Button("Browse shows") { savedOnly = false }
            } else {
                Button("Clear search and filters") {
                    query = ""
                    filters = CatalogFilters(status: "all")
                }
            }
        }
    }

    private func saveButton(_ match: CatalogMatch) -> some View {
        let saved = store.savedIDs.contains(match.id)
        return Button { store.toggleSaved(match.id) } label: {
            Label(saved ? "Remove from Saved" : "Save show", systemImage: saved ? "bookmark.slash" : "bookmark")
        }
        .tint(saved ? .secondary : store.theme.accent)
        .accessibilityIdentifier("catalog.save.\(match.id)")
    }
}

private struct CatalogRow: View {
    let match: CatalogMatch
    let saved: Bool
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.mobileTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(match.show.dateLabel)
                        .font(.system(.caption, design: theme == .nightShift || theme == .laserGrid ? .monospaced : .default, weight: .semibold))
                        .foregroundStyle(theme.muted)
                    if saved {
                        Image(systemName: "bookmark.fill").font(.caption2)
                            .foregroundStyle(theme.accent)
                            .accessibilityLabel("Saved")
                    }
                }
                Text(match.show.venue).font(.headline).foregroundStyle(theme.text).fixedSize(horizontal: false, vertical: true)
                if !match.show.location.isEmpty {
                    Text(match.show.location).font(.subheadline).foregroundStyle(theme.muted)
                }
                if typeSize.isAccessibilitySize, let score = match.rating { rating(score) }
            }
            Spacer(minLength: 3)
            if !typeSize.isAccessibilitySize, let score = match.rating { rating(score) }
            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func rating(_ score: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
            if theme == .nightShift && !typeSize.isAccessibilitySize {
                ArchiveNumberDisplay(value: String(format: "%.1f", score)).frame(height: 15)
            } else {
                Text(score.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 7).padding(.vertical, 4)
        .foregroundStyle(theme.accent)
        .background(theme.accent.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound rating \(score.formatted()) out of 10")
    }
}
