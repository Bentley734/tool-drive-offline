using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Windows.Forms;
using System.Threading;

namespace ToolDriveOffline
{
    internal static class DesktopBootstrap
    {
        internal static readonly string Profile = GetProfile();
        internal static string ProfileKey
        {
            get
            {
                using (SHA256 sha = SHA256.Create())
                    return BitConverter.ToString(sha.ComputeHash(System.Text.Encoding.UTF8.GetBytes(Profile.ToUpperInvariant()))).Replace("-", "");
            }
        }
        private static string GetProfile()
        {
            string path = Environment.GetEnvironmentVariable("TOOL_DRIVE_DATA_DIR");
            if (!String.IsNullOrWhiteSpace(path) && Path.IsPathRooted(path))
            {
                string root = Path.GetPathRoot(path);
                if (root.Length > 2)
                {
                    string full = Path.GetFullPath(path);
                    return full.Length == root.Length ? full : full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                }
            }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tool Drive Offline");
        }
        private static readonly Dictionary<string, string> Assemblies = new Dictionary<string, string>(StringComparer.Ordinal);

        public static void Run(Catalog catalog, string warning, EventWaitHandle activate)
        {
            // Install the resolver before the CLR first resolves the WebView2 form.
            string machine = Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE");
            string arch = IntPtr.Size == 4 ? "x86" : String.Equals(machine, "ARM64", StringComparison.OrdinalIgnoreCase) ? "arm64" : "x64";
            foreach (string name in new[] { "Microsoft.Web.WebView2.Core", "Microsoft.Web.WebView2.WinForms" })
                Assemblies[name] = Materialize(name + ".dll", name + ".dll");
            string loader = Materialize(arch + ".WebView2Loader.dll", "WebView2Loader.dll");
            AppDomain.CurrentDomain.AssemblyResolve += Resolve;
            RunDesktop(catalog, warning, Path.GetDirectoryName(loader), activate);
        }

        private static Assembly Resolve(object sender, ResolveEventArgs e)
        {
            string path;
            return Assemblies.TryGetValue(new AssemblyName(e.Name).Name, out path) ? Assembly.LoadFrom(path) : null;
        }

        [MethodImpl(MethodImplOptions.NoInlining)]
        private static void RunDesktop(Catalog catalog, string warning, string loaderFolder, EventWaitHandle activate)
        {
            Microsoft.Web.WebView2.Core.CoreWebView2Environment.SetLoaderDllFolderPath(loaderFolder);
            using (ArchiveWindow window = new ArchiveWindow(catalog, warning))
            {
                RegisteredWaitHandle registration = null;
                window.Load += delegate
                {
                    registration = ThreadPool.RegisterWaitForSingleObject(activate, delegate
                    {
                        try { window.BeginInvoke(new Action(delegate {
                            if (window.WindowState == FormWindowState.Minimized) window.WindowState = FormWindowState.Normal;
                            window.Activate();
                        })); } catch (InvalidOperationException) { }
                    }, null, Timeout.Infinite, false);
                };
                try { Application.Run(window); }
                finally { if (registration != null) registration.Unregister(null); }
            }
        }

        // Each version has its own immutable path so a running app and its updater can coexist.
        internal static string Materialize(string resourceName, string fileName)
        {
            byte[] bytes;
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("Desktop." + resourceName))
            using (MemoryStream buffer = new MemoryStream()) { source.CopyTo(buffer); bytes = buffer.ToArray(); }
            using (SHA256 sha = SHA256.Create())
            {
                string hash = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "");
                string folder = Path.Combine(Profile, "Runtime", hash);
                string path = Path.Combine(folder, fileName);
                Directory.CreateDirectory(folder);
                if (!File.Exists(path))
                {
                    string temporary = path + "." + Guid.NewGuid().ToString("N");
                    try
                    {
                        File.WriteAllBytes(temporary, bytes);
                        try { File.Move(temporary, path); } catch (IOException) { if (!File.Exists(path)) throw; }
                    }
                    finally { if (File.Exists(temporary)) File.Delete(temporary); }
                }
                using (FileStream cached = File.OpenRead(path))
                    if (BitConverter.ToString(sha.ComputeHash(cached)).Replace("-", "") != hash)
                        throw new InvalidDataException("A cached desktop component is damaged. Remove " + folder + " and reopen the app.");
                return path;
            }
        }
    }
}
