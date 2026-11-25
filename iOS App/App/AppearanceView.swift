import SwiftUI
import ImageIO

private func wallpaperThumbnail(_ file: String) -> UIImage? {
    guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Wallpapers"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                    kCGImageSourceThumbnailMaxPixelSize: 440,
                                    kCGImageSourceCreateThumbnailWithTransform: true]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
}

struct AppearanceView: View {
    @EnvironmentObject private var archive: ArchiveStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var thumbnails: [String: UIImage] = [:]

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 138, maximum: 360), spacing: 12)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    VStack(alignment: .leading, spacing: 10) {
                        heading("Theme")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(MobileTheme.allCases) { theme in
                                choice(theme.title, id: "theme." + theme.rawValue, selected: archive.theme == theme) {
                                    archive.selectTheme(theme)
                                } image: {
                                    ArchiveThemeArtwork(theme: theme, picture: archive.picture, wallpaperID: archive.wallpaperID)
                                        .overlay(alignment: .bottomLeading) {
                                            Capsule().fill(theme.accent).frame(width: 30, height: 4).padding(9)
                                        }
                                }
                            }
                        }
                        Toggle("Liquid Glass controls", isOn: Binding(get: { archive.glassEnabled }, set: archive.setGlassEnabled))
                            .padding(.horizontal, 14).padding(.vertical, 11).archivePanel()
                            .accessibilityIdentifier("appearance.glass")
                    }

                    if archive.theme == .liquidGlass {
                        wallpapers
                    } else if archive.theme == .frontRow {
                        VStack(alignment: .leading, spacing: 10) {
                            heading("Front Row picture")
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(FrontRowPicture.allCases) { picture in
                                    choice(picture.title, id: "picture." + picture.rawValue, selected: archive.picture == picture) {
                                        archive.selectPicture(picture)
                                    } image: {
                                        ArchiveThemeArtwork(theme: .frontRow, picture: picture, wallpaperID: archive.wallpaperID)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        heading("Logo")
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(MobileLogo.allCases) { logo in
                                choice(logo.title, id: "logo." + logo.rawValue, selected: archive.logo == logo) {
                                    archive.selectLogo(logo)
                                } image: {
                                    ZStack {
                                        archive.theme.panel
                                        ArchiveBrandLogo(logo: logo).padding(12)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity)
            }
            .archivePage(wallpaperID: archive.wallpaperID)
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                thumbnails = await Task.detached(priority: .utility) {
                    Dictionary(uniqueKeysWithValues: GlassWallpaper.choices.compactMap { photo in
                        wallpaperThumbnail(photo.file).map { (photo.id, $0) }
                    })
                }.value
            }
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Wallpaper")
            Button { archive.selectWallpaper(GlassWallpaperPreferences.shuffle) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "shuffle").font(.title3).foregroundStyle(archive.theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shuffle").font(.headline)
                        Text("A different concert photo each launch.").font(.subheadline).foregroundStyle(archive.theme.muted)
                    }
                    Spacer()
                    if archive.wallpaperChoice == GlassWallpaperPreferences.shuffle {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(archive.theme.accent)
                    }
                }.padding(14).archivePanel()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("appearance.wallpaper.shuffle")
            .accessibilityAddTraits(archive.wallpaperChoice == GlassWallpaperPreferences.shuffle ? .isSelected : [])
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(GlassWallpaper.choices, id: \.id) { photo in
                    choice(photo.title, id: "wallpaper." + photo.id, selected: archive.wallpaperChoice == photo.id) {
                        archive.selectWallpaper(photo.id)
                    } image: {
                        if let image = thumbnails[photo.id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else { archive.theme.panel }
                    }
                }
            }
        }
    }

    private func heading(_ name: String) -> some View {
        Text(name).font(.title3.bold()).foregroundStyle(archive.theme.text).accessibilityAddTraits(.isHeader)
    }

    private func choice<Preview: View>(_ name: String, id: String, selected: Bool, action: @escaping () -> Void,
                                       @ViewBuilder image: () -> Preview) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(archive.theme.panel).aspectRatio(2.55, contentMode: .fit)
                    .overlay { image().accessibilityHidden(true) }
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.black, archive.theme.accent).padding(6)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? archive.theme.accent : archive.theme.line,
                                                                       lineWidth: selected ? 2 : 1)
                    }
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(archive.theme.text)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityIdentifier("appearance." + id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
