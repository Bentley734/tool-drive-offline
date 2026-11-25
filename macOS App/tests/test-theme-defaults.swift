import Foundation

@main
private enum ThemeDefaultsTests {
    static func main() {
        let domain = "net.bentley734.tooldrive.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = CatalogThemePreferences(defaults: defaults)
        func reset() { defaults.removePersistentDomain(forName: domain) }
        precondition(preferences.glassEnabled && preferences.effectiveTheme == "liquid-glass")
        precondition(preferences.select(preferences.effectiveTheme) && preferences.lastStandardTheme == "front-row")
        precondition(preferences.select("night-shift") && preferences.glassEnabled)
        precondition(preferences.select("liquid-glass") && preferences.lastStandardTheme == "night-shift")
        defaults.set(false, forKey: "catalogLiquidGlass")
        precondition(preferences.effectiveTheme == "night-shift")
        reset()
        defaults.set(false, forKey: "catalogLiquidGlass")
        precondition(!preferences.glassEnabled && preferences.effectiveTheme == "front-row")
        reset()
        defaults.set("plasma-bloom", forKey: "catalogTheme")
        precondition(!preferences.glassEnabled && preferences.effectiveTheme == "laser-grid")
        precondition(preferences.select(preferences.effectiveTheme))
        precondition(defaults.string(forKey: "catalogTheme") == "laser-grid")
        reset()
        defaults.set("night-shift", forKey: "catalogLastStandardTheme")
        precondition(preferences.effectiveTheme == "night-shift")
        reset()
        defaults.set("liquid-glass", forKey: "catalogTheme")
        defaults.set("graphite", forKey: "catalogLastStandardTheme")
        precondition(preferences.glassEnabled && preferences.effectiveTheme == "liquid-glass")
        precondition(preferences.lastStandardTheme == "graphite")
        print("PASS first-launch Liquid Glass, saved glass opt-out, older theme migration and return choices")
    }
}
