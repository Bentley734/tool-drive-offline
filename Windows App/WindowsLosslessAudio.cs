using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ToolDriveOffline
{
    internal sealed partial class WindowsMediaService
    {
        internal Func<string> GetLosslessDecoder { get; set; }
        private PlaybackDecode activeDecode;

        private sealed class PlaybackDecode
        {
            public readonly MediaTrack Source;
            public readonly CancellationTokenSource Lifetime;
            public readonly string Folder;
            public Task<MediaTrack> Prepared;

            public PlaybackDecode(MediaTrack source, string cache, CancellationToken shutdownToken)
            {
                Source = source;
                Lifetime = CancellationTokenSource.CreateLinkedTokenSource(shutdownToken);
                Folder = Path.Combine(cache, Guid.NewGuid().ToString("N"));
            }

            public void Retire()
            {
                Lifetime.Cancel();
                Prepared.ContinueWith(task => {
                    Clean(Folder);
                    Lifetime.Dispose();
                }, TaskScheduler.Default);
            }
        }

        // Called under the handle lock on a queue change, release, or Plex sign-out.
        private void ReplaceDecoderSession()
        {
            if (activeDecode == null) return;
            var previous = activeDecode;
            activeDecode = null;
            previous.Retire();
        }

        private static bool NeedsDecoder(MediaTrack track)
        {
            return track.mime == "audio/aiff" || track.mime == "audio/x-caf" ||
                track.mime == "audio/alac" || (track.mime == "audio/mp4" && !track.directMp4);
        }

        private Task<MediaTrack> PrepareLosslessTrack(string id, MediaTrack track)
        {
            lock (handles) {
                MediaTrack current;
                if (disposed || !handles.TryGetValue(id, out current) || !Object.ReferenceEquals(current, track))
                    throw new OperationCanceledException();
                if (activeDecode != null && activeDecode.Source == track &&
                    !activeDecode.Prepared.IsCanceled && !activeDecode.Prepared.IsFaulted) return activeDecode.Prepared;

                ReplaceDecoderSession();
                var next = new PlaybackDecode(track, Path.Combine(root, "PlaybackCache"), shutdown.Token);
                activeDecode = next;
                next.Prepared = Task.Run(() => DecodeTrackAsync(next), CancellationToken.None);
                return next.Prepared;
            }
        }

        private async Task<MediaTrack> DecodeTrackAsync(PlaybackDecode job)
        {
            var token = job.Lifetime.Token;
            token.ThrowIfCancellationRequested();
            var track = job.Source;
            string parent = Path.GetDirectoryName(job.Folder);
            Directory.CreateDirectory(parent);
            foreach (var old in Directory.GetDirectories(parent)) {
                Guid unused;
                if (Guid.TryParseExact(Path.GetFileName(old), "N", out unused) &&
                    Directory.GetLastWriteTimeUtc(old) < DateTime.UtcNow.AddDays(-2)) Clean(old);
            }
            Directory.CreateDirectory(job.Folder);
            string input = track.localPath;
            try {
                if (input == null) {
                    input = Path.Combine(job.Folder, "source.audio");
                    using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
                    using (var request = new HttpRequestMessage(HttpMethod.Get, track.remote)) {
                        timeout.CancelAfter(TimeSpan.FromMinutes(15));
                        if (!String.IsNullOrEmpty(track.token)) request.Headers.Add("X-Plex-Token", track.token);
                        using (var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false)) {
                            response.EnsureSuccessStatusCode();
                            const long limit = 2147483600;
                            if (response.Content.Headers.ContentLength.GetValueOrDefault() > limit)
                                throw Problem("This track exceeds the playback cache limit.");
                            using (var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false)) {
                                await CopyBounded(stream, input, limit, timeout.Token).ConfigureAwait(false);
                            }
                        }
                    }
                }
                var output = Path.Combine(job.Folder, "playback.wav");
                if (GetLosslessDecoder == null) throw Problem("The lossless audio decoder is unavailable.");
                int status = DecodeFile(GetLosslessDecoder(), input, output, token);
                if (status == 3) return new MediaTrack { localPath = input, mime = "audio/mp4" };
                if (status != 0 || !RealFile(output))
                    throw Problem("This audio track could not be decoded.");
                if (track.localPath == null) File.Delete(input);
                return new MediaTrack { localPath = output, mime = "audio/wav" };
            } catch {
                Clean(job.Folder);
                throw;
            }
        }

        internal static int DecodeFile(string decoder, string input, string output, CancellationToken token)
        {
            // All three are absolute filesystem paths generated or selected by the host.
            // Windows filenames cannot contain a quote, and none is a directory.
            if (input.IndexOf('"') >= 0 || output.IndexOf('"') >= 0) throw new ArgumentException("Invalid audio path.");
            var start = new ProcessStartInfo {
                FileName = decoder, Arguments = "\"" + input + "\" \"" + output + "\"",
                UseShellExecute = false, CreateNoWindow = true
            };
            token.ThrowIfCancellationRequested();
            using (var process = Process.Start(start))
            using (token.Register(() => {
                try { if (!process.HasExited) process.Kill(); }
                catch (InvalidOperationException) {}
                catch (System.ComponentModel.Win32Exception) {}
            })) {
                if (!process.WaitForExit(15 * 60 * 1000)) {
                    try { process.Kill(); } catch (InvalidOperationException) {}
                    process.WaitForExit();
                    throw new TimeoutException("Lossless audio conversion timed out.");
                }
                token.ThrowIfCancellationRequested();
                return process.ExitCode;
            }
        }
    }
}
