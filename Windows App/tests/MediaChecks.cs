using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ToolDriveOffline
{
    // This fixture exercises the same host message and media resource entry
    // points as WebView2, without a Plex account or a public archive connection.
    static class MediaChecks
    {
        const string Date = "2024-02-03", MediaBase = "https://fixture.plex.direct:32400";
        const long Show = 2024020301, Source = 2765;
        static readonly JavaScriptSerializer json = new JavaScriptSerializer();
        static string Catalog
        {
            get {
                return json.Serialize(new { shows = new[] {
                    new { id = Show, date = Date, venue = "Paycom Center",
                          sources = new[] { new { id = Source, status = "OTD", version = "V.02" } } }
                } });
            }
        }
        static readonly byte[] audio = new byte[] { 73,  68, 51, 4,  0, 0,   0,  0,  0, 0, 255, 251,
                                                    144, 0,  16, 20, 6, 100, 19, 11, 0, 0, 0,   0 };
        static Dictionary<string, object> Body(object o)
        {
            return json.Deserialize<Dictionary<string, object>>(json.Serialize(o));
        }
        static void Check(bool b, string what)
        {
            if (!b)
                throw new Exception(what);
            Console.WriteLine("PASS " + what);
        }
        sealed class Fixture : HttpMessageHandler
        {
            public bool failAudio, breakTransfer, offline;
            public byte[] publicSample;
            public string publicListing;
            public int resources, partRequests;
            static HttpResponseMessage Json(object o)
            {
                return new HttpResponseMessage(HttpStatusCode.OK) {
                    Content = new StringContent(json.Serialize(o), Encoding.UTF8, "application/json")
                };
            }
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage req,
                                                                   CancellationToken token)
            {
                token.ThrowIfCancellationRequested();
                var uri = req.RequestUri;
                string path = uri.AbsolutePath;
                if (offline)
                    throw new HttpRequestException("Offline fixture");
                HttpResponseMessage res;
                if (uri.Host == "plex.tv" && path == "/api/v2/pins")
                {
                    Check(req.Method == HttpMethod.Post, "Create Plex PIN");
                    res = Json(new { id = 21, code = "signed-in-browser" });
                }
                else if (path == "/api/v2/pins/21")
                    res =
                        Json(new { id = 21, code = "signed-in-browser", authToken = "private-account-test" });
                else if (uri.Host == "clients.plex.tv")
                {
                    ++resources;
                    Check(req.Headers.GetValues("X-Plex-Token").Single() == "private-account-test",
                          "Account credential scoped to Plex resources");
                    res =
                        Json(new[] { new { provides = "server", clientIdentifier = "fixture", name = "Music",
                                           accessToken = "private-server-test",
                                           connections = new[] { new { uri = MediaBase, local = true } } } });
                }
                else if (uri.Host == "fixture.plex.direct")
                {
                    Check(req.Headers.GetValues("X-Plex-Token").Single() == "private-server-test" &&
                              uri.Query.IndexOf("private", StringComparison.Ordinal) < 0,
                          "Server credential sent in native header only");
                    if (path == "/library/sections")
                        res = Json(new { MediaContainer = new {
                            Directory = new[] { new { key = "1", type = "artist", title = "Archive" },
                                                new { key = "2", type = "artist", title = "Music" },
                                                new { key = "3", type = "movie", title = "Film" } }
                        } });
                    else if (path == "/library/sections/1/all")
                        res = Json(new { MediaContainer = new {
                            Metadata = new[] { new { type = "album", ratingKey = "99", title = "TOOL " + Date,
                                                     librarySectionID = "1" } }
                        } });
                    else if (path == "/library/metadata/99/children")
                        res = Json(new { MediaContainer = new {
                            Metadata = new[] { new {
                                type = "track", ratingKey = "504", title = "Intro",
                                parentTitle = "TOOL " + Date, grandparentTitle = "TOOL",
                                parentRatingKey = "99", duration = 2000,
                                Media = new[] { new {
                                    Part = new[] { new { key = "/library/parts/543/1/file.mp3",
                                                         file = "Z:/Archive/2024/tool" + Date + ".v2/tool" +
                                                                Date + ".v2.t01.mp3" } }
                                } }
                            } }
                        } });
                    else if (path.StartsWith("/library/parts/"))
                    {
                        partRequests++;
                        Check(req.Headers.Range != null && req.Headers.Range.ToString() == "bytes=2-5",
                              "Plex audio range forwarded");
                        res = new HttpResponseMessage(HttpStatusCode.PartialContent) {
                            Content = new ByteArrayContent(audio.Skip(2).Take(4).ToArray())
                        };
                        res.Content.Headers.ContentRange = new ContentRangeHeaderValue(2, 5, audio.Length);
                    }
                    else
                        throw new Exception("Unexpected fixture path " + path);
                }
                else if (path.EndsWith("/resolve.php"))
                {
                    Check(uri.Query == "?date=" + Date + "&ver=2",
                          "Resolver uses canonical catalog date and V.02");
                    if (publicListing != null)
                        return Task.FromResult(new HttpResponseMessage(
                            HttpStatusCode.OK) { Content = new StringContent(publicListing) });
                    res = Json(new { ok = true, data = new {
                                        tracks = new[] { 1, 2 }
                                                     .Select(i => new { trackNumber = i, title = "Track " + i,
                                                                        durationSeconds = i + 1,
                                                                        url = "/mp3_2.0/2024/tool" + Date +
                                                                              ".v2/tool" + Date + ".v2.t0" +
                                                                              i + ".mp3" })
                                                     .ToArray()
                                    } });
                }
                else if (path == "/data/02-sources.js")
                    res = new HttpResponseMessage(
                        HttpStatusCode.OK) { Content = new StringContent(
                                                 "const SOURCES_DATA = {\"" + Show + "\":[{\"id\":" + Source +
                                                 (",\"driveUrl\":\"https://drive.google.com/drive/folders/" +
                                                  "testfolder123?usp=share\"}]};")) };
                else if (uri.Host == "tooldriveproject.net")
                {
                    if (publicSample != null)
                    {
                        res = new HttpResponseMessage(
                            HttpStatusCode.PartialContent) { Content = new ByteArrayContent(publicSample) };
                        res.Content.Headers.ContentRange =
                            new ContentRangeHeaderValue(0, publicSample.Length - 1, 3080074);
                    }
                    else if (breakTransfer && path.Contains("t02"))
                        res = new HttpResponseMessage(HttpStatusCode.InternalServerError);
                    else
                        res = new HttpResponseMessage(HttpStatusCode.OK) {
                            Content =
                                new ByteArrayContent(failAudio ? Encoding.ASCII.GetBytes("not audio") : audio)
                        };
                }
                else
                    throw new Exception("Unexpected request");
                return Task.FromResult(res);
            }
        }
        static async Task Run(string root)
        {
            var output = new Dictionary<string, Dictionary<string, object>>();
            Action<string, object> emit = (name, data) =>
            {
                var raw = json.Serialize(data);
                Check(!raw.Contains("private-") && !raw.Contains("fixture.plex.direct"),
                      "UI receives only safe state: " + name);
                output[name] = Body(data);
            };
            var handler = new Fixture();
            var service = new WindowsMediaService(root, () => Catalog, emit, handler);
            Func<string, object, Task> send = (channel, p) => service.HandleAsync(channel, Body(p));
            await send("live",
                       new { action = "resolve", showId = Show, sources = new[] { new { id = Source } } });
            string folder = null;
            service.OpenOriginalFolder = (u, id) => folder = u.AbsoluteUri;
            await send("live", new { action = "openDownload", sourceId = Source });
            Check(folder == "https://drive.google.com/drive/folders/testfolder123",
                  "Validated original folder");
            await send("player", new { action = "load", sourceId = Source, showId = Show, request = 1 });
            var player = output["windowsMediaReply"];
            Func<Dictionary<string, object>, Uri> firstUrl = state => new Uri(
                (string)((Dictionary<string, object>)((System.Collections.IList)state["tracks"])[0])["url"]);
            var archiveURL = firstUrl(player);
            var direct = await service.OpenAsync(archiveURL, "GET", null);
            using (direct.Content)
            {
                Check(direct.Status == 200 && direct.Content.ReadByte() == 73,
                      "Archive playback streams audio");
            }
            string h = archiveURL.AbsolutePath.Substring(1);
            await send("player", new { action = "beginTrack", handle = h });
            var held = await service.OpenAsync(archiveURL, "GET", null);
            await send("player", new { action = "seekTrack", handle = h });
            var replacement = await service.OpenAsync(archiveURL, "GET", "bytes=0-");
            Check(held.Content.ReadByte() == -1, "Superseded range streams close on seek");
            await send("player", new { action = "release" });
            Check(replacement.Content.ReadByte() == -1, "Close releases network reader");
            handler.breakTransfer = true;
            await send("download", new { action = "save", showId = Show, sourceId = Source });
            Check((string)output["macDownloadState"]["status"] == "failed" &&
                      Directory.GetDirectories(Path.Combine(root, "Recordings")).Length == 0,
                  "Interrupted download fully rolls back");
            handler.breakTransfer = false;
            handler.failAudio = true;
            await send("download", new { action = "save", showId = Show, sourceId = Source });
            Check((string)output["macDownloadState"]["status"] == "failed", "Invalid audio rejected");
            handler.failAudio = false;
            await send("download", new { action = "save", showId = Show, sourceId = Source });
            Check((string)output["macDownloadState"]["status"] == "complete",
                  "Complete offline recording committed");
            await send("player",
                       new { action = "playLibrary", itemId = Source, request = 2, trackIndex = 1 });
            var offline = await service.OpenAsync(firstUrl(output["windowsMediaReply"]), "GET", "bytes=2-5");
            using (var m = new MemoryStream()) using (offline.Content)
            {
                offline.Content.CopyTo(m);
                Check(offline.Status == 206 && m.ToArray().SequenceEqual(audio.Skip(2).Take(4)),
                      "Offline seeking with correct bytes");
            }
            Check((await service.OpenAsync(archiveURL, "GET", null)).Status == 404, "Old handles revoked");
            var zip = Path.Combine(root, "original.zip");
            using (var z = ZipFile.Open(
                       zip, ZipArchiveMode.Create)) foreach (int n in new[] {
                                                                 10, 2, 1
                                                             }) using (var stream =
                                                                           z.CreateEntry("Original/Track " +
                                                                                         n + ".mp3")
                                                                               .Open())
                stream.Write(audio, 0, audio.Length);
            await service.ImportOriginalAsync(Source, zip);
            string manifest =
                File.ReadAllText(Path.Combine(root, "Recordings", Source.ToString(), "recording.json"));
            Check(manifest.IndexOf("Track 2", StringComparison.Ordinal) <
                      manifest.IndexOf("Track 10", StringComparison.Ordinal),
                  "ZIP import sorted and committed");
            string auth = null;
            service.OpenSignIn = s => auth = s;
            await send("plex", new { action = "connect" });
            Check(auth != null && auth.StartsWith("https://app.plex.tv/auth#?") && !auth.Contains("private-"),
                  "Plex secure browser sign-in");
            Check((string)output["macPlexState"]["status"] == "connected" &&
                      ((System.Collections.IList)output["macPlexState"]["libraries"]).Count == 2,
                  "Only music sections offered");
            await send("plex", new { action = "selectLibrary", libraryId = "1" });
            await send("plex", new { action = "search", query = "Paycom Center" });
            Check(((System.Collections.IList)output["macPlexState"]["matches"]).Count == 1,
                  "Venue search finds exact Plex archive");
            await send("plex", new { action = "play", sourceId = Source, showId = Show, request = 3 });
            var plexURL = firstUrl(output["windowsMediaReply"]);
            var media = await service.OpenAsync(plexURL, "GET", "bytes=2-5");
            using (media.Content)
            {
                Check(media.Status == 206 && handler.partRequests == 1,
                      "Authorized Plex direct playback and seeking");
            }
            Check(!Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(root, "plex-account.bin")))
                       .Contains("private-account-test"),
                  "Credential file does not store plaintext");
            service.Dispose();
            handler = new Fixture();
            service = new WindowsMediaService(root, () => Catalog, emit, handler);
            await send("plex", new { action = "status" });
            Check(handler.resources == 1 && (string)output["macPlexState"]["libraryId"] == "1",
                  "Relaunch restores server, library and account");
            await send("plex", new { action = "disconnect" });
            Check(!File.Exists(Path.Combine(root, "plex-account.bin")), "Disconnect clears credentials");
            handler.offline = true;
            await send("player", new { action = "playLibrary", itemId = Source, request = 4 });
            var saved = await service.OpenAsync(firstUrl(output["windowsMediaReply"]), "GET", null);
            using (saved.Content)
            {
                Check(saved.Status == 200, "Offline playback after relaunch");
            }
            var recyclePolicy = new RecordingRecycleSink();
            Check(recyclePolicy.PreDeleteItem(0, IntPtr.Zero) != 0 &&
                      recyclePolicy.PreDeleteItem(0x80, IntPtr.Zero) == 0,
                  "Permanent deletion refused");
            service.RecycleRecording = (path, owner) =>
            { throw new IOException("Recycle Bin unavailable"); };
            await send("library", new { action = "remove", itemId = Source });
            Check(Directory.Exists(Path.Combine(root, "Recordings", Source.ToString())),
                  "Recycle Bin failure leaves recording available");
            service.RecycleRecording = (path, owner) =>
                Directory.Move(path, Path.Combine(root, "FixtureRecycleBin"));
            await send("library", new { action = "remove", itemId = Source });
            Check(Directory.Exists(Path.Combine(root, "FixtureRecycleBin")) &&
                      !Directory.Exists(Path.Combine(root, "Recordings", Source.ToString())),
                  "Remove moves whole recording to Recycle Bin");
            service.Dispose();
        }
        static async Task Replay(string root, string list, string sample)
        {
            var handler = new Fixture { publicListing = File.ReadAllText(list),
                                        publicSample = File.ReadAllBytes(sample) };
            Dictionary<string, object> queue = null;
            using (var service = new WindowsMediaService(root, () => Catalog,
                                                         (name, data) =>
                                                         {
                                                             if (name == "windowsMediaReply")
                                                                 queue = Body(data);
                                                         },
                                                         handler))
            {
                await service.HandleAsync(
                    "player", Body(new { action = "load", showId = Show, sourceId = Source, request = 1 }));
                var tracks = (System.Collections.IList)queue["tracks"];
                Check(tracks.Count == 17, "Current public archive resolves all 17 tracks");
                var t = (Dictionary<string, object>)tracks[0];
                Check((string)t["title"] == "intro", "Current public titles kept");
                var response = await service.OpenAsync(new Uri((string)t["url"]), "GET", "bytes=0-65535");
                using (var saved = new MemoryStream()) using (response.Content)
                {
                    response.Content.CopyTo(saved);
                    Check(response.Status == 206 && saved.Length == 65536 &&
                              saved.ToArray().SequenceEqual(handler.publicSample),
                          "Current archive MP3 ranged bytes pass through exactly");
                }
            }
        }
        static int Main(string[] args)
        {
            string root =
                Path.Combine(Path.GetTempPath(), "ToolDriveMediaChecks-" + Guid.NewGuid().ToString("N"));
            try
            {
                Run(root).GetAwaiter().GetResult();
                if (args.Length == 2)
                    Replay(root, args[0], args[1]).GetAwaiter().GetResult();
                return 0;
            }
            catch (Exception e)
            {
                Console.Error.WriteLine(e);
                return 1;
            }
            finally
            {
                if (Directory.Exists(root))
                    Directory.Delete(root, true);
            }
        }
    }
}
