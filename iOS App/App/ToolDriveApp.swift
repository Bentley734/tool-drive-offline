import SwiftUI

@main
struct ToolDriveApp: App {
    var body: some Scene {
        WindowGroup { ArchiveRoot() }
    }
}

private struct ArchiveRoot: View {
    @StateObject private var archive = ArchiveStore()
    @StateObject private var audio = AudioPlayer()
    @StateObject private var library = MobileLibrary()
    @StateObject private var plex = MobilePlex()

    var body: some View {
        CatalogView()
            .archiveWindowCanvas()
            .environmentObject(archive)
            .environmentObject(audio)
            .environmentObject(library)
            .environmentObject(plex)
            .environment(\.mobileTheme, archive.theme)
            .environment(\.mobileGlassControls, archive.glassEnabled)
            .tint(archive.theme.accent)
            .preferredColorScheme(.dark)
            .task { await archive.load() }
    }
}

#if DEBUG
struct CatalogDevicePreviews: PreviewProvider {
    static var previews: some View {
        Group {
            ArchiveRoot().previewDevice("iPhone 16").previewDisplayName("iPhone")
            ArchiveRoot().previewDevice("iPad Pro 11-inch (M4)")
                .previewInterfaceOrientation(.landscapeLeft).previewDisplayName("iPad landscape")
        }
    }
}
#endif
