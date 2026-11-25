import AppKit
import ImageIO

/// The native pull-down button handles pointer, accessibility and keyboard input.
private final class GlassMenuSymbol: NSView {
    var image: NSImage?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

private final class GlassNavigationButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

private final class GlassAppearanceButton: NSPopUpButton {
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
}

/// The window overlays this view on the web header only while native glass is enabled.
@available(macOS 26.0, *)
final class LiquidGlassToolbar: NSView, NSMenuDelegate {
    private let onAction: (String, String?) -> Void
    private let glass = NSGlassEffectView()
    private let controls = NSView()
    private let divider = NSBox()
    private let appearanceButton = GlassAppearanceButton(frame: .zero, pullsDown: true)
    private let menuSymbol = GlassMenuSymbol()
    private let library = GlassNavigationButton()
    private let plex = GlassNavigationButton()
    private let updates = GlassNavigationButton()
    private var choiceItems: [String: [NSMenuItem]] = [:]
    private var pictureSection: NSMenuItem!
    private var wallpaperSection: NSMenuItem!
    private var loadedWallpaperThumbnails = false
    private var compact = false

    override var intrinsicContentSize: NSSize { NSSize(width: 300, height: 44) }

    init(onAction: @escaping (String, String?) -> Void) {
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44))
        appearance = NSAppearance(named: .darkAqua)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        glass.style = .regular
        glass.cornerRadius = 22
        addSubview(glass)
        controls.frame = bounds
        controls.autoresizingMask = [.width, .height]
        controls.wantsLayer = true
        controls.layer?.cornerCurve = .continuous
        glass.contentView = controls
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Catalog toolbar")

        configure(library, name: "Library", action: "library", symbol: "books.vertical")
        configure(plex, name: "Plex", action: "plex", symbol: "server.rack")
        configure(updates, name: "Updates", action: "updates", symbol: "arrow.triangle.2.circlepath")
        divider.boxType = .separator
        divider.setAccessibilityElement(false)
        controls.addSubview(divider)
        configureAppearanceMenu()

        update(theme: "front-row", logo: "classic", picture: "blue-silhouette", plexConnected: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(onAction:)") }

    private func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [.labelColor])))
    }

    private func configure(_ button: NSButton, name: String, action: String, symbol: String) {
        button.identifier = NSUserInterfaceItemIdentifier(action)
        button.title = name
        button.image = image(symbol)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.imageScaling = .scaleProportionallyDown
        let type = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        button.font = type
        button.attributedTitle = NSAttributedString(string: name,
            attributes: [.font: type, .foregroundColor: NSColor.labelColor])
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.showsBorderOnlyWhileMouseInside = true
        button.target = self
        button.action = #selector(navigate(_:))
        button.focusRingType = .exterior
        button.toolTip = name
        button.setAccessibilityLabel(name)
        controls.addSubview(button)
    }

    private func configureAppearanceMenu() {
        appearanceButton.identifier = NSUserInterfaceItemIdentifier("appearance")
        appearanceButton.bezelStyle = .accessoryBarAction
        appearanceButton.showsBorderOnlyWhileMouseInside = true
        appearanceButton.imagePosition = .noImage
        (appearanceButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        appearanceButton.focusRingType = .exterior
        appearanceButton.toolTip = "Appearance"
        appearanceButton.setAccessibilityLabel("Appearance")
        let menu = NSMenu(title: "Appearance")
        menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        addChoices("Theme", action: "theme", choices: [
            ("front-row", "Front Row"), ("night-shift", "Night Shift"),
            ("graphite", "Graphite"), ("laser-grid", "Laser Grid"), ("liquid-glass", "Liquid Glass")
        ], to: menu)
        addChoices("Logo", action: "logo", choices: [("classic", "Classic"), ("2006", "2006")], to: menu)
        pictureSection = addChoices("Front Row Picture", action: "picture", choices: [
            ("blue-silhouette", "Blue Silhouette"), ("governors-ball", "Governors Ball")
        ], to: menu)
        let photographs = GlassWallpaper.choices.map { ($0.id, $0.title) }
        wallpaperSection = addChoices("Wallpaper", action: "wallpaper",
                                      choices: photographs + [(GlassWallpaperPreferences.shuffle, "Shuffle")], to: menu)
        if let wallpapers = wallpaperSection.submenu, let shuffle = wallpapers.items.last {
            wallpapers.insertItem(.separator(), at: photographs.count)
            shuffle.image = image("shuffle")
            shuffle.toolTip = "Choose a different concert photo each time you open the app."
        }
        wallpaperSection.submenu?.delegate = self
        menu.addItem(.separator())
        let glassItem = NSMenuItem(title: "Liquid Glass", action: #selector(disableGlass), keyEquivalent: "")
        glassItem.target = self
        glassItem.state = .on
        menu.addItem(glassItem)
        appearanceButton.menu = menu
        appearanceButton.synchronizeTitleAndSelectedItem()
        controls.addSubview(appearanceButton)
        // A pull-down's empty first item keeps its title out of the capsule.
        // Draw its permanent symbol independently of the selected menu item.
        menuSymbol.image = image("slider.horizontal.3")
        menuSymbol.setAccessibilityElement(false)
        menuSymbol.setAccessibilityHidden(true)
        controls.addSubview(menuSymbol)
    }

    @discardableResult
    private func addChoices(_ title: String, action: String, choices: [(String, String)],
                            to menu: NSMenu) -> NSMenuItem {
        let section = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let items = NSMenu(title: title)
        for (value, label) in choices {
            let item = NSMenuItem(title: label, action: #selector(selectPreference(_:)), keyEquivalent: "")
            item.target = self
            item.identifier = NSUserInterfaceItemIdentifier(action)
            item.representedObject = value
            items.addItem(item)
        }
        choiceItems[action] = items.items
        section.submenu = items
        menu.addItem(section)
        return section
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === wallpaperSection.submenu, !loadedWallpaperThumbnails else { return }
        loadedWallpaperThumbnails = true
        for (item, wallpaper) in zip(menu.items, GlassWallpaper.choices) {
            item.image = Self.wallpaperThumbnail(wallpaper)
        }
    }

    private static func wallpaperThumbnail(_ wallpaper: GlassWallpaper) -> NSImage? {
        guard let url = Bundle.main.url(forResource: wallpaper.file, withExtension: nil, subdirectory: "Wallpapers"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: 96]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height))
        return NSImage(size: NSSize(width: 32, height: 20), flipped: false) { bounds in
            let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
            let w = image.size.width * scale, h = image.size.height * scale
            let destination = NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
            NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).addClip()
            image.draw(in: destination)
            return true
        }
    }

    func update(theme: String, logo: String, picture: String, plexConnected: Bool, updatesReady: Bool = false,
                wallpaperChoice: String = GlassWallpaper.defaultID) {
        // Keep bright concert lights legible through the real glass material.
        // This translucent backing affects the content plane only; the outer
        // glass still supplies the live backdrop, highlights and refracted rim.
        let shade: CGFloat
        switch theme {
        case "night-shift":
            glass.tintColor = NSColor.systemOrange.withAlphaComponent(0.055)
            shade = 0.08
        case "laser-grid":
            glass.tintColor = NSColor.systemTeal.withAlphaComponent(0.065)
            shade = 0.48
        case "liquid-glass":
            glass.tintColor = NSColor.systemIndigo.withAlphaComponent(0.065)
            shade = 0.40
        case "front-row":
            glass.tintColor = nil
            shade = 0.28
        default:
            glass.tintColor = nil
            shade = 0.08
        }
        controls.layer?.backgroundColor = NSColor.black.withAlphaComponent(shade).cgColor
        for (key, value) in [("theme", theme), ("logo", logo), ("picture", picture), ("wallpaper", wallpaperChoice)] {
            for item in choiceItems[key] ?? [] {
                item.state = (item.representedObject as? String) == value ? .on : .off
            }
        }
        pictureSection.isHidden = theme != "front-row"
        wallpaperSection.isHidden = theme != CatalogThemePreferences.exclusive || GlassWallpaper.choices.isEmpty
        plex.image = image(plexConnected ? "checkmark.circle.fill" : "server.rack")
        plex.toolTip = plexConnected ? "Plex is connected" : "Plex"
        plex.setAccessibilityHelp(plex.toolTip)
        updates.image = image(updatesReady ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
        updates.toolTip = updatesReady ? "Update ready" : "Updates"
        updates.setAccessibilityLabel(updatesReady ? "Updates, update ready" : "Updates")
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        glass.frame = bounds
        controls.frame = glass.bounds
        controls.layer?.cornerRadius = h * 0.5
        let isCompact = w < 270
        if compact != isCompact {
            compact = isCompact
            for button in [library, plex, updates] {
                button.imagePosition = compact ? .imageOnly : .imageLeading
            }
        }
        let inset: CGFloat = 6
        let menuWidth: CGFloat = min(41, w * 0.22)
        let navWidth = max(0, w - 2 * inset - menuWidth - 6)
        let height = max(0, min(32, h - 8))
        let y = (h - height) * 0.5
        var x = inset
        for (button, share) in [(library, 0.36), (plex, 0.28), (updates, 0.36)] {
            let width = navWidth * share
            button.frame = NSRect(x: x, y: y, width: width, height: height).integral
            x += width
        }
        divider.frame = NSRect(x: x + 2, y: (h - 16) * 0.5, width: 1, height: 16).integral
        appearanceButton.frame = NSRect(x: w - inset - menuWidth, y: y, width: menuWidth, height: height).integral
        menuSymbol.frame = NSRect(x: appearanceButton.frame.midX - 9, y: h * 0.5 - 9, width: 18, height: 18).integral
        glass.cornerRadius = h * 0.5
        if window != nil, library.nextKeyView !== plex {
            library.nextKeyView = plex
            plex.nextKeyView = updates
            updates.nextKeyView = appearanceButton
        }
    }

    func focusAction(_ action: String) {
        let target: NSView?
        switch action {
        case "library": target = library
        case "plex": target = plex
        case "updates": target = updates
        case "appearance": target = appearanceButton
        default: target = nil
        }
        if let target { window?.makeFirstResponder(target) }
    }

    @objc private func navigate(_ sender: NSButton) {
        if let action = sender.identifier?.rawValue { onAction(action, nil) }
    }

    @objc private func selectPreference(_ sender: NSMenuItem) {
        guard let action = sender.identifier?.rawValue, let value = sender.representedObject as? String else { return }
        onAction(action, value)
    }

    @objc private func disableGlass() { onAction("liquidGlass", "off") }
}
