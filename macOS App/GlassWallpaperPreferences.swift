import Foundation

struct GlassWallpaper: Decodable {
    let id: String
    let title: String
    let file: String

    static let defaultID = "crimson-current"
    static let choices: [GlassWallpaper] = {
        guard let url = Bundle.main.url(forResource: "glass-wallpapers", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let choices = try? JSONDecoder().decode([GlassWallpaper].self, from: data) else { return [] }
        return choices
    }()
}

final class GlassWallpaperPreferences {
    static let shuffle = "shuffle"
    private let defaults: UserDefaults
    private let wallpaperIDs: [String]
    private var pickedThisLaunch = false

    init(defaults: UserDefaults, wallpaperIDs: [String]) {
        self.defaults = defaults
        self.wallpaperIDs = wallpaperIDs
    }

    var wallpaper: String {
        if let saved = defaults.string(forKey: "catalogGlassWallpaper"), wallpaperIDs.contains(saved) { return saved }
        return wallpaperIDs.first ?? GlassWallpaper.defaultID
    }

    var choice: String { defaults.bool(forKey: "catalogGlassWallpaperShuffle") ? Self.shuffle : wallpaper }

    func enterTheme() {
        guard choice == Self.shuffle, !pickedThisLaunch else { return }
        let previous = wallpaper
        let others = wallpaperIDs.filter { $0 != previous }
        guard let next = others.randomElement() ?? wallpaperIDs.first else { return }
        defaults.set(next, forKey: "catalogGlassWallpaper")
        pickedThisLaunch = true
    }

    @discardableResult
    func select(_ value: String) -> Bool {
        if value == Self.shuffle {
            guard !wallpaperIDs.isEmpty else { return false }
            defaults.set(true, forKey: "catalogGlassWallpaperShuffle")
            enterTheme()
        } else {
            guard wallpaperIDs.contains(value) else { return false }
            defaults.set(value, forKey: "catalogGlassWallpaper")
            defaults.set(false, forKey: "catalogGlassWallpaperShuffle")
            pickedThisLaunch = false
        }
        return true
    }
}
