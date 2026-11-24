import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let scratch = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
func require(_ condition: Bool, _ message: String) throws { if !condition { throw UpdateError(message) } }
func rejects(_ message: String, _ block: () throws -> Void) throws {
    var rejected = false
    do { try block() } catch { rejected = true }
    try require(rejected, message)
}
let bundled = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("catalog.json"))) as! [String: Any]
try CatalogUpdate.validate(bundled)
try CatalogUpdate.protect(bundled, bundled)
try require(CatalogUpdate.summary(bundled, bundled) == "Your catalog is up to date.", "Unchanged catalog")
var partial = bundled; partial["shows"] = Array((bundled["shows"] as! [[String: Any]]).prefix(30))
try rejects("Reject incomplete snapshot") { try CatalogUpdate.protect(bundled, partial) }
try rejects("Reject malformed constant") { _ = try CatalogUpdate.constant(Data("const SHOWS = [{broken];".utf8), "SHOWS") }
try rejects("Reject executable metadata") { _ = try CatalogUpdate.constant(Data("const SHOWS = alert('bad');".utf8), "SHOWS") }
let escaped = try CatalogUpdate.constant(Data("const SHOWS = [{\"text\":\"bracket } and \\\" quoted\"}];".utf8), "SHOWS") as! [[String: String]]
try require(escaped.count == 1, "Quoted bracket parsing")
try require(!CatalogUpdate.clean("https://example.com/file https://host/x").contains("https"), "URL stripping")
let operation = UpdateOperation(); operation.cancel()
try rejects("Cancellation") { try operation.check() }
func releaseJSON(version: String = "1.5.0", digest: String = "sha256:" + String(repeating: "a", count: 64), url: String? = nil, name: String = AppUpdate.assetName) throws -> Data {
    try CatalogUpdate.serialize(["draft": false,"prerelease":false,"tag_name":"v"+version,"html_url":AppUpdate.repository+"/releases/tag/v"+version,"assets":[["name":name,"digest":digest,"size":100,"browser_download_url":url ?? AppUpdate.repository+"/releases/download/v"+version+"/"+name]]])
}
try require(try AppUpdate.parse(releaseJSON(), current: "1.4.0") != nil, "Accept new release")
try require(try AppUpdate.parse(releaseJSON(version:"1.4.0"), current: "1.4.0") == nil, "Ignore current release")
try rejects("Reject wrong repository") { _ = try AppUpdate.parse(releaseJSON(url:"https://example.com/bad.zip"),current:"1.4.0") }
try rejects("Reject missing digest") { _ = try AppUpdate.parse(releaseJSON(digest:""),current:"1.4.0") }
try rejects("Reject Windows package") { _ = try AppUpdate.parse(releaseJSON(name:"Tool.Drive.Offline.exe"),current:"1.4.0") }
let release = try AppUpdate.parse(releaseJSON(), current:"1.4.0")!
try rejects("Reject corrupted bytes") { try AppUpdate.verify(Data("wrong".utf8),release:release) }
let archive = try Data(contentsOf: root.appendingPathComponent("macOS App/dist/Tool.Drive.Offline.macOS.zip"))
let hash = SHA256.hash(data:archive).map { String(format:"%02x",$0) }.joined()
let buildVersion = try String(contentsOf: root.appendingPathComponent("macOS App/VERSION"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let fixture = MacRelease(version:buildVersion,url:URL(string:"https://example.com")!,digest:hash,size:archive.count)
let candidate = try AppUpdate.stage(archive,release:fixture,directory:scratch.appendingPathComponent("stage"))
try require(FileManager.default.fileExists(atPath:candidate.path), "Verified bundle staging")
try rejects("Reject bundle version mismatch") { _ = try AppUpdate.stage(archive,release:MacRelease(version:"9.0.0",url:fixture.url,digest:hash,size:archive.count),directory:scratch.appendingPathComponent("wrong-version")) }
if CommandLine.arguments.contains("--live") {
    let fetch = UpdateOperation()
    let blobs = try CatalogUpdate.files.map { try fetch.fetch(URL(string:"https://tooldriveproject.net/data/"+$0)!,limit:16*1024*1024) }
    let catalog = try CatalogUpdate.compile(blobs,date:"2026-11-24")
    try CatalogUpdate.validate(catalog); try CatalogUpdate.protect(bundled,catalog)
    for (index,name) in CatalogUpdate.files.enumerated() { try blobs[index].write(to:scratch.appendingPathComponent(name)) }
    try CatalogUpdate.serialize(catalog).write(to:scratch.appendingPathComponent("swift-catalog.json"))
    let metadata = try fetch.fetch(URL(string:"https://api.github.com/repos/Bentley734/tool-drive-offline/releases/latest")!,limit:2*1024*1024)
    _ = try AppUpdate.parse(metadata,current:"1.4.0")
    print("PASS live catalog import and GitHub release check: \(CatalogUpdate.summary(bundled,catalog))")
}
print("PASS catalog validation, partial snapshots, inert parsing, cancellation, release identity, digest rejection, signed bundle staging, wrong-version rejection")
