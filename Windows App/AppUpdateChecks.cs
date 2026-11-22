using System;
using System.CodeDom.Compiler;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.CSharp;

// Isolated update fixtures never replace the real EXE or write to the user's update folder.
public static class AppUpdateChecks
{
    static Type updaterType, releaseType;
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = 2 * 1024 * 1024 };
    static int assertions;
    static string sourceExe;
    static Version currentVersion;
    static string Hash(string path)
    {
        using (var sha = SHA256.Create()) using (var file = File.OpenRead(path))
            return String.Concat(sha.ComputeHash(file).Select(value => value.ToString("x2", CultureInfo.InvariantCulture)));
    }
    static Dictionary<string, object> Map(params object[] pairs)
    {
        var result = new Dictionary<string, object>();
        for (int i = 0; i < pairs.Length; i += 2) result[(string)pairs[i]] = pairs[i + 1];
        return result;
    }
    static Dictionary<string, object> Asset(string tag, string digest, long size)
    {
        return Map("name", "Tool.Drive.Offline.exe", "state", "uploaded", "size", size, "digest", "sha256:" + digest,
            "browser_download_url", "https://github.com/Bentley734/tool-drive-offline/releases/download/" + tag + "/Tool.Drive.Offline.exe");
    }
    static Dictionary<string, object> Release(string tag, string digest, long size)
    {
        return Map("tag_name", tag, "draft", false, "prerelease", false,
            "html_url", "https://github.com/Bentley734/tool-drive-offline/releases/tag/" + tag,
            "assets", new object[] { Asset(tag, digest, size) });
    }
    static object Get(object value, string name) { return value.GetType().GetProperty(name).GetValue(value, null); }
    static void Set(object value, string name, object next) { value.GetType().GetProperty(name).SetValue(value, next, null); }
    static object Parse(Dictionary<string, object> release, Version current)
    {
        return updaterType.GetMethod("ParseRelease").Invoke(null, new object[] { Json.Serialize(release), current });
    }
    static void Assert(bool condition, string label) { if (!condition) throw new Exception(label); assertions++; Console.WriteLine("PASS " + label); }
    static bool Fails(Action action)
    {
        try { action(); return false; }
        catch (TargetInvocationException ex) { if (ex.InnerException == null) throw; return true; }
        catch (InvalidDataException) { return true; }
        catch (IOException) { return true; }
        catch (ArgumentException) { return true; }
        catch (InvalidOperationException) { return true; }
    }
    static object CandidateRelease()
    {
        string tag = "v" + currentVersion.Major + "." + currentVersion.Minor + "." + currentVersion.Build;
        return Parse(Release(tag, Hash(sourceExe), new FileInfo(sourceExe).Length), new Version(0, 0, 0, 0));
    }
    static void Verify(string path, object release) { updaterType.GetMethod("VerifyCandidate").Invoke(null, new object[] { path, release }); }
    static object Await(Task task) { task.GetAwaiter().GetResult(); return task.GetType().GetProperty("Result").GetValue(task, null); }

    static void FixtureChecks()
    {
        string digest = Hash(sourceExe);
        long size = new FileInfo(sourceExe).Length;
        var latest = Release("v9.8.7", digest, size);
        object release = Parse(latest, currentVersion);
        Assert(release != null && (Version)Get(release, "Version") == new Version(9, 8, 7, 0), "a newer stable GitHub release is detected");
        Assert(Parse(Release("v1.0.0", digest, size), currentVersion) == null, "older app releases are not offered");
        string sameTag = "v" + currentVersion.Major + "." + currentVersion.Minor + "." + currentVersion.Build;
        Assert(Parse(Release(sameTag, digest, size), currentVersion) == null, "three-part tags compare correctly with the current four-part assembly version");
        var invalid = Release("v9.8.7", digest, size); invalid["draft"] = true;
        Assert(Parse(invalid, currentVersion) == null, "draft releases are ignored");
        invalid = Release("v9.8.7", digest, size); invalid["prerelease"] = true;
        Assert(Parse(invalid, currentVersion) == null, "prereleases are ignored");
        invalid = Release("v9.8.7", digest, size); ((Dictionary<string, object>)((object[])invalid["assets"])[0])["digest"] = null;
        Assert(Fails(() => Parse(invalid, currentVersion)), "an app update requires GitHub's SHA-256 asset digest");
        invalid = Release("v9.8.7", digest, size); ((Dictionary<string, object>)((object[])invalid["assets"])[0])["digest"] = "sha256:bad";
        Assert(Fails(() => Parse(invalid, currentVersion)), "malformed asset digests are rejected");
        invalid = Release("v9.8.7", digest, size); ((Dictionary<string, object>)((object[])invalid["assets"])[0])["browser_download_url"] = "https://github.com/another/repository/releases/download/v9.8.7/Tool.Drive.Offline.exe";
        Assert(Fails(() => Parse(invalid, currentVersion)), "assets from another repository are rejected");
        invalid = Release("v9.8.7", digest, size); ((Dictionary<string, object>)((object[])invalid["assets"])[0])["browser_download_url"] = "http://github.com/Bentley734/tool-drive-offline/releases/download/v9.8.7/Tool.Drive.Offline.exe";
        Assert(Fails(() => Parse(invalid, currentVersion)), "non-HTTPS app downloads are rejected");
        invalid = Release("v9.8.7", digest, size); invalid["assets"] = new object[] { Asset("v9.8.7", digest, size), Asset("v9.8.7", digest, size) };
        Assert(Fails(() => Parse(invalid, currentVersion)), "ambiguous executable assets are rejected");
        invalid = Release("v9.8.7", digest, 128L * 1024 * 1024);
        Assert(Fails(() => Parse(invalid, currentVersion)), "oversized app assets are rejected before downloading");

        var check = updaterType.GetMethod("CheckAsync", new Type[] { typeof(Version), typeof(Func<Uri, CancellationToken, Task<string>>), typeof(CancellationToken) });
        int requests = 0;
        Func<Uri, CancellationToken, Task<string>> fetch = (uri, token) => {
            if (uri.Scheme != "https" || uri.Host != "api.github.com" || uri.AbsolutePath != "/repos/Bentley734/tool-drive-offline/releases/latest") throw new Exception("Wrong release API destination");
            requests++; return Task.FromResult(Json.Serialize(latest));
        };
        Assert(Await((Task)check.Invoke(null, new object[] { currentVersion, fetch, CancellationToken.None })) != null && requests == 1, "app checks use only the fixed public GitHub release endpoint");
        using (var canceled = new CancellationTokenSource())
        {
            canceled.Cancel(); requests = 0; bool stopped = false;
            try { Await((Task)check.Invoke(null, new object[] { currentVersion, fetch, canceled.Token })); }
            catch (OperationCanceledException) { stopped = true; }
            catch (TargetInvocationException error) { stopped = error.InnerException is OperationCanceledException; }
            Assert(stopped && requests == 0, "canceling an app check prevents a request");
        }

        string scratch = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "ToolDriveOffline.AppUpdateChecks." + Guid.NewGuid().ToString("N") + " & test's files"));
        string expectedScratch = scratch;
        Directory.CreateDirectory(scratch);
        try
        {
            object candidateRelease = CandidateRelease();
            string candidate = Path.Combine(scratch, "candidate.exe"); File.Copy(sourceExe, candidate);
            Verify(candidate, candidateRelease); Assert(true, "the expected executable identity, version, size, and digest verify without execution");
            string cachedCandidate = Path.Combine(scratch, "Tool.Drive.Offline.exe"); File.Copy(sourceExe, cachedCandidate);
            var download = updaterType.GetMethod("DownloadAsync", new Type[] { releaseType, typeof(string), typeof(CancellationToken) });
            string reused = (string)Await((Task)download.Invoke(null, new object[] { candidateRelease, scratch, CancellationToken.None }));
            Assert(Path.GetFullPath(reused) == Path.GetFullPath(cachedCandidate), "an already verified staged executable is reused without a download");
            using (var canceled = new CancellationTokenSource())
            {
                canceled.Cancel(); bool stopped = false;
                try { Await((Task)download.Invoke(null, new object[] { candidateRelease, scratch, canceled.Token })); }
                catch (OperationCanceledException) { stopped = true; }
                catch (TargetInvocationException error) { stopped = error.InnerException is OperationCanceledException; }
                Assert(stopped && Hash(cachedCandidate) == digest, "canceling a staged app update preserves the verified file");
            }
            File.AppendAllText(candidate, "corrupt");
            Assert(Fails(() => Verify(candidate, candidateRelease)), "modified executable bytes are rejected");
            File.Copy(sourceExe, candidate, true);
            object wrongVersion = CandidateRelease(); Set(wrongVersion, "Version", new Version(9, 8, 7, 0));
            Assert(Fails(() => Verify(candidate, wrongVersion)), "an assembly version mismatch is rejected");
            string invalidExe = Path.Combine(scratch, "not-an-exe.bin"); File.WriteAllText(invalidExe, "not a Windows executable");
            object invalidRelease = CandidateRelease(); Set(invalidRelease, "Sha256", Hash(invalidExe)); Set(invalidRelease, "Size", new FileInfo(invalidExe).Length);
            Assert(Fails(() => Verify(invalidExe, invalidRelease)), "matching hashes alone cannot admit a non-executable payload");

            string target = Path.Combine(scratch, "Tool Drive Offline.exe");
            using (var compiler = new CSharpCodeProvider())
            {
                var parameters = new CompilerParameters { GenerateExecutable = true, OutputAssembly = target, CompilerOptions = "/target:winexe /optimize+", IncludeDebugInformation = false };
                parameters.ReferencedAssemblies.Add("System.dll");
                var result = compiler.CompileAssemblyFromSource(parameters, "using System.Reflection; [assembly:AssemblyVersion(\"1.0.0.0\")][assembly:AssemblyFileVersion(\"1.0.0.0\")][assembly:AssemblyTitle(\"Tool Drive Offline\")] class Program { static void Main() {} }");
                if (result.Errors.HasErrors) throw new Exception("Old executable fixture failed to compile: " + String.Join(";", result.Errors.Cast<CompilerError>().Select(error => error.ToString())));
            }
            byte[] oldBytes = File.ReadAllBytes(target);
            var install = updaterType.GetMethod("InstallFiles", new Type[] { typeof(string), typeof(string), releaseType, typeof(Action<string>) });
            bool started = false;
            Action<string> start = path => { Assert(Path.GetFullPath(path) == Path.GetFullPath(target), "restart targets the installed EXE without shell commands"); started = true; };
            install.Invoke(null, new object[] { target, candidate, candidateRelease, start });
            Assert(started && Hash(target) == digest, "verified app replacement installs the new bytes before restart");
            Assert(Fails(() => install.Invoke(null, new object[] { target, candidate, candidateRelease, start })) && Hash(target) == digest, "an already current executable cannot be downgraded or replaced again");
            File.WriteAllBytes(target, oldBytes);
            Action<string> failStart = path => { throw new IOException("Fixture restart failure"); };
            Assert(Fails(() => install.Invoke(null, new object[] { target, candidate, candidateRelease, failStart })) && File.ReadAllBytes(target).SequenceEqual(oldBytes), "a failed restart restores the previous working executable");
            File.AppendAllText(candidate, "corrupt");
            Assert(Fails(() => install.Invoke(null, new object[] { target, candidate, candidateRelease, start })) && File.ReadAllBytes(target).SequenceEqual(oldBytes), "an invalid staged download cannot replace the installed app");
            Assert(!(bool)updaterType.GetMethod("HandleCommandLine").Invoke(null, new object[] { new string[0] }), "ordinary launches do not enter updater helper mode");
        }
        finally
        {
            // This is the exact, uniquely created test directory; no user paths can enter it.
            string resolved = Path.GetFullPath(scratch);
            string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (resolved == expectedScratch && resolved.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) && Path.GetFileName(resolved).StartsWith("ToolDriveOffline.AppUpdateChecks.", StringComparison.Ordinal))
                Directory.Delete(resolved, true);
        }
        Console.WriteLine("PASS " + assertions + " application-update assertions; only isolated fixture files were replaced.");
    }

    public static int Main(string[] args)
    {
        try
        {
            sourceExe = Path.GetFullPath(args[0]);
            var assembly = Assembly.LoadFrom(sourceExe);
            currentVersion = assembly.GetName().Version;
            updaterType = assembly.GetType("ToolDriveOffline.AppUpdater", true);
            releaseType = assembly.GetType("ToolDriveOffline.AppRelease", true);
            if (args.Length > 1 && args[1] == "--verify-download")
            {
                object release = Parse(Json.Deserialize<Dictionary<string, object>>(File.ReadAllText(args[2])), new Version(0, 0, 0, 0));
                var task = (Task)updaterType.GetMethod("DownloadAsync", new Type[] { releaseType, typeof(string), typeof(CancellationToken) }).Invoke(null, new object[] { release, Path.GetFullPath(args[3]), CancellationToken.None });
                string file = (string)Await(task); Verify(file, release);
                Console.WriteLine("PASS live GitHub executable download and SHA-256/assembly verification: " + Get(release, "TagName"));
            }
            else FixtureChecks();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
