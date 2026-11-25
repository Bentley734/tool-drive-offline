using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

namespace ToolDriveOffline
{
    // External Drive content lives in a private view with no application bridge.
    internal sealed class OriginalDownloadWindow : Form
    {
        private readonly WebView2 browser = new WebView2();
        private readonly Label status = new Label();
        private readonly WindowsMediaService media;
        private readonly Uri folder;
        private readonly long sourceID;
        private CoreWebView2DownloadOperation download;
        private bool importing, closeAfterImport;
        private string temporaryDirectory;

        public OriginalDownloadWindow(Uri folderUri, long id, WindowsMediaService service)
        {
            folder = folderUri; sourceID = id; media = service;
            Text = "Original recording · Google Drive";
            Size = new Size(920, 720);
            StartPosition = FormStartPosition.CenterParent;
            browser.CreationProperties = new CoreWebView2CreationProperties {
                UserDataFolder = Path.Combine(DesktopBootstrap.Profile, "DriveBrowser"), IsInPrivateModeEnabled = true
            };
            var bar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 42, Padding = new Padding(3) };
            AddButton(bar, "Back", () => { if (browser.CanGoBack) browser.GoBack(); });
            AddButton(bar, "Forward", () => { if (browser.CanGoForward) browser.GoForward(); });
            AddButton(bar, "Reload", () => { if (browser.CoreWebView2 != null) browser.Reload(); });
            AddButton(bar, "Open in browser", () => Process.Start(new ProcessStartInfo(folder.AbsoluteUri) { UseShellExecute = true }));
            status.Text = "Choose a recording file or ZIP to add to your Library.";
            status.AutoEllipsis = true; status.Dock = DockStyle.Bottom; status.Height = 30;
            status.Padding = new Padding(7, 5, 7, 0);
            browser.Dock = DockStyle.Fill; Controls.Add(browser); Controls.Add(bar); Controls.Add(status);
            Shown += async delegate
            {
                try
                {
                    await browser.EnsureCoreWebView2Async(null);
                    if (IsDisposed) return;
                    var core = browser.CoreWebView2;
                    core.Settings.IsWebMessageEnabled = false; core.Settings.AreHostObjectsAllowed = false;
                    core.PermissionRequested += (s, e) => { e.State = CoreWebView2PermissionState.Deny; };
                    core.NavigationStarting += (s, e) => { if (!Allowed(e.Uri)) { e.Cancel = true; status.Text = "This window opens Google Drive links only."; } };
                    core.NewWindowRequested += (s, e) => { e.Handled = true; if (Allowed(e.Uri)) core.Navigate(e.Uri); };
                    core.DownloadStarting += DownloadStarting;
                    core.Navigate(folder.AbsoluteUri);
                }
                catch { if (!IsDisposed) status.Text = "Drive could not open here. Use Open in browser, then import the download from its recording source."; }
            };
            FormClosing += (s, e) => { if (importing && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; closeAfterImport = true; status.Text = "Finishing your Library import…"; } };
            FormClosed += delegate { if (download != null && download.State == CoreWebView2DownloadState.InProgress) download.Cancel(); if (!importing) Cleanup(); };
        }
        private static void AddButton(FlowLayoutPanel bar, string label, Action action)
        {
            var button = new Button { Text = label, AutoSize = true };
            button.Click += delegate { action(); }; bar.Controls.Add(button);
        }
        private static bool Allowed(string value)
        {
            Uri uri;
            return Uri.TryCreate(value, UriKind.Absolute, out uri) && uri.Scheme == "https" && uri.IsDefaultPort && uri.UserInfo.Length == 0
                && (uri.Host == "drive.google.com" || uri.Host == "drive.usercontent.google.com" || uri.Host == "googleusercontent.com" || uri.Host.EndsWith(".googleusercontent.com", StringComparison.Ordinal));
        }
        private void DownloadStarting(object sender, CoreWebView2DownloadStartingEventArgs e)
        {
            if (download != null || importing || !Allowed(e.DownloadOperation.Uri)) { e.Cancel = true; return; }
            string name = Path.GetFileName(e.ResultFilePath);
            string extension = Path.GetExtension(name).ToLowerInvariant();
            if (Array.IndexOf(new[] { ".zip", ".flac", ".mp3", ".aac", ".m4a", ".mp4", ".wav", ".wave", ".alac", ".aif", ".aiff", ".aifc", ".caf" }, extension) < 0)
            { e.Cancel = true; status.Text = "Choose an audio file or ZIP."; return; }
            try
            {
                temporaryDirectory = Path.Combine(Path.GetTempPath(), "ToolDrive-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(temporaryDirectory);
                string target = Path.Combine(temporaryDirectory, "Track-" + name);
                e.ResultFilePath = target; e.Handled = true; download = e.DownloadOperation;
                status.Text = "Downloading " + name + "…";
                var current = download;
                current.BytesReceivedChanged += delegate
                {
                    if (current.BytesReceived > 8L * 1024 * 1024 * 1024) current.Cancel();
                    else if (!IsDisposed && current.State == CoreWebView2DownloadState.InProgress) status.Text = "Downloading " + name + " · " + (current.BytesReceived / (1024 * 1024)) + " MB";
                };
                current.StateChanged += async delegate
                {
                    if (current.State == CoreWebView2DownloadState.InProgress || download != current) return;
                    download = null;
                    try
                    {
                        if (current.State == CoreWebView2DownloadState.Completed && !IsDisposed)
                        {
                            importing = true; status.Text = "Importing " + name + " into your Library…";
                            await media.ImportOriginalAsync(sourceID, target);
                            if (!IsDisposed) status.Text = "Library import finished. See Library for the recording.";
                        }
                        else if (!IsDisposed) status.Text = "Download interrupted. Choose the file to try again.";
                    }
                    catch { if (!IsDisposed) status.Text = "The recording could not be imported. Check the file and try again."; }
                    finally { importing = false; Cleanup(); if (closeAfterImport && !IsDisposed) Close(); }
                };
            }
            catch { e.Cancel = true; Cleanup(); status.Text = "There was no space to start this download."; }
        }
        private void Cleanup()
        {
            if (temporaryDirectory == null) return;
            try { Directory.Delete(temporaryDirectory, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            temporaryDirectory = null;
        }
    }
}
