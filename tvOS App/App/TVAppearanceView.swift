import SwiftUI

struct TVAppearanceView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 280, maximum: 540), spacing: 26)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                HStack {
                    Text("Appearance").font(.largeTitle.bold())
                    Spacer()
                    Button("Done") { dismiss() }.accessibilityIdentifier("tv.appearance.done")
                }
                VStack(alignment: .leading, spacing: 22) {
                    Text("Theme").font(.title3.bold())
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                        ForEach(MobileTheme.allCases) { theme in
                            artChoice(theme.title, selected: archive.theme == theme,
                                      id: "tv.theme." + theme.rawValue, action: { archive.selectTheme(theme) }) {
                                ArchiveThemeArtwork(theme: theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
                                    .overlay(alignment: .leading) {
                                        ArchiveBrandLogo(logo: archive.logo)
                                            .foregroundStyle(.white)
                                            .frame(width: 116, height: 38)
                                            .padding(16)
                                            .background(.black.opacity(0.58))
                                    }
                            }
                        }
                    }
                }.focusSection()
                HStack(spacing: 24) {
                    Button {
                        archive.setGlassEnabled(!archive.glassEnabled)
                    } label: {
                        Label(archive.glassEnabled ? "Liquid Glass controls on" : "Liquid Glass controls off",
                              systemImage: archive.glassEnabled ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityAddTraits(archive.glassEnabled ? .isSelected : [])
                    .accessibilityIdentifier("tv.controls.glass")
                }
                VStack(alignment: .leading, spacing: 20) {
                    Text("Logo").font(.title3.bold())
                    HStack(spacing: 27) {
                        ForEach(MobileLogo.allCases) { logo in
                            Button { archive.selectLogo(logo) } label: {
                                HStack(spacing: 14) {
                                    ArchiveBrandLogo(logo: logo).frame(width: 90, height: 32)
                                    Text(logo.title)
                                    if logo == archive.logo { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                            .accessibilityLabel(logo.title)
                            .accessibilityAddTraits(logo == archive.logo ? .isSelected : [])
                            .accessibilityIdentifier("tv.logo." + logo.rawValue)
                        }
                    }
                }.focusSection()
                if archive.theme == .frontRow {
                    Text("Front Row picture").font(.title3.bold())
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(FrontRowPicture.allCases) { picture in
                            artChoice(picture.title, selected: picture == archive.picture,
                                      id: "tv.picture." + picture.rawValue, action: { archive.selectPicture(picture) }) {
                                ArchiveThemeArtwork(theme: .frontRow, picture: picture, wallpaperID: archive.wallpaperID)
                            }
                        }
                    }.focusSection()
                }
                if archive.theme == .liquidGlass {
                    Text("Wallpaper").font(.title3.bold())
                    Button { archive.selectWallpaper(GlassWallpaperPreferences.shuffle) } label: {
                        Label(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? "Shuffle ✓" : "Shuffle",
                              systemImage: "shuffle")
                    }
                    .accessibilityLabel("Shuffle wallpaper on each launch")
                    .accessibilityAddTraits(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? .isSelected : [])
                    .accessibilityIdentifier("tv.wallpaper.shuffle")
                    LazyVGrid(columns: columns, spacing: 26) {
                        ForEach(GlassWallpaper.choices, id: \.id) { photo in
                            artChoice(photo.title, selected: photo.id == archive.wallpaperChoice,
                                      id: "tv.wallpaper." + photo.id, action: { archive.selectWallpaper(photo.id) }) {
                                ArchiveWallpaper(id: photo.id)
                            }
                        }
                    }.focusSection()
                }
            }
            .padding(50)
        }
        .buttonStyle(TVActionStyle())
        .archivePage(wallpaperID: archive.wallpaperID)
        .onExitCommand { dismiss() }
    }

    private func artChoice<Artwork: View>(_ title: String, selected: Bool, id: String,
                                          action: @escaping () -> Void,
                                          @ViewBuilder art: () -> Artwork) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                art().frame(height: 118).clipped()
                HStack {
                    Text(title).font(.headline)
                    Spacer(minLength: 4)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(archive.theme.accent) }
                }
                .padding(14)
                .foregroundStyle(archive.theme.text)
                .background(archive.theme.panel)
            }
        }
        .buttonStyle(.card)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}
