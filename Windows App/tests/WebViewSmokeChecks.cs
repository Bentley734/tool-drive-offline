using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

// Runs the unmodified shipping program on its normal STA thread. The only
// automation interface used is CoreWebView2.ExecuteScriptAsync on its real view.
internal static class WebViewSmokeChecks
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(90);
    private static object core;
    private static Form window;
    private static int result = 1;

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3 || (args[2] != "first" && args[2] != "reopen")) return 2;
        string profile = Environment.GetEnvironmentVariable("TOOL_DRIVE_DATA_DIR");
        if (String.IsNullOrEmpty(profile) || !Path.GetFullPath(profile).StartsWith(
            Path.Combine(Path.GetTempPath(), "ToolDriveOffline.Tests."), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The native smoke fixture requires an isolated temporary profile.");
        Assembly product = Assembly.LoadFrom(Path.GetFullPath(args[0]));
        // Fail before calling Main if a build predates isolated profiles.
        Type bootstrap = product.GetType("ToolDriveOffline.DesktopBootstrap", true);
        const BindingFlags flags = BindingFlags.NonPublic | BindingFlags.Public | BindingFlags.Static;
        FieldInfo field = bootstrap.GetField("Profile", flags);
        string actual = (string)(field != null ? field.GetValue(null) : bootstrap.GetProperty("Profile", flags).GetValue(null, null));
        if (!String.Equals(Path.GetFullPath(profile), Path.GetFullPath(actual), StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The application did not select the isolated profile.");

        // Automatic online update checks are out of scope for this local test.
        WebRequest.DefaultWebProxy = new WebProxy("http://127.0.0.1:1");
        string fixture = File.ReadAllText(args[1]);
        EventHandler begin = null;
        begin = async delegate
        {
            Application.Idle -= begin;
            try
            {
                await Wait(async delegate
                {
                    window = Application.OpenForms.Cast<Form>().FirstOrDefault(f => f.GetType().Name == "ArchiveWindow");
                    if (window == null) return false;
                    Control view = window.Controls.Cast<Control>().FirstOrDefault(c => c.GetType().Name == "WebView2");
                    if (view == null) return false;
                    core = view.GetType().GetProperty("CoreWebView2").GetValue(view, null);
                    if (core == null || (string)core.GetType().GetProperty("Source").GetValue(core, null) != "https://archive.tooldrive.invalid/index.html") return false;
                    return await Evaluate("document.readyState === 'complete' && !!document.getElementById('show-appearance')") == "true";
                }, "start the production catalog in WebView2");
                string value = await Evaluate("(" + fixture + ")('" + args[2] + "')");
                if (value != "\"passed\"") throw new InvalidOperationException("Renderer checks returned " + value);
                if (args[2] == "first")
                {
                    await Wait(() => Task.FromResult(File.Exists(Path.Combine(profile, "saved-shows.json")) &&
                        File.Exists(Path.Combine(profile, "column-layout.json"))), "persist a favorite and a resized column");
                }
                // This action is answered by the actual native Library service.
                await Evaluate("document.getElementById('show-library').click()");
                await Wait(async () => await Evaluate("document.getElementById('library-dialog').open && document.getElementById('library-status').textContent.includes('No recordings')") == "true",
                    "receive the native library response");
                Console.WriteLine("PASS native WebView2 host, bridge, local resources and appearance (" + args[2] + ")");
                result = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally { if (window != null) window.Close(); else Application.ExitThread(); }
        };
        Application.Idle += begin;
        using (new System.Threading.Timer(_ => { Console.Error.WriteLine("Timed out while running the Windows app smoke test."); Environment.Exit(2); },
            null, TimeSpan.FromMinutes(3), System.Threading.Timeout.InfiniteTimeSpan))
        {
            product.EntryPoint.Invoke(null, new object[] { new string[0] });
        }
        return result;
    }
    private static Task<string> Evaluate(string script)
    {
        return (Task<string>)core.GetType().GetMethod("ExecuteScriptAsync", new[] { typeof(string) }).Invoke(core, new object[] { script });
    }
    private static async Task Wait(Func<Task<bool>> predicate, string operation)
    {
        var watch = System.Diagnostics.Stopwatch.StartNew();
        while (!await predicate())
        {
            if (watch.Elapsed > Timeout) throw new TimeoutException("Could not " + operation + ".");
            await Task.Delay(150);
        }
    }
}
