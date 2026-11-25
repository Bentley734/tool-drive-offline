import SafariServices
import SwiftUI

@MainActor
final class MobilePlex: ObservableObject {
    enum Activity { case idle, signingIn, servers, libraries, searching }
    struct SignInPage: Identifiable {
        let url: URL
        let id = UUID()
    }

    @Published private(set) var connected: Bool
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var servers: [PlexServer] = []
    @Published private(set) var libraries: [PlexLibrary] = []
    @Published private(set) var serverID: String?
    @Published private(set) var libraryID: String?
    @Published private(set) var match: PlexSearchResult?
    @Published private(set) var message: String?
    @Published var signInPage: SignInPage?

    private let service: PlexService
    private let defaults: UserDefaults
    private let serverKey = "mobilePreferredPlexServer"
    private var task: Task<Void, Never>?
    private var operationID = UUID()
    private var signInURL: URL?
    private var loadedServers = false

    init(defaults: UserDefaults = .standard, service: PlexService? = nil) {
        self.defaults = defaults
        let actual = service ?? PlexService(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
        self.service = actual
        connected = actual.status.connected
    }

    func open() {
        if connected && !loadedServers && activity == .idle { refresh() }
    }

    func signIn() {
        run(.signingIn) {
            let authorization = try await self.request(self.service.beginConnection)
            self.signInURL = authorization.authorizationURL
            self.signInPage = SignInPage(url: authorization.authorizationURL)
            let deadline = ContinuousClock.now.advanced(by: .seconds(300))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(2))
                guard ContinuousClock.now < deadline else { break }
                let state = try await self.request { self.service.pollConnection(pinID: authorization.pinID, completion: $0) }
                if state == .connected {
                    self.connected = true
                    self.signInURL = nil
                    self.signInPage = nil
                    try await self.loadServers()
                    return
                }
            }
            throw PlexServiceError("Plex sign-in expired. Start again to get a new sign-in link.")
        }
    }

    func reopenSignIn() {
        if let signInURL { signInPage = SignInPage(url: signInURL) }
    }

    func refresh() {
        run(.servers) { try await self.loadServers() }
    }

    private func loadServers() async throws {
        activity = .servers
        loadedServers = false
        servers = []
        libraries = []
        serverID = nil
        libraryID = nil
        match = nil
        let found = try await request(service.refreshServers)
        connected = service.status.connected
        loadedServers = true
        servers = found
        guard !found.isEmpty else {
            message = "No Plex servers are available to this account."
            return
        }
        let preferred = defaults.string(forKey: serverKey)
        if let selected = found.first(where: { $0.id == preferred }) ?? found.first {
            try await loadLibraries(on: selected.id, remember: preferred == nil)
        }
    }

    func selectServer(_ id: String) {
        guard servers.contains(where: { $0.id == id }) else { return }
        run(.libraries) { try await self.loadLibraries(on: id, remember: true) }
    }

    private func loadLibraries(on id: String, remember: Bool) async throws {
        activity = .libraries
        libraryID = nil
        libraries = []
        match = nil
        try service.selectServer(id: id)
        serverID = id
        if remember { defaults.set(id, forKey: serverKey) }
        libraries = try await request(service.refreshLibraries)
        libraryID = service.status.selectedLibraryID
        if libraries.isEmpty { message = "This server has no music libraries available to your account." }
    }

    func selectLibrary(_ id: String) {
        guard !id.isEmpty else { return }
        cancel()
        match = nil
        do {
            try service.selectLibrary(id: id)
            libraryID = service.status.selectedLibraryID
        } catch { message = error.localizedDescription }
    }

    func search(date: String, version: Int?) {
        guard connected, libraryID != nil else { return }
        match = nil
        run(.searching) {
            self.match = try await self.request { self.service.search(showDate: date, preferredVersion: version, completion: $0) }
        }
    }

    func play(_ result: PlexSearchResult, index: Int, with player: AudioPlayer) {
        result.withNativePlaybackTracks { tracks in
            do {
                let validated = try PlexParser.validatedPlaybackTracks(tracks)
                guard validated.indices.contains(index) else { return }
                player.play(tracks: validated, title: result.collection, context: "Plex · \(result.showDate)",
                            startIndex: index, expandPlayer: false)
            } catch { message = error.localizedDescription }
        }
    }

    func disconnect() {
        cancel()
        do {
            try service.disconnect()
        } catch { message = error.localizedDescription }
        connected = service.status.connected
        loadedServers = false
        match = nil
        servers = []
        libraries = []
        serverID = nil
        libraryID = nil
        defaults.removeObject(forKey: serverKey)
    }

    func cancel() {
        if activity == .servers || activity == .libraries { loadedServers = false }
        operationID = UUID()
        task?.cancel()
        task = nil
        _ = service.cancelSearch()
        activity = .idle
        signInURL = nil
        signInPage = nil
        message = nil
    }

    private func run(_ activity: Activity, _ work: @escaping @MainActor () async throws -> Void) {
        cancel()
        self.activity = activity
        let id = operationID
        task = Task {
            do {
                try Task.checkCancellation()
                try await work()
            } catch {
                guard id == operationID, !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            guard id == operationID else { return }
            connected = service.status.connected
            signInURL = nil
            signInPage = nil
            self.activity = .idle
            task = nil
        }
    }

    private func request<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { continuation in
            start { continuation.resume(with: $0) }
        }
        try Task.checkCancellation()
        return value
    }
}

struct PlexView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @EnvironmentObject private var plex: MobilePlex
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    private let initialDate: String
    private let version: Int?
    @State private var date: String
    @State private var searchOnOpen: Bool
    @State private var confirmDisconnect = false
    @State private var showsPlayer = false

    init(initialDate: String = "", version: Int? = nil) {
        self.initialDate = initialDate
        self.version = version
        _date = State(initialValue: initialDate)
        _searchOnOpen = State(initialValue: !initialDate.isEmpty)
    }

    private var trimmedDate: String { date.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var preferredVersion: Int? { trimmedDate == initialDate ? version : nil }
    private var validDate: Bool { (try? PlexParser.searchQueries(showDate: trimmedDate, preferredVersion: preferredVersion)) != nil }

    var body: some View {
        NavigationStack {
            List {
                if plex.connected {
                    connection
                    if plex.libraryID != nil { searchForm }
                    if let match = plex.match, match.showDate == trimmedDate, plex.libraryID != nil { recording(match) }
                } else {
                    Section {
                        if plex.activity == .signingIn {
                            ProgressView("Waiting for Plex sign-in")
                            Button("Open Plex sign-in") { plex.reopenSignIn() }
                            Button("Cancel sign-in", role: .cancel) { plex.cancel() }
                        } else {
                            Button("Sign in to Plex", systemImage: "person.crop.circle.badge.checkmark") { plex.signIn() }
                                .accessibilityIdentifier("plex.signIn")
                        }
                    } footer: {
                        Text("Connect a Plex account to stream recordings from a music library on your server.")
                    }
                    .listRowBackground(ArchiveRowBackground())
                }
                if let message = plex.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                        .listRowBackground(ArchiveRowBackground())
                }
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Plex")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { close() } } }
            .sheet(item: $plex.signInPage) { page in
                PlexSignInBrowser(url: page.url) { plex.signInPage = nil }.ignoresSafeArea()
            }
            .sheet(isPresented: $showsPlayer) { PlayerView().presentationDragIndicator(.visible) }
            .confirmationDialog("Disconnect from Plex?", isPresented: $confirmDisconnect) {
                Button("Disconnect", role: .destructive) {
                    if player.context.hasPrefix("Plex · ") { player.stop() }
                    plex.disconnect()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .onAppear {
            plex.open()
            performSuggestedSearch()
        }
        .onChange(of: plex.activity) { _, _ in performSuggestedSearch() }
        .onChange(of: plex.libraryID) { _, _ in performSuggestedSearch() }
        .onChange(of: player.isVisible) { _, visible in if !visible { showsPlayer = false } }
        .onDisappear {
            if plex.signInPage == nil { plex.cancel() }
        }
    }

    private var connection: some View {
        Section("Connection") {
            if !plex.servers.isEmpty {
                Picker("Server", selection: Binding(get: { plex.serverID ?? "" }, set: plex.selectServer)) {
                    if plex.serverID == nil { Text("Choose server").tag("") }
                    ForEach(plex.servers, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(plex.activity != .idle)
                .accessibilityIdentifier("plex.server")
            }
            if !plex.libraries.isEmpty {
                Picker("Music library", selection: Binding(get: { plex.libraryID ?? "" }, set: plex.selectLibrary)) {
                    if plex.libraryID == nil { Text("Choose library").tag("") }
                    ForEach(plex.libraries, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(plex.activity != .idle)
                .accessibilityIdentifier("plex.library")
            }
            if plex.activity == .servers || plex.activity == .libraries {
                ProgressView(plex.activity == .servers ? "Finding servers" : "Finding music libraries")
            }
            Button("Refresh servers", systemImage: "arrow.clockwise") { plex.refresh() }
                .disabled(plex.activity != .idle)
            Button("Disconnect", role: .destructive) { confirmDisconnect = true }
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private var searchForm: some View {
        Section("Find a recording") {
            TextField("YYYY-MM-DD", text: $date)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel("Show date").accessibilityIdentifier("plex.date")
                .submitLabel(.search).onSubmit { find() }
            if let preferredVersion { LabeledContent("Source version", value: String(preferredVersion)) }
            if plex.activity == .searching {
                ProgressView("Searching your library")
                Button("Cancel search") { plex.cancel() }
            } else {
                Button("Find recording", systemImage: "magnifyingglass") { find() }
                    .disabled(!validDate || plex.activity != .idle)
                    .accessibilityIdentifier("plex.search")
            }
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private func recording(_ match: PlexSearchResult) -> some View {
        let active = player.isVisible && player.collection == match.collection && player.context == "Plex · \(match.showDate)"
        return Section {
            Button("Play recording", systemImage: "play.fill") { plex.play(match, index: 0, with: player) }
                .accessibilityIdentifier("plex.play")
            if active {
                Button("Now Playing", systemImage: "waveform") { showsPlayer = true }
            }
            ForEach(Array(match.tracks.enumerated()), id: \.offset) { index, track in
                Button {
                    plex.play(match, index: index, with: player)
                } label: {
                    HStack {
                        Text(String(track.number)).monospacedDigit().foregroundStyle(.secondary)
                        Text(track.title).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: active && player.index == index ? "waveform" : "play").foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("\(match.collection) · Version \(match.version)")
        }
        .listRowBackground(ArchiveRowBackground())
    }

    private func performSuggestedSearch() {
        guard searchOnOpen, plex.activity == .idle, plex.libraryID != nil, validDate else { return }
        find()
    }

    private func find() {
        guard validDate, plex.activity == .idle else { return }
        searchOnOpen = false
        plex.search(date: trimmedDate, version: preferredVersion)
    }

    private func close() { plex.cancel(); dismiss() }
}

private struct PlexSignInBrowser: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    @Environment(\.mobileTheme) private var theme
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let finished: () -> Void
        init(_ finished: @escaping () -> Void) { self.finished = finished }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { finished() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {
        controller.preferredBarTintColor = UIColor(theme.panel)
        controller.preferredControlTintColor = UIColor(theme.accent)
    }
}
