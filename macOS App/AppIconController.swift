import AppKit

enum AppIconController {
    private static let resources = ["classic": "AppIcon", "2006": "AppIcon2006"]
    private static let preference = "appIconStyle"

    static var selectedID: String {
        guard let saved = UserDefaults.standard.string(forKey: preference), resources[saved] != nil else {
            return "classic"
        }
        return saved
    }

    static func image(for id: String) -> NSImage? {
        guard let name = resources[id],
              let url = Bundle.main.url(forResource: name, withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static func restore() {
        NSApp.applicationIconImage = selectedID == "classic" ? nil : image(for: selectedID)
    }

    @discardableResult
    static func select(_ id: String) -> Bool {
        guard let icon = image(for: id) else { return false }
        NSApp.applicationIconImage = id == "classic" ? nil : icon
        UserDefaults.standard.set(id, forKey: preference)
        return true
    }
}
