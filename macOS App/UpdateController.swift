import AppKit
import WebKit

extension AppDelegate {
    func updateState(_ kind: String, _ text: String, _ button: String = "Check now", busy: Bool = false, ready: Bool = false) {
        let args: [Any] = [kind, text, button, busy, ready]
        guard let data = try? JSONSerialization.data(withJSONObject: args), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.macUpdateState?.(...\(json))", completionHandler: nil)
    }
    func startCatalogUpdate() {
        if let operation = catalogOperation { operation.cancel(); return }
        let operation = UpdateOperation(); catalogOperation = operation
        let previous = activeCatalog
        updateState("catalog", "Checking the published metadata…", "Cancel", busy: true)
        DispatchQueue.global(qos: .utility).async {
            do {
                var blobs = [Data]()
                for file in CatalogUpdate.files {
                    try operation.check()
                    blobs.append(try operation.fetch(URL(string: "https://tooldriveproject.net/data/" + file)!, limit: 16 * 1024 * 1024))
                }
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
                let candidate = try CatalogUpdate.compile(blobs, date: formatter.string(from: Date()))
                try CatalogUpdate.protect(previous, candidate)
                let summary = CatalogUpdate.summary(previous, candidate)
                try operation.check()
                DispatchQueue.main.async {
                    do {
                        try operation.check()
                        try FileManager.default.createDirectory(at: self.dataURL, withIntermediateDirectories: true)
                        let cache: [String: Any] = ["catalog": candidate, "checkedAt": ISO8601DateFormatter().string(from: Date())]
                        try CatalogUpdate.serialize(cache).write(to: self.dataURL.appendingPathComponent("catalog-update.json"), options: .atomic)
                        self.activeCatalog = candidate
                        let json = self.javascriptJSON(candidate)
                        self.web.evaluateJavaScript("window.applyMacCatalog(\(json))") { _, error in
                            self.updateState("catalog", error == nil ? summary + " Checked just now." : "Saved update. Reopen the app to load it.")
                        }
                    } catch { self.updateState("catalog", error.localizedDescription) }
                    self.catalogOperation = nil
                }
            } catch { DispatchQueue.main.async { self.catalogOperation = nil; self.updateState("catalog", error.localizedDescription) } }
        }
    }
    func startAppUpdate() {
        if let operation = appOperation { operation.cancel(); return }
        if stagedApp != nil { restartToUpdate(); return }
        let operation = UpdateOperation(); appOperation = operation
        updateState("app", "Checking GitHub releases…", "Cancel", busy: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.6.0"
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try operation.fetch(URL(string: "https://api.github.com/repos/Bentley734/tool-drive-offline/releases/latest")!, limit: 2 * 1024 * 1024)
                guard let release = try AppUpdate.parse(data, current: version) else {
                    DispatchQueue.main.async { self.appOperation = nil; self.updateState("app", "Version \(version) is up to date.") }; return
                }
                DispatchQueue.main.async { self.updateState("app", "Downloading version \(release.version)…", "Cancel", busy: true) }
                let archive = try operation.fetch(release.url, limit: 128 * 1024 * 1024, redirects: true)
                try operation.check()
                let directory = self.dataURL.appendingPathComponent("AppUpdates/" + UUID().uuidString)
                let candidate = try AppUpdate.stage(archive, release: release, directory: directory)
                let installedTeam = try AppUpdate.team(Bundle.main.bundleURL)
                if let installedTeam = installedTeam, try AppUpdate.team(candidate) != installedTeam { throw UpdateError("The update was signed by a different developer.") }
                try operation.check()
                DispatchQueue.main.async {
                    self.appOperation = nil
                    do {
                        try operation.check()
                        self.stagedApp = candidate
                        self.updateState("app", "Version \(release.version) is verified and ready.", "Restart to update", ready: true)
                    } catch { self.updateState("app", error.localizedDescription) }
                }
            } catch { DispatchQueue.main.async { self.appOperation = nil; self.updateState("app", error.localizedDescription) } }
        }
    }
    func restartToUpdate() {
        guard let candidate = stagedApp else { return }
        do {
            let installed = Bundle.main.bundleURL
            guard !installed.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else { throw UpdateError("Move the app into a writable folder, such as Applications, then check again.") }
            // Copy next to the installed app before quitting, so renames stay on one volume.
            let sibling = installed.deletingLastPathComponent().appendingPathComponent(".ToolDrive-update-" + UUID().uuidString + ".app")
            try FileManager.default.copyItem(at: candidate, to: sibling)
            try AppUpdate.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", sibling.path])
            let helper = dataURL.appendingPathComponent("AppUpdates/install-" + UUID().uuidString + ".sh")
            let script = try String(contentsOf: Bundle.main.url(forResource: "install-update", withExtension: "sh")!, encoding: .utf8)
            let ack = dataURL.appendingPathComponent("AppUpdates/ack-" + UUID().uuidString)
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), installed.path, sibling.path, installed.path + ".previous-" + UUID().uuidString + ".app", dataURL.appendingPathComponent("AppUpdates/install.log").path, ack.path]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); NSApp.terminate(nil)
        } catch { updateState("app", error.localizedDescription, "Restart to update", ready: true) }
    }
    func javascriptJSON(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e").replacingOccurrences(of: "&", with: "\\u0026").replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
