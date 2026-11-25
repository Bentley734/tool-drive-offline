import AppKit
import WebKit

@available(macOS 26.0, *)
extension NSWindow {
    func setCatalogGlassTitlebar(_ active: Bool) {
        guard titlebarAppearsTransparent != active else { return }
        titlebarAppearsTransparent = active
        titlebarSeparatorStyle = active ? .none : .automatic
        backgroundColor = active ? NSColor(srgbRed: 0.045, green: 0.068, blue: 0.12, alpha: 1) : .windowBackgroundColor
    }
}

extension AppDelegate {
    func applyExclusiveWindowAppearance(_ active: Bool) {
        guard #available(macOS 26.0, *) else { return }
        window?.setCatalogGlassTitlebar(active)
        for case let browser as DownloadBrowser in downloadBrowsers.values {
            browser.setExclusiveGlass(active)
        }
    }

    var supportsNativeGlassToolbar: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    var liquidGlassEnabled: Bool {
        catalogThemes.glassEnabled
    }

    var catalogThemes: CatalogThemePreferences {
        CatalogThemePreferences(defaults: .standard)
    }

    var exclusiveGlassActive: Bool { catalogThemes.effectiveTheme == CatalogThemePreferences.exclusive }

    @discardableResult
    func setCatalogGlassWallpaper(_ id: String) -> Bool {
        exclusiveGlassActive && glassWallpapers.select(id)
    }

    @discardableResult
    func setCatalogTheme(_ theme: String) -> Bool {
        guard catalogThemes.select(theme) else { return false }
        if exclusiveGlassActive { glassWallpapers.enterTheme() }
        applyExclusiveWindowAppearance(exclusiveGlassActive)
        return true
    }

    func installCatalogContent() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(glassDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        guard #available(macOS 26.0, *) else {
            window.contentView = web
            return
        }
        let content = NSView(frame: window.contentLayoutRect)
        web.frame = content.bounds
        web.autoresizingMask = [.width, .height]
        content.addSubview(web)
        window.contentView = content

        let toolbar = LiquidGlassToolbar { [weak self] action, value in
            self?.handleGlassAction(action, value)
        }
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.isHidden = true
        content.addSubview(toolbar, positioned: .above, relativeTo: web)
        NSLayoutConstraint.activate([
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            toolbar.widthAnchor.constraint(equalToConstant: 300),
            toolbar.heightAnchor.constraint(equalToConstant: 44)
        ])
        glassView = toolbar
    }

    func addLiquidGlassMenuItem(to menu: NSMenu) {
        let item = menu.addItem(withTitle: "Use Liquid Glass", action: #selector(toggleLiquidGlass), keyEquivalent: "")
        item.target = self
        item.state = liquidGlassEnabled ? .on : .off
        glassMenuItem = item
    }

    @objc private func toggleLiquidGlass() { setLiquidGlassEnabled(!liquidGlassEnabled) }

    func setLiquidGlassEnabled(_ enabled: Bool, focusAppearance: Bool = false) {
        let previousTheme = catalogThemes.effectiveTheme
        if enabled && supportsNativeGlassToolbar && !liquidGlassEnabled && focusAppearance { glassFocusOnReturn = "appearance" }
        UserDefaults.standard.set(enabled, forKey: "catalogLiquidGlass")
        let restoreStandard = !enabled && previousTheme == CatalogThemePreferences.exclusive
        setCatalogTheme(restoreStandard ? catalogThemes.lastStandardTheme : previousTheme)
        glassMenuItem?.state = enabled ? .on : .off
        if !enabled {
            if let responder = window?.firstResponder as? NSView, let glass = glassView,
               responder.isDescendant(of: glass) {
                window.makeFirstResponder(web)
            }
            glassView?.isHidden = true
            glassFocusOnReturn = nil
        }
        syncLiquidGlassPage()
    }

    func setCatalogZoom(_ zoom: CGFloat) {
        web.pageZoom = zoom
        updateGlassPointSize()
    }

    private func updateGlassPointSize() {
        guard supportsNativeGlassToolbar, let web = web else { return }
        // The toolbar is measured in AppKit points and the catalog in CSS pixels.
        let points = 1 / web.pageZoom
        web.evaluateJavaScript("document.documentElement.style.setProperty('--mac-glass-point','\(points)px')", completionHandler: nil)
    }

    @objc private func glassDisplayOptionsDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.syncGlassAccessibility() }
    }

    private func syncGlassAccessibility() {
        let workspace = NSWorkspace.shared
        web?.evaluateJavaScript("""
            document.documentElement.dataset.glassReduceTransparency = '\(workspace.accessibilityDisplayShouldReduceTransparency)';
            document.documentElement.dataset.glassIncreaseContrast = '\(workspace.accessibilityDisplayShouldIncreaseContrast)';
            """, completionHandler: nil)
    }

    func syncLiquidGlassPage() {
        updateGlassPointSize()
        syncGlassAccessibility()
        // A reloaded document can start with the preferences from its first
        // navigation. Reconcile with the live menu before showing the toolbar.
        let choices = javascriptJSON([catalogThemes.effectiveTheme, glassWallpapers.wallpaper, glassWallpapers.choice])
        web?.evaluateJavaScript("window.macLiquidGlassEnabled?.(\(liquidGlassEnabled), ...\(choices))", completionHandler: nil)
    }

    private func handleGlassAction(_ action: String, _ value: String?) {
        guard liquidGlassEnabled else { return }
        if action == "liquidGlass" {
            setLiquidGlassEnabled(false)
            return
        }
        if action == "theme" {
            if let value, setCatalogTheme(value) { syncLiquidGlassPage() }
            return
        }
        if action == "wallpaper" {
            if let value, setCatalogGlassWallpaper(value) { syncLiquidGlassPage() }
            return
        }
        if ["library", "plex", "updates"].contains(action) {
            glassFocusOnReturn = action
            window.makeFirstResponder(web)
        }
        let args = javascriptJSON([action, value ?? ""])
        web.evaluateJavaScript("window.macGlassAction?.(...\(args))", completionHandler: nil)
    }

    func updateGlassChrome(_ state: [String: Any]) {
        guard #available(macOS 26.0, *), liquidGlassEnabled,
              let toolbar = glassView as? LiquidGlassToolbar,
              let visible = state["visible"] as? Bool, let theme = state["theme"] as? String,
              theme == catalogThemes.effectiveTheme,
              let logo = state["logo"] as? String, let picture = state["picture"] as? String else { return }
        toolbar.update(theme: theme, logo: logo, picture: picture,
                       plexConnected: state["plexConnected"] as? Bool ?? false,
                       updatesReady: state["updatesReady"] as? Bool ?? false, wallpaperChoice: glassWallpapers.choice)
        let returning = toolbar.isHidden && visible
        toolbar.isHidden = !visible
        if returning, let action = glassFocusOnReturn {
            glassFocusOnReturn = nil
            toolbar.focusAction(action)
        }
    }
}
