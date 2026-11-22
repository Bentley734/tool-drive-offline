using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

// Fixture checks have no network access and never write to the real app profile.
public static class UpdateChecks
{
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 32 * 1024 * 1024 };
    static Type catalogType, updaterType, cacheType;
    static int passed;
    static readonly DateTime CheckedAt = new DateTime(2026, 11, 22, 15, 0, 0, DateTimeKind.Utc);

    static Dictionary<string, object> Row(params object[] pairs)
    {
        var result = new Dictionary<string, object>();
        for (int i = 0; i < pairs.Length; i += 2) result[(string)pairs[i]] = pairs[i + 1];
        return result;
    }

    static Dictionary<string, object> Show(long id, string day, string venue, string status)
    {
        return Row("id", id, "date", day, "venue", venue, "city", "Test City", "state", "TS", "country", "USA", "status", status);
    }

    static Dictionary<string, object> Source(long id, string status, string rating)
    {
        return Row("id", id, "ver", "V.01", "status", status, "rating", rating, "taper", "Fixture Taper", "gear", "Fixture Gear", "generation", "0", "len", "45:00", "recordingType", "audience", "lineage", "Recorder > https://example.invalid/audio.flac > FLAC", "fileCodec", "flac", "fileLossless", "lossless", "driveUrl", "https://drive.google.com/should-never-survive");
    }

    static string[] Fixture(bool changed)
    {
        var shows = new List<object> {
            Show(1991090501L, "1991-09-05", changed ? "Updated Hall" : "Fixture Hall", "OTD"),
            Show(1992010101L, "1992-01-01", "Second Hall", "Unknown")
        };
        var sources = new Dictionary<string, object> {
            { "1991090501", new object[] { Source(3, "OTD", changed ? "9.5" : "9.0"), Source(4, changed ? "OTD" : "Confirmed", changed ? "7.0" : "—") } },
            { "1992010101", new object[] { Source(5, "Unknown", "0") } }
        };
        var history = new Dictionary<string, object> {
            { "1991-09-05", Row("s", new int[] { 0, 1 }, "t", "Fixture tour", "d", 1) },
            { "1992-01-01", Row("s", new int[0]) }
        };
        if (changed)
        {
            shows.Add(Show(1993073001L, "1993-07-30", "New Hall", "OTD"));
            sources.Add("1993073001", new object[] { Source(6, "OTD", "8.0") });
            history.Add("1993-07-30", Row("s", new int[] { 1 }));
        }
        object[] songs = {
            Row("id", "sober", "title", "Sober", "appearances", new long[] { 1991090501L }),
            Row("id", "aenema", "title", "Ænema", "appearances", new long[] { 1991090501L })
        };
        return new string[] {
            "const SHOWS = " + Json.Serialize(shows) + ";",
            "const SOURCES_DATA = " + Json.Serialize(sources) + ";",
            "const SONGS = " + Json.Serialize(songs) + ";",
            "/* Metadata only. */\nconst SETLIST_SONG_IDS = [\"sober\",\"aenema\"];\nconst SETLIST_HISTORY = " + Json.Serialize(history) + ";\nconst SETLIST_LEGS = [];"
        };
    }

    static object Get(object value, string name) { return value.GetType().GetProperty(name).GetValue(value, null); }
    static void Set(object value, string name, object next) { value.GetType().GetProperty(name).SetValue(value, next, null); }
    static List<object> List(object value) { return ((IEnumerable)value).Cast<object>().ToList(); }
    static void Assert(bool condition, string label) { if (!condition) throw new Exception(label); passed++; Console.WriteLine("PASS " + label); }
    static object Import(string[] files)
    {
        return updaterType.GetMethod("ImportMetadata").Invoke(null, new object[] { files[0], files[1], files[2], files[3], CheckedAt });
    }
    static object Compare(object first, object second) { return updaterType.GetMethod("Compare").Invoke(null, new object[] { first, second }); }
    static object CheckWithDownloader(object current, Func<Uri, CancellationToken, Task<string>> downloader, CancellationToken token)
    {
        var method = updaterType.GetMethod("CheckAsync", new Type[] { catalogType, typeof(Func<Uri, CancellationToken, Task<string>>), typeof(CancellationToken) });
        var task = (Task)method.Invoke(null, new object[] { current, downloader, token });
        task.GetAwaiter().GetResult();
        return task.GetType().GetProperty("Result").GetValue(task, null);
    }
    static bool Fails(Action action)
    {
        try { action(); return false; }
        catch (TargetInvocationException ex) { if (ex.InnerException == null) throw; return true; }
        catch (InvalidOperationException) { return true; }
        catch (ArgumentException) { return true; }
        catch (InvalidDataException) { return true; }
        catch (IOException) { return true; }
    }

    static void FixtureChecks()
    {
        object baseline = Import(Fixture(false)), changed = Import(Fixture(true));
        var shows = List(Get(baseline, "shows"));
        var firstSources = List(Get(shows[0], "sources"));
        string serialized = Json.Serialize(baseline);
        Assert(shows.Count == 2 && firstSources.Count == 2, "metadata import preserves shows and recording versions");
        Assert(!serialized.Contains("http://") && !serialized.Contains("https://") && !serialized.Contains("driveUrl"), "audio and download URLs are stripped from imported metadata");
        Assert(Convert.ToString(Get(firstSources[0], "generation")) == "0", "generation zero survives metadata import");
        Assert(Convert.ToDouble(Get(firstSources[0], "rating"), CultureInfo.InvariantCulture) == 9.0, "source sound rating imported exactly");
        Assert(Get(List(Get(shows[1], "sources"))[0], "rating") == null, "zero rating imports as unrated");
        var setlist = List(Get(shows[0], "setlist"));
        Assert(Convert.ToString(Get(setlist[0], "title")) == "Sober" && Convert.ToString(Get(setlist[1], "title")) == "Ænema" && Convert.ToInt32(Get(shows[0], "setlistOmitted")) == 1, "ordered setlist and omitted-item count preserved");
        object delta = Compare(baseline, changed);
        Assert(Convert.ToInt32(Get(delta, "NewShows")) == 1, "new shows detected");
        Assert(Convert.ToInt32(Get(delta, "NewRecordings")) == 1, "new recordings exclude pre-existing confirmed sources");
        Assert(Convert.ToInt32(Get(delta, "NewOnDriveRecordings")) == 2, "new on-drive recordings include status promotions");
        Assert(Convert.ToInt32(Get(delta, "ChangedRatings")) == 2, "changed and newly supplied ratings detected");
        Assert((bool)Get(delta, "HasChanges"), "catalog changes reported");
        object unchanged = Import(Fixture(false));
        Set(unchanged, "snapshotDate", "2026-11-23");
        Assert(!(bool)Get(Compare(baseline, unchanged), "HasChanges"), "a newer check date alone is not a content update");

        string[] fileNames = { "01-shows.js", "02-sources.js", "03-songs.js", "09-setlist-history.js" };
        string[] updatedFiles = Fixture(true);
        var requested = new List<string>();
        Func<Uri, CancellationToken, Task<string>> fixtureDownload = (uri, token) => {
            if (uri.Scheme != "https" || uri.Host != "tooldriveproject.net" || uri.Port != 443 || !String.IsNullOrEmpty(uri.UserInfo)) throw new Exception("Unexpected update destination");
            string file = uri.AbsolutePath.Substring("/data/".Length);
            int index = Array.IndexOf(fileNames, file);
            if (!uri.AbsolutePath.StartsWith("/data/", StringComparison.Ordinal) || index < 0) throw new Exception("Unexpected metadata path");
            requested.Add(file);
            return Task.FromResult(updatedFiles[index]);
        };
        object fetched = CheckWithDownloader(baseline, fixtureDownload, CancellationToken.None);
        Assert(requested.SequenceEqual(fileNames) && List(Get(Get(fetched, "Catalog"), "shows")).Count == 3, "update pipeline requests only the four fixed HTTPS metadata files");
        Assert(Fails(() => CheckWithDownloader(baseline, (uri, token) => { throw new IOException("Fixture connection failure"); }, CancellationToken.None)), "connection failures abort the update pipeline");
        Assert(Fails(() => CheckWithDownloader(baseline, (uri, token) => Task.FromResult("<html>Temporary error</html>"), CancellationToken.None)), "incomplete download sets cannot become a catalog");
        object bundled = catalogType.GetMethod("Load").Invoke(null, null);
        Assert(Fails(() => CheckWithDownloader(bundled, fixtureDownload, CancellationToken.None)), "suspiciously truncated snapshots cannot replace a full catalog");
        using (var canceledDownload = new CancellationTokenSource())
        {
            int calls = 0;
            bool canceled = false;
            try {
                CheckWithDownloader(baseline, (uri, token) => { calls++; canceledDownload.Cancel(); return Task.FromResult(updatedFiles[0]); }, canceledDownload.Token);
            } catch (OperationCanceledException) { canceled = true; }
            Assert(canceled && calls == 1, "canceling during download stops subsequent requests and import");
        }

        var malformed = Fixture(false); malformed[0] = "<html>Service unavailable</html>";
        Assert(Fails(() => Import(malformed)), "HTML/error responses are rejected");
        malformed = Fixture(false); malformed[1] = malformed[1].Replace("9.0", "11.0");
        Assert(Fails(() => Import(malformed)), "out-of-range sound ratings are rejected");
        malformed = Fixture(false); malformed[0] = malformed[0].Replace("1992-01-01", "1992-02-30");
        Assert(Fails(() => Import(malformed)), "invalid concert dates are rejected");
        malformed = Fixture(false); malformed[0] = malformed[0].Replace("1992010101", "1991090501");
        Assert(Fails(() => Import(malformed)), "duplicate show IDs are rejected");
        malformed = Fixture(false); malformed[3] = malformed[3].Replace("[0,1]", "[0,99]");
        Assert(Fails(() => Import(malformed)), "invalid setlist indexes are rejected");
        malformed = Fixture(false); malformed[1] = malformed[1].Replace("1992010101", "1999010101");
        Assert(Fails(() => Import(malformed)), "inconsistent show/source files are rejected");
        malformed = Fixture(false); malformed[2] = "const SONGS = []";
        Assert(Fails(() => Import(malformed)), "a partial song catalog is rejected");

        using (var cancel = new CancellationTokenSource())
        {
            cancel.Cancel();
            bool canceled = false;
            try { ((Task)updaterType.GetMethod("CheckAsync", new Type[] { catalogType, typeof(CancellationToken) }).Invoke(null, new object[] { baseline, cancel.Token })).GetAwaiter().GetResult(); }
            catch (OperationCanceledException) { canceled = true; }
            catch (TargetInvocationException ex) { canceled = ex.InnerException is OperationCanceledException; }
            Assert(canceled, "cancellation before checking performs no update");
        }

        string scratch = Path.Combine(Path.GetTempPath(), "ToolDriveOffline.UpdateChecks." + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
        string path = Path.Combine(scratch, "catalog-update.json");
        try
        {
            var save = cacheType.GetMethod("Save", new Type[] { typeof(string), catalogType, typeof(DateTime) });
            var load = cacheType.GetMethod("Load", new Type[] { typeof(string), typeof(string).MakeByRefType() });
            save.Invoke(null, new object[] { path, baseline, CheckedAt });
            object[] readArgs = { path, null };
            object restored = load.Invoke(null, readArgs);
            Assert(restored != null && List(Get(restored, "shows")).Count == 2 && readArgs[1] == null, "validated catalog is available from cache without network access");
            string previous = File.ReadAllText(path);
            object invalid = Import(Fixture(false));
            Set(List(Get(List(Get(invalid, "shows"))[0], "sources"))[0], "rating", 99.0);
            Assert(Fails(() => save.Invoke(null, new object[] { path, invalid, CheckedAt })) && File.ReadAllText(path) == previous, "invalid cache updates preserve the last working file");
            File.WriteAllText(path, "{broken cache"); readArgs = new object[] { path, null };
            restored = load.Invoke(null, readArgs);
            Assert(restored == null && !String.IsNullOrEmpty(Convert.ToString(readArgs[1])), "a corrupt cache is reported for bundled-catalog fallback");
            readArgs = new object[] { Path.Combine(scratch, "missing.json"), null };
            Assert(load.Invoke(null, readArgs) == null, "first launch can use the bundled catalog when no cache exists");
        }
        finally
        {
            foreach (string file in Directory.GetFiles(scratch)) File.Delete(file);
            Directory.Delete(scratch, false);
        }
        Console.WriteLine("PASS " + passed + " updater assertions; no profile data or network access used.");
    }

    public static int Main(string[] args)
    {
        try
        {
            var assembly = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            catalogType = assembly.GetType("ToolDriveOffline.Catalog", true);
            updaterType = assembly.GetType("ToolDriveOffline.CatalogUpdater", true);
            cacheType = assembly.GetType("ToolDriveOffline.CatalogCache", true);
            if (args.Length > 1 && args[1] == "--live")
            {
                object current = catalogType.GetMethod("Load").Invoke(null, null);
                using (var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(90)))
                {
                    var task = (Task)updaterType.GetMethod("CheckAsync", new Type[] { catalogType, typeof(CancellationToken) }).Invoke(null, new object[] { current, cancel.Token });
                    task.GetAwaiter().GetResult();
                    object result = task.GetType().GetProperty("Result").GetValue(task, null);
                    object catalog = Get(result, "Catalog");
                    if (args.Length > 2) File.WriteAllText(args[2], Json.Serialize(catalog));
                    Console.WriteLine("PASS live metadata check: " + List(Get(catalog, "shows")).Count + " shows; " + Convert.ToString(Get(Get(result, "Changes"), "Summary")));
                }
            }
            else FixtureChecks();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
