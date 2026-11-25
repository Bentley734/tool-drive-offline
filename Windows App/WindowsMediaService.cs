using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace ToolDriveOffline
{
    internal sealed partial class WindowsMediaService : IDisposable
    {
        readonly string root;
        readonly Func<string> catalogJson;
        readonly Action<string, object> emit;
        readonly HttpClient http;
        readonly CancellationTokenSource shutdown = new CancellationTokenSource();
        readonly Dictionary<long, SourceRef> sources = new Dictionary<long, SourceRef>();
        readonly Dictionary<long, Dictionary<string, object>> shows =
            new Dictionary<long, Dictionary<string, object>>();
        string catalogText;
        Task<Dictionary<long, Uri>> links;
        readonly Dictionary<string, MediaTrack> handles = new Dictionary<string, MediaTrack>();
        readonly Dictionary<long, CancellationTokenSource> transfers =
            new Dictionary<long, CancellationTokenSource>();
        long latestRequest;
        bool disposed;
        internal Action<string> OpenSignIn { get; set; }
        public Action<Uri, long> OpenOriginalFolder { get; set; }

        public WindowsMediaService(string libraryDataRoot, Func<string> catalogJson,
                                   Action<string, object> emit)
            : this(libraryDataRoot, catalogJson, emit,
                   new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        {
        }
        internal WindowsMediaService(string libraryDataRoot, Func<string> catalogJson,
                                     Action<string, object> emit, HttpMessageHandler handler)
        {
            this.OpenSignIn = Launch;
            this.root = Path.GetFullPath(libraryDataRoot);
            this.catalogJson = catalogJson;
            this.emit = emit;
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            http = new HttpClient(handler);
            http.Timeout = Timeout.InfiniteTimeSpan;
            Directory.CreateDirectory(root);
            RecoverLibrary();
        }
        static JavaScriptSerializer Json()
        {
            return new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024, RecursionLimit = 64 };
        }
        static Dictionary<string, object> Map(object o)
        {
            return o as Dictionary<string, object> ?? new Dictionary<string, object>();
        }
        static object Get(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) ? v : null;
        }
        static string Str(Dictionary<string, object> d, string key)
        {
            return Convert.ToString(Get(d, key), CultureInfo.InvariantCulture) ?? "";
        }
        static long Num(Dictionary<string, object> d, string key)
        {
            long n;
            return Int64.TryParse(Str(d, key), out n) ? n : 0;
        }
        static IEnumerable<Dictionary<string, object>> Rows(object o)
        {
            var items = o as IEnumerable;
            return items == null || o is string ? Enumerable.Empty<Dictionary<string, object>>()
                                                : items.Cast<object>().OfType<Dictionary<string, object>>();
        }
        static Exception Problem(string message)
        {
            return new InvalidDataException(message);
        }
        static string Message(Exception e)
        {
            if (e is OperationCanceledException)
                return "The operation was canceled or timed out.";
            return e is InvalidDataException ? e.Message
                                             : "Could not complete the request. Check your connection, " +
                                               "storage, and access, then try again.";
        }
        void Send(string name, object data)
        {
            if (!disposed)
                emit(name, data);
        }
        static async Task<string> ReadText(HttpResponseMessage response, int limit, CancellationToken token)
        {
            if (!response.IsSuccessStatusCode)
                throw Problem("The service returned HTTP " + (int)response.StatusCode + ".");
            if (response.Content.Headers.ContentLength > limit)
                throw Problem("The response exceeded the metadata limit.");
            using (var buffer = new MemoryStream()) using (
                var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
            {
                var bytes = new byte[32768];
                int n;
                while ((n = await stream.ReadAsync(bytes, 0, bytes.Length, token).ConfigureAwait(false)) > 0)
                {
                    if (buffer.Length + n > limit)
                        throw Problem("The response exceeded the metadata limit.");
                    buffer.Write(bytes, 0, n);
                }
                return Encoding.UTF8.GetString(buffer.ToArray());
            }
        }
        async Task<string> TextAsync(HttpRequestMessage req, int limit, CancellationToken token,
                                     int seconds = 25)
        {
            using (req) using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(seconds));
                using (var response =
                           await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                               .ConfigureAwait(false)) return await ReadText(response, limit, timeout.Token)
                    .ConfigureAwait(false);
            }
        }
        internal sealed class SourceRef
        {
            public long showId, sourceId;
            public int version;
            public string date, venue, versionLabel;
            public bool onDrive;
            public string Title
            {
                get {
                    return String.Join(
                        " · ", new[] { date, venue, versionLabel }.Where(s => !String.IsNullOrEmpty(s)));
                }
            }
        }
        internal sealed class MediaTrack
        {
            public int number;
            public string title, localPath, token, mime;
            public double? durationSeconds;
            public Uri remote;
            public bool directMp4;
            public long readerGeneration;
        }
        static bool ValidDate(string value)
        {
            DateTime result;
            return DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                          DateTimeStyles.None, out result);
        }
        void RefreshCatalog()
        {
            string text = catalogJson();
            if (String.Equals(text, catalogText, StringComparison.Ordinal))
                return;
            var parsed = Map(Json().DeserializeObject(text));
            sources.Clear();
            shows.Clear();
            foreach (var s in Rows(Get(parsed, "shows")))
            {
                var showId = Num(s, "id");
                var date = Str(s, "date");
                if (!ValidDate(date))
                    continue;
                shows[showId] = s;
                foreach (var raw in Rows(Get(s, "sources")))
                {
                    Match m = Regex.Match(Str(raw, "version"), @"\d{1,3}");
                    var id = Num(raw, "id");
                    if (id <= 0 || !m.Success)
                        continue;
                    sources[id] =
                        new SourceRef { showId = showId,
                                        sourceId = id,
                                        date = date,
                                        version = Int32.Parse(m.Value, CultureInfo.InvariantCulture),
                                        versionLabel = Str(raw, "version"),
                                        venue = Str(s, "venue"),
                                        onDrive = String.Equals(Str(raw, "status"), "OTD",
                                                                StringComparison.OrdinalIgnoreCase) };
                }
            }
            catalogText = text;
        }
        SourceRef Source(long id, long show = 0)
        {
            RefreshCatalog();
            SourceRef s;
            if (!sources.TryGetValue(id, out s) || (show != 0 && s.showId != show))
                throw Problem("This recording was not found in the catalog.");
            return s;
        }
        internal static List<MediaTrack> ParseTracks(string json, SourceRef s)
        {
            var result = Map(Json().DeserializeObject(json));
            var rows = Rows(Get(Map(Get(result, "data")), "tracks")).ToList();
            if (!Object.Equals(Get(result, "ok"), true) || rows.Count == 0 || rows.Count > 250)
                throw Problem("The archive did not provide a playable track list.");
            var numbers = new HashSet<int>();
            var tracks = new List<MediaTrack>();
            string stem = "tool" + s.date + ".v" + s.version;
            string prefix = "/mp3_2.0/" + s.date.Substring(0, 4) + "/" + stem + "/" + stem + ".t";
            foreach (var row in rows)
            {
                var path = Str(row, "url");
                long num = Num(row, "trackNumber");
                var m = Regex.Match(path, "^" + Regex.Escape(prefix) + @"(\d{1,3})\.mp3\z");
                if (!m.Success || num < 1 || num != Int32.Parse(m.Groups[1].Value) || !numbers.Add((int)num))
                    throw Problem("The archive returned a mismatched track.");
                string t = Str(row, "title");
                if (t.Length > 300)
                    throw Problem("The track title is invalid.");
                double dur;
                tracks.Add(new MediaTrack {
                    number = (int)num, title = t.Trim().Length > 0 ? t.Trim() : "Track " + num,
                    durationSeconds = Double.TryParse(Str(row, "durationSeconds"), NumberStyles.Float,
                                                      CultureInfo.InvariantCulture, out dur) &&
                                              dur >= 0 && dur <= 28800
                                          ? (double?)dur
                                          : null,
                    remote = new Uri("https://tooldriveproject.net" + path), mime = "audio/mpeg"
                });
            }
            return tracks;
        }
        async Task<List<MediaTrack>> Archive(SourceRef source, CancellationToken token)
        {
            if (!source.onDrive)
                throw Problem("This recording is unavailable to stream.");
            var url = "https://tooldriveproject.net/api/stream/resolve.php?date=" + source.date +
                      "&ver=" + source.version;
            return ParseTracks(
                await TextAsync(new HttpRequestMessage(HttpMethod.Get, url), 2 * 1024 * 1024, token), source);
        }
        async Task<Dictionary<long, Uri>> ReadLinks()
        {
            const string url = "https://tooldriveproject.net/data/02-sources.js";
            string text = await TextAsync(new HttpRequestMessage(HttpMethod.Get, url), 16 * 1024 * 1024,
                                          shutdown.Token);
            var m = Regex.Match(text, @"^\s*const\s+SOURCES_DATA\s*=\s*");
            if (!m.Success)
                throw Problem("The archive returned an invalid link index.");
            var data = Map(Json().DeserializeObject(text.Substring(m.Length).Trim().TrimEnd(';')));
            var list = new Dictionary<long, Uri>();
            foreach (var show in data.Values)
                foreach (var source in Rows(show))
                {
                    var raw = Str(source, "driveUrl");
                    Match folder = Regex.Match(
                        raw,
                        @"^https://drive\.google\.com/drive/folders/([a-zA-Z0-9_-]{8,128})/?(?:\?[^#\s]*)?\z",
                        RegexOptions.IgnoreCase);
                    if (folder.Success)
                        list[Num(source, "id")] =
                            new Uri("https://drive.google.com/drive/folders/" + folder.Groups[1].Value);
                }
            return list;
        }
        async Task Live(Dictionary<string, object> p)
        {
            if (links == null || links.IsFaulted || links.IsCanceled)
                links = ReadLinks();
            if (Str(p, "action") == "openDownload")
            {
                var s = Source(Num(p, "sourceId"));
                Uri uri;
                if (!(await links).TryGetValue(s.sourceId, out uri))
                    throw Problem("No original download is published.");
                if (OpenOriginalFolder != null)
                    OpenOriginalFolder(uri, s.sourceId);
                else
                    Launch(uri.AbsoluteUri);
                return;
            }
            var showId = Num(p, "showId");
            var ids = Rows(Get(p, "sources")).Select(row => Num(row, "id")).ToArray();
            var results = new List<object>();
            Dictionary<long, Uri> index = null;
            try
            {
                index = await links;
            }
            catch (Exception)
            { /* Allow offline catalog use. */
            }
            RefreshCatalog();
            foreach (long id in ids)
            {
                SourceRef s;
                bool ok = sources.TryGetValue(id, out s) && s.showId == showId && index != null &&
                          index.ContainsKey(id);
                results.Add(new { sourceId = id, downloadAvailable = ok,
                                  message = index == null ? "Live links unavailable offline" : "" });
            }
            Send("macLiveLinks", new { showId, sources = results });
        }
        static void Launch(string path)
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
        }
        void Queue(long request, string label, string origin, List<MediaTrack> tracks, int start)
        {
            if (disposed || request != latestRequest)
                return;
            var entries = new List<object>();
            lock (handles)
            {
                ReleaseHandles();
                foreach (var track in tracks)
                {
                    var id = Guid.NewGuid().ToString("N");
                    handles.Add(id, track);
                    entries.Add(new { track.title, track.durationSeconds,
                                      url = "https://media.tooldrive.invalid/" + id });
                }
            }
            Send("windowsMediaReply",
                 new { request, context = label, origin, tracks = entries, startIndex = start });
        }
        public async Task HandleAsync(string channel, Dictionary<string, object> body)
        {
            if (disposed)
                return;
            long request = Num(body, "request");
            string action = Str(body, "action");
            if (request != 0)
                latestRequest = request;
            try
            {
                switch (channel)
                {
                case "live":
                    await Live(body);
                    break;
                case "player":
                    if (action == "release")
                    {
                        latestRequest = 0;
                        ReleaseHandles();
                    }
                    else if (action == "beginTrack" || action == "seekTrack")
                        PlaybackPosition(action, Str(body, "handle"));
                    else if (action == "load")
                    {
                        var s = Source(Num(body, "sourceId"), Num(body, "showId"));
                        Queue(request, s.Title, "archive", await Archive(s, shutdown.Token), 0);
                    }
                    else if (action == "playLibrary")
                        PlayLibrary(body, request);
                    break;
                case "download":
                    await Download(body);
                    break;
                case "library":
                    await Library(body);
                    break;
                case "plex":
                    await PlexAction(body, request);
                    break;
                }
            }
            catch (Exception e)
            {
                if (disposed)
                    return;
                string message = Message(e);
                if (request != 0 && request == latestRequest)
                    Send("windowsMediaReply", new { request, error = message });
                if (channel == "plex")
                {
                    plexMessage = message;
                    PlexState();
                }
                else if (channel == "library")
                    PublishLibrary(message);
                else if (channel == "download")
                    DownloadState(Num(body, "sourceId"), "failed", 0, message, "");
                else if (channel == "live" && action == "openDownload")
                    Send("windowsMediaNotice", message);
            }
        }
        public void Dispose()
        {
            disposed = true;
            shutdown.Cancel();
            http.Dispose();
            ReleaseHandles();
        }
    }
}
