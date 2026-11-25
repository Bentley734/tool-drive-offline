import Foundation

struct CatalogThemePreferences {
    let defaults: UserDefaults
    var glassEnabled: Bool {
        if defaults.object(forKey: "catalogLiquidGlass") != nil { return defaults.bool(forKey: "catalogLiquidGlass") }
        // Releases before the glass toggle wrote the selected catalog theme.
        return defaults.string(forKey: "catalogTheme") == Self.exclusive || hasNoThemeHistory
    }

    private var hasNoThemeHistory: Bool {
        defaults.object(forKey: "catalogTheme") == nil && defaults.object(forKey: "catalogLastStandardTheme") == nil
    }
    static let exclusive = "liquid-glass"
    private static let standard = ["front-row", "night-shift", "graphite", "laser-grid"]

    private func standardTheme(_ value: String?) -> String? {
        guard let value else { return nil }
        if Self.standard.contains(value) { return value }
        if ["plasma-bloom", "lightfall", "violet-hour", "solar-flare"].contains(value) { return "laser-grid" }
        return nil
    }

    var lastStandardTheme: String {
        standardTheme(defaults.string(forKey: "catalogTheme"))
            ?? standardTheme(defaults.string(forKey: "catalogLastStandardTheme"))
            ?? "front-row"
    }

    var effectiveTheme: String {
        if glassEnabled && (hasNoThemeHistory || defaults.string(forKey: "catalogTheme") == Self.exclusive) { return Self.exclusive }
        return lastStandardTheme
    }

    @discardableResult
    func select(_ theme: String) -> Bool {
        guard Self.standard.contains(theme) || (glassEnabled && theme == Self.exclusive) else { return false }
        // Persist the inferred choice before the first change creates theme history.
        if defaults.object(forKey: "catalogLiquidGlass") == nil {
            defaults.set(glassEnabled, forKey: "catalogLiquidGlass")
        }
        let standard = theme == Self.exclusive ? lastStandardTheme : theme
        // Save the return choice first, so an interrupted write still has a usable theme.
        if defaults.string(forKey: "catalogLastStandardTheme") != standard {
            defaults.set(standard, forKey: "catalogLastStandardTheme")
        }
        if defaults.string(forKey: "catalogTheme") != theme { defaults.set(theme, forKey: "catalogTheme") }
        return true
    }
}
