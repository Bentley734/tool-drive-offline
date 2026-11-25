using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ToolDriveOffline
{
    internal sealed partial class WindowsMediaService
    {
        sealed class Server
        {
            public string Id, Name, Token;
            public List<Uri> Bases;
            public Uri Working;
        }
        sealed class Section
        {
            public string id { get; set; }
            public string name { get; set; }
        }
        sealed class PlexMatch
        {
            public string Id, Title;
            public int Version;
            public List<MediaTrack> Tracks;
        }
        sealed class Candidate
        {
            public string album, identity;
            public int version;
            public bool hierarchy;
            public MediaTrack track;
        }
        readonly Dictionary<string, Server> servers = new Dictionary<string, Server>();
        List<Section> sections = new List<Section>();
        readonly List<PlexMatch> matches = new List<PlexMatch>();
        Dictionary<string, string> plexPrefs;
        CancellationTokenSource plexJob;
        string account = "", selectedServer = "", selectedSection = "", plexMessage = "", phase = "",
               clientID = "";
        bool initialized, searching, loadingSections;
        string TokenFile
        {
            get {
                return Path.Combine(root, "plex-account.bin");
            }
        }
        string PrefFile
        {
            get {
                return Path.Combine(root, "plex-preferences.json");
            }
        }
        static void Atomic(string path, byte[] bytes)
        {
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.WriteAllBytes(temp, bytes);
                if (File.Exists(path))
                    File.Replace(temp, path, null);
                else
                    File.Move(temp, path);
            }
            finally
            {
                if (File.Exists(temp))
                    File.Delete(temp);
            }
        }
        void SavePrefs()
        {
            Atomic(PrefFile, Encoding.UTF8.GetBytes(Json().Serialize(plexPrefs)));
        }
        string Pref(string k)
        {
            string v;
            return plexPrefs.TryGetValue(k, out v) ? v : "";
        }
        void InitPlex()
        {
            if (initialized)
                return;
            plexPrefs = new Dictionary<string, string>();
            if (File.Exists(PrefFile))
            {
                try
                {
                    plexPrefs = Json().Deserialize<Dictionary<string, string>>(File.ReadAllText(PrefFile)) ??
                                plexPrefs;
                }
                catch (ArgumentException)
                {
                }
                catch (InvalidOperationException)
                {
                }
            }
            clientID = Pref("client");
            Guid id;
            if (!Guid.TryParse(clientID, out id))
            {
                clientID = Guid.NewGuid().ToString();
                plexPrefs["client"] = clientID;
                SavePrefs();
            }
            if (File.Exists(TokenFile))
            {
                try
                {
                    account = Encoding.UTF8.GetString(ProtectedData.Unprotect(
                        File.ReadAllBytes(TokenFile), null, DataProtectionScope.CurrentUser));
                }
                catch (CryptographicException)
                {
                    plexMessage = "Connect Plex again to authorize this Windows account.";
                }
            }
            initialized = true;
        }
        static bool ValidToken(string s)
        {
            return !String.IsNullOrEmpty(s) && s.Length <= 8192 && s.All(c => c >= 33 && c <= 126);
        }
        void PlexState()
        {
            string status = phase == "connecting" ? "connecting"
                            : account.Length > 0  ? "connected"
                            : phase == "error"    ? "error"
                                                  : "disconnected";
            string message = plexMessage;
            if (String.IsNullOrEmpty(message))
                message = account.Length > 0 ? "Connected to Plex."
                                             : "Connect your Plex account to find original recordings.";
            Server server;
            servers.TryGetValue(selectedServer, out server);
            Send("macPlexState", new {
                status, message, searching, loadingLibraries = loadingSections, libraryMessage = "",
                serverId = selectedServer, serverName = server != null ? server.Name : "",
                libraryId = selectedSection,
                servers =
                    servers.Values.OrderBy(s => s.Name)
                        .Select(s => new { id = s.Id, name = s.Name, selected = s.Id == selectedServer })
                        .ToArray(),
                libraries =
                    sections.Select(s => new { s.id, s.name, selected = s.id == selectedSection }).ToArray(),
                matches =
                    matches
                        .Select(m => new { id = m.Id, title = m.Title,
                                           subtitle = m.Tracks.Count + " tracks · archive v" + m.Version,
                                           durationSeconds = m.Tracks.Sum(t => t.durationSeconds ?? 0) })
                        .ToArray()
            });
        }
        HttpRequestMessage PlexRequest(HttpMethod method, Uri uri, string token)
        {
            var req = new HttpRequestMessage(method, uri);
            req.Headers.Add("Accept", "application/json");
            req.Headers.Add("X-Plex-Product", "Tool Drive Offline");
            req.Headers.Add("X-Plex-Version", "2.0.0");
            req.Headers.Add("X-Plex-Platform", "Windows");
            req.Headers.Add("X-Plex-Client-Identifier", clientID);
            req.Headers.Add("X-Plex-Device", "Windows");
            req.Headers.Add("X-Plex-Device-Name", "Tool Drive Offline");
            if (!String.IsNullOrEmpty(token))
                req.Headers.Add("X-Plex-Token", token);
            return req;
        }
        async Task<object> FetchPlex(HttpMethod method, Uri url, string token, CancellationToken ct,
                                     int max = 2 * 1024 * 1024, int seconds = 18)
        {
            var text = await TextAsync(PlexRequest(method, url, token), max, ct, seconds);
            ct.ThrowIfCancellationRequested();
            return Json().DeserializeObject(text);
        }
        async Task Authorize(CancellationToken token)
        {
            phase = "connecting";
            plexMessage = "Complete sign-in in your browser.";
            PlexState();
            var pin = Map(await FetchPlex(HttpMethod.Post, new Uri("https://plex.tv/api/v2/pins?strong=true"),
                                          null, token));
            long id = Num(pin, "id");
            string code = Str(pin, "code");
            if (id <= 0 || !Regex.IsMatch(code, @"^[a-zA-Z0-9_-]{1,200}\z"))
                throw Problem("Plex returned an invalid sign-in code.");
            OpenSignIn("https://app.plex.tv/auth#?clientID=" + Uri.EscapeDataString(clientID) +
                       "&code=" + Uri.EscapeDataString(code) +
                       "&context%5Bdevice%5D%5Bproduct%5D=Tool%20Drive%20Offline");
            DateTime expires = DateTime.UtcNow.AddMinutes(5);
            while (DateTime.UtcNow < expires)
            {
                await Task.Delay(3000, token);
                var result = Map(await FetchPlex(HttpMethod.Get, new Uri("https://plex.tv/api/v2/pins/" + id),
                                                 null, token));
                var secret = Str(result, "authToken");
                if (String.IsNullOrEmpty(secret))
                    continue;
                if (!ValidToken(secret))
                    throw Problem("Plex returned an invalid credential.");
                token.ThrowIfCancellationRequested();
                Atomic(TokenFile, ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), null,
                                                        DataProtectionScope.CurrentUser));
                account = secret;
                phase = "";
                await LoadServers(token);
                return;
            }
            throw Problem("The Plex sign-in request expired. Choose Connect to retry.");
        }
        static Uri SecureBase(string raw)
        {
            Uri uri;
            if (raw.Length > 2048 || !Uri.TryCreate(raw, UriKind.Absolute, out uri) ||
                uri.Scheme != "https" ||
                !(uri.Host.Equals("plex.direct", StringComparison.OrdinalIgnoreCase) ||
                  uri.Host.EndsWith(".plex.direct", StringComparison.OrdinalIgnoreCase)) ||
                uri.UserInfo != "" || uri.AbsolutePath != "/" || uri.Query != "" || uri.Fragment != "")
                return null;
            return uri;
        }
        async Task LoadServers(CancellationToken token)
        {
            if (!ValidToken(account))
                throw Problem("Connect Plex first.");
            plexMessage = "Finding Plex servers…";
            PlexState();
            var entries = Rows(await FetchPlex(
                HttpMethod.Get,
                new Uri(
                    "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"),
                account, token));
            var fresh = new Dictionary<string, Server>();
            foreach (var row in entries.Take(100))
            {
                string id = Str(row, "clientIdentifier"), secret = Str(row, "accessToken");
                if (!Str(row, "provides").Split(',').Any(x => x.Trim() == "server") || !ValidToken(secret) ||
                    !Regex.IsMatch(id, @"^[A-Za-z0-9._-]{1,200}\z"))
                    continue;
                var uris = Rows(Get(row, "connections"))
                               .Take(32)
                               .OrderBy(r => Object.Equals(Get(r, "relay"), true)   ? 2
                                             : Object.Equals(Get(r, "local"), true) ? 0
                                                                                    : 1)
                               .Select(r => SecureBase(Str(r, "uri")))
                               .Where(u => u != null)
                               .Distinct()
                               .ToList();
                if (uris.Count > 0)
                    fresh[id] = new Server { Id = id, Name = Str(row, "name"), Token = secret, Bases = uris };
            }
            token.ThrowIfCancellationRequested();
            servers.Clear();
            foreach (var kv in fresh)
                servers[kv.Key] = kv.Value;
            selectedServer = servers.ContainsKey(Pref("server"))
                                 ? Pref("server")
                                 : servers.Keys.OrderBy(k => k).FirstOrDefault() ?? "";
            sections.Clear();
            matches.Clear();
            selectedSection = "";
            phase = "";
            if (servers.Count == 0)
            {
                plexMessage = "No secure Plex Media Server is available for this account.";
                PlexState();
                return;
            }
            await LoadSections(token);
        }
        async Task<T> WithServer<T>(Server server, Func<Uri, Task<T>> attempt, CancellationToken token)
        {
            foreach (Uri uri in server.Bases.OrderBy(b => b == server.Working ? 0 : 1))
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var value = await attempt(uri);
                    token.ThrowIfCancellationRequested();
                    server.Working = uri;
                    return value;
                }
                catch (HttpRequestException)
                {
                }
                catch (OperationCanceledException)
                {
                    token.ThrowIfCancellationRequested();
                }
                catch (InvalidDataException e)
                {
                    if (!e.Message.StartsWith("The service returned HTTP ", StringComparison.Ordinal))
                        throw;
                }
            }
            throw Problem("Could not reach the selected Plex server over a secure connection.");
        }
        async Task LoadSections(CancellationToken token)
        {
            Server server;
            if (!servers.TryGetValue(selectedServer, out server))
                throw Problem("Choose a Plex server first.");
            loadingSections = true;
            plexMessage = "Finding music libraries…";
            PlexState();
            var list = await WithServer(
                server,
                async uri =>
                {
                    var container =
                        Map(Get(Map(await FetchPlex(HttpMethod.Get, new Uri(uri, "/library/sections"),
                                                    server.Token, token, 2 * 1024 * 1024, 8)),
                                "MediaContainer"));
                    return Rows(Get(container, "Directory"))
                        .Where(r => Str(r, "type") == "artist" &&
                                    Regex.IsMatch(Str(r, "key"), @"^[1-9]\d{0,18}\z"))
                        .Select(r => new Section { id = Str(r, "key"), name = Str(r, "title") })
                        .OrderBy(s => s.name)
                        .ToList();
                },
                token);
            token.ThrowIfCancellationRequested();
            sections = list;
            var previous = Pref("library." + server.Id);
            selectedSection = list.Any(s => s.id == previous) ? previous : list.Count == 1 ? list[0].id : "";
            loadingSections = false;
            plexMessage = list.Count == 0         ? "No music libraries found on this server."
                          : selectedSection == "" ? "Choose a music library."
                                                  : "Connected to your music library.";
            PlexState();
        }
        static IEnumerable<Dictionary<string, object>> Metadata(object result, string section)
        {
            var c = Map(Get(Map(result), "MediaContainer"));
            Func<Dictionary<string, object>, bool> belongs = r =>
                !r.ContainsKey("librarySectionID") || Str(r, "librarySectionID") == section;
            if (!belongs(c))
                return Enumerable.Empty<Dictionary<string, object>>();
            return Rows(Get(c, "Metadata"))
                .Concat(Rows(Get(c, "Hub")).Where(belongs).SelectMany(h => Rows(Get(h, "Metadata"))))
                .Where(belongs)
                .Take(2000);
        }
        static bool PartPath(string key)
        {
            if (String.IsNullOrEmpty(key) || key.Length > 2048 ||
                !Regex.IsMatch(key, @"^/library/parts/[0-9]{1,20}/") ||
                key.IndexOfAny(new[] { '\\', '?', '#' }) >= 0)
                return false;
            string d = Uri.UnescapeDataString(key);
            return !d.Contains("\\") && !d.Contains("//") && !d.Contains("%") &&
                   !d.Split('/').Any(x => x == "." || x == "..");
        }
        static List<Candidate> Candidates(IEnumerable<Dictionary<string, object>> rows, string date,
                                          int? version, Uri baseUri, string secret)
        {
            var pattern =
                new Regex("^tool" + Regex.Escape(date) + @"\.v(\d{1,3})\.t(\d{1,3})(\.[a-z0-9]{2,8})\z",
                          RegexOptions.IgnoreCase);
            var result = new List<Candidate>();
            foreach (var r in rows.Where(r => Str(r, "type") == "track"))
            {
                var identity = Str(r, "ratingKey");
                var title = Str(r, "title");
                var album = Str(r, "parentTitle");
                if (!Regex.IsMatch(identity, @"^\d{1,20}\z") || String.IsNullOrWhiteSpace(title))
                    continue;
                bool tagged = album.Contains(date) &&
                              new[] { "grandparentTitle", "originalTitle", "artist" }.Any(
                                  k => String.Equals(Str(r, k), "TOOL", StringComparison.OrdinalIgnoreCase));
                foreach (var item in Rows(Get(r, "Media"))
                             .Take(16)
                             .SelectMany(media =>
                                             Rows(Get(media, "Part"))
                                                 .Take(16)
                                                 .Select(part => new {
                                                     part, codec = Str(media, "audioCodec").ToLowerInvariant()
                                                 })))
                {
                    var part = item.part;
                    string key = Str(part, "key");
                    if (!PartPath(key))
                        continue;
                    string[] components = Str(part, "file").Replace('\\', '/').Split('/');
                    Match m = pattern.Match(components.Last());
                    if (!m.Success)
                        continue;
                    int ver = Int32.Parse(m.Groups[1].Value), number = Int32.Parse(m.Groups[2].Value);
                    string mime;
                    if (number < 1 || (version.HasValue && ver != version) ||
                        !Types.TryGetValue(m.Groups[3].Value, out mime))
                        continue;
                    bool hierarchy = components.Length >= 3 &&
                                     components[components.Length - 3] == date.Substring(0, 4) &&
                                     String.Equals(components[components.Length - 2],
                                                   "tool" + date + ".v" + m.Groups[1].Value,
                                                   StringComparison.OrdinalIgnoreCase);
                    if (!tagged && !hierarchy)
                        continue;
                    result.Add(new Candidate {
                        album = Str(r, "parentRatingKey") + "|" + album, identity = identity, version = ver,
                        hierarchy = hierarchy,
                        track = new MediaTrack { number = number, title = title, mime = mime,
                                                 durationSeconds = Num(r, "duration") > 0
                                                                       ? (double?)Num(r, "duration") / 1000
                                                                       : null,
                                                 remote = new Uri(baseUri, key), token = secret,
                                                 directMp4 = mime == "audio/mp4" &&
                                                             new[] { "aac", "mp3", "flac", "opus" }.Contains(
                                                                 item.codec) }
                    });
                    break;
                }
            }
            return result;
        }
        static PlexMatch Best(List<Candidate> c, string date)
        {
            var choice = c.GroupBy(x => new { x.album, x.version })
                             .Select(g => g.GroupBy(x => x.identity).Select(group => group.First()).ToList())
                             .Where(g => g.Count > 0 && g.Count <= 250 &&
                                         g.Select(x => x.track.number).Distinct().Count() == g.Count)
                             .OrderByDescending(g => g.Count(x => x.hierarchy))
                             .ThenByDescending(g => g.Count)
                             .ThenBy(g => g[0].version)
                             .FirstOrDefault();
            if (choice == null)
                return null;
            return new PlexMatch { Id = Guid.NewGuid().ToString("N"),
                                   Title = "TOOL " + date + " · v" + choice[0].version,
                                   Version = choice[0].version,
                                   Tracks =
                                       choice.OrderBy(x => x.track.number).Select(x => x.track).ToList() };
        }
        async Task<PlexMatch> FindPlex(string date, int? version, CancellationToken ct)
        {
            Server server;
            string section = selectedSection;
            if (!servers.TryGetValue(selectedServer, out server) || !sections.Any(s => s.id == section))
                throw Problem("Choose a Plex server and music library first.");
            return await WithServer(
                server,
                async uri =>
                {
                    Func<string, Task<object>> get = path =>
                        FetchPlex(HttpMethod.Get, new Uri(uri, path), server.Token, ct, 8 * 1024 * 1024, 12);
                    var pathPrefix = "/library/sections/" + section + "/all?title=" + date;
                    var albums = Metadata(await get(pathPrefix + "&type=9&limit=100"), section);
                    var ids = albums.Where(r => Str(r, "type") == "album" && Str(r, "title").Contains(date))
                                  .Select(r => Str(r, "ratingKey"))
                                  .Where(k => Regex.IsMatch(k, @"^\d{1,20}\z"))
                                  .Distinct()
                                  .Take(24);
                    var all = new List<Candidate>();
                    foreach (string id in ids)
                        all.AddRange(
                            Candidates(Metadata(await get("/library/metadata/" + id + "/children"), section),
                                       date, version, uri, server.Token));
                    var result = Best(all, date);
                    if (result == null)
                    {
                        all.AddRange(
                            Candidates(Metadata(await get(pathPrefix + "&type=10&limit=500"), section),
                                       date, version, uri, server.Token));
                        result = Best(all, date);
                    }
                    if (result == null)
                        throw Problem("Plex did not find the exact TOOL recording for " + date +
                                      (version.HasValue ? " v" + version : "") + ".");
                    return result;
                },
                ct);
        }
        void ClearPlexPlayback()
        {
            lock (handles) if (handles.Values.Any(track => track.token != null)) ReleaseHandles();
        }
        async Task PlexAction(Dictionary<string, object> p, long request)
        {
            bool first = !initialized;
            InitPlex();
            string action = Str(p, "action");
            if (action == "status" && !(first && account.Length > 0))
            {
                PlexState();
                return;
            }
            if (plexJob != null)
                plexJob.Cancel();
            var job = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token);
            plexJob = job;
            var token = job.Token;
            try
            {
                searching = false;
                loadingSections = false;
                phase = "";
                if (action == "disconnect")
                {
                    if (File.Exists(TokenFile))
                        File.Delete(TokenFile);
                    account = "";
                    selectedServer = selectedSection = "";
                    servers.Clear();
                    sections.Clear();
                    matches.Clear();
                    ClearPlexPlayback();
                    var client = clientID;
                    plexPrefs.Clear();
                    plexPrefs["client"] = client;
                    SavePrefs();
                    plexMessage = "Plex disconnected.";
                    PlexState();
                }
                else if (action == "connect")
                    await Authorize(token);
                else if (action == "status" || action == "servers")
                    await LoadServers(token);
                else if (action == "selectServer")
                {
                    var id = Str(p, "serverId");
                    if (!servers.ContainsKey(id))
                        throw Problem("Choose a Plex server from the list.");
                    selectedServer = id;
                    selectedSection = "";
                    sections.Clear();
                    matches.Clear();
                    ClearPlexPlayback();
                    plexPrefs["server"] = id;
                    SavePrefs();
                    await LoadSections(token);
                }
                else if (action == "refreshLibraries")
                    await LoadSections(token);
                else if (action == "selectLibrary")
                {
                    var id = Str(p, "libraryId");
                    if (!sections.Any(s => s.id == id))
                        throw Problem("Choose an available music library.");
                    selectedSection = id;
                    matches.Clear();
                    ClearPlexPlayback();
                    plexPrefs["library." + selectedServer] = id;
                    SavePrefs();
                    plexMessage = "Connected to your music library.";
                    PlexState();
                }
                else if (action == "playMatch")
                {
                    var match = matches.FirstOrDefault(x => x.Id == Str(p, "matchId"));
                    if (match == null)
                        throw Problem("Search again to play this recording.");
                    Queue(request, match.Title, "plex", match.Tracks, 0);
                }
                else if (action == "play" || action == "search")
                {
                    string date;
                    int? version;
                    if (action == "play")
                    {
                        var s = Source(Num(p, "sourceId"), Num(p, "showId"));
                        date = s.date;
                        version = s.version;
                    }
                    else
                    {
                        string query = Str(p, "query").Trim();
                        if (query.Length < 1 || query.Length > 300)
                            throw Problem("Enter a date or venue.");
                        var dateMatch = Regex.Match(query, @"\d{4}-\d{2}-\d{2}");
                        date = dateMatch.Value;
                        if (!ValidDate(date))
                        {
                            RefreshCatalog();
                            var dates =
                                shows.Values
                                    .Where(s => String
                                                    .Join(" ", new[] { "venue", "city", "state", "country" }
                                                                   .Select(k => Str(s, k)))
                                                    .IndexOf(query, StringComparison.OrdinalIgnoreCase) >= 0)
                                    .Select(s => Str(s, "date"))
                                    .Distinct()
                                    .Take(2)
                                    .ToList();
                            date = dates.Count == 1 ? dates[0] : "";
                        }
                        if (!ValidDate(date))
                            throw Problem(
                                "Enter a show date (YYYY-MM-DD) or a venue that identifies one show.");
                        var v = Regex.Match(query, @"(?:\.v|\bv\.?|version\s*)(\d{1,3})",
                                            RegexOptions.IgnoreCase);
                        version = v.Success ? (int?)Int32.Parse(v.Groups[1].Value) : null;
                    }
                    searching = true;
                    plexMessage = "Searching your Plex music library…";
                    PlexState();
                    var match = await FindPlex(date, version, token);
                    token.ThrowIfCancellationRequested();
                    matches.Insert(0, match);
                    if (matches.Count > 20)
                        matches.RemoveAt(20);
                    searching = false;
                    plexMessage = "Found the exact archive recording.";
                    PlexState();
                    if (action == "play")
                        Queue(request, match.Title, "plex", match.Tracks, 0);
                }
            }
            catch (OperationCanceledException)
            {
                if (!job.IsCancellationRequested)
                    throw;
            }
            catch (Exception)
            {
                if (job.IsCancellationRequested)
                    return;
                phase = "error";
                loadingSections = searching = false;
                throw;
            }
            finally
            {
                if (plexJob == job)
                    plexJob = null;
                job.Dispose();
            }
        }
    }
}
