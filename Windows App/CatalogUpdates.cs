using System;
using System.Collections.Generic;
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
    public sealed class CatalogUpdateResult
    {
        public Catalog Catalog { get; set; }
        public CatalogChanges Changes { get; set; }
        public DateTime CheckedAtUtc { get; set; }
    }

    public sealed class CatalogChanges
    {
        public int NewShows { get; set; }
        public int NewRecordings { get; set; }
        public int NewOnDriveRecordings { get; set; }
        public int ChangedRatings { get; set; }
        public int UpdatedShows { get; set; }
        public bool HasChanges { get; set; }
        public string Summary
        {
            get
            {
                if (!HasChanges) return "The public catalog has no changes since your last snapshot.";
                List<string> parts = new List<string>();
                if (NewShows > 0) parts.Add(Count(NewShows, "new show"));
                if (NewRecordings > 0) parts.Add(Count(NewRecordings, "new recording"));
                if (NewOnDriveRecordings > 0) parts.Add(Count(NewOnDriveRecordings, "newly on-drive recording"));
                if (ChangedRatings > 0) parts.Add(Count(ChangedRatings, "changed sound rating"));
                if (UpdatedShows > 0) parts.Add(Count(UpdatedShows, "updated show"));
                return parts.Count == 0 ? "The catalog metadata has changed." : String.Join(", ", parts) + ".";
            }
        }
        private static string Count(int value, string text)
        {
            return value.ToString("N0", CultureInfo.CurrentCulture) + " " + text + (value == 1 ? "" : "s");
        }
    }

    public static class CatalogUpdater
    {
        internal const int MaximumFileBytes = 16 * 1024 * 1024;
        internal const int MaximumTotalBytes = 64 * 1024 * 1024;
        private static readonly string[] FileNames = { "01-shows.js", "02-sources.js", "03-songs.js", "09-setlist-history.js" };
        private static readonly string[] Statuses = { "OTD", "Confirmed", "Unconfirmed", "Unknown" };
        private static readonly string[] RecordingTypes = { "unknown", "audience", "soundboard", "studio", "fm", "IEM", "ALD" };
        private static readonly Regex Links = new Regex(@"(?:(?:[a-z][a-z0-9+.-]*:)?//|www\.)\S+", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        // Checking never changes a live catalog or cache. The UI commits a fully validated result.
        public static Task<CatalogUpdateResult> CheckAsync(Catalog current, CancellationToken token)
        {
            return CheckAsync(current, DownloadAsync, token);
        }

        // A deterministic downloader seam for isolated failure/cancellation/partial-snapshot tests.
        // Even injected downloaders receive only the same four fixed HTTPS metadata addresses.
        public static async Task<CatalogUpdateResult> CheckAsync(Catalog current, Func<Uri, CancellationToken, Task<string>> downloader, CancellationToken token)
        {
            if (current == null) throw new ArgumentNullException("current");
            if (downloader == null) throw new ArgumentNullException("downloader");
            token.ThrowIfCancellationRequested();
            DateTime checkedAt = DateTime.UtcNow;
            List<string> files = new List<string>();
            long totalBytes = 0;
            foreach (string fileName in FileNames)
            {
                token.ThrowIfCancellationRequested();
                Uri address = new Uri("https://tooldriveproject.net/data/" + fileName + "?offline-check=" + checkedAt.Ticks.ToString(CultureInfo.InvariantCulture));
                string text = await downloader(address, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (String.IsNullOrWhiteSpace(text)) throw new InvalidDataException("A public metadata file was empty.");
                int length = Encoding.UTF8.GetByteCount(text);
                totalBytes += length;
                if (length > MaximumFileBytes || totalBytes > MaximumTotalBytes) throw new InvalidDataException("The public metadata exceeded the download size limit.");
                files.Add(text);
            }
            token.ThrowIfCancellationRequested();
            Catalog candidate = await Task.Run(delegate { return ImportMetadata(files[0], files[1], files[2], files[3], checkedAt); }, token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            ProtectAgainstPartialSnapshot(current, candidate);
            CatalogChanges changes = Compare(current, candidate);
            token.ThrowIfCancellationRequested();
            return new CatalogUpdateResult { Catalog = candidate, Changes = changes, CheckedAtUtc = checkedAt };
        }

        private static async Task<string> DownloadAsync(Uri address, CancellationToken token)
        {
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            using (HttpClientHandler handler = new HttpClientHandler())
            {
                handler.AllowAutoRedirect = false;
                handler.UseCookies = false;
                handler.UseDefaultCredentials = false;
                handler.AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate;
                using (HttpClient client = new HttpClient(handler))
                {
                    client.Timeout = TimeSpan.FromSeconds(30);
                    client.DefaultRequestHeaders.UserAgent.ParseAdd("ToolDriveOffline/" + AppUpdater.CurrentVersion.ToString(3) + " CatalogUpdate");
                    token.ThrowIfCancellationRequested();
                    using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
                    using (HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, address))
                    {
                        timeout.CancelAfter(TimeSpan.FromSeconds(30));
                        request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true, MaxAge = TimeSpan.Zero };
                        request.Headers.Pragma.ParseAdd("no-cache");
                        using (HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                        using (timeout.Token.Register(delegate { response.Dispose(); }))
                        {
                            try
                            {
                                response.EnsureSuccessStatusCode();
                                if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value > MaximumFileBytes)
                                    throw new InvalidDataException("A public metadata file exceeded the size limit.");
                                using (Stream body = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                                using (MemoryStream bytes = new MemoryStream())
                                {
                                    byte[] buffer = new byte[16384];
                                    int read;
                                    while ((read = await body.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) != 0)
                                    {
                                        if (bytes.Length + read > MaximumFileBytes) throw new InvalidDataException("A public metadata file exceeded the download size limit.");
                                        bytes.Write(buffer, 0, read);
                                    }
                                    timeout.Token.ThrowIfCancellationRequested();
                                    return new UTF8Encoding(false, true).GetString(bytes.ToArray()).TrimStart('\uFEFF');
                                }
                            }
                            catch (Exception error)
                            {
                                // Closing the response also aborts old Framework streams whose
                                // ReadAsync implementation does not promptly honor cancellation.
                                if (timeout.IsCancellationRequested && (error is IOException || error is ObjectDisposedException || error is HttpRequestException))
                                    throw new OperationCanceledException("The metadata request was canceled or timed out.", error, timeout.Token);
                                throw;
                            }
                        }
                    }
                }
            }
        }

        public static Catalog ImportMetadata(string showsJs, string sourcesJs, string songsJs, string historyJs, DateTime checkedAtUtc)
        {
            string[] texts = { showsJs, sourcesJs, songsJs, historyJs };
            long bytes = 0;
            foreach (string text in texts)
            {
                if (String.IsNullOrWhiteSpace(text)) throw new InvalidDataException("A public metadata file was empty.");
                int length = Encoding.UTF8.GetByteCount(text);
                if (length > MaximumFileBytes) throw new InvalidDataException("A public metadata file exceeded the size limit.");
                bytes += length;
            }
            if (bytes > MaximumTotalBytes) throw new InvalidDataException("The metadata exceeded the size limit.");
            List<object> rawShows = Array(Constant(showsJs, "SHOWS"), "SHOWS");
            Dictionary<string, object> rawSources = Object(Constant(sourcesJs, "SOURCES_DATA"), "SOURCES_DATA");
            List<object> rawSongs = Array(Constant(songsJs, "SONGS"), "SONGS");
            Dictionary<string, object> history = Object(Constant(historyJs, "SETLIST_HISTORY"), "SETLIST_HISTORY");
            List<object> rawSongIds = Array(Constant(historyJs, "SETLIST_SONG_IDS"), "SETLIST_SONG_IDS");
            if (rawShows.Count == 0 || rawSources.Count == 0 || rawSongs.Count == 0 || history.Count == 0 || rawSongIds.Count == 0)
                throw new InvalidDataException("The public catalog was incomplete or empty.");

            Dictionary<long, Dictionary<string, object>> showMap = new Dictionary<long, Dictionary<string, object>>();
            HashSet<string> showDates = new HashSet<string>(StringComparer.Ordinal);
            foreach (object item in rawShows)
            {
                Dictionary<string, object> row = Object(item, "show");
                long id = Id(Required(row, "id"), "show ID");
                if (showMap.ContainsKey(id)) throw new InvalidDataException("Duplicate show ID in the public catalog.");
                string date = Date(Required(row, "date"), "show date");
                if (!showDates.Add(date)) throw new InvalidDataException("Duplicate show date in the public catalog.");
                showMap.Add(id, row);
            }
            if (rawSources.Count != showMap.Count) throw new InvalidDataException("The show and recording files did not match.");
            foreach (string key in rawSources.Keys)
            {
                long id = Id(key, "recording show key");
                if (id.ToString(CultureInfo.InvariantCulture) != key || !showMap.ContainsKey(id))
                    throw new InvalidDataException("A recording referred to an unknown show.");
            }

            Dictionary<string, string> titles = new Dictionary<string, string>(StringComparer.Ordinal);
            Dictionary<long, List<string>> knownSongs = new Dictionary<long, List<string>>();
            foreach (object item in rawSongs)
            {
                Dictionary<string, object> song = Object(item, "song");
                string id = Text(Required(song, "id"));
                string title = Text(Required(song, "title"));
                if (id.Length == 0 || title.Length == 0 || titles.ContainsKey(id)) throw new InvalidDataException("The song catalog contained missing or duplicate song IDs.");
                titles.Add(id, title);
                HashSet<long> seenAppearances = new HashSet<long>();
                foreach (object appearance in Array(Required(song, "appearances"), "song appearances"))
                {
                    long showId = Id(appearance, "song appearance show ID");
                    if (!showMap.ContainsKey(showId) || !seenAppearances.Add(showId)) throw new InvalidDataException("The song catalog referred to an unknown or duplicate show.");
                    List<string> names;
                    if (!knownSongs.TryGetValue(showId, out names)) { names = new List<string>(); knownSongs.Add(showId, names); }
                    if (!names.Contains(title)) names.Add(title);
                }
            }
            List<string> songIds = new List<string>();
            HashSet<string> uniqueSongIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (object item in rawSongIds)
            {
                string id = Text(item);
                if (!titles.ContainsKey(id) || !uniqueSongIds.Add(id)) throw new InvalidDataException("The setlist song index did not match the song catalog.");
                songIds.Add(id);
            }
            foreach (KeyValuePair<string, object> pair in history)
            {
                Date(pair.Key, "setlist date");
                Dictionary<string, object> entry = Object(pair.Value, "setlist");
                foreach (object index in Array(Required(entry, "s"), "ordered setlist"))
                {
                    long number = Integer(index, "setlist index");
                    if (number < 0 || number >= songIds.Count) throw new InvalidDataException("A setlist song index was out of range.");
                }
                if (entry.ContainsKey("d") && (Integer(entry["d"], "omitted setlist count") < 0 || Integer(entry["d"], "omitted setlist count") > 10000))
                    throw new InvalidDataException("The omitted setlist count was invalid.");
                if (entry.ContainsKey("t")) Text(entry["t"]);
            }

            HashSet<long> recordingIds = new HashSet<long>();
            Catalog candidate = new Catalog { snapshotDate = Utc(checkedAtUtc).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), source = "Tool Drive Project · setlists from setlist.fm", ratingDescription = "Sound quality out of 10. Source averages from the public catalog snapshot; vote counts are not available.", shows = new List<Show>() };
            foreach (object item in rawShows)
            {
                Dictionary<string, object> row = Object(item, "show");
                long id = Id(Required(row, "id"), "show ID");
                Show show = new Show { id = id, date = Date(Required(row, "date"), "show date"), venue = Field(row, "venue", true), city = Field(row, "city", true), state = Field(row, "state", true), country = Field(row, "country", true), status = EnumValue(Required(row, "status"), Statuses, "show status"), festival = Field(row, "festival", false), sources = new List<Source>(), setlist = new List<SetlistItem>(), songs = new List<string>(), tour = "" };
                List<object> sourceRows = Array(rawSources[id.ToString(CultureInfo.InvariantCulture)], "show recordings");
                if (sourceRows.Count == 0) throw new InvalidDataException("A show was missing its recording status entry.");
                foreach (object sourceItem in sourceRows)
                {
                    Dictionary<string, object> source = Object(sourceItem, "recording");
                    long sourceId = Id(Required(source, "id"), "recording ID");
                    if (!recordingIds.Add(sourceId)) throw new InvalidDataException("Duplicate recording ID in the public catalog.");
                    Source recording = new Source { id = sourceId, rating = Rating(Required(source, "rating")), version = Field(source, "ver", true), taper = Field(source, "taper", true), gear = Field(source, "gear", true), generation = Field(source, "generation", true), length = Field(source, "len", true), status = EnumValue(Required(source, "status"), Statuses, "recording status"), lineage = Field(source, "lineage", true), recordingType = EnumValue(Required(source, "recordingType"), RecordingTypes, "recording type"), codec = Field(source, "fileCodec", true), lossless = EnumValue(Required(source, "fileLossless"), new string[] { "unknown", "lossless", "lossy" }, "file format") };
                    if (recording.status == "Unknown" && recording.rating.HasValue) throw new InvalidDataException("An unknown recording placeholder had a sound rating.");
                    show.sources.Add(recording);
                }
                string rollup = Statuses.First(status => show.sources.Any(source => source.status == status));
                if (show.status != rollup) throw new InvalidDataException("The show and recording status files did not match.");
                object historyItem;
                if (history.TryGetValue(show.date, out historyItem))
                {
                    Dictionary<string, object> entry = Object(historyItem, "setlist");
                    foreach (object index in Array(entry["s"], "ordered setlist")) show.setlist.Add(new SetlistItem { title = titles[songIds[(int)Integer(index, "setlist index")]] });
                    show.setlistOmitted = entry.ContainsKey("d") ? (int)Integer(entry["d"], "omitted setlist count") : 0;
                    show.tour = Field(entry, "t", false);
                }
                List<string> known;
                if (knownSongs.TryGetValue(id, out known)) show.songs.AddRange(known);
                foreach (SetlistItem song in show.setlist) if (!show.songs.Contains(song.title)) show.songs.Add(song.title);
                candidate.shows.Add(show);
            }
            return Catalog.FromJson(Serializer().Serialize(candidate));
        }

        public static CatalogChanges Compare(Catalog current, Catalog candidate)
        {
            if (current == null || candidate == null || current.shows == null || candidate.shows == null) throw new ArgumentException("Both catalogs are required.");
            Dictionary<long, Show> oldShows = current.shows.ToDictionary(show => show.id);
            Dictionary<long, Show> newShows = candidate.shows.ToDictionary(show => show.id);
            Dictionary<long, Source> oldSources = current.shows.SelectMany(show => show.sources).ToDictionary(source => source.id);
            Dictionary<long, Source> newSources = candidate.shows.SelectMany(show => show.sources).ToDictionary(source => source.id);
            CatalogChanges result = new CatalogChanges();
            result.NewShows = newShows.Keys.Count(id => !oldShows.ContainsKey(id));
            foreach (Source source in newSources.Values)
            {
                Source old;
                bool existed = oldSources.TryGetValue(source.id, out old);
                if (source.status != "Unknown" && (!existed || old.status == "Unknown")) result.NewRecordings++;
                if (source.status == "OTD" && (!existed || old.status != "OTD")) result.NewOnDriveRecordings++;
                if (existed && Catalog.SoundRating(source) != Catalog.SoundRating(old)) result.ChangedRatings++;
            }
            JavaScriptSerializer serializer = Serializer();
            foreach (Show show in candidate.shows)
            {
                Show old;
                if (oldShows.TryGetValue(show.id, out old) && ShowFingerprint(serializer, old) != ShowFingerprint(serializer, show)) result.UpdatedShows++;
            }
            result.HasChanges = result.NewShows > 0 || result.NewRecordings > 0 || result.NewOnDriveRecordings > 0 || result.ChangedRatings > 0 || result.UpdatedShows > 0 || oldShows.Keys.Any(id => !newShows.ContainsKey(id)) || oldSources.Keys.Any(id => !newSources.ContainsKey(id));
            return result;
        }

        private static string ShowFingerprint(JavaScriptSerializer serializer, Show show)
        {
            // Server ordering is not a change; ordered setlists and song text remain significant.
            return serializer.Serialize(new { show.id, show.date, show.venue, show.city, show.state, show.country, show.status, show.festival, show.tour, sources = show.sources.OrderBy(source => source.id).ToArray(), show.setlist, show.setlistOmitted, show.songs });
        }

        private static void ProtectAgainstPartialSnapshot(Catalog current, Catalog candidate)
        {
            ProtectCount(current.shows.Count, candidate.shows.Count, "shows", 0.95);
            List<Source> oldSources = current.shows.SelectMany(show => show.sources).ToList();
            List<Source> newSources = candidate.shows.SelectMany(show => show.sources).ToList();
            ProtectCount(oldSources.Count, newSources.Count, "recording entries", 0.95);
            ProtectCount(oldSources.Count(source => source.status == "OTD"), newSources.Count(source => source.status == "OTD"), "on-drive recordings", 0.95);
            ProtectCount(oldSources.Count(source => Catalog.SoundRating(source).HasValue), newSources.Count(source => Catalog.SoundRating(source).HasValue), "sound ratings", 0.80);
            ProtectCount(current.shows.Count(show => show.setlist.Count > 0), candidate.shows.Count(show => show.setlist.Count > 0), "setlists", 0.80);
            HashSet<long> newShowIds = new HashSet<long>(candidate.shows.Select(show => show.id));
            HashSet<long> newSourceIds = new HashSet<long>(newSources.Select(source => source.id));
            ProtectCount(current.shows.Count, current.shows.Count(show => newShowIds.Contains(show.id)), "existing show IDs", 0.95);
            ProtectCount(oldSources.Count, oldSources.Count(source => newSourceIds.Contains(source.id)), "existing recording IDs", 0.95);
        }
        private static void ProtectCount(int oldCount, int newCount, string name, double fraction)
        {
            if (oldCount >= 20 && newCount < Math.Ceiling(oldCount * fraction)) throw new InvalidDataException("The downloaded snapshot unexpectedly lost " + name + ". Your existing catalog was kept; try again after the site's next metadata refresh.");
        }
        internal static JavaScriptSerializer Serializer()
        {
            return new JavaScriptSerializer { MaxJsonLength = MaximumTotalBytes, RecursionLimit = 64 };
        }
        internal static DateTime Utc(DateTime value)
        {
            return value.Kind == DateTimeKind.Unspecified ? DateTime.SpecifyKind(value, DateTimeKind.Utc) : value.ToUniversalTime();
        }
        private static object Constant(string text, string name)
        {
            MatchCollection matches = Regex.Matches(text, @"^\s*const\s+" + Regex.Escape(name) + @"\s*=\s*", RegexOptions.Multiline | RegexOptions.CultureInvariant);
            if (matches.Count != 1) throw new InvalidDataException("Missing or duplicate public metadata constant: " + name + ".");
            StrictJson reader = new StrictJson(text, matches[0].Index + matches[0].Length);
            object value = reader.Read();
            reader.WhiteSpace();
            if (!reader.AtEnd && reader.Current != ';') throw new InvalidDataException("Unexpected content after metadata constant " + name + ".");
            return value;
        }
        private static Dictionary<string, object> Object(object value, string field)
        {
            Dictionary<string, object> result = value as Dictionary<string, object>;
            if (result == null) throw new InvalidDataException("Expected a metadata object: " + field + ".");
            return result;
        }
        private static List<object> Array(object value, string field)
        {
            List<object> result = value as List<object>;
            if (result == null) throw new InvalidDataException("Expected a metadata array: " + field + ".");
            return result;
        }
        private static object Required(Dictionary<string, object> row, string field)
        {
            object value;
            if (!row.TryGetValue(field, out value)) throw new InvalidDataException("A required metadata field was missing: " + field + ".");
            return value;
        }
        private static string Field(Dictionary<string, object> row, string field, bool required)
        {
            object value;
            if (!row.TryGetValue(field, out value)) { if (required) Required(row, field); return ""; }
            return Text(value);
        }
        private static string Text(object value)
        {
            if (value == null) return "";
            if (value is Dictionary<string, object> || value is List<object> || value is bool) throw new InvalidDataException("A metadata text field was malformed.");
            string text = Convert.ToString(value, CultureInfo.InvariantCulture);
            if (text.Length > 131072) throw new InvalidDataException("A metadata text field was too long.");
            return Links.Replace(text, "[link removed]").Trim();
        }
        private static long Integer(object value, string field)
        {
            long number;
            if (value == null || value is bool || !Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)) throw new InvalidDataException("Invalid metadata integer: " + field + ".");
            return number;
        }
        private static long Id(object value, string field)
        {
            long id = Integer(value, field);
            if (id <= 0) throw new InvalidDataException("Invalid metadata ID: " + field + ".");
            return id;
        }
        private static string Date(object value, string field)
        {
            string text = Text(value);
            DateTime parsed;
            if (!DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed)) throw new InvalidDataException("Invalid metadata date: " + field + ".");
            return text;
        }
        private static string EnumValue(object value, string[] allowed, string field)
        {
            string text = Text(value);
            if (!allowed.Contains(text, StringComparer.Ordinal)) throw new InvalidDataException("Unrecognized metadata value for " + field + ".");
            return text;
        }
        private static double? Rating(object value)
        {
            if (value == null) return null;
            string text = Text(value);
            if (text == "" || text == "—" || text == "-") return null;
            double number;
            if (!Double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out number) || Double.IsNaN(number) || Double.IsInfinity(number) || number < 0 || number > 10) throw new InvalidDataException("A source sound rating was invalid.");
            return number == 0 ? (double?)null : number;
        }
    }

    public static class CatalogCache
    {
        private const int MaximumCacheBytes = 32 * 1024 * 1024;
        private static DateTime? lastChecked;
        public static DateTime? LastCheckedUtc { get { return lastChecked; } }
        public static string FilePath { get { return Path.Combine(DesktopBootstrap.Profile, "catalog-update.json"); } }

        public static Catalog Load(out string warning)
        {
            Catalog catalog = LoadCore(FilePath, out warning, true);
            return catalog ?? Catalog.Load();
        }
        // The path overload never reads the user's cache or embedded fallback; useful for isolated tests.
        public static Catalog Load(string path, out string warning)
        {
            return LoadCore(path, out warning, false);
        }
        private static Catalog LoadCore(string path, out string warning, bool updateLastChecked)
        {
            warning = null;
            if (updateLastChecked) lastChecked = null;
            try
            {
                if (!File.Exists(path)) return null;
                if (new FileInfo(path).Length > MaximumCacheBytes) throw new InvalidDataException("The saved catalog was too large.");
                string json = File.ReadAllText(path, new UTF8Encoding(false, true));
                StrictJson reader = new StrictJson(json, 0);
                Dictionary<string, object> wrapper = reader.Read() as Dictionary<string, object>;
                reader.WhiteSpace();
                if (!reader.AtEnd || wrapper == null || !wrapper.ContainsKey("schemaVersion") || !wrapper.ContainsKey("catalog") || !wrapper.ContainsKey("checkedAtUtc") || Convert.ToString(wrapper["schemaVersion"], CultureInfo.InvariantCulture) != "1") throw new InvalidDataException("The saved catalog format was not recognized.");
                DateTime checkedAt;
                if (!(wrapper["checkedAtUtc"] is string) || !DateTime.TryParseExact((string)wrapper["checkedAtUtc"], "o", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out checkedAt) || checkedAt.Kind != DateTimeKind.Utc) throw new InvalidDataException("The saved catalog check time was invalid.");
                if (!(wrapper["catalog"] is Dictionary<string, object>)) throw new InvalidDataException("The saved catalog was missing.");
                Catalog catalog = Catalog.FromJson(CatalogUpdater.Serializer().Serialize(wrapper["catalog"]));
                if (updateLastChecked) lastChecked = checkedAt;
                return catalog;
            }
            catch (Exception ex)
            {
                if (ex is OutOfMemoryException || ex is StackOverflowException) throw;
                warning = "The saved catalog update could not be loaded. The bundled offline catalog is available.";
                return null;
            }
        }
        public static void Save(Catalog catalog, DateTime checkedAtUtc)
        {
            SaveCore(FilePath, catalog, checkedAtUtc);
            lastChecked = CatalogUpdater.Utc(checkedAtUtc);
        }
        public static void Save(string path, Catalog catalog, DateTime checkedAtUtc)
        {
            SaveCore(path, catalog, checkedAtUtc);
        }
        private static void SaveCore(string path, Catalog catalog, DateTime checkedAtUtc)
        {
            if (catalog == null) throw new ArgumentNullException("catalog");
            JavaScriptSerializer serializer = CatalogUpdater.Serializer();
            Catalog validated = Catalog.FromJson(serializer.Serialize(catalog));
            string json = serializer.Serialize(new { schemaVersion = 1, checkedAtUtc = CatalogUpdater.Utc(checkedAtUtc).ToString("o", CultureInfo.InvariantCulture), catalog = validated });
            byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);
            if (bytes.Length > MaximumCacheBytes) throw new InvalidDataException("The catalog exceeded the local cache size limit.");
            string fullPath = Path.GetFullPath(path);
            string temporary = fullPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(fullPath));
                using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    stream.Write(bytes, 0, bytes.Length);
                    stream.Flush(true);
                }
                if (File.Exists(fullPath)) File.Replace(temporary, fullPath, null);
                else File.Move(temporary, fullPath);
            }
            finally
            {
                try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }

    // A bounded JSON reader, not a JavaScript interpreter. It rejects duplicate keys and malformed
    // JSON before the framework serializer maps the whitelisted metadata into the app's model.
    internal sealed class StrictJson
    {
        private readonly string text;
        private int position;
        private int depth;
        private int nodes;
        public StrictJson(string value, int start) { text = value; position = start; }
        public bool AtEnd { get { return position >= text.Length; } }
        public char Current { get { return text[position]; } }
        public void WhiteSpace() { while (!AtEnd && (Current == ' ' || Current == '\t' || Current == '\r' || Current == '\n' || Current == '\uFEFF')) position++; }
        public object Read()
        {
            WhiteSpace();
            if (AtEnd || ++depth > 64 || ++nodes > 2000000) throw Error();
            object value;
            char c = Current;
            if (c == '{') value = ReadObject();
            else if (c == '[') value = ReadArray();
            else if (c == '"') value = ReadString();
            else if (c == 't') { Literal("true"); value = true; }
            else if (c == 'f') { Literal("false"); value = false; }
            else if (c == 'n') { Literal("null"); value = null; }
            else value = ReadNumber();
            depth--;
            return value;
        }
        private Dictionary<string, object> ReadObject()
        {
            position++;
            Dictionary<string, object> result = new Dictionary<string, object>(StringComparer.Ordinal);
            WhiteSpace();
            if (Consume('}')) return result;
            while (true)
            {
                WhiteSpace();
                if (AtEnd || Current != '"') throw Error();
                string key = ReadString();
                WhiteSpace();
                if (!Consume(':') || result.ContainsKey(key)) throw Error();
                result.Add(key, Read());
                WhiteSpace();
                if (Consume('}')) return result;
                if (!Consume(',')) throw Error();
            }
        }
        private List<object> ReadArray()
        {
            position++;
            List<object> result = new List<object>();
            WhiteSpace();
            if (Consume(']')) return result;
            while (true)
            {
                result.Add(Read());
                WhiteSpace();
                if (Consume(']')) return result;
                if (!Consume(',')) throw Error();
            }
        }
        private string ReadString()
        {
            position++;
            StringBuilder result = new StringBuilder();
            while (!AtEnd)
            {
                char c = text[position++];
                if (c == '"') return result.ToString();
                if (c < 0x20) throw Error();
                if (c != '\\') { result.Append(c); continue; }
                if (AtEnd) throw Error();
                c = text[position++];
                if (c == '"' || c == '\\' || c == '/') result.Append(c);
                else if (c == 'b') result.Append('\b');
                else if (c == 'f') result.Append('\f');
                else if (c == 'n') result.Append('\n');
                else if (c == 'r') result.Append('\r');
                else if (c == 't') result.Append('\t');
                else if (c == 'u')
                {
                    if (position + 4 > text.Length) throw Error();
                    ushort number;
                    if (!UInt16.TryParse(text.Substring(position, 4), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out number)) throw Error();
                    result.Append((char)number); position += 4;
                }
                else throw Error();
            }
            throw Error();
        }
        private object ReadNumber()
        {
            int start = position;
            Consume('-');
            if (AtEnd) throw Error();
            if (Current == '0') position++;
            else { if (Current < '1' || Current > '9') throw Error(); while (!AtEnd && Current >= '0' && Current <= '9') position++; }
            bool fractional = false;
            if (Consume('.')) { fractional = true; Digits(); }
            if (!AtEnd && (Current == 'e' || Current == 'E')) { fractional = true; position++; if (!AtEnd && (Current == '+' || Current == '-')) position++; Digits(); }
            string number = text.Substring(start, position - start);
            long integer;
            if (!fractional && Int64.TryParse(number, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out integer)) return integer;
            double real;
            if (!Double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out real) || Double.IsNaN(real) || Double.IsInfinity(real)) throw Error();
            return real;
        }
        private void Digits() { int start = position; while (!AtEnd && Current >= '0' && Current <= '9') position++; if (start == position) throw Error(); }
        private void Literal(string value) { if (position + value.Length > text.Length || String.CompareOrdinal(text, position, value, 0, value.Length) != 0) throw Error(); position += value.Length; }
        private bool Consume(char value) { if (!AtEnd && Current == value) { position++; return true; } return false; }
        private InvalidDataException Error() { return new InvalidDataException("The metadata contained malformed or duplicate JSON data."); }
    }
}
