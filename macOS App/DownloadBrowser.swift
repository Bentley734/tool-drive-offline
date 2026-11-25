import AppKit
import Foundation
import WebKit

@available(macOS 11.3, *)
final class DownloadBrowser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let source: LibrarySourceDescriptor
    let folderURL: URL

    var onProgress: ((LibraryTransferProgress) -> Void)?
    var onCompletion: ((Result<LibraryEntry, Error>) -> Void)?
    var onClose: (() -> Void)?

    private let library: LibraryController
    private var window: NSWindow?
    private var webView: WKWebView?
    private var statusLabel: NSTextField?
    private weak var backButton: NSButton?
    private weak var forwardButton: NSButton?
    private weak var reloadButton: NSButton?
    private weak var safariButton: NSButton?
    private weak var navigationControls: NSStackView?
    private var usesExclusiveGlass = false
    private var activeDownload: WKDownload?
    private var importDirectory: URL?
    private var downloadedFile: URL?
    private var isImporting = false
    private var closeAfterImport = false
    private var outcomeReported = false
    private var didFinishOperation = false
    private var importRetainer: DownloadBrowser?
    private var didClose = false

    init(library: LibraryController, source: LibrarySourceDescriptor, folderURL: URL) throws {
        guard let canonical = LibraryController.approvedDriveFolderURL(folderURL) else {
            throw LibraryError.invalidURL
        }
        self.library = library
        self.source = source
        self.folderURL = canonical
        super.init()
    }

    func show() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.show() }; return }
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsMagnification = true
        web.translatesAutoresizingMaskIntoConstraints = false

        let effect = NSVisualEffectView()
        effect.material = .headerView
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        controls.translatesAutoresizingMaskIntoConstraints = false

        let back = button("Back", action: #selector(goBack), toolTip: "Go back")
        let forward = button("Forward", action: #selector(goForward), toolTip: "Go forward")
        let reload = button("Reload", action: #selector(reload), toolTip: "Reload this folder")
        let safari = button("Open in Safari", action: #selector(openInSafari), toolTip: "Open this approved folder in Safari")
        let done = button("Done", action: #selector(done), toolTip: "Close the download browser")
        let status = NSTextField(labelWithString: "Tool Drive Project · Google Drive")
        status.lineBreakMode = .byTruncatingTail
        status.textColor = .secondaryLabelColor
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)

        [back, forward, reload, status, safari, done].forEach(controls.addArrangedSubview)
        effect.addSubview(controls)

        let root = NSView()
        root.addSubview(effect)
        root.addSubview(web)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: root.topAnchor),
            effect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.topAnchor.constraint(equalTo: effect.topAnchor),
            controls.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            controls.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            web.topAnchor.constraint(equalTo: effect.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let browserWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                     backing: .buffered, defer: false)
        // This controller owns the window and releases it in windowWillClose.
        browserWindow.isReleasedWhenClosed = false
        browserWindow.title = "Download \(source.date) · \(source.version)"
        browserWindow.minSize = NSSize(width: 720, height: 520)
        browserWindow.contentView = root
        browserWindow.delegate = self
        browserWindow.setFrameAutosaveName("ToolDriveDownloadBrowser")
        browserWindow.center()

        window = browserWindow
        webView = web
        statusLabel = status
        backButton = back
        forwardButton = forward
        reloadButton = reload
        safariButton = safari
        navigationControls = controls
        setExclusiveGlass(usesExclusiveGlass)
        updateNavigationButtons()
        web.load(URLRequest(url: folderURL, cachePolicy: .reloadIgnoringLocalCacheData,
                            timeoutInterval: 60))
        browserWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.close() }; return }
        window?.performClose(nil)
    }

    func setExclusiveGlass(_ active: Bool) {
        usesExclusiveGlass = active
        guard #available(macOS 26.0, *), let window, let navigationControls else { return }
        window.setCatalogGlassTitlebar(active)
        for case let button as NSButton in navigationControls.arrangedSubviews {
            button.bezelStyle = active ? .glass : .texturedRounded
        }
    }

    private func button(_ title: String, action: Selector, toolTip: String) -> NSButton {
        let value = NSButton(title: title, target: self, action: action)
        value.bezelStyle = .texturedRounded
        value.toolTip = toolTip
        return value
    }

    @objc private func goBack() { if !isImporting { webView?.goBack() } }
    @objc private func goForward() { if !isImporting { webView?.goForward() } }
    @objc private func reload() { if !isImporting { webView?.reload() } }
    @objc private func openInSafari() { if !isImporting { NSWorkspace.shared.open(folderURL) } }
    @objc private func done() { window?.performClose(nil) }

    private func setStatus(_ value: String) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.setStatus(value) }; return }
        statusLabel?.stringValue = value
    }

    private func updateNavigationButtons() {
        backButton?.isEnabled = !isImporting && webView?.canGoBack == true
        forwardButton?.isEnabled = !isImporting && webView?.canGoForward == true
        reloadButton?.isEnabled = !isImporting
        safariButton?.isEnabled = !isImporting
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isImporting else { return true }
        closeAfterImport = true
        setStatus("Finishing the Library import before closing…")
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        if let download = activeDownload {
            download.delegate = nil
            download.cancel { _ in }
            activeDownload = nil
        }
        if !isImporting { cleanupImportStaging() }
        if !didFinishOperation && !isImporting { reportOutcome(.failure(LibraryError.canceled)) }
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        window = nil
        webView = nil
        onClose?()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !isImporting else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload {
            guard !didFinishOperation, Self.approvedDownloadURL(url), activeDownload == nil else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.download)
            return
        }
        guard Self.approvedBrowserURL(url) else {
            setStatus("Blocked a link outside the approved Google Drive folder browser")
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard !isImporting else { decisionHandler(.cancel); return }
        guard let url = navigationResponse.response.url else { decisionHandler(.cancel); return }
        if !navigationResponse.canShowMIMEType {
            guard !didFinishOperation, Self.approvedDownloadURL(url), activeDownload == nil else {
                decisionHandler(.cancel); return
            }
            decisionHandler(.download)
            return
        }
        guard Self.approvedBrowserURL(url) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavigationButtons()
        if activeDownload == nil && !isImporting { setStatus("Choose a file or folder to download") }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !isImporting else { return }
        updateNavigationButtons()
        setStatus("Couldn’t load the folder: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !isImporting else { return }
        updateNavigationButtons()
        setStatus("Couldn’t open the folder: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        begin(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        begin(download)
    }

    private func begin(_ download: WKDownload) {
        if activeDownload === download { return }
        guard !isImporting, !didFinishOperation, activeDownload == nil else {
            download.cancel { _ in }
            return
        }
        activeDownload = download
        download.delegate = self
        setStatus("Starting download…")
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !isImporting, !didFinishOperation, activeDownload === download,
              response.url.map(Self.approvedDownloadURL) == true,
              response.expectedContentLength == NSURLSessionTransferSizeUnknown ||
                response.expectedContentLength <= LibraryController.maximumArchiveBytes else {
            activeDownload = nil
            completionHandler(nil)
            reportOutcome(.failure(LibraryError.server("The Google Drive download response was not accepted.")))
            return
        }
        do {
            let directory = try library.makeImportStagingDirectory(sourceID: source.sourceID)
            importDirectory = directory
            let suppliedExtension = (suggestedFilename as NSString).pathExtension.lowercased()
            let base = LibraryController.safeFilename((suggestedFilename as NSString).deletingPathExtension,
                                                      fallback: "Tool Drive download")
            let ext = suppliedExtension.isEmpty ? "download" : String(suppliedExtension.prefix(12))
            let name = "\(base).\(ext)"
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            guard Self.isDescendant(destination, of: directory) else { throw LibraryError.invalidURL }
            downloadedFile = destination
            setStatus("Downloading \(name)…")
            completionHandler(destination)
        } catch {
            activeDownload = nil
            cleanupImportStaging()
            setStatus("Couldn’t prepare the download: \(error.localizedDescription)")
            completionHandler(nil)
            reportOutcome(.failure(error))
        }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(request.url.map(Self.approvedDownloadURL) == true ? .allow : .cancel)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard !isImporting, !didFinishOperation, activeDownload === download, let file = downloadedFile else {
            download.cancel { _ in }
            return
        }
        activeDownload = nil
        isImporting = true
        importRetainer = self
        webView?.stopLoading()
        updateNavigationButtons()
        setStatus("Checking and importing the audio…")
        library.importDownloadedFile(file, source: source, progress: { [weak self] value in
            self?.setStatus(value.message)
            // The native browser owns this non-cancellable verification/import phase. Do not
            // publish it through the cancellable direct-download progress bridge.
        }, completion: { result in
            self.isImporting = false
            self.cleanupImportStaging()
            self.didFinishOperation = true
            self.updateNavigationButtons()
            switch result {
            case .success(let entry): self.setStatus("Saved \(entry.tracks.count) tracks to Library")
            case .failure(let error): self.setStatus("Import failed: \(error.localizedDescription)")
            }
            self.reportOutcome(result)
            let shouldClose = self.closeAfterImport
            self.importRetainer = nil
            if shouldClose { self.window?.performClose(nil) }
        })
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard activeDownload === download else { return }
        activeDownload = nil
        cleanupImportStaging()
        let cocoa = error as NSError
        if cocoa.code == NSURLErrorCancelled { setStatus("Download canceled") }
        else { setStatus("Download failed: \(error.localizedDescription)") }
        reportOutcome(.failure(error))
    }

    private func cleanupImportStaging() {
        if let directory = importDirectory { library.discardImportStagingDirectory(directory) }
        importDirectory = nil
        downloadedFile = nil
    }

    private func reportOutcome(_ result: Result<LibraryEntry, Error>) {
        guard !outcomeReported else { return }
        outcomeReported = true
        didFinishOperation = true
        onCompletion?(result)
    }

    private static func approvedBrowserURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "drive.google.com",
              url.user == nil, url.password == nil else { return false }
        return safeWebPath(url.path)
    }

    private static func approvedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return false }
        let approvedHost = host == "drive.google.com" || host == "drive.usercontent.google.com" ||
            host == "googleusercontent.com" || host.hasSuffix(".googleusercontent.com")
        return approvedHost && safeWebPath(url.path)
    }

    private static func safeWebPath(_ path: String) -> Bool {
        guard !path.contains("\\"), !path.contains("\0") else { return false }
        let decoded = path.removingPercentEncoding ?? path
        return !decoded.split(separator: "/", omittingEmptySubsequences: true).contains { $0 == "." || $0 == ".." }
    }

    private static func isDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let base = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/")
    }
}
