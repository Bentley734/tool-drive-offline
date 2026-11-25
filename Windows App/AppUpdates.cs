using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    public sealed class AppRelease
    {
        public Version Version { get; set; }
        public string TagName { get; set; }
        public string AssetUrl { get; set; }
        public string Sha256 { get; set; }
        public string ReleasePageUrl { get; set; }
        public long Size { get; set; }
    }

    public static class AppUpdater
    {
        private const string ApiUrl = "https://api.github.com/repos/Bentley734/tool-drive-offline/releases/latest";
        private const string ProjectUrl = "https://github.com/Bentley734/tool-drive-offline";
        private const string AssetName = "Tool.Drive.Offline.exe";
        private const int MaximumMetadataBytes = 2 * 1024 * 1024;
        private const long MaximumExecutableBytes = 64 * 1024 * 1024;
        private static readonly Regex TagPattern = new Regex(@"^v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?$", RegexOptions.CultureInvariant);
        private static readonly Regex HashPattern = new Regex(@"^[0-9a-fA-F]{64}$", RegexOptions.CultureInvariant);
        public static Version CurrentVersion { get { return Normalize(Assembly.GetExecutingAssembly().GetName().Version); } }
        private static string StagingRoot { get { return Path.Combine(DesktopBootstrap.Profile, "AppUpdates"); } }

        public static Task<AppRelease> CheckAsync(CancellationToken token)
        {
            return CheckAsync(CurrentVersion, FetchMetadataAsync, token);
        }
        public static async Task<AppRelease> CheckAsync(Version current, Func<Uri, CancellationToken, Task<string>> fetch, CancellationToken token)
        {
            if (current == null) throw new ArgumentNullException("current");
            if (fetch == null) throw new ArgumentNullException("fetch");
            token.ThrowIfCancellationRequested();
            string json = await fetch(new Uri(ApiUrl), token).ConfigureAwait(false);
            token.ThrowIfCancellationRequested();
            return ParseRelease(json, current);
        }
        public static AppRelease ParseRelease(string json, Version current)
        {
            if (current == null) throw new ArgumentNullException("current");
            if (String.IsNullOrWhiteSpace(json) || Encoding.UTF8.GetByteCount(json) > MaximumMetadataBytes) throw new InvalidDataException("The GitHub release metadata was empty or too large.");
            StrictJson reader = new StrictJson(json.TrimStart('\uFEFF'), 0);
            Dictionary<string, object> root = reader.Read() as Dictionary<string, object>;
            reader.WhiteSpace();
            if (!reader.AtEnd || root == null) throw new InvalidDataException("The GitHub release metadata was malformed.");
            if (BooleanField(root, "draft") || BooleanField(root, "prerelease")) return null;
            string tag = StringField(root, "tag_name");
            Version version = ParseTag(tag);
            if (version.CompareTo(Normalize(current)) <= 0) return null;
            string page = StringField(root, "html_url");
            RequireExactUrl(page, ProjectUrl + "/releases/tag/" + tag);
            object rawAssets;
            List<object> assets;
            if (!root.TryGetValue("assets", out rawAssets) || (assets = rawAssets as List<object>) == null) throw new InvalidDataException("The GitHub release asset list was missing.");
            AppRelease release = null;
            foreach (object value in assets)
            {
                Dictionary<string, object> asset = value as Dictionary<string, object>;
                if (asset == null) throw new InvalidDataException("The GitHub release asset list was malformed.");
                if (StringField(asset, "name") != AssetName) continue;
                if (release != null) throw new InvalidDataException("The release contained duplicate Windows executable assets.");
                string digest = StringField(asset, "digest");
                if (!digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) || !HashPattern.IsMatch(digest.Substring(7))) throw new InvalidDataException("The Windows release asset did not have a valid SHA-256 digest.");
                release = new AppRelease { Version = version, TagName = tag, AssetUrl = StringField(asset, "browser_download_url"), ReleasePageUrl = page, Sha256 = digest.Substring(7).ToLowerInvariant(), Size = IntegerField(asset, "size") };
                ValidateRelease(release);
            }
            if (release == null) throw new InvalidDataException("The release did not contain the portable Windows executable.");
            return release;
        }

        public static Task<string> DownloadAsync(AppRelease release, CancellationToken token)
        {
            ValidateRelease(release);
            return DownloadAsync(release, Path.Combine(StagingRoot, Normalize(release.Version).ToString(4)), token);
        }
        // Explicit-directory overload allows tests to stay entirely inside their own scratch folder.
        public static async Task<string> DownloadAsync(AppRelease release, string stagingDir, CancellationToken token)
        {
            ValidateRelease(release);
            token.ThrowIfCancellationRequested();
            string directory = Path.GetFullPath(stagingDir);
            Directory.CreateDirectory(directory);
            string final = Path.Combine(directory, AssetName);
            if (File.Exists(final))
            {
                try { VerifyCandidate(final, release); token.ThrowIfCancellationRequested(); return final; }
                catch (InvalidDataException) { }
                catch (BadImageFormatException) { }
            }
            string temporary = Path.Combine(directory, ".download-" + Guid.NewGuid().ToString("N") + ".tmp");
            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
                using (HttpClientHandler handler = Handler())
                using (HttpClient client = new HttpClient(handler))
                {
                    client.Timeout = Timeout.InfiniteTimeSpan;
                    client.DefaultRequestHeaders.UserAgent.ParseAdd("ToolDriveOffline/" + CurrentVersion.ToString(3) + " AppUpdate");
                    Uri address = new Uri(release.AssetUrl);
                    bool downloaded = false;
                    using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
                    {
                        timeout.CancelAfter(TimeSpan.FromSeconds(120));
                        for (int redirects = 0; redirects <= 5; redirects++)
                        {
                            timeout.Token.ThrowIfCancellationRequested();
                            using (HttpRequestMessage request = Request(address, false))
                            using (HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                            using (timeout.Token.Register(delegate { response.Dispose(); }))
                            {
                                if (Redirect(response.StatusCode))
                                {
                                    if (redirects == 5 || response.Headers.Location == null) throw new InvalidDataException("The release asset had too many or invalid redirects.");
                                    Uri next = new Uri(address, response.Headers.Location);
                                    ValidateDownloadRedirect(next, release);
                                    address = next;
                                    continue;
                                }
                                response.EnsureSuccessStatusCode();
                                if (response.StatusCode != HttpStatusCode.OK) throw new InvalidDataException("The release server did not return the complete executable.");
                                if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value != release.Size) throw new InvalidDataException("The Windows release download size did not match GitHub metadata.");
                                try
                                {
                                    using (Stream body = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                                    using (FileStream output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                                    {
                                        byte[] buffer = new byte[65536];
                                        long count = 0;
                                        int read;
                                        while ((read = await body.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) != 0)
                                        {
                                            count += read;
                                            if (count > release.Size || count > MaximumExecutableBytes) throw new InvalidDataException("The Windows release download exceeded its expected size.");
                                            output.Write(buffer, 0, read);
                                        }
                                        timeout.Token.ThrowIfCancellationRequested();
                                        if (count != release.Size) throw new InvalidDataException("The Windows release download was incomplete.");
                                        output.Flush(true);
                                    }
                                }
                                catch (Exception error)
                                {
                                    if (timeout.IsCancellationRequested && (error is IOException || error is ObjectDisposedException || error is HttpRequestException)) throw new OperationCanceledException("The app download was canceled or timed out.", error, timeout.Token);
                                    throw;
                                }
                                downloaded = true;
                                break;
                            }
                        }
                    }
                    if (!downloaded) throw new InvalidDataException("The Windows release could not be downloaded.");
                }
                token.ThrowIfCancellationRequested();
                VerifyCandidate(temporary, release);
                token.ThrowIfCancellationRequested();
                if (File.Exists(final)) File.Replace(temporary, final, null); else File.Move(temporary, final);
                return final;
            }
            finally { DeleteOwnFile(temporary); }
        }

        public static void VerifyCandidate(string path, AppRelease release)
        {
            ValidateRelease(release);
            FileInfo info = new FileInfo(path);
            if (!info.Exists || info.Length != release.Size || info.Length < 2 || info.Length > MaximumExecutableBytes) throw new InvalidDataException("The staged Windows executable had the wrong size.");
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.ReadByte() != 'M' || stream.ReadByte() != 'Z') throw new InvalidDataException("The downloaded file was not a Windows executable.");
                stream.Position = 0;
                using (SHA256 sha = SHA256.Create()) if (!SameHash(Hex(sha.ComputeHash(stream)), release.Sha256)) throw new InvalidDataException("The Windows executable's SHA-256 digest did not match GitHub.");
            }
            AssemblyName identity;
            try { identity = AssemblyName.GetAssemblyName(path); }
            catch (Exception error)
            {
                if (error is BadImageFormatException || error is FileLoadException) throw new InvalidDataException("The downloaded file was not the expected managed Windows app.", error);
                throw;
            }
            if (!String.Equals(identity.Name, Assembly.GetExecutingAssembly().GetName().Name, StringComparison.Ordinal) || Normalize(identity.Version) != Normalize(release.Version)) throw new InvalidDataException("The downloaded executable's application name or version did not match this release.");
        }

        public static bool BeginInstall(AppRelease release, string candidatePath, string targetExe, out string error)
        {
            error = null;
            Process helper = null;
            try
            {
                ValidateRelease(release);
                if (Normalize(release.Version).CompareTo(CurrentVersion) <= 0) throw new InvalidDataException("The app update is not newer than this application.");
                string target = Path.GetFullPath(targetExe);
                using (Process parent = Process.GetCurrentProcess())
                {
                    if (!SamePath(target, parent.MainModule.FileName)) throw new InvalidDataException("The update target must be this running application's executable.");
                    RequireTargetIdentity(target);
                    if (Normalize(AssemblyName.GetAssemblyName(target).Version).CompareTo(Normalize(release.Version)) >= 0) throw new InvalidDataException("The installed executable is already this version or newer.");
                    RequireNoOtherInstance(target, parent.Id);
                    VerifyCandidate(candidatePath, release);
                    string candidate = Path.GetFullPath(candidatePath);
                    string expectedStage = Path.Combine(StagingRoot, Normalize(release.Version).ToString(4), AssetName);
                    if (!SamePath(candidate, expectedStage)) throw new InvalidDataException("The app update was not in its expected private staging folder.");
                    RejectReparsePath(candidate, StagingRoot);
                    ProbeWritableDirectory(Path.GetDirectoryName(target));
                    string id = Guid.NewGuid().ToString("N");
                    string folder = Path.Combine(StagingRoot, "install-" + id);
                    Directory.CreateDirectory(folder);
                    RejectReparsePath(folder, StagingRoot);
                    string helperPath = Path.Combine(folder, "ToolDriveOffline.UpdateHelper.exe");
                    string manifestPath = Path.Combine(folder, "update.json");
                    string oldHash = FileHash(target);
                    File.Copy(target, helperPath, false);
                    if (!SameHash(FileHash(helperPath), oldHash)) throw new InvalidDataException("The app update helper copy did not match this executable.");
                    UpdateManifest manifest = new UpdateManifest { SchemaVersion = 1, ParentPid = parent.Id, ParentStartUtcTicks = parent.StartTime.ToUniversalTime().Ticks, Target = target, Candidate = candidate, ReleaseVersion = Normalize(release.Version).ToString(4), TagName = release.TagName, AssetUrl = release.AssetUrl, Sha256 = release.Sha256, Size = release.Size, ReleasePageUrl = release.ReleasePageUrl, CurrentSha256 = oldHash, HelperPath = helperPath, ReadyEventName = "Local\\ToolDriveOffline.Update." + id };
                    File.WriteAllText(manifestPath, Serializer().Serialize(manifest), new UTF8Encoding(false));
                    using (EventWaitHandle ready = new EventWaitHandle(false, EventResetMode.ManualReset, manifest.ReadyEventName))
                    {
                        ProcessStartInfo start = new ProcessStartInfo(helperPath, "--apply-app-update " + QuotePath(manifestPath));
                        start.UseShellExecute = false;
                        start.CreateNoWindow = true;
                        start.WorkingDirectory = folder;
                        helper = Process.Start(start);
                        if (helper == null) throw new InvalidOperationException("The app update helper could not be started.");
                        if (!ready.WaitOne(TimeSpan.FromSeconds(15)))
                        {
                            try { if (!helper.HasExited) helper.Kill(); } catch (InvalidOperationException) { }
                            throw new IOException("The app update helper did not become ready. This app is still open and unchanged.");
                        }
                    }
                }
                return true;
            }
            catch (Exception problem)
            {
                if (problem is OutOfMemoryException || problem is StackOverflowException) throw;
                error = "The app update could not be started. Your current app was kept. " + problem.Message;
                return false;
            }
            finally { if (helper != null) helper.Dispose(); }
        }

        // Program calls this before opening any GUI. Only a validated copied helper consumes it.
        public static bool HandleCommandLine(string[] args)
        {
            if (args == null || args.Length == 0 || args[0] != "--apply-app-update") return false;
            string logFolder = null;
            try
            {
                if (args.Length != 2) throw new InvalidDataException("The app update helper arguments were invalid.");
                string manifestPath = ValidateManifestPath(args[1]);
                logFolder = Path.GetDirectoryName(manifestPath);
                if (new FileInfo(manifestPath).Length > 16384) throw new InvalidDataException("The app update plan was too large.");
                string json = File.ReadAllText(manifestPath, new UTF8Encoding(false, true));
                StrictJson reader = new StrictJson(json, 0);
                if (!(reader.Read() is Dictionary<string, object>)) throw new InvalidDataException("The app update plan was malformed.");
                reader.WhiteSpace();
                if (!reader.AtEnd) throw new InvalidDataException("The app update plan contained unexpected data.");
                UpdateManifest manifest = Serializer().Deserialize<UpdateManifest>(json);
                string id = Path.GetFileName(logFolder).Substring("install-".Length);
                if (manifest == null || manifest.SchemaVersion != 1 || manifest.ParentPid <= 0 || manifest.ParentPid == Process.GetCurrentProcess().Id || manifest.ParentStartUtcTicks <= 0 || !HashPattern.IsMatch(manifest.CurrentSha256 ?? "") || manifest.ReadyEventName != "Local\\ToolDriveOffline.Update." + id || !SamePath(manifest.HelperPath, Path.Combine(logFolder, "ToolDriveOffline.UpdateHelper.exe"))) throw new InvalidDataException("The app update plan did not match its private helper folder.");
                using (Process own = Process.GetCurrentProcess()) if (!SamePath(own.MainModule.FileName, manifest.HelperPath)) throw new InvalidDataException("App update mode can only run from its copied helper executable.");
                AppRelease release = manifest.Release();
                ValidateRelease(release);
                if (Normalize(release.Version).CompareTo(CurrentVersion) <= 0) throw new InvalidDataException("The app update was no longer newer than its helper.");
                if (!SamePath(manifest.Candidate, Path.Combine(StagingRoot, Normalize(release.Version).ToString(4), AssetName))) throw new InvalidDataException("The staged executable was outside the update folder.");
                RejectReparsePath(manifest.Candidate, StagingRoot);
                if (!SameHash(FileHash(manifest.HelperPath), manifest.CurrentSha256)) throw new InvalidDataException("The update helper's original hash did not match the plan.");
                VerifyCandidate(manifest.Candidate, release);
                using (Process parent = Process.GetProcessById(manifest.ParentPid))
                {
                    if (parent.HasExited || parent.StartTime.ToUniversalTime().Ticks != manifest.ParentStartUtcTicks || !SamePath(parent.MainModule.FileName, manifest.Target)) throw new InvalidDataException("The original app process no longer matched this update plan.");
                    RequireTargetIdentity(manifest.Target);
                    if (!SameHash(FileHash(manifest.Target), manifest.CurrentSha256)) throw new InvalidDataException("The current executable changed after the update was prepared.");
                    using (EventWaitHandle ready = EventWaitHandle.OpenExisting(manifest.ReadyEventName)) ready.Set();
                    if (!parent.WaitForExit(60000)) throw new IOException("The original app did not close within 60 seconds. Its executable was kept unchanged.");
                }
                RequireNoOtherInstance(manifest.Target, Process.GetCurrentProcess().Id);
                // This hash is checked again immediately before each atomic replacement attempt.
                InstallFilesCore(manifest.Target, manifest.Candidate, release, StartUpdatedApp, manifest.CurrentSha256);
                DeleteOwnFile(manifestPath);
            }
            catch (Exception error)
            {
                if (error is OutOfMemoryException || error is StackOverflowException) throw;
                string message = "The app update could not be completed. The previous executable was kept or restored.\r\n\r\n" + error.Message;
                if (logFolder != null)
                {
                    try { File.WriteAllText(Path.Combine(logFolder, "update-error.txt"), DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture) + "\r\n" + error, new UTF8Encoding(false)); }
                    catch (IOException) { } catch (UnauthorizedAccessException) { }
                }
                MessageBox.Show(message, "Tool Drive Offline update", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return true;
        }

        // Test seam: no process waiting, GUI, real profile paths, or implicit application launch.
        public static void InstallFiles(string target, string candidate, AppRelease release, Action<string> startProcess)
        {
            InstallFilesCore(target, candidate, release, startProcess, FileHash(target));
        }
        private static void InstallFilesCore(string target, string candidate, AppRelease release, Action<string> startProcess, string expectedCurrentHash)
        {
            if (startProcess == null) throw new ArgumentNullException("startProcess");
            ValidateRelease(release);
            target = Path.GetFullPath(target); candidate = Path.GetFullPath(candidate);
            if (SamePath(target, candidate)) throw new InvalidDataException("The update candidate and installed executable must be separate files.");
            RequireTargetIdentity(target);
            if (Normalize(AssemblyName.GetAssemblyName(target).Version).CompareTo(Normalize(release.Version)) >= 0) throw new InvalidDataException("The installed executable is already this version or newer.");
            VerifyCandidate(candidate, release);
            string incoming = target + ".update-" + Guid.NewGuid().ToString("N") + ".incoming";
            string backup = target + ".update-" + Guid.NewGuid().ToString("N") + ".bak";
            bool replaced = false;
            try
            {
                File.Copy(candidate, incoming, false);
                VerifyCandidate(incoming, release);
                DateTime deadline = DateTime.UtcNow.AddSeconds(30);
                while (true)
                {
                    if (!SameHash(FileHash(target), expectedCurrentHash)) throw new InvalidDataException("The installed executable changed during the update. It was not overwritten.");
                    try { File.Replace(incoming, target, backup, true); replaced = true; break; }
                    catch (IOException)
                    {
                        if (File.Exists(backup) || DateTime.UtcNow >= deadline) throw;
                        Thread.Sleep(250);
                    }
                }
                VerifyCandidate(target, release);
                startProcess(target);
                DeleteOwnFile(backup);
            }
            catch (Exception error)
            {
                if (replaced || File.Exists(backup))
                {
                    try
                    {
                        if (File.Exists(target)) File.Replace(backup, target, null, true);
                        else File.Move(backup, target);
                        if (!SameHash(FileHash(target), expectedCurrentHash)) throw new IOException("The restored executable did not match its original hash.");
                    }
                    catch (Exception rollback)
                    {
                        throw new IOException("The app update failed and automatic restoration could not finish. The original executable backup is: " + backup, new AggregateException(error, rollback));
                    }
                }
                throw;
            }
            finally { DeleteOwnFile(incoming); }
        }

        private static async Task<string> FetchMetadataAsync(Uri address, CancellationToken token)
        {
            if (address.AbsoluteUri != ApiUrl) throw new InvalidDataException("Only this app's GitHub release endpoint is allowed.");
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            using (HttpClientHandler handler = Handler())
            using (HttpClient client = new HttpClient(handler))
            using (CancellationTokenSource timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            using (HttpRequestMessage request = Request(address, true))
            {
                client.Timeout = Timeout.InfiniteTimeSpan;
                client.DefaultRequestHeaders.UserAgent.ParseAdd("ToolDriveOffline/" + CurrentVersion.ToString(3) + " AppUpdate");
                timeout.CancelAfter(TimeSpan.FromSeconds(30));
                using (HttpResponseMessage response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false))
                using (timeout.Token.Register(delegate { response.Dispose(); }))
                {
                    response.EnsureSuccessStatusCode();
                    if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value > MaximumMetadataBytes) throw new InvalidDataException("GitHub release metadata exceeded its size limit.");
                    try
                    {
                        using (Stream body = await response.Content.ReadAsStreamAsync().ConfigureAwait(false))
                        using (MemoryStream bytes = new MemoryStream())
                        {
                            byte[] buffer = new byte[16384]; int count;
                            while ((count = await body.ReadAsync(buffer, 0, buffer.Length, timeout.Token).ConfigureAwait(false)) != 0)
                            {
                                if (bytes.Length + count > MaximumMetadataBytes) throw new InvalidDataException("GitHub release metadata exceeded its size limit.");
                                bytes.Write(buffer, 0, count);
                            }
                            timeout.Token.ThrowIfCancellationRequested();
                            return new UTF8Encoding(false, true).GetString(bytes.ToArray());
                        }
                    }
                    catch (Exception error)
                    {
                        if (timeout.IsCancellationRequested && (error is IOException || error is ObjectDisposedException || error is HttpRequestException)) throw new OperationCanceledException("The app release check was canceled or timed out.", error, timeout.Token);
                        throw;
                    }
                }
            }
        }
        private static HttpClientHandler Handler()
        {
            return new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false, AutomaticDecompression = DecompressionMethods.None };
        }
        private static HttpRequestMessage Request(Uri address, bool metadata)
        {
            HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, address);
            request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true, MaxAge = TimeSpan.Zero };
            request.Headers.Pragma.ParseAdd("no-cache");
            if (metadata) { request.Headers.Accept.ParseAdd("application/vnd.github+json"); request.Headers.Add("X-GitHub-Api-Version", "2022-11-28"); }
            return request;
        }
        private static void ValidateRelease(AppRelease release)
        {
            if (release == null || release.Version == null || release.Size < 1 || release.Size > MaximumExecutableBytes || !HashPattern.IsMatch(release.Sha256 ?? "") || ParseTag(release.TagName) != Normalize(release.Version)) throw new InvalidDataException("The app release identity, size, or SHA-256 digest was invalid.");
            RequireExactUrl(release.ReleasePageUrl, ProjectUrl + "/releases/tag/" + release.TagName);
            RequireExactUrl(release.AssetUrl, ProjectUrl + "/releases/download/" + release.TagName + "/" + AssetName);
        }
        private static void RequireExactUrl(string value, string expected)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Query.Length != 0 || uri.Fragment.Length != 0 || value != expected) throw new InvalidDataException("A release URL was not the expected HTTPS URL for this GitHub project.");
        }
        private static void ValidateDownloadRedirect(Uri address, AppRelease release)
        {
            if (address.Scheme != Uri.UriSchemeHttps || !address.IsDefaultPort || address.UserInfo.Length != 0 || address.Fragment.Length != 0) throw new InvalidDataException("The app download attempted an unsafe redirect.");
            if (address.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)) { RequireExactUrl(address.AbsoluteUri, release.AssetUrl); return; }
            if (!address.Host.Equals("release-assets.githubusercontent.com", StringComparison.OrdinalIgnoreCase) && !address.Host.Equals("objects.githubusercontent.com", StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("The app download redirected outside GitHub's release asset servers.");
        }
        private static bool Redirect(HttpStatusCode status)
        {
            int code = (int)status;
            return code == 301 || code == 302 || code == 303 || code == 307 || code == 308;
        }
        private static Version ParseTag(string tag)
        {
            Match match = TagPattern.Match(tag ?? "");
            int major, minor, build, revision = 0;
            if (!match.Success || !Int32.TryParse(match.Groups[1].Value, NumberStyles.None, CultureInfo.InvariantCulture, out major) || !Int32.TryParse(match.Groups[2].Value, NumberStyles.None, CultureInfo.InvariantCulture, out minor) || !Int32.TryParse(match.Groups[3].Value, NumberStyles.None, CultureInfo.InvariantCulture, out build) || (match.Groups[4].Success && !Int32.TryParse(match.Groups[4].Value, NumberStyles.None, CultureInfo.InvariantCulture, out revision))) throw new InvalidDataException("The release tag was not a stable numeric version.");
            return new Version(major, minor, build, revision);
        }
        private static Version Normalize(Version value)
        {
            if (value == null) throw new InvalidDataException("The executable version was missing.");
            return new Version(value.Major, value.Minor, Math.Max(0, value.Build), Math.Max(0, value.Revision));
        }
        private static bool BooleanField(Dictionary<string, object> map, string name)
        {
            object value;
            if (!map.TryGetValue(name, out value) || !(value is bool)) throw new InvalidDataException("A required GitHub release flag was missing: " + name + ".");
            return (bool)value;
        }
        private static string StringField(Dictionary<string, object> map, string name)
        {
            object value;
            if (!map.TryGetValue(name, out value) || !(value is string)) throw new InvalidDataException("A required GitHub release field was missing: " + name + ".");
            return (string)value;
        }
        private static long IntegerField(Dictionary<string, object> map, string name)
        {
            object value; long number;
            if (!map.TryGetValue(name, out value) || !(value is long || value is int) || !Int64.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out number)) throw new InvalidDataException("A required GitHub release size was invalid.");
            return number;
        }
        private static bool SamePath(string first, string second)
        {
            return String.Equals(Path.GetFullPath(first), Path.GetFullPath(second), StringComparison.OrdinalIgnoreCase);
        }
        private static void RejectReparsePath(string path, string root)
        {
            string full = Path.GetFullPath(path), boundary = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar);
            if (!full.StartsWith(boundary + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) && !SamePath(full, boundary)) throw new InvalidDataException("The update path was outside its private staging root.");
            string current = full;
            while (current.Length >= boundary.Length)
            {
                if ((File.Exists(current) || Directory.Exists(current)) && (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("A private update path was redirected through a filesystem link.");
                if (SamePath(current, boundary)) break;
                current = Path.GetDirectoryName(current);
            }
        }
        private static string ValidateManifestPath(string value)
        {
            string path = Path.GetFullPath(value);
            string folder = Path.GetDirectoryName(path);
            string folderName = Path.GetFileName(folder);
            Guid id;
            if (Path.GetFileName(path) != "update.json" || !SamePath(Path.GetDirectoryName(folder), StagingRoot) || !folderName.StartsWith("install-", StringComparison.Ordinal) || !Guid.TryParseExact(folderName.Substring(8), "N", out id)) throw new InvalidDataException("App update mode requires its own private installation plan.");
            RejectReparsePath(path, StagingRoot);
            return path;
        }
        private static void RequireTargetIdentity(string target)
        {
            AssemblyName identity = AssemblyName.GetAssemblyName(target);
            if (identity.Name != Assembly.GetExecutingAssembly().GetName().Name) throw new InvalidDataException("The update target was not this Windows application.");
        }
        private static void RequireNoOtherInstance(string target, int allowedPid)
        {
            foreach (Process process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(target)))
            {
                using (process)
                {
                    if (process.Id == allowedPid) continue;
                    try { if (!process.HasExited && SamePath(process.MainModule.FileName, target)) throw new IOException("Another copy of this app is using the executable. Close the other copy and try again."); }
                    catch (System.ComponentModel.Win32Exception) { }
                    catch (InvalidOperationException) { }
                }
            }
        }
        private static void ProbeWritableDirectory(string directory)
        {
            string probe = Path.Combine(directory, ".tool-drive-update-probe-" + Guid.NewGuid().ToString("N") + ".tmp");
            try { using (FileStream stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None)) stream.Flush(true); }
            finally { DeleteOwnFile(probe); }
        }
        private static void StartUpdatedApp(string path)
        {
            ProcessStartInfo start = new ProcessStartInfo(path) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(path) };
            Process process = Process.Start(start);
            if (process == null) throw new IOException("Windows could not launch the updated app.");
            process.Dispose();
        }
        private static string QuotePath(string path)
        {
            if (path.IndexOf('"') >= 0 || path.IndexOf('\r') >= 0 || path.IndexOf('\n') >= 0) throw new InvalidDataException("The update plan path was invalid.");
            return "\"" + path + "\"";
        }
        private static string FileHash(string path)
        {
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (SHA256 sha = SHA256.Create()) return Hex(sha.ComputeHash(file));
        }
        private static string Hex(byte[] bytes) { return BitConverter.ToString(bytes).Replace("-", "").ToLowerInvariant(); }
        private static bool SameHash(string first, string second)
        {
            if (first == null || second == null || first.Length != second.Length) return false;
            int difference = 0;
            for (int index = 0; index < first.Length; index++) difference |= Char.ToLowerInvariant(first[index]) ^ Char.ToLowerInvariant(second[index]);
            return difference == 0;
        }
        private static void DeleteOwnFile(string path)
        {
            try { if (File.Exists(path)) File.Delete(path); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        private static JavaScriptSerializer Serializer() { return new JavaScriptSerializer { MaxJsonLength = 16384, RecursionLimit = 12 }; }
        private sealed class UpdateManifest
        {
            public UpdateManifest() { }
            public int SchemaVersion { get; set; }
            public int ParentPid { get; set; }
            public long ParentStartUtcTicks { get; set; }
            public string Target { get; set; }
            public string Candidate { get; set; }
            public string ReleaseVersion { get; set; }
            public string TagName { get; set; }
            public string AssetUrl { get; set; }
            public string Sha256 { get; set; }
            public long Size { get; set; }
            public string ReleasePageUrl { get; set; }
            public string CurrentSha256 { get; set; }
            public string HelperPath { get; set; }
            public string ReadyEventName { get; set; }
            public AppRelease Release()
            {
                Version version;
                if (!Version.TryParse(ReleaseVersion, out version)) throw new InvalidDataException("The installation plan's release version was invalid.");
                return new AppRelease { Version = version, TagName = TagName, AssetUrl = AssetUrl, Sha256 = Sha256, Size = Size, ReleasePageUrl = ReleasePageUrl };
            }
        }
    }
}
