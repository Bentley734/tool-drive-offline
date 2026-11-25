using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    internal sealed partial class WindowsMediaService
    {
        internal Action<string, IntPtr> RecycleRecording = WindowsMediaRecycle.Move;
        public sealed class SavedTrack
        {
            public string file { get; set; }
            public string title { get; set; }
            public double? durationSeconds { get; set; }
        }
        public sealed class Recording
        {
            public long sourceId { get; set; }
            public long showId { get; set; }
            public string date { get; set; }
            public string venue { get; set; }
            public string version { get; set; }
            public List<SavedTrack> tracks { get; set; }
            public string Title
            {
                get {
                    return String.Join(" · ",
                                       new[] { date, venue, version }.Where(x => !String.IsNullOrEmpty(x)));
                }
            }
        }
        static readonly Dictionary<string, string> Types =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) {
                { ".mp3", "audio/mpeg" },  { ".flac", "audio/flac" }, { ".wav", "audio/wav" },
                { ".wave", "audio/wav" },  { ".aiff", "audio/aiff" }, { ".aif", "audio/aiff" },
                { ".aifc", "audio/aiff" }, { ".alac", "audio/alac" }, { ".aac", "audio/aac" },
                { ".m4a", "audio/mp4" },   { ".mp4", "audio/mp4" },   { ".caf", "audio/x-caf" }
            };
        const long MaxRecordingSize = 8L * 1024 * 1024 * 1024;
        string LibraryRoot
        {
            get {
                return Path.Combine(root, "Recordings");
            }
        }
        string Folder(long id)
        {
            return Path.Combine(LibraryRoot, id.ToString(CultureInfo.InvariantCulture));
        }
        static bool RealFile(string f)
        {
            return File.Exists(f) && (File.GetAttributes(f) & FileAttributes.ReparsePoint) == 0;
        }
        static bool RealDirectory(string f)
        {
            return Directory.Exists(f) && (File.GetAttributes(f) & FileAttributes.ReparsePoint) == 0;
        }
        static Recording ReadRecording(string folder)
        {
            var manifest = Path.Combine(folder, "recording.json");
            if (!RealDirectory(folder) || !RealFile(manifest) || new FileInfo(manifest).Length > 1024 * 1024)
                throw Problem("The recording manifest is missing.");
            var r = Json().Deserialize<Recording>(File.ReadAllText(manifest));
            if (r == null || r.sourceId == 0 || r.tracks == null || r.tracks.Count < 1 ||
                r.tracks.Count > 250 ||
                r.tracks.Any(t => t == null || String.IsNullOrEmpty(t.file) ||
                                  !Regex.IsMatch(t.file, @"^\d{3}\.[a-zA-Z0-9]{2,5}\z") ||
                                  !Types.ContainsKey(Path.GetExtension(t.file)) ||
                                  !RealFile(Path.Combine(folder, t.file))))
                throw Problem("A recording file is missing or invalid.");
            return r;
        }
        void PublishLibrary(string error = "")
        {
            var items = new List<object>();
            try
            {
                Directory.CreateDirectory(LibraryRoot);
                foreach (var folder in Directory.GetDirectories(LibraryRoot)
                             .OrderByDescending(Directory.GetLastWriteTimeUtc))
                {
                    long id;
                    if (!Int64.TryParse(Path.GetFileName(folder), out id))
                        continue;
                    try
                    {
                        var r = ReadRecording(folder);
                        if (r.sourceId != id)
                            continue;
                        items.Add(new {
                            id = id.ToString(CultureInfo.InvariantCulture), r.showId, r.sourceId, r.date,
                            r.venue, r.version, folderAvailable = true,
                            sizeBytes = r.tracks.Sum(t => new FileInfo(Path.Combine(folder, t.file)).Length),
                            tracks = r.tracks.Select(t => new { t.title, t.durationSeconds }).ToArray()
                        });
                    }
                    catch (Exception)
                    {
                        if (error == "")
                            error = "A saved recording has missing files. Restore it or import it again.";
                    }
                }
            }
            catch (Exception)
            {
                error = "The recordings folder could not be opened.";
            }
            Send("macLibraryState", new { loading = false, error, items });
        }
        void PlayLibrary(Dictionary<string, object> body, long request)
        {
            long id = Num(body, "itemId");
            var folder = Folder(id);
            var r = ReadRecording(folder);
            if (r.sourceId != id)
                throw Problem("Recording unavailable.");
            var tracks = r.tracks
                             .Select((t, i) => new MediaTrack { number = i + 1, title = t.title,
                                                                durationSeconds = t.durationSeconds,
                                                                mime = Types[Path.GetExtension(t.file)],
                                                                localPath = Path.Combine(folder, t.file) })
                             .ToList();
            Queue(request, r.Title, "library", tracks, (int)Num(body, "trackIndex"));
        }
        void DownloadState(long id, string status, double progress, string message, string title)
        {
            Send("macDownloadState", new { sourceId = id, status, progress, message, title });
        }
        void OpenFolder(string path)
        {
            Process.Start(
                new ProcessStartInfo("explorer.exe", "/select,\"" + path + "\"") { UseShellExecute = false });
        }
        async Task Library(Dictionary<string, object> p)
        {
            var action = Str(p, "action");
            long id = Num(p, "itemId");
            var folder = Folder(id);
            if (action == "openFolder")
            {
                ReadRecording(folder);
                OpenFolder(folder);
            }
            else if (action == "remove")
            {
                if (transfers.ContainsKey(id))
                    throw Problem("Cancel the active transfer before removing the recording.");
                if (RealDirectory(folder))
                {
                    Form owner = Form.ActiveForm;
                    RecycleRecording(folder, owner != null ? owner.Handle : IntPtr.Zero);
                }
            }
            else if (action == "import")
            {
                SourceRef source =
                    Num(p, "sourceId") == 0 ? null : Source(Num(p, "sourceId"), Num(p, "showId"));
                using (var picker =
                           new OpenFileDialog { Title = "Import original audio or a ZIP recording",
                                                Multiselect = true,
                                                Filter = "Audio recordings or " +
                                                         "ZIP|*.mp3;*.flac;*.wav;*.wave;*.aif;*.aiff;*." +
                                                         "aifc;*.alac;*.aac;*.m4a;*.mp4;*.caf;*.zip" })
                {
                    var owner = Form.ActiveForm;
                    if ((owner != null ? picker.ShowDialog(owner) : picker.ShowDialog()) == DialogResult.OK)
                        await Import(source, picker.FileNames);
                }
            }
            PublishLibrary();
        }
        public async Task ImportOriginalAsync(long sourceId, string downloadedPath)
        {
            await Import(Source(sourceId), new[] { downloadedPath });
        }
        static CancellationTokenSource ActiveTransfer(Dictionary<long, CancellationTokenSource> active,
                                                      long id, CancellationToken parent)
        {
            if (active.ContainsKey(id))
                throw Problem("A transfer for this recording is already running.");
            var token = CancellationTokenSource.CreateLinkedTokenSource(parent);
            active.Add(id, token);
            return token;
        }
        string Stage()
        {
            Directory.CreateDirectory(LibraryRoot);
            var folder = Path.Combine(LibraryRoot, ".incoming-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            return folder;
        }
        static void Clean(string path)
        {
            try
            {
                if (path != null && Directory.Exists(path))
                    Directory.Delete(path, true);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
        void Install(string stage, Recording r)
        {
            File.WriteAllText(Path.Combine(stage, "recording.json"), Json().Serialize(r));
            ReadRecording(stage);
            var target = Folder(r.sourceId);
            var backup = target + ".previous";
            if (Directory.Exists(backup))
            {
                if (!Directory.Exists(target))
                    Directory.Move(backup, target);
                else
                    Directory.Delete(backup, true);
            }
            if (Directory.Exists(target))
                Directory.Move(target, backup);
            try
            {
                Directory.Move(stage, target);
            }
            catch
            {
                if (!Directory.Exists(target) && Directory.Exists(backup))
                    Directory.Move(backup, target);
                throw;
            }
            Clean(backup);
        }
        void RecoverLibrary()
        {
            Directory.CreateDirectory(LibraryRoot);
            foreach (var f in Directory.GetDirectories(LibraryRoot, "*.previous"))
            {
                string name = Path.GetFileNameWithoutExtension(f);
                long id;
                if (Int64.TryParse(name, out id) && !Directory.Exists(Folder(id)))
                    Directory.Move(f, Folder(id));
                else if (Int64.TryParse(name, out id))
                    Clean(f);
            }
            foreach (var f in Directory.GetDirectories(LibraryRoot, ".incoming-*"))
                Clean(f);
        }
        static bool HasAudioHeader(string name)
        {
            byte[] bytes = new byte[4096];
            int n;
            using (var fs = File.OpenRead(name)) n = fs.Read(bytes, 0, bytes.Length);
            string sig = Encoding.ASCII.GetString(bytes, 0, Math.Min(n, 12)),
                   ext = Path.GetExtension(name).ToLowerInvariant();
            if (ext == ".mp3")
            {
                if (sig.StartsWith("ID3", StringComparison.Ordinal) && n >= 10)
                    return true;
                for (int i = 0; i + 3 < n; i++)
                    if (bytes[i] == 255 && (bytes[i + 1] & 0xe0) == 0xe0 && (bytes[i + 1] & 6) != 0 &&
                        (bytes[i + 2] & 0xf0) != 0xf0)
                        return true;
                return false;
            }
            if (ext == ".flac")
                return sig.StartsWith("fLaC");
            if (ext == ".wav" || ext == ".wave")
                return (sig.StartsWith("RIFF") || sig.StartsWith("RF64")) && sig.EndsWith("WAVE");
            if (ext == ".aif" || ext == ".aiff" || ext == ".aifc")
                return sig.StartsWith("FORM") && (sig.EndsWith("AIFF") || sig.EndsWith("AIFC"));
            if (ext == ".aac")
                return n >= 2 && bytes[0] == 255 && (bytes[1] & 246) == 240;
            if (ext == ".caf")
                return sig.StartsWith("caff");
            if (ext == ".alac" && sig.StartsWith("caff"))
                return true;
            return sig.Length >= 8 && sig.Substring(4, 4) == "ftyp";
        }
        static async Task<long> CopyBounded(Stream input, string file, long limit, CancellationToken token,
                                            Action<long> progress = null)
        {
            using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                                               65536, true))
            {
                var block = new byte[65536];
                long total = 0;
                int n;
                while ((n = await input.ReadAsync(block, 0, block.Length, token).ConfigureAwait(false)) > 0)
                {
                    total += n;
                    if (total > limit)
                        throw Problem("This recording exceeds the storage limit.");
                    await output.WriteAsync(block, 0, n, token).ConfigureAwait(false);
                    if (progress != null)
                        progress(total);
                }
                if (total == 0)
                    throw Problem("An audio file was empty.");
                return total;
            }
        }
        async Task Download(Dictionary<string, object> p)
        {
            long id = Num(p, "sourceId");
            CancellationTokenSource cancel;
            if (Str(p, "action") == "cancel")
            {
                if (transfers.TryGetValue(id, out cancel))
                    cancel.Cancel();
                return;
            }
            if (Str(p, "action") != "save")
                return;
            SourceRef source = Source(id, Num(p, "showId"));
            if (transfers.ContainsKey(id))
                return;
            if (Directory.Exists(Folder(id)))
            {
                ReadRecording(Folder(id));
                DownloadState(id, "complete", 1, "Already in Library", source.Title);
                PublishLibrary();
                return;
            }
            cancel = ActiveTransfer(transfers, id, shutdown.Token);
            string stage = null;
            try
            {
                DownloadState(id, "resolving", 0, "Finding tracks…", source.Title);
                var tracks = await Archive(source, cancel.Token);
                stage = Stage();
                var r = new Recording {
                    sourceId = id,        showId = source.showId,        date = source.date,
                    venue = source.venue, version = source.versionLabel, tracks = new List<SavedTrack>()
                };
                long total = 0;
                for (int i = 0; i < tracks.Count; i++)
                {
                    var t = tracks[i];
                    string file = (i + 1).ToString("000") + ".mp3", target = Path.Combine(stage, file);
                    DownloadState(id, "downloading", i / (double)tracks.Count,
                                  "Saving track " + (i + 1) + " of " + tracks.Count, source.Title);
                    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                               cancel.Token)) using (var req =
                                                         new HttpRequestMessage(HttpMethod.Get, t.remote))
                    {
                        timeout.CancelAfter(TimeSpan.FromMinutes(10));
                        using (var res = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead,
                                                              timeout.Token))
                        {
                            if (!res.IsSuccessStatusCode)
                                throw Problem("The archive could not deliver this track.");
                            using (var raw = await res.Content.ReadAsStreamAsync())
                            {
                                var count =
                                    await CopyBounded(raw, target, MaxRecordingSize - total, timeout.Token);
                                if (res.Content.Headers.ContentLength.HasValue &&
                                    count != res.Content.Headers.ContentLength)
                                    throw Problem("An audio download ended early.");
                                total += count;
                            }
                        }
                    }
                    if (!HasAudioHeader(target))
                        throw Problem("The archive did not return a valid MP3.");
                    r.tracks.Add(
                        new SavedTrack { title = t.title, durationSeconds = t.durationSeconds, file = file });
                }
                cancel.Token.ThrowIfCancellationRequested();
                Install(stage, r);
                DownloadState(id, "complete", 1, "Saved to Library", source.Title);
                PublishLibrary();
            }
            catch (OperationCanceledException)
            {
                DownloadState(id, cancel.IsCancellationRequested ? "cancelled" : "failed", 0,
                              cancel.IsCancellationRequested ? "Download cancelled"
                                                             : "The download timed out.",
                              source.Title);
            }
            finally
            {
                Clean(stage);
                transfers.Remove(id);
                cancel.Dispose();
            }
        }
        static string SortKey(string path)
        {
            return Regex.Replace(path, @"\d+", m => m.Value.PadLeft(12, '0'));
        }
        async Task Import(SourceRef source, string[] files)
        {
            if (files.Length < 1 || files.Length > 250)
                throw Problem("Choose up to 250 audio files or one ZIP archive.");
            long id = source != null ? source.sourceId : -DateTime.UtcNow.Ticks / 10000;
            // JavaScript integers can represent millisecond ticks exactly.
            if (source == null)
                while (Directory.Exists(Folder(id)) || transfers.ContainsKey(id))
                    id--;
            string title = source != null ? source.Title : Path.GetFileNameWithoutExtension(files[0]);
            var r = new Recording { sourceId = id,
                                    showId = source != null ? source.showId : 0,
                                    date = source != null ? source.date : "",
                                    venue = source != null ? source.venue : title,
                                    version = source != null ? source.versionLabel : "Imported audio",
                                    tracks = new List<SavedTrack>() };
            var cancel = ActiveTransfer(transfers, id, shutdown.Token);
            string stage = null;
            try
            {
                stage = Stage();
                DownloadState(id, "downloading", 0, "Importing original audio…", title);
                await Task.Run(async delegate {
                    long total = 0;
                    Func<string, Stream, Task> add = async (name, input) =>
                    {
                        string ext = Path.GetExtension(name).ToLowerInvariant();
                        if (!Types.ContainsKey(ext))
                            throw Problem("This audio format is unsupported.");
                        string file = (r.tracks.Count + 1).ToString("000") + ext;
                        string dest = Path.Combine(stage, file);
                        total += await CopyBounded(input, dest, MaxRecordingSize - total, cancel.Token)
                                     .ConfigureAwait(false);
                        if (!HasAudioHeader(dest))
                            throw Problem("The file does not contain the selected audio format.");
                        r.tracks.Add(
                            new SavedTrack { file = file, title = Path.GetFileNameWithoutExtension(name) });
                    };
                    if (files.Length == 1 &&
                        Path.GetExtension(files[0]).Equals(".zip", StringComparison.OrdinalIgnoreCase))
                    {
                        using (var zip = new ZipArchive(File.OpenRead(files[0]), ZipArchiveMode.Read))
                        {
                            if (zip.Entries.Count > 10000)
                                throw Problem("The archive contains too many entries.");
                            var entries =
                                zip.Entries
                                    .Where(e => !e.FullName.StartsWith("__MACOSX/",
                                                                       StringComparison.OrdinalIgnoreCase) &&
                                                !e.Name.StartsWith(".") &&
                                                Types.ContainsKey(Path.GetExtension(e.Name)))
                                    .OrderBy(e => SortKey(e.FullName), StringComparer.OrdinalIgnoreCase)
                                    .ToList();
                            if (entries.Count < 1 || entries.Count > 250)
                                throw Problem("The ZIP must contain between 1 and 250 audio tracks.");
                            foreach (var e in entries)
                            {
                                if (e.Length <= 0 || e.Length > MaxRecordingSize - total)
                                    throw Problem("Invalid ZIP audio size.");
                                using (var stream = e.Open()) await add(e.Name, stream).ConfigureAwait(false);
                            }
                        }
                    }
                    else
                    {
                        foreach (var file in files.OrderBy(f => SortKey(Path.GetFileName(f)),
                                             StringComparer.OrdinalIgnoreCase))
                        {
                            using (var stream = File.OpenRead(file)) await add(Path.GetFileName(file), stream)
                                .ConfigureAwait(false);
                        }
                    }
                }, cancel.Token);
                cancel.Token.ThrowIfCancellationRequested();
                Install(stage, r);
                DownloadState(id, "complete", 1, "Original audio imported", title);
                PublishLibrary();
            }
            catch (OperationCanceledException)
            {
                DownloadState(id, "cancelled", 0, "Import cancelled", title);
                throw;
            }
            catch (Exception e)
            {
                DownloadState(id, "failed", 0, Message(e), title);
                throw;
            }
            finally
            {
                Clean(stage);
                transfers.Remove(id);
                cancel.Dispose();
            }
        }
    }
}
