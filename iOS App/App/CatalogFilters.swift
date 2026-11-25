import SwiftUI

enum CatalogSort: String, CaseIterable, Identifiable {
    case highest = "Top rated"
    case newest = "Newest first"
    case oldest = "Oldest first"
    case venue = "Venue A–Z"
    var id: Self { self }
}

struct CatalogMatch: Identifiable {
    let show: Concert
    let rating: Double?
    var id: Int { show.id }
}

struct CatalogFilters: Equatable {
    enum Rating: String, CaseIterable, Identifiable {
        case all = "Any", rated = "Rated", unrated = "Unrated"
        var id: Self { self }
    }

    static let statusOptions = [("all", "Any status"), ("OTD", "On the drive"), ("Confirmed", "Confirmed"),
                                ("Unconfirmed", "Unconfirmed"), ("Unknown", "No known recording")]
    var status = "OTD"
    var type = "all"
    var rating: Rating = .all
    var minimum = 0
    var firstYear: Int?
    var lastYear: Int?

    var activeCount: Int {
        [status != "all", type != "all", rating != .all || minimum > 0, firstYear != nil || lastYear != nil]
            .filter { $0 }.count
    }

    func matches(_ shows: [Concert], query: String, savedOnly: Bool, savedIDs: Set<Int>, sort: CatalogSort) -> [CatalogMatch] {
        let text = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased().replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "œ", with: "oe")
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [CatalogMatch] = []
        for show in shows {
            guard !savedOnly || savedIDs.contains(show.id),
                  firstYear.map({ show.year >= $0 }) ?? true, lastYear.map({ show.year <= $0 }) ?? true else { continue }
            let sourceTokens = tokens.filter { !show.searchText.contains($0) }
            var found = false
            var best: Double?
            for source in show.sources {
                guard (status == "all" || status == source.status), (type == "all" || type == source.recordingType),
                      sourceTokens.allSatisfy({ source.searchText.contains($0) }) else { continue }
                let score = source.rating.flatMap { $0 > 0 && $0 <= 10 ? $0 : nil }
                if let score {
                    guard rating != .unrated, score >= Double(minimum) else { continue }
                    best = max(best ?? score, score)
                } else if rating == .rated || (minimum > 0 && rating != .unrated) {
                    continue
                }
                found = true
            }
            if show.sources.isEmpty && (status == "all" || show.status == status) &&
                (type == "all" || type == "unknown") && rating != .rated &&
                (minimum == 0 || rating == .unrated) && sourceTokens.isEmpty {
                found = true
            }
            if found { result.append(CatalogMatch(show: show, rating: best)) }
        }
        return result.sorted { a, b in
            switch sort {
            case .highest:
                if a.rating != b.rating { return (a.rating ?? -1) > (b.rating ?? -1) }
            case .venue:
                let order = a.show.venue.localizedCaseInsensitiveCompare(b.show.venue)
                if order != .orderedSame { return order == .orderedAscending }
            case .oldest:
                if a.show.date != b.show.date { return a.show.date < b.show.date }
            case .newest: break
            }
            if a.show.date != b.show.date { return a.show.date > b.show.date }
            return a.id < b.id
        }
    }
}

#if os(iOS)
struct CatalogFilterSheet: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Binding var filters: CatalogFilters
    let years: [Int]
    let types: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Recording") {
                    Picker("Status", selection: $filters.status) {
                        ForEach(CatalogFilters.statusOptions, id: \.0) { option in
                            Text(option.1).tag(option.0)
                        }
                    }
                    Picker("Recording type", selection: $filters.type) {
                        Text("All types").tag("all")
                        ForEach(types, id: \.self) { type in
                            Text(type == "fm" ? "FM" : type.prefix(1).uppercased() + type.dropFirst()).tag(type)
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("Sound rating") {
                    Picker("Rating availability", selection: $filters.rating) {
                        ForEach(CatalogFilters.Rating.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if filters.rating != .unrated {
                        Stepper(value: $filters.minimum, in: 0...10) {
                            LabeledContent("Minimum", value: filters.minimum == 0 ? "Any" : "\(filters.minimum) / 10")
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section("Show years") {
                    Picker("From", selection: $filters.firstYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.lastYear.map { year <= $0 } ?? true }, id: \.self) { year in
                            Text(String(year)).tag(Optional(year))
                        }
                    }
                    Picker("Through", selection: $filters.lastYear) {
                        Text("Any year").tag(Int?.none)
                        ForEach(years.filter { year in filters.firstYear.map { year >= $0 } ?? true }, id: \.self) { year in
                            Text(String(year)).tag(Optional(year))
                        }
                    }
                }
                .listRowBackground(ArchiveRowBackground())
                Section {
                    Button("Clear all filters") {
                        filters = CatalogFilters(status: "all")
                    }
                    .disabled(filters.activeCount == 0)
                }
                .listRowBackground(ArchiveRowBackground())
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
#endif
