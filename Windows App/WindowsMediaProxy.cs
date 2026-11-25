using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace ToolDriveOffline
{
    internal sealed class WindowsMediaResponse
    {
        public int Status;
        public string Reason, Headers;
        public Stream Content;
    }
    internal sealed partial class WindowsMediaService
    {
        const string MediaHeaders =
            "Access-Control-Allow-Origin: " +
            "https://archive.tooldrive.invalid\r\nAccess-Control-Allow-Methods: GET, HEAD, " +
            "OPTIONS\r\nAccess-Control-Allow-Headers: Range\r\nAccess-Control-Expose-Headers: " +
            "Accept-Ranges, Content-Length, Content-Range\r\nAccept-Ranges: bytes\r\nCache-Control: " +
            "no-store\r\nX-Content-Type-Options: nosniff\r\n";
        static WindowsMediaResponse Response(int status, string reason, string headers = "",
                                             Stream stream = null)
        {
            return new WindowsMediaResponse { Status = status, Reason = reason,
                                              Headers = MediaHeaders + headers,
                                              Content = stream ?? new MemoryStream() };
        }
        // WebView2 can retain its managed IStream adapter after canceling a resource request.
        // Keep ownership of every response until delivery finishes or the queue releases it.
        readonly Dictionary<MediaSlice, string> readers = new Dictionary<MediaSlice, string>();
        string seekHandle;

        void DropReaders(Func<string, bool> matches)
        {
            foreach (var item in handles.Where(pair => matches(pair.Key)))
                item.Value.readerGeneration++;
            foreach (var item in readers.Where(pair => matches(pair.Value)).ToArray())
                item.Key.Dispose();
        }
        void ReleaseHandles()
        {
            lock (handles)
            {
                DropReaders(id => true);
                seekHandle = null;
                handles.Clear();
                ReplaceDecoderSession();
            }
        }
        void PlaybackPosition(string action, string handle)
        {
            lock (handles)
            {
                if (!handles.ContainsKey(handle))
                    return;
                if (action == "beginTrack")
                {
                    // The browser can open the new track before its postMessage arrives.
                    // Preserve its in-flight request and retire only the preceding track.
                    DropReaders(id => id != handle);
                    if (activeDecode != null && activeDecode.Source != handles[handle])
                        ReplaceDecoderSession();
                    seekHandle = null;
                }
                else if (action == "seekTrack")
                {
                    // A seek inside the current buffer does not open a new HTTP request.
                    // Close the old response when the replacement byte range actually opens.
                    seekHandle = handle;
                }
            }
        }
        public async Task<WindowsMediaResponse> OpenAsync(Uri uri, string method, string range)
        {
            if (disposed || uri == null || uri.Scheme != "https" || uri.Host != "media.tooldrive.invalid" ||
                !uri.IsDefaultPort || uri.Query.Length != 0 ||
                !Regex.IsMatch(uri.AbsolutePath, @"^/[a-f0-9]{32}\z"))
                return Response(404, "Not Found");
            if (method == "OPTIONS")
                return Response(204, "No Content");
            if (method != "GET" && method != "HEAD")
                return Response(405, "Method Not Allowed");
            string handle = uri.AbsolutePath.Substring(1);
            MediaTrack track;
            long generation;
            lock (handles)
            {
                if (!handles.TryGetValue(handle, out track))
                    return Response(404, "Not Found");
                if (method == "GET" && seekHandle == handle && !String.IsNullOrEmpty(range))
                {
                    DropReaders(id => id == handle);
                    seekHandle = null;
                }
                generation = track.readerGeneration;
            }
            var response = await ReadMediaAsync(handle, track, method, range);
            var slice = response.Content as MediaSlice;
            if (slice == null)
                return response;
            lock (handles)
            {
                if (disposed || generation != track.readerGeneration || !handles.ContainsKey(handle))
                {
                    slice.Dispose();
                    return Response(404, "Not Found");
                }
                readers[slice] = handle;
                slice.Finished = () =>
                { lock (handles) readers.Remove(slice); };
            }
            return response;
        }
        async Task<WindowsMediaResponse> ReadMediaAsync(string handle, MediaTrack track, string method,
                                                        string range)
        {
            RangeHeaderValue requested = null;
            if (!String.IsNullOrEmpty(range) && (!RangeHeaderValue.TryParse(range, out requested) ||
                                                 requested.Unit != "bytes" || requested.Ranges.Count != 1))
                return Response(416, "Range Not Satisfiable");
            try
            {
                if (NeedsDecoder(track))
                    track = await PrepareLosslessTrack(handle, track).ConfigureAwait(false);
                if (track.localPath != null)
                    return OpenLocal(track, method, requested);
                using (var cts = CancellationTokenSource.CreateLinkedTokenSource(shutdown.Token)) using (
                    var req = new HttpRequestMessage(method == "HEAD" ? HttpMethod.Head : HttpMethod.Get,
                                                     track.remote))
                {
                    cts.CancelAfter(TimeSpan.FromSeconds(22));
                    if (requested != null)
                        req.Headers.Range = requested;
                    if (!String.IsNullOrEmpty(track.token))
                        req.Headers.Add("X-Plex-Token", track.token);
                    var upstream =
                        await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
                    try
                    {
                        int code = (int)upstream.StatusCode;
                        if (code != 200 && code != 206 && code != 416)
                        {
                            upstream.Dispose();
                            return Response(502, "Media Unavailable");
                        }
                        var h = upstream.Content.Headers;
                        string headers = "Content-Type: " + track.mime + "\r\n";
                        if (h.ContentLength.HasValue)
                            headers += "Content-Length: " +
                                       h.ContentLength.Value.ToString(CultureInfo.InvariantCulture) + "\r\n";
                        if (h.ContentRange != null)
                            headers += "Content-Range: " + h.ContentRange + "\r\n";
                        if (method == "HEAD" || code == 416)
                        {
                            upstream.Dispose();
                            return Response(code, code == 416 ? "Range Not Satisfiable" : "OK", headers);
                        }
                        return Response(code, code == 206 ? "Partial Content" : "OK", headers,
                                        new MediaSlice(await upstream.Content.ReadAsStreamAsync(),
                                                       h.ContentLength ?? Int64.MaxValue, upstream));
                    }
                    catch
                    {
                        upstream.Dispose();
                        throw;
                    }
                }
            }
            catch (Exception)
            {
                return Response(502, "Media Unavailable");
            }
        }
        static WindowsMediaResponse OpenLocal(MediaTrack track, string method, RangeHeaderValue range)
        {
            var file = new FileStream(track.localPath, FileMode.Open, FileAccess.Read,
                                      FileShare.Read | FileShare.Delete);
            try
            {
                long length = file.Length, start = 0, end = length - 1;
                if (range != null)
                {
                    foreach (var r in range.Ranges)
                    {
                        if (!r.From.HasValue)
                            start = Math.Max(0, length - r.To.GetValueOrDefault());
                        else
                        {
                            start = r.From.Value;
                            end = Math.Min(end, r.To.GetValueOrDefault(end));
                        }
                    }
                    if (start > end || start >= length)
                    {
                        file.Dispose();
                        return Response(416, "Range Not Satisfiable",
                                        "Content-Range: bytes */" + length + "\r\n");
                    }
                }
                string headers =
                    "Content-Type: " + track.mime + "\r\nContent-Length: " + (end - start + 1) + "\r\n";
                if (range != null)
                    headers += "Content-Range: bytes " + start + "-" + end + "/" + length + "\r\n";
                var status = range == null ? 200 : 206;
                var reason = range == null ? "OK" : "Partial Content";
                if (method == "HEAD")
                {
                    file.Dispose();
                    return Response(status, reason, headers);
                }
                file.Position = start;
                return Response(status, reason, headers, new MediaSlice(file, end - start + 1, null));
            }
            catch
            {
                file.Dispose();
                throw;
            }
        }
        sealed class MediaSlice : Stream
        {
            readonly Stream stream;
            readonly IDisposable owner;
            readonly long length, initial;
            long position;
            int closed;
            internal Action Finished;
            public MediaSlice(Stream stream, long length, IDisposable owner)
            {
                this.stream = stream;
                this.length = length;
                this.owner = owner;
                initial = stream.CanSeek ? stream.Position : 0;
            }
            public override bool CanRead
            {
                get {
                    return true;
                }
            }
            public override bool CanSeek
            {
                get {
                    return stream.CanSeek;
                }
            }
            public override bool CanWrite
            {
                get {
                    return false;
                }
            }
            public override long Length
            {
                get {
                    return length;
                }
            }
            public override long Position
            {
                get {
                    return position;
                }
                set {
                    Seek(value, SeekOrigin.Begin);
                }
            }
            public override int Read(byte[] buffer, int offset, int count)
            {
                if (count == 0 || Volatile.Read(ref closed) != 0)
                    return 0;
                try
                {
                    int n = stream.Read(buffer, offset, (int)Math.Min(count, length - position));
                    position += n;
                    if (owner != null && (n == 0 || position >= length))
                        Dispose();
                    return n;
                }
                catch (ObjectDisposedException)
                {
                    return 0;
                }
                catch (IOException)
                {
                    if (Volatile.Read(ref closed) != 0)
                        return 0;
                    Dispose();
                    throw;
                }
            }
            public override long Seek(long offset, SeekOrigin origin)
            {
                if (!CanSeek)
                    throw new NotSupportedException();
                long target = origin == SeekOrigin.Begin
                                  ? offset
                                  : (origin == SeekOrigin.Current ? position : length) + offset;
                if (target < 0 || target > length)
                    throw new IOException("Media position is out of range.");
                stream.Position = initial + target;
                return position = target;
            }
            public override void Flush() {}
            public override void Write(byte[] buffer, int offset, int count)
            {
                throw new NotSupportedException();
            }
            public override void SetLength(long value)
            {
                throw new NotSupportedException();
            }
            protected override void Dispose(bool disposing)
            {
                if (disposing && Interlocked.Exchange(ref closed, 1) == 0)
                {
                    try
                    {
                        stream.Dispose();
                    }
                    finally
                    {
                        if (owner != null)
                            owner.Dispose();
                        var notify = Finished;
                        if (notify != null)
                            notify();
                    }
                }
                base.Dispose(disposing);
            }
        }
    }
}
