import Foundation

@main
enum WallpaperShuffleChecks {
    static func main() throws {
        let manifestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        struct Photo: Decodable { let id: String }
        let photoIDs = try JSONDecoder().decode([Photo].self, from: Data(contentsOf: manifestURL)).map(\.id)
        precondition(photoIDs.count == 9 && photoIDs.first == "crimson-current")

        let suite = "ToolDriveTests.WallpaperShuffle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let photoKey = "catalogGlassWallpaper"
        let shuffleKey = "catalogGlassWallpaperShuffle"
        func launch() -> GlassWallpaperPreferences {
            GlassWallpaperPreferences(defaults: UserDefaults(suiteName: suite)!, wallpaperIDs: photoIDs)
        }

        let fresh = launch()
        fresh.enterTheme()
        precondition(fresh.wallpaper == photoIDs[0] && fresh.choice == photoIDs[0])
        precondition(!defaults.bool(forKey: shuffleKey), "Shuffle must be opt-in")

        defaults.set("retired-photo", forKey: photoKey)
        defaults.set(["old": "preference"], forKey: shuffleKey)
        let recovered = launch()
        recovered.enterTheme()
        precondition(recovered.wallpaper == photoIDs[0] && recovered.choice == photoIDs[0])

        // Previous releases stored only a fixed photo ID.
        defaults.removeObject(forKey: shuffleKey)
        defaults.set("violet-anatomy", forKey: photoKey)
        let fixed = launch()
        for _ in 0..<4 { fixed.enterTheme() }
        precondition(fixed.wallpaper == "violet-anatomy" && fixed.choice == fixed.wallpaper)
        precondition(launch().wallpaper == fixed.wallpaper)
        precondition(!fixed.select("obsolete-wallpaper") && fixed.wallpaper == "violet-anatomy")

        precondition(fixed.select("shuffle"))
        let first = fixed.wallpaper
        precondition(photoIDs.contains(first) && fixed.choice == "shuffle")
        precondition(defaults.string(forKey: photoKey) == first && defaults.bool(forKey: shuffleKey))
        for _ in 0..<4 {
            fixed.enterTheme()
            precondition(fixed.select("shuffle") && fixed.wallpaper == first,
                         "Returning to the theme or reselecting Shuffle changed the current photo")
        }

        var previous = first
        for _ in 0..<32 {
            // A standard theme may read preferences to initialize the bridge. Only
            // entering Liquid Glass should advance this launch's wallpaper.
            let next = launch()
            precondition(next.choice == "shuffle" && next.wallpaper == previous)
            precondition(defaults.string(forKey: photoKey) == previous)
            next.enterTheme()
            let current = next.wallpaper
            precondition(photoIDs.contains(current) && current != previous, "Consecutive launches repeated")
            precondition(defaults.string(forKey: photoKey) == current && defaults.bool(forKey: shuffleKey))
            next.enterTheme()
            precondition(next.wallpaper == current && next.choice == "shuffle")
            previous = current
        }

        let disabled = launch()
        precondition(disabled.select("prism-beams") && disabled.choice == "prism-beams")
        precondition(!defaults.bool(forKey: shuffleKey))
        let reopened = launch()
        reopened.enterTheme()
        precondition(reopened.wallpaper == "prism-beams" && reopened.choice == reopened.wallpaper)

        defaults.set("removed-photo", forKey: photoKey)
        defaults.set(true, forKey: shuffleKey)
        let repaired = launch()
        repaired.enterTheme()
        precondition(repaired.choice == "shuffle" && photoIDs.contains(repaired.wallpaper))
        precondition(defaults.string(forKey: photoKey) == repaired.wallpaper)
        print("PASS wallpaper Shuffle opt-in, legacy preferences, deferred selection, non-repeating launches and fixed choices")
    }
}
