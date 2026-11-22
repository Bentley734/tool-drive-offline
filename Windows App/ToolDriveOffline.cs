using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace ToolDriveOffline
{
    public sealed class Source
    {
        public long id { get; set; }
        public double? rating { get; set; }
        public string version { get; set; }
        public string taper { get; set; }
        public string gear { get; set; }
        public string generation { get; set; }
        public string length { get; set; }
        public string status { get; set; }
        public string lineage { get; set; }
        public string recordingType { get; set; }
        public string codec { get; set; }
        public string lossless { get; set; }
        internal string SearchText;
    }

    public sealed class SetlistItem
    {
        public string title { get; set; }
        public string info { get; set; }
        public string encore { get; set; }
    }

    public sealed class Show
    {
        public long id { get; set; }
        public string date { get; set; }
        public string venue { get; set; }
        public string city { get; set; }
        public string state { get; set; }
        public string country { get; set; }
        public string status { get; set; }
        public string festival { get; set; }
        public string tour { get; set; }
        public List<Source> sources { get; set; }
        public List<SetlistItem> setlist { get; set; }
        public int setlistOmitted { get; set; }
        public List<string> songs { get; set; }
        internal string SearchText;
    }

    public sealed class FilterOptions
    {
        public string Search { get; set; }
        public double MinimumRating { get; set; }
        public string RatingMode { get; set; }
        public string FromYear { get; set; }
        public string ToYear { get; set; }
        public string Status { get; set; }
        public string RecordingType { get; set; }
        public bool SavedOnly { get; set; }
        public string Sort { get; set; }
        public FilterOptions()
        {
            Search = ""; RatingMode = "any"; FromYear = ""; ToYear = "";
            Status = "OTD"; RecordingType = "all"; Sort = "rating";
        }
    }

    public sealed class ShowMatch
    {
        public Show Show { get; set; }
        public List<Source> Sources { get; set; }
        public Source BestSource { get; set; }
        public double? Rating { get; set; }
    }

    public sealed class Catalog
    {
        public string snapshotDate { get; set; }
        public string source { get; set; }
        public string ratingDescription { get; set; }
        public List<Show> shows { get; set; }

        private const int MaximumJsonBytes = 32 * 1024 * 1024;
        private static readonly HashSet<string> ValidStatuses = new HashSet<string>(new string[] { "OTD", "Confirmed", "Unconfirmed", "Unknown" }, StringComparer.Ordinal);
        private static readonly Regex UrlPattern = new Regex(@"(?:(?:[a-z][a-z0-9+.-]*:)?//|www\.|mailto:|magnet:)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        public static Catalog Load()
        {
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("ToolDriveOffline.catalog.json"))
            {
                if (stream == null) throw new InvalidOperationException("The embedded show catalog is missing.");
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                    return FromJson(reader.ReadToEnd());
            }
        }

        public static Catalog FromJson(string json)
        {
            if (String.IsNullOrWhiteSpace(json) || json.Length > MaximumJsonBytes || Encoding.UTF8.GetByteCount(json) > MaximumJsonBytes)
                throw new InvalidDataException("The catalog is empty or exceeds the 32 MB metadata limit.");
            try
            {
                JavaScriptSerializer serializer = new JavaScriptSerializer { MaxJsonLength = MaximumJsonBytes, RecursionLimit = 32 };
                object raw = serializer.DeserializeObject(json);
                if (!(raw is IDictionary<string, object>)) throw new InvalidDataException("The catalog must be a JSON object.");
                ValidateRaw(raw, 0);
                Catalog catalog = serializer.ConvertToType<Catalog>(raw);
                if (catalog == null || catalog.shows == null || catalog.shows.Count == 0 || catalog.shows.Count > 50000)
                    throw new InvalidDataException("The catalog must contain between 1 and 50,000 shows.");
                ValidateDate(catalog.snapshotDate, "snapshot date");
                ValidateText(catalog.source, 2048, true); ValidateText(catalog.ratingDescription, 4096, false);
                HashSet<long> showIds = new HashSet<long>(), sourceIds = new HashSet<long>();
                foreach (Show show in catalog.shows)
                {
                    if (show == null || show.id <= 0 || !showIds.Add(show.id)) throw new InvalidDataException("Show IDs must be positive and unique.");
                    ValidateDate(show.date, "show date"); ValidateStatus(show.status);
                    ValidateText(show.venue, 2048, true); ValidateText(show.city, 512, false); ValidateText(show.state, 512, false);
                    ValidateText(show.country, 512, false); ValidateText(show.festival, 2048, false); ValidateText(show.tour, 2048, false);
                    if (show.sources == null || show.sources.Count == 0 || show.sources.Count > 4096) throw new InvalidDataException("Each show must contain a bounded recording-source list.");
                    foreach (Source item in show.sources)
                    {
                        if (item == null || item.id <= 0 || !sourceIds.Add(item.id) || sourceIds.Count > 250000)
                            throw new InvalidDataException("Recording-source IDs must be positive and unique throughout the catalog.");
                        ValidateStatus(item.status);
                        if (item.rating.HasValue && (Double.IsNaN(item.rating.Value) || Double.IsInfinity(item.rating.Value) || item.rating.Value < 0 || item.rating.Value > 10))
                            throw new InvalidDataException("Sound ratings must be finite numbers between 0 and 10, or null.");
                        if (item.rating == 0) item.rating = null;
                        ValidateText(item.version, 128, false); ValidateText(item.taper, 2048, false); ValidateText(item.gear, 8192, false);
                        ValidateText(item.generation, 512, false); ValidateText(item.length, 128, false); ValidateText(item.lineage, 32768, false);
                        ValidateText(item.recordingType, 128, true); ValidateText(item.codec, 128, false); ValidateText(item.lossless, 128, false);
                    }
                    if (show.setlist == null) show.setlist = new List<SetlistItem>();
                    if (show.songs == null) show.songs = new List<string>();
                    if (show.setlist.Count > 2048 || show.songs.Count > 2048 || show.setlistOmitted < 0 || show.setlistOmitted > 10000)
                        throw new InvalidDataException("A show contains an invalid song list.");
                    foreach (SetlistItem item in show.setlist)
                    {
                        if (item == null) throw new InvalidDataException("Setlist items cannot be null.");
                        ValidateText(item.title, 2048, true); ValidateText(item.info, 8192, false); ValidateText(item.encore, 128, false);
                    }
                    foreach (string title in show.songs) ValidateText(title, 2048, true);
                    catalog.Prepare(show);
                }
                return catalog;
            }
            catch (InvalidDataException) { throw; }
            catch (Exception error)
            {
                if (error is ArgumentException || error is InvalidOperationException || error is FormatException || error is OverflowException)
                    throw new InvalidDataException("The catalog metadata could not be read safely.", error);
                throw;
            }
        }

        private static void ValidateRaw(object value, int depth)
        {
            if (depth > 32) throw new InvalidDataException("The catalog nesting limit was exceeded.");
            string text = value as string;
            if (text != null) { ValidateText(text, 32768, false); return; }
            IDictionary<string, object> map = value as IDictionary<string, object>;
            if (map != null)
            {
                if (map.Count > 128) throw new InvalidDataException("A metadata object contains too many fields.");
                foreach (KeyValuePair<string, object> item in map)
                {
                    ValidateText(item.Key, 128, true);
                    if (item.Key == "id")
                    {
                        decimal id;
                        if (!IsNumber(item.Value) || !Decimal.TryParse(Convert.ToString(item.Value, CultureInfo.InvariantCulture), NumberStyles.Number, CultureInfo.InvariantCulture, out id) || id <= 0 || id > Int64.MaxValue || Decimal.Truncate(id) != id)
                            throw new InvalidDataException("Catalog IDs must be positive whole numbers.");
                    }
                    if (item.Key == "rating" && item.Value != null && !IsNumber(item.Value)) throw new InvalidDataException("Sound ratings must be numeric or null.");
                    ValidateRaw(item.Value, depth + 1);
                }
                return;
            }
            System.Collections.IList list = value as System.Collections.IList;
            if (list != null)
            {
                if (list.Count > 250000) throw new InvalidDataException("A metadata list is too large.");
                foreach (object item in list) ValidateRaw(item, depth + 1);
            }
        }
        private static bool IsNumber(object value)
        {
            return value is Int32 || value is Int64 || value is Decimal || value is Double || value is Single || value is Int16 || value is Byte;
        }
        private static void ValidateText(string value, int maximumLength, bool required)
        {
            if ((required && String.IsNullOrWhiteSpace(value)) || (value != null && (value.Length > maximumLength || UrlPattern.IsMatch(value))))
                throw new InvalidDataException("Catalog text is missing, too long, or contains a URL.");
        }
        private static void ValidateDate(string value, string name)
        {
            DateTime parsed;
            if (value == null || value.Length != 10 || !DateTime.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
                throw new InvalidDataException("The catalog contains an invalid " + name + ".");
        }
        private static void ValidateStatus(string value)
        {
            if (value == null || !ValidStatuses.Contains(value)) throw new InvalidDataException("The catalog contains an unknown recording status.");
        }

        private void Prepare(Show show)
        {
            if (show.sources == null || show.sources.Count == 0)
                show.sources = new List<Source> { new Source { status = "Unknown", recordingType = "unknown", version = "Source" } };
            if (show.songs == null) show.songs = new List<string>();
            if (show.setlist == null) show.setlist = new List<SetlistItem>();
            show.SearchText = TextUtil.Normalize(String.Join(" ", new string[] {
                show.date, (show.date ?? "").Replace('-', '/'), show.venue, show.city, show.state, show.country,
                show.festival, show.tour, String.Join(" ", show.songs), String.Join(" ", show.setlist.Select(x => x.title)) }));
            foreach (Source item in show.sources)
                item.SearchText = TextUtil.Normalize(String.Join(" ", new string[] { item.taper, item.gear, item.lineage, item.version, item.recordingType }));
        }

        public static double? SoundRating(Source source)
        {
            if (source == null || !source.rating.HasValue || Double.IsNaN(source.rating.Value) || Double.IsInfinity(source.rating.Value)) return null;
            return source.rating.Value > 0 && source.rating.Value <= 10 ? source.rating : null;
        }

        public bool SourceMatches(Show show, Source item, FilterOptions options)
        {
            string[] tokens = TextUtil.Normalize(options.Search).Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            return SourceMatches(show, item, options, tokens);
        }

        private bool SourceMatches(Show show, Source item, FilterOptions options, string[] tokens)
        {
            double? rating = SoundRating(item);
            if (!String.IsNullOrEmpty(options.Status) && options.Status != "all" && item.status != options.Status) return false;
            if (!String.IsNullOrEmpty(options.RecordingType) && options.RecordingType != "all" && item.recordingType != options.RecordingType) return false;
            if (options.RatingMode == "rated" && !rating.HasValue) return false;
            if (options.RatingMode == "unrated" && rating.HasValue) return false;
            if (options.MinimumRating > 0 && (!rating.HasValue || rating.Value < options.MinimumRating)) return false;
            string text = (show.SearchText ?? "") + " " + (item.SearchText ?? "");
            return tokens.All(token => text.IndexOf(token, StringComparison.Ordinal) >= 0);
        }

        public List<ShowMatch> Filter(FilterOptions options, ISet<string> saved)
        {
            if (options == null) options = new FilterOptions();
            List<ShowMatch> result = new List<ShowMatch>();
            if (!String.IsNullOrEmpty(options.FromYear) && !String.IsNullOrEmpty(options.ToYear) && String.CompareOrdinal(options.FromYear, options.ToYear) > 0) return result;
            string[] tokens = TextUtil.Normalize(options.Search).Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (Show show in shows)
            {
                if (show.SearchText == null) Prepare(show);
                string year = (show.date ?? "").Length >= 4 ? show.date.Substring(0, 4) : "";
                if (!String.IsNullOrEmpty(options.FromYear) && String.CompareOrdinal(year, options.FromYear) < 0) continue;
                if (!String.IsNullOrEmpty(options.ToYear) && String.CompareOrdinal(year, options.ToYear) > 0) continue;
                if (options.SavedOnly && (saved == null || !saved.Contains(show.id.ToString(CultureInfo.InvariantCulture)))) continue;
                List<Source> matching = show.sources.Where(item => SourceMatches(show, item, options, tokens)).ToList();
                if (matching.Count == 0) continue;
                Source best = matching.OrderByDescending(item => SoundRating(item) ?? -1).First();
                result.Add(new ShowMatch { Show = show, Sources = matching, BestSource = best, Rating = SoundRating(best) });
            }
            if (options.Sort == "newest") result = result.OrderByDescending(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            else if (options.Sort == "oldest") result = result.OrderBy(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            else if (options.Sort == "venue") result = result.OrderBy(x => x.Show.venue, StringComparer.CurrentCultureIgnoreCase).ThenByDescending(x => x.Show.date, StringComparer.Ordinal).ToList();
            else result = result.OrderByDescending(x => x.Rating ?? -1).ThenByDescending(x => x.Show.date, StringComparer.Ordinal).ThenBy(x => x.Show.id).ToList();
            return result;
        }
    }

    internal static class TextUtil
    {
        public static string Normalize(string value)
        {
            string text = (value ?? "").Replace("Æ", "AE").Replace("æ", "ae").Replace("Œ", "OE").Replace("œ", "oe").Normalize(NormalizationForm.FormD);
            StringBuilder output = new StringBuilder();
            foreach (char c in text) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) output.Append(Char.ToLowerInvariant(c));
            return output.ToString().Normalize(NormalizationForm.FormC);
        }
        public static bool Useful(string value) { return !String.IsNullOrWhiteSpace(value) && value != "—" && value != "-" && !String.Equals(value, "unknown", StringComparison.OrdinalIgnoreCase); }
        public static string Display(string value) { return Useful(value) ? value : "Not documented"; }
        public static string Location(Show show) { return String.Join(", ", new string[] { show.city, show.state, show.country }.Where(Useful)); }
        public static string Status(string status) { return status == "OTD" ? "On the drive" : status == "Unknown" ? "No known recording" : Display(status); }
        public static string Score(Source source) { double? value = Catalog.SoundRating(source); return value.HasValue ? value.Value.ToString("0.0", CultureInfo.InvariantCulture) + " / 10" : "Unrated"; }
    }

    internal sealed class SavedStore
    {
        public HashSet<string> Ids = new HashSet<string>(StringComparer.Ordinal);
        public string Warning;
        private readonly string path;
        public SavedStore(IEnumerable<Show> shows)
        {
            path = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tool Drive Offline", "saved-shows.json");
            try
            {
                if (File.Exists(path))
                {
                    List<string> values = new JavaScriptSerializer().Deserialize<List<string>>(File.ReadAllText(path, Encoding.UTF8));
                    if (values != null) foreach (string value in values)
                    {
                        long id;
                        if (Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out id) && id > 0)
                            Ids.Add(id.ToString(CultureInfo.InvariantCulture));
                    }
                }
            }
            catch { Warning = "The saved list could not be loaded. You can save shows for this session."; }
        }
        public bool Contains(Show show) { return Ids.Contains(show.id.ToString(CultureInfo.InvariantCulture)); }
        public void Toggle(Show show)
        {
            string key = show.id.ToString(CultureInfo.InvariantCulture);
            if (!Ids.Remove(key)) Ids.Add(key);
            string temp = null;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                File.WriteAllText(temp, new JavaScriptSerializer().Serialize(Ids.OrderBy(x => x).ToArray()), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(temp, path, null); else File.Move(temp, path);
                Warning = null;
            }
            catch { Warning = "Saved for this session. The saved list could not be written to your profile."; }
            finally { try { if (temp != null && File.Exists(temp)) File.Delete(temp); } catch { } }
        }
    }

    internal static class Theme
    {
        public static readonly Color Background = Color.FromArgb(18, 21, 21);
        public static readonly Color Panel = Color.FromArgb(26, 31, 30);
        public static readonly Color Raised = Color.FromArgb(35, 42, 39);
        public static readonly Color Line = Color.FromArgb(53, 64, 58);
        public static readonly Color Text = Color.FromArgb(235, 237, 230);
        public static readonly Color Muted = Color.FromArgb(167, 180, 170);
        public static readonly Color Amber = Color.FromArgb(232, 178, 93);
        public static readonly Font Body = new Font("Segoe UI", 11F);
        public static readonly Font Small = new Font("Segoe UI", 10F);
        public static readonly Font Strong = new Font("Segoe UI", 11F, FontStyle.Bold);
        public static readonly Font Mono = new Font("Consolas", 10.5F);
        public static readonly Font Heading = new Font("Segoe UI", 19F, FontStyle.Bold);
        public static Button Button(string text, bool primary)
        {
            Button button = new Button(); button.Text = text; button.AutoSize = true;
            button.AutoSizeMode = AutoSizeMode.GrowAndShrink; button.Padding = new Padding(11, 6, 11, 6);
            button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderColor = primary ? Amber : Line;
            button.BackColor = primary ? Amber : Panel; button.ForeColor = primary ? Background : Text;
            button.Font = Body; button.Cursor = Cursors.Hand; button.Margin = new Padding(0, 0, 8, 0);
            return button;
        }
        public static Label Label(string text, Color color, Font font)
        {
            return new Label { Text = text, ForeColor = color, Font = font, AutoSize = true, BackColor = Color.Transparent, Margin = new Padding(0) };
        }
        public static ComboBox Combo()
        {
            return new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, BackColor = Panel, ForeColor = Text, FlatStyle = FlatStyle.Flat, Font = Body, IntegralHeight = false, DropDownHeight = 350, Dock = DockStyle.Fill };
        }
        public static void Frame(Form form)
        {
            form.Font = Body; form.BackColor = Background; form.ForeColor = Text;
            form.AutoScaleMode = AutoScaleMode.Dpi;
            try { form.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
        }
    }

    internal sealed class Choice
    {
        public string Text;
        public string Value;
        public Choice(string text, string value) { Text = text; Value = value; }
        public override string ToString() { return Text; }
    }

    internal sealed class GridRow
    {
        public string Date { get; set; }
        public string Venue { get; set; }
        public string Location { get; set; }
        public string Sound { get; set; }
        public string Sources { get; set; }
        public string Type { get; set; }
        public string Taper { get; set; }
        public object Value(int columnIndex)
        {
            switch (columnIndex)
            {
                case 0: return Date;
                case 1: return Venue;
                case 2: return Location;
                case 3: return Sound;
                case 4: return Sources;
                case 5: return Type;
                case 6: return Taper;
                default: return null;
            }
        }
    }

    internal sealed class MainForm : Form
    {
        private Catalog catalog;
        private readonly SavedStore saved;
        private readonly TextBox search = new TextBox();
        private readonly NumericUpDown minimum = new NumericUpDown();
        private readonly ComboBox fromYear = Theme.Combo(), toYear = Theme.Combo(), status = Theme.Combo(), type = Theme.Combo(), ratingMode = Theme.Combo(), sort = Theme.Combo();
        private readonly DataGridView grid = new DataGridView();
        private readonly CheckBox savedOnly = new CheckBox();
        private readonly Label resultCount = Theme.Label("", Theme.Text, Theme.Strong);
        private readonly Label selection = Theme.Label("Select a show to see its recording details.", Theme.Muted, Theme.Small);
        private readonly Label footer = Theme.Label("", Theme.Muted, Theme.Small);
        private readonly Label stats = Theme.Label("", Theme.Muted, Theme.Small);
        private readonly Label lastChecked = Theme.Label("", Theme.Muted, Theme.Small);
        private readonly Label empty = Theme.Label("", Theme.Muted, Theme.Body);
        private readonly Button detail = Theme.Button("Show details", true), copy = Theme.Button("Copy date", false), save = Theme.Button("Save show", false), random = Theme.Button("Pick a show", false);
        private readonly Button update = Theme.Button("Check for catalog updates", false);
        private readonly System.Windows.Forms.Timer searchTimer = new System.Windows.Forms.Timer();
        private readonly System.Windows.Forms.Timer columnSaveTimer = new System.Windows.Forms.Timer();
        private readonly Random rng = new Random();
        private readonly Dictionary<string, int> defaultColumnWidths = new Dictionary<string, int>(StringComparer.Ordinal);
        private List<ShowMatch> matches = new List<ShowMatch>();
        private GridRow[] displayRows = new GridRow[0];
        private bool initializing = true;
        private bool refreshing;
        private bool closing;
        private CancellationTokenSource updateCancellation;
        private string catalogWarning;
        private string updateMessage;
        private DateTime? lastCheckedUtc;
        private bool startupUpdateStarted;
        private bool columnsReady;
        private bool applyingColumnLayout;
        private bool columnWidthsDirty;
        private string columnLayoutWarning;

        public MainForm(Catalog catalog, string warning = null)
        {
            this.catalog = catalog; saved = new SavedStore(catalog.shows);
            catalogWarning = warning; lastCheckedUtc = CatalogCache.LastCheckedUtc;
            Text = "Tool Drive Offline"; StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(1000, 700); Size = new Size(1280, 850);
            Theme.Frame(this); KeyPreview = true;
            Build(); PopulateFilters(); UpdateCatalogHeader(); Wire(); initializing = false; RefreshResults(null);
        }

        private void Build()
        {
            TableLayoutPanel root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(24, 18, 24, 12), BackColor = Theme.Background };
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 145)); root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 72));
            Controls.Add(root);
            TableLayoutPanel header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 3, Margin = new Padding(0, 0, 0, 15) };
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            header.RowStyles.Add(new RowStyle(SizeType.Absolute, 43)); header.RowStyles.Add(new RowStyle(SizeType.Absolute, 37)); header.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            Label title = Theme.Label("TOOL  /  Listening index", Theme.Text, Theme.Heading); title.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
            Label subtitle = Theme.Label("Find your next live listen. Pick a show here; find it in Plexamp.", Theme.Muted, Theme.Body); subtitle.Dock = DockStyle.Fill; subtitle.AutoSize = false; subtitle.AutoEllipsis = true; subtitle.Padding = new Padding(0, 4, 0, 0);
            Label offline = Theme.Label("OFFLINE  ·  METADATA ONLY", Theme.Amber, Theme.Small); offline.Anchor = AnchorStyles.Right | AnchorStyles.Bottom; offline.Padding = new Padding(0, 0, 0, 5);
            stats.Anchor = AnchorStyles.Top | AnchorStyles.Right; stats.Padding = new Padding(0, 6, 0, 0); stats.Margin = new Padding(16, 0, 0, 0); offline.Margin = new Padding(16, 0, 0, 0);
            header.Controls.Add(title, 0, 0); header.Controls.Add(subtitle, 0, 1); header.Controls.Add(offline, 1, 0); header.Controls.Add(stats, 1, 1); root.Controls.Add(header, 0, 0);
            FlowLayoutPanel updateBand = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0), Padding = new Padding(0, 2, 0, 0) };
            update.MinimumSize = new Size(260, 40); update.AccessibleName = "Check catalog metadata updates now; a check also runs once at launch";
            lastChecked.Margin = new Padding(7, 10, 0, 0); updateBand.Controls.Add(update); updateBand.Controls.Add(lastChecked); header.Controls.Add(updateBand, 0, 2); header.SetColumnSpan(updateBand, 2);

            TableLayoutPanel workspace = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0) };
            workspace.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 240)); workspace.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); root.Controls.Add(workspace, 0, 1);
            Panel filterPanel = new Panel { Dock = DockStyle.Fill, AutoScroll = true, BackColor = Theme.Panel, Padding = new Padding(17), Margin = new Padding(0, 0, 21, 0) };
            TableLayoutPanel filters = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 1, Padding = new Padding(0), Margin = new Padding(0) };
            filters.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); filterPanel.Controls.Add(filters); workspace.Controls.Add(filterPanel, 0, 0);
            Label filterTitle = Theme.Label("FILTER THE ARCHIVE", Theme.Amber, Theme.Small); filterTitle.Margin = new Padding(0, 0, 0, 22); filters.Controls.Add(filterTitle);
            minimum.Minimum = 0; minimum.Maximum = 10; minimum.Increment = 0.5M; minimum.DecimalPlaces = 1; minimum.BackColor = Theme.Background; minimum.ForeColor = Theme.Text; minimum.BorderStyle = BorderStyle.FixedSingle; minimum.Font = Theme.Body; minimum.Dock = DockStyle.Fill;
            AddField(filters, "Minimum sound rating / 10", minimum);
            AddField(filters, "Rating availability", ratingMode); AddField(filters, "From year", fromYear); AddField(filters, "Through year", toYear);
            AddField(filters, "Recording status", status); AddField(filters, "Recording type", type);
            Button reset = Theme.Button("Reset filters", false); reset.Dock = DockStyle.Fill; reset.Margin = new Padding(0, 8, 0, 18); reset.Click += delegate { ResetFilters(); }; filters.Controls.Add(reset);
            Label note = Theme.Label("Sound ratings describe recording quality, out of 10.\r\n\r\nEach show uses its highest matching source rating. One source must match all source filters.", Theme.Muted, Theme.Small);
            note.MaximumSize = new Size(181, 0); note.AutoSize = true; note.Margin = new Padding(0, 0, 0, 15); filters.Controls.Add(note);

            TableLayoutPanel results = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Margin = new Padding(0) };
            results.RowStyles.Add(new RowStyle(SizeType.Absolute, 58)); results.RowStyles.Add(new RowStyle(SizeType.Absolute, 49)); results.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); results.RowStyles.Add(new RowStyle(SizeType.Absolute, 91)); workspace.Controls.Add(results, 1, 0);
            TableLayoutPanel searchBand = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, Margin = new Padding(0) };
            searchBand.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); searchBand.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            search.BorderStyle = BorderStyle.FixedSingle; search.BackColor = Theme.Panel; search.ForeColor = Theme.Text; search.Font = new Font("Segoe UI", 13F); search.Dock = DockStyle.Fill; search.Margin = new Padding(0, 0, 8, 15); search.AccessibleName = "Search date, venue, city, taper, or song";
            Button clear = Theme.Button("Clear", false); clear.MinimumSize = new Size(104, 40); clear.Dock = DockStyle.Top; clear.Margin = new Padding(0); clear.Click += delegate { search.Clear(); search.Focus(); };
            searchBand.Controls.Add(search, 0, 0); searchBand.Controls.Add(clear, 1, 0); results.Controls.Add(searchBand, 0, 0);
            TableLayoutPanel toolbar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, RowCount = 1, Margin = new Padding(0) };
            toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 108)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145)); toolbar.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 169));
            resultCount.Dock = DockStyle.Fill; resultCount.TextAlign = ContentAlignment.TopLeft; resultCount.Padding = new Padding(0, 4, 0, 0);
            savedOnly.Text = "Saved (0)"; savedOnly.AutoSize = true; savedOnly.ForeColor = Theme.Text; savedOnly.Font = Theme.Small; savedOnly.Margin = new Padding(0, 5, 5, 0); savedOnly.AccessibleName = "Show saved shows only";
            random.Font = Theme.Small; random.Dock = DockStyle.Top; random.Padding = new Padding(4, 4, 4, 4); random.Margin = new Padding(0, 0, 8, 0); sort.Dock = DockStyle.Top; sort.Margin = new Padding(0); sort.AccessibleName = "Sort shows";
            toolbar.Controls.Add(resultCount, 0, 0); toolbar.Controls.Add(savedOnly, 1, 0); toolbar.Controls.Add(random, 2, 0); toolbar.Controls.Add(sort, 3, 0); results.Controls.Add(toolbar, 0, 1);
            Panel gridPanel = new Panel { Dock = DockStyle.Fill, Margin = new Padding(0), BackColor = Theme.Panel };
            ConfigureGrid(); gridPanel.Controls.Add(grid); empty.Dock = DockStyle.Fill; empty.TextAlign = ContentAlignment.MiddleCenter; empty.Visible = false; empty.Padding = new Padding(25); gridPanel.Controls.Add(empty); results.Controls.Add(gridPanel, 0, 2);
            TableLayoutPanel selectedBand = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 2, Margin = new Padding(0), Padding = new Padding(0, 10, 0, 0) };
            selectedBand.RowStyles.Add(new RowStyle(SizeType.Absolute, 29)); selectedBand.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); selection.Dock = DockStyle.Fill; selection.AutoEllipsis = true; selectedBand.Controls.Add(selection, 0, 0);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0) }; actions.Controls.Add(detail); actions.Controls.Add(copy); actions.Controls.Add(save); selectedBand.Controls.Add(actions, 0, 1); results.Controls.Add(selectedBand, 0, 3);
            footer.Dock = DockStyle.Fill; footer.AutoSize = false; footer.AutoEllipsis = true; footer.Padding = new Padding(0, 12, 0, 0); root.Controls.Add(footer, 0, 2);
        }

        private static void AddField(TableLayoutPanel panel, string text, Control control)
        {
            Label label = Theme.Label(text, Theme.Muted, Theme.Small); label.Margin = new Padding(0, 0, 0, 7); panel.Controls.Add(label);
            control.Margin = new Padding(0, 0, 0, 17); control.AccessibleName = text; control.Height = 32; panel.Controls.Add(control);
        }

        private void ConfigureGrid()
        {
            grid.Dock = DockStyle.Fill; grid.BackgroundColor = Theme.Panel; grid.BorderStyle = BorderStyle.None; grid.AutoGenerateColumns = false;
            grid.VirtualMode = true; grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.None; grid.AutoSizeRowsMode = DataGridViewAutoSizeRowsMode.None;
            grid.ScrollBars = ScrollBars.Both;
            grid.ReadOnly = true; grid.AllowUserToAddRows = false; grid.AllowUserToDeleteRows = false; grid.AllowUserToResizeRows = false;
            grid.RowHeadersVisible = false; grid.MultiSelect = false; grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            grid.EnableHeadersVisualStyles = false; grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal; grid.GridColor = Theme.Line;
            grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None; grid.ColumnHeadersHeight = 41; grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
            grid.ColumnHeadersDefaultCellStyle.BackColor = Theme.Raised; grid.ColumnHeadersDefaultCellStyle.ForeColor = Theme.Muted; grid.ColumnHeadersDefaultCellStyle.Font = Theme.Small;
            grid.DefaultCellStyle.BackColor = Theme.Panel; grid.DefaultCellStyle.ForeColor = Theme.Text; grid.DefaultCellStyle.Font = Theme.Body;
            grid.DefaultCellStyle.SelectionBackColor = Color.FromArgb(59, 64, 46); grid.DefaultCellStyle.SelectionForeColor = Theme.Text;
            grid.DefaultCellStyle.Padding = new Padding(7, 0, 7, 0); grid.RowTemplate.Height = 46;
            AddColumn("Date", "DATE", 140); AddColumn("Venue", "VENUE", 250); AddColumn("Location", "LOCATION", 210);
            AddColumn("Sound", "SOUND /10", 112); AddColumn("Sources", "SOURCES", 100); AddColumn("Type", "BEST TYPE", 130); AddColumn("Taper", "TAPER", 175);
            grid.Columns["Sound"].DefaultCellStyle.ForeColor = Theme.Amber; grid.Columns["Sound"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleRight;
            grid.Columns["Date"].DefaultCellStyle.Font = Theme.Mono; grid.Columns["Sources"].DefaultCellStyle.Alignment = DataGridViewContentAlignment.MiddleCenter;
            grid.AccessibleName = "Matching shows. Press Enter to open recording details.";
            grid.CellValueNeeded += delegate(object sender, DataGridViewCellValueEventArgs e)
            {
                if (e.RowIndex >= 0 && e.RowIndex < matches.Count) e.Value = DisplayRow(e.RowIndex).Value(e.ColumnIndex);
            };
            typeof(DataGridView).GetProperty("DoubleBuffered", BindingFlags.Instance | BindingFlags.NonPublic).SetValue(grid, true, null);
        }
        private void AddColumn(string property, string header, int width)
        {
            DataGridViewTextBoxColumn column = new DataGridViewTextBoxColumn { Name = property, HeaderText = header, Width = width, MinimumWidth = property == "Date" ? 130 : 48, SortMode = DataGridViewColumnSortMode.NotSortable, AutoSizeMode = DataGridViewAutoSizeColumnMode.None, Resizable = DataGridViewTriState.True };
            defaultColumnWidths[property] = width;
            grid.Columns.Add(column);
        }

        private GridRow DisplayRow(int rowIndex)
        {
            GridRow row = displayRows[rowIndex];
            if (row != null) return row;
            ShowMatch item = matches[rowIndex];
            row = new GridRow { Date = item.Show.date, Venue = (saved.Contains(item.Show) ? "★  " : "") + item.Show.venue,
                Location = TextUtil.Location(item.Show), Sound = item.Rating.HasValue ? item.Rating.Value.ToString("0.0", CultureInfo.InvariantCulture) : "—",
                Sources = item.Sources.Count(x => x.status != "Unknown").ToString(CultureInfo.InvariantCulture), Type = TextUtil.Display(item.BestSource.recordingType), Taper = TextUtil.Display(item.BestSource.taper) };
            displayRows[rowIndex] = row; return row;
        }

        private double CurrentGridDpi()
        {
            using (Graphics graphics = grid.CreateGraphics()) return Math.Max(1.0, graphics.DpiX);
        }

        private void RestoreColumnLayout()
        {
            applyingColumnLayout = true; columnsReady = false; columnSaveTimer.Stop();
            try
            {
                Dictionary<string, int> widths = ColumnLayoutStore.Load(out columnLayoutWarning);
                ApplyColumnWidths(widths, CurrentGridDpi()); columnWidthsDirty = false;
            }
            catch { columnLayoutWarning = "Column widths could not be loaded. You can still resize the columns."; }
            finally { applyingColumnLayout = false; columnsReady = true; }
            UpdateFooter(null);
        }

        private void ApplyColumnWidths(IDictionary<string, int> widths, double dpi)
        {
            grid.SuspendLayout();
            try
            {
                foreach (DataGridViewColumn column in grid.Columns)
                {
                    int logical;
                    if (widths == null || !widths.TryGetValue(column.Name, out logical)) logical = defaultColumnWidths[column.Name];
                    logical = Math.Max(column.Name == "Date" ? 130 : 48, Math.Min(3000, logical));
                    column.AutoSizeMode = DataGridViewAutoSizeColumnMode.None; column.Visible = true;
                    column.MinimumWidth = Math.Max(2, (int)Math.Round((column.Name == "Date" ? 130 : 48) * dpi / 96.0));
                    column.Width = Math.Max(column.MinimumWidth, (int)Math.Round(logical * dpi / 96.0));
                }
            }
            finally { grid.ResumeLayout(); }
        }

        private Dictionary<string, int> CaptureColumnWidths(double dpi)
        {
            Dictionary<string, int> widths = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (DataGridViewColumn column in grid.Columns)
                widths[column.Name] = Math.Max(40, Math.Min(3000, (int)Math.Round(column.Width * 96.0 / dpi)));
            return widths;
        }

        private void FlushColumnLayout()
        {
            columnSaveTimer.Stop(); if (!columnsReady || !columnWidthsDirty || applyingColumnLayout) return;
            try
            {
                if (ColumnLayoutStore.Save(CaptureColumnWidths(CurrentGridDpi()), out columnLayoutWarning)) columnWidthsDirty = false;
            }
            catch { columnLayoutWarning = "Column widths could not be saved. The current layout remains available for this session."; }
            if (!closing && !IsDisposed && !Disposing) UpdateFooter(null);
        }

        private void PopulateFilters(FilterOptions preserve = null)
        {
            foreach (ComboBox combo in new ComboBox[] { ratingMode, status, sort, fromYear, toYear, type }) combo.Items.Clear();
            ratingMode.Items.AddRange(new object[] { new Choice("Rated and unrated", "any"), new Choice("Rated only", "rated"), new Choice("Unrated only", "unrated") });
            status.Items.AddRange(new object[] { new Choice("On the drive", "OTD"), new Choice("All statuses", "all"), new Choice("Confirmed", "Confirmed"), new Choice("Unconfirmed", "Unconfirmed"), new Choice("No known recording", "Unknown") });
            sort.Items.AddRange(new object[] { new Choice("Highest rated", "rating"), new Choice("Newest first", "newest"), new Choice("Oldest first", "oldest"), new Choice("Venue A–Z", "venue") });
            fromYear.Items.Add(new Choice("Any starting year", "")); toYear.Items.Add(new Choice("Any ending year", ""));
            foreach (string year in catalog.shows.Select(s => s.date.Substring(0, 4)).Distinct().OrderBy(x => x)) { fromYear.Items.Add(new Choice(year, year)); toYear.Items.Add(new Choice(year, year)); }
            type.Items.Add(new Choice("All recording types", "all"));
            foreach (string value in catalog.shows.SelectMany(s => s.sources).Select(s => s.recordingType ?? "unknown").Distinct().OrderBy(x => x == "unknown" ? "zzzz" : x))
                type.Items.Add(new Choice(Char.ToUpperInvariant(value[0]) + value.Substring(1), value));
            SelectChoice(ratingMode, preserve == null ? "any" : preserve.RatingMode, false);
            SelectChoice(status, preserve == null ? "OTD" : preserve.Status, false);
            SelectChoice(sort, preserve == null ? "rating" : preserve.Sort, false);
            SelectChoice(fromYear, preserve == null ? "" : preserve.FromYear, true);
            SelectChoice(toYear, preserve == null ? "" : preserve.ToYear, true);
            SelectChoice(type, preserve == null ? "all" : preserve.RecordingType, true);
        }

        private static void SelectChoice(ComboBox combo, string value, bool retainMissing)
        {
            for (int index = 0; index < combo.Items.Count; index++)
                if (((Choice)combo.Items[index]).Value == value) { combo.SelectedIndex = index; return; }
            if (retainMissing && !String.IsNullOrEmpty(value))
            {
                combo.Items.Add(new Choice(value + " (not in catalog)", value)); combo.SelectedIndex = combo.Items.Count - 1;
            }
            else combo.SelectedIndex = 0;
        }

        private void UpdateCatalogHeader()
        {
            int onDriveCount = catalog.shows.Sum(s => s.sources.Count(x => x.status == "OTD"));
            stats.Text = catalog.shows.Count.ToString("N0") + " shows  ·  " + onDriveCount.ToString("N0") + " on-drive recordings";
            lastChecked.Text = lastCheckedUtc.HasValue ? "Last checked: " + lastCheckedUtc.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) : "Checks once at launch · saved catalog works offline";
        }

        private void Wire()
        {
            searchTimer.Interval = 200; searchTimer.Tick += delegate { searchTimer.Stop(); RefreshResults(null); };
            columnSaveTimer.Interval = 500; columnSaveTimer.Tick += delegate { FlushColumnLayout(); };
            search.TextChanged += delegate { if (!initializing) { searchTimer.Stop(); searchTimer.Start(); } };
            minimum.ValueChanged += delegate { if (!initializing) RefreshResults(null); };
            foreach (ComboBox combo in new ComboBox[] { fromYear, toYear, status, type, ratingMode, sort }) combo.SelectedIndexChanged += delegate
            {
                if (initializing) return; bool unrated = Value(ratingMode) == "unrated";
                minimum.Enabled = !unrated; if (unrated) minimum.Value = 0; RefreshResults(null);
            };
            savedOnly.CheckedChanged += delegate { if (!initializing) RefreshResults(null); };
            grid.SelectionChanged += delegate { if (!refreshing) UpdateSelection(); };
            grid.CellDoubleClick += delegate(object sender, DataGridViewCellEventArgs e) { if (e.RowIndex >= 0) OpenSelected(); };
            grid.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Enter) { e.Handled = true; e.SuppressKeyPress = true; OpenSelected(); } };
            detail.Click += delegate { OpenSelected(); }; copy.Click += delegate { ShowMatch item = Selected(); if (item != null) CopyText(item.Show.date); };
            save.Click += delegate { ShowMatch item = Selected(); if (item != null) ToggleSaved(item.Show); };
            random.Click += delegate { if (matches.Count > 0) OpenShow(matches[rng.Next(matches.Count)].Show); };
            update.Click += async delegate { startupUpdateStarted = true; await CheckForUpdates(false); };
            KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Control && e.KeyCode == Keys.F) { search.Focus(); search.SelectAll(); e.Handled = true; e.SuppressKeyPress = true; } };
            grid.ColumnWidthChanged += delegate
            {
                if (!columnsReady || applyingColumnLayout || initializing || closing) return;
                columnWidthsDirty = true; columnSaveTimer.Stop(); columnSaveTimer.Start();
            };
            FormClosed += delegate { searchTimer.Dispose(); columnSaveTimer.Dispose(); };
            Shown += delegate
            {
                RestoreColumnLayout(); search.Focus();
                BeginInvoke(new Action(StartStartupUpdate));
            };
        }

        private async void StartStartupUpdate()
        {
            if (startupUpdateStarted || closing || IsDisposed || Disposing) return;
            startupUpdateStarted = true;
            if (updateCancellation == null) await CheckForUpdates(true);
        }

        private static string Value(ComboBox combo) { Choice choice = combo.SelectedItem as Choice; return choice == null ? "" : choice.Value; }
        private FilterOptions Options()
        {
            return new FilterOptions { Search = search.Text, MinimumRating = Decimal.ToDouble(minimum.Value), RatingMode = Value(ratingMode), FromYear = Value(fromYear), ToYear = Value(toYear), Status = Value(status), RecordingType = Value(type), SavedOnly = savedOnly.Checked, Sort = Value(sort) };
        }
        private void ResetFilters()
        {
            initializing = true; searchTimer.Stop(); search.Clear(); minimum.Value = 0; minimum.Enabled = true; savedOnly.Checked = false;
            foreach (ComboBox combo in new ComboBox[] { fromYear, toYear, status, type, ratingMode, sort }) combo.SelectedIndex = 0;
            initializing = false; RefreshResults(null); search.Focus();
        }
        private void RefreshResults(long? selectedId)
        {
            if (initializing) return; searchTimer.Stop(); refreshing = true;
            int previousIndex = grid.CurrentCell == null ? 0 : grid.CurrentCell.RowIndex;
            int previousColumn = grid.CurrentCell == null ? 0 : grid.CurrentCell.ColumnIndex;
            int oldTopIndex = grid.IsHandleCreated ? grid.FirstDisplayedScrollingRowIndex : -1;
            long? oldTopId = selectedId.HasValue && oldTopIndex >= 0 && oldTopIndex < matches.Count ? (long?)matches[oldTopIndex].Show.id : null;
            int horizontalOffset = grid.HorizontalScrollingOffset;
            grid.SuspendLayout();
            try
            {
                matches = catalog.Filter(Options(), saved.Ids);
                displayRows = new GridRow[matches.Count];
                if (grid.RowCount != matches.Count) grid.RowCount = matches.Count;
                grid.ClearSelection();
                if (matches.Count > 0)
                {
                    int index = selectedId.HasValue ? matches.FindIndex(x => x.Show.id == selectedId.Value) : 0;
                    if (index < 0) index = Math.Min(previousIndex, matches.Count - 1);
                    grid.CurrentCell = grid[Math.Min(previousColumn, grid.ColumnCount - 1), index];
                    grid.CurrentCell.Selected = true;
                    if (grid.IsHandleCreated && selectedId.HasValue && oldTopId.HasValue)
                    {
                        int top = matches.FindIndex(x => x.Show.id == oldTopId.Value);
                        int visibleRows = Math.Max(1, grid.DisplayedRowCount(false));
                        if (top >= 0 && index >= top && index < top + visibleRows) grid.FirstDisplayedScrollingRowIndex = top;
                    }
                    else if (grid.IsHandleCreated) grid.FirstDisplayedScrollingRowIndex = 0;
                    if (grid.IsHandleCreated) grid.HorizontalScrollingOffset = horizontalOffset;
                }
                resultCount.Text = matches.Count.ToString("N0") + (savedOnly.Checked ? " saved shows" : " shows");
                savedOnly.Text = "Saved (" + saved.Ids.Count.ToString(CultureInfo.InvariantCulture) + ")"; random.Enabled = matches.Count > 0;
                empty.Visible = matches.Count == 0; grid.Visible = matches.Count > 0;
                if (empty.Visible) { empty.BringToFront(); empty.Text = savedOnly.Checked && saved.Ids.Count == 0 ? "Your listening shortlist starts here.\r\n\r\nUncheck Saved, then save a show you would like to hear." : "No shows match these filters.\r\n\r\nTry a lower rating, a wider year range, or another recording status."; }
                grid.Invalidate();
            }
            finally { grid.ResumeLayout(); refreshing = false; }
            UpdateSelection(); UpdateFooter(null);
        }
        private ShowMatch Selected()
        {
            int index = grid.CurrentCell == null ? -1 : grid.CurrentCell.RowIndex;
            return index >= 0 && index < matches.Count ? matches[index] : null;
        }
        private void UpdateSelection()
        {
            ShowMatch item = Selected(); detail.Enabled = item != null; copy.Enabled = item != null; save.Enabled = item != null;
            selection.Text = item == null ? "No show selected. Adjust your filters to browse the archive." : item.Show.date + "  ·  " + item.Show.venue + "  ·  " + TextUtil.Location(item.Show);
            save.Text = item != null && saved.Contains(item.Show) ? "Remove saved" : "Save show";
        }
        private void UpdateFooter(string message)
        {
            string state = message ?? (updateCancellation != null ? "Checking public show and rating metadata. Your current catalog remains available; use Cancel update to stop." : null)
                ?? updateMessage ?? saved.Warning ?? catalogWarning ?? columnLayoutWarning ?? "Metadata only · checks once at launch · Sound quality /10, not performance rating";
            footer.Text = "Snapshot " + catalog.snapshotDate + (lastCheckedUtc.HasValue ? "  ·  Last checked " + lastCheckedUtc.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) : "  ·  Never checked online") + "\r\n" + state;
        }

        private async Task CheckForUpdates(bool startup)
        {
            if (closing || IsDisposed || Disposing) return;
            if (updateCancellation != null)
            {
                if (startup) return;
                updateCancellation.Cancel(); update.Enabled = false; update.Text = "Canceling update…";
                UpdateFooter("Canceling the check. Your current catalog remains available."); return;
            }
            CancellationTokenSource cancellation = new CancellationTokenSource(); updateCancellation = cancellation;
            update.Text = "Cancel update"; updateMessage = null; UpdateFooter(null);
            try
            {
                CatalogUpdateResult result = await CatalogUpdater.CheckAsync(catalog, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();
                if (closing || IsDisposed || Disposing) return;
                FilterOptions preserve = Options(); ShowMatch selected = Selected(); long? selectedId = selected == null ? (long?)null : selected.Show.id;
                try { CatalogCache.Save(result.Catalog, result.CheckedAtUtc); }
                catch
                {
                    updateMessage = "The update could not be saved. Your current catalog is unchanged. Check available disk space or profile permissions and try again.";
                    return;
                }
                catalog = result.Catalog; lastCheckedUtc = result.CheckedAtUtc; catalogWarning = null;
                initializing = true;
                try { PopulateFilters(preserve); UpdateCatalogHeader(); }
                finally { initializing = false; }
                updateMessage = result.Changes.HasChanges ? "Catalog updated: " + result.Changes.Summary : "Catalog is up to date. No show or recording metadata changed.";
                RefreshResults(selectedId);
            }
            catch (OperationCanceledException)
            {
                if (!closing && !IsDisposed && !Disposing) updateMessage = cancellation.IsCancellationRequested ? "Update canceled. Your current catalog is unchanged." : "The update check timed out. Your current catalog is unchanged; try again later.";
            }
            catch (Exception)
            {
                if (!closing && !IsDisposed && !Disposing) updateMessage = startup
                    ? "Could not check for updates. Your saved catalog is ready to use offline; you can try again with Check for catalog updates."
                    : "The catalog update could not be completed. Your current catalog is unchanged. Check your connection and try again later.";
            }
            finally
            {
                updateCancellation = null; cancellation.Dispose();
                if (!closing && !IsDisposed && !Disposing)
                {
                    update.Enabled = true; update.Text = "Check for catalog updates"; UpdateFooter(null);
                }
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            closing = true; if (updateCancellation != null) updateCancellation.Cancel(); searchTimer.Stop();
            FlushColumnLayout();
            base.OnFormClosing(e); if (e.Cancel) closing = false;
        }

        protected override void OnDpiChanged(DpiChangedEventArgs e)
        {
            if (!columnsReady) { base.OnDpiChanged(e); return; }
            Dictionary<string, int> widths = CaptureColumnWidths(Math.Max(1, e.DeviceDpiOld));
            bool pendingSave = columnWidthsDirty; applyingColumnLayout = true; columnSaveTimer.Stop();
            try { base.OnDpiChanged(e); ApplyColumnWidths(widths, Math.Max(1, e.DeviceDpiNew)); }
            finally { applyingColumnLayout = false; }
            if (pendingSave) columnSaveTimer.Start();
        }
        private void ToggleSaved(Show show) { saved.Toggle(show); RefreshResults(show.id); }
        private void OpenSelected() { ShowMatch item = Selected(); if (item != null) OpenShow(item.Show); }
        private void OpenShow(Show show)
        {
            using (DetailForm dialog = new DetailForm(catalog, show, Options(), saved, ToggleSaved)) dialog.ShowDialog(this);
            if (grid.Visible) grid.Focus();
        }
        private void CopyText(string value)
        {
            if (ClipboardHelper.Copy(this, value)) UpdateFooter("Copied " + value + ". Paste into Plexamp search.");
        }
    }

    internal static class ClipboardHelper
    {
        public static bool Copy(IWin32Window owner, string text)
        {
            try { Clipboard.SetText(text ?? ""); return true; }
            catch
            {
                using (Form form = new Form())
                {
                    Theme.Frame(form); form.Text = "Copy for Plexamp"; form.ClientSize = new Size(500, 142); form.FormBorderStyle = FormBorderStyle.FixedDialog; form.StartPosition = FormStartPosition.CenterParent; form.MaximizeBox = false; form.MinimizeBox = false;
                    Label label = Theme.Label("The clipboard is busy. Select and copy this text:", Theme.Text, Theme.Body); label.Location = new Point(18, 16); label.AutoSize = true;
                    TextBox field = new TextBox { Text = text, ReadOnly = true, Location = new Point(18, 52), Size = new Size(464, 30), BackColor = Theme.Panel, ForeColor = Theme.Text, Font = Theme.Body };
                    Button close = Theme.Button("Close", false); close.Location = new Point(389, 94); close.DialogResult = DialogResult.OK;
                    form.Controls.Add(label); form.Controls.Add(field); form.Controls.Add(close); form.CancelButton = close;
                    form.Shown += delegate { field.Focus(); field.SelectAll(); }; form.ShowDialog(owner);
                }
                return false;
            }
        }
    }

    internal sealed class DetailForm : Form
    {
        private readonly Show show;
        private readonly SavedStore saved;
        private readonly Action<Show> toggle;
        private readonly Button save = Theme.Button("Save show", false);
        public DetailForm(Catalog catalog, Show show, FilterOptions options, SavedStore saved, Action<Show> toggle)
        {
            this.show = show; this.saved = saved; this.toggle = toggle;
            Theme.Frame(this); Text = show.date + " · " + show.venue; Size = new Size(920, 760); MinimumSize = new Size(700, 570); StartPosition = FormStartPosition.CenterParent; KeyPreview = true;
            TableLayoutPanel root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, Padding = new Padding(24, 20, 24, 15) };
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 98)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58)); root.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); root.RowStyles.Add(new RowStyle(SizeType.Absolute, 39)); Controls.Add(root);
            TableLayoutPanel header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Margin = new Padding(0) };
            header.RowStyles.Add(new RowStyle(SizeType.Absolute, 26)); header.RowStyles.Add(new RowStyle(SizeType.Absolute, 39)); header.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            header.Controls.Add(Theme.Label(show.date + "   /   RECORDING NOTES", Theme.Amber, Theme.Mono), 0, 0);
            Label venue = Theme.Label(show.venue, Theme.Text, Theme.Heading); venue.Dock = DockStyle.Fill; venue.AutoEllipsis = true; header.Controls.Add(venue, 0, 1);
            Label location = Theme.Label(TextUtil.Location(show) + (TextUtil.Useful(show.tour) ? "   ·   " + show.tour : ""), Theme.Muted, Theme.Body); location.Dock = DockStyle.Fill; location.AutoEllipsis = true; header.Controls.Add(location, 0, 2); root.Controls.Add(header, 0, 0);
            FlowLayoutPanel actions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false, Margin = new Padding(0), Padding = new Padding(0, 5, 0, 10) };
            Button date = Theme.Button("Copy date for Plexamp", true), search = Theme.Button("Copy Tool + date", false), close = Theme.Button("Close", false);
            date.Click += delegate { ClipboardHelper.Copy(this, show.date); }; search.Click += delegate { ClipboardHelper.Copy(this, "Tool " + show.date); };
            save.Text = saved.Contains(show) ? "Remove saved" : "Save show"; save.Click += delegate { toggle(show); save.Text = saved.Contains(show) ? "Remove saved" : "Save show"; };
            close.DialogResult = DialogResult.Cancel; CancelButton = close; actions.Controls.Add(date); actions.Controls.Add(search); actions.Controls.Add(save); actions.Controls.Add(close); root.Controls.Add(actions, 0, 1);
            TabControl tabs = new TabControl { Dock = DockStyle.Fill, Font = Theme.Body, Padding = new Point(16, 7), Margin = new Padding(0) };
            TabPage sources = new TabPage("Recording sources (" + show.sources.Count.ToString() + ")"), setlist = new TabPage(show.setlist.Count > 0 ? "Setlist" : "Known songs");
            sources.BackColor = Theme.Panel; setlist.BackColor = Theme.Panel;
            RichTextBox sourceText = RichText(), songText = RichText(); sources.Controls.Add(sourceText); setlist.Controls.Add(songText); tabs.TabPages.Add(sources); tabs.TabPages.Add(setlist); root.Controls.Add(tabs, 0, 2);
            Append(sourceText, "SOUND QUALITY OUT OF 10\r\n", Theme.Amber, Theme.Strong);
            Append(sourceText, "All sources are shown. Matching means a source passes your search, status, type and sound-rating filters.\r\n\r\n", Theme.Muted, Theme.Body);
            foreach (Source item in show.sources.OrderByDescending(x => catalog.SourceMatches(show, x, options)).ThenByDescending(x => Catalog.SoundRating(x) ?? -1))
            {
                bool match = catalog.SourceMatches(show, item, options);
                Append(sourceText, TextUtil.Display(item.version) + "   ·   " + TextUtil.Status(item.status) + "   ·   " + TextUtil.Score(item) + "\r\n", Theme.Amber, Theme.Strong);
                Append(sourceText, match ? "MATCHES CURRENT SOURCE FILTERS\r\n" : "OUTSIDE CURRENT SOURCE FILTERS\r\n", Theme.Muted, Theme.Small);
                Append(sourceText, "Taper: " + TextUtil.Display(item.taper) + "\r\nType: " + TextUtil.Display(item.recordingType) + "     Length: " + TextUtil.Display(item.length) + "\r\n", Theme.Text, Theme.Body);
                Append(sourceText, "Gear: " + TextUtil.Display(item.gear) + "\r\nGeneration: " + (item.generation == "0" ? "0 (master)" : TextUtil.Display(item.generation)) + "     Format: " + TextUtil.Display(item.codec) + " / " + TextUtil.Display(item.lossless) + "\r\n", Theme.Text, Theme.Body);
                if (TextUtil.Useful(item.lineage)) Append(sourceText, "Lineage: " + item.lineage + "\r\n", Theme.Muted, Theme.Body);
                Append(sourceText, "Source ID: " + item.id.ToString(CultureInfo.InvariantCulture) + "\r\n\r\n────────────────────────────────────────\r\n\r\n", Theme.Muted, Theme.Small);
            }
            if (show.setlist.Count > 0)
            {
                Append(songText, "DOCUMENTED PERFORMANCE ORDER\r\n\r\n", Theme.Amber, Theme.Strong);
                for (int i = 0; i < show.setlist.Count; i++)
                {
                    SetlistItem item = show.setlist[i]; Append(songText, (i + 1).ToString("00") + "   " + item.title + "\r\n", Theme.Text, Theme.Body);
                    if (TextUtil.Useful(item.info)) Append(songText, "       " + item.info + "\r\n", Theme.Muted, Theme.Small);
                }
                if (show.setlistOmitted > 0) Append(songText, "\r\n" + show.setlistOmitted.ToString() + " uncatalogued item(s) omitted from this setlist.\r\n", Theme.Muted, Theme.Small);
            }
            else if (show.songs.Count > 0)
            {
                Append(songText, "KNOWN SONGS · PERFORMANCE ORDER UNAVAILABLE\r\n\r\n", Theme.Amber, Theme.Strong);
                foreach (string song in show.songs) Append(songText, "•  " + song + "\r\n", Theme.Text, Theme.Body);
            }
            else Append(songText, "No setlist is documented in this snapshot.\r\n", Theme.Muted, Theme.Body);
            Append(songText, "\r\n" + catalog.source + "\r\n", Theme.Muted, Theme.Small);
            foreach (RichTextBox box in new RichTextBox[] { sourceText, songText }) { box.SelectionStart = 0; box.SelectionLength = 0; box.ScrollToCaret(); }
            Label footer = Theme.Label("Snapshot " + catalog.snapshotDate + "  ·  Metadata only. Search your own library in Plexamp.", Theme.Muted, Theme.Small); footer.Dock = DockStyle.Fill; footer.Padding = new Padding(0, 13, 0, 0); footer.AutoEllipsis = true; root.Controls.Add(footer, 0, 3);
            KeyDown += delegate(object sender, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) { Close(); e.Handled = true; } };
        }
        private static RichTextBox RichText() { return new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, DetectUrls = false, BackColor = Theme.Panel, ForeColor = Theme.Text, BorderStyle = BorderStyle.None, Font = Theme.Body, WordWrap = true, ScrollBars = RichTextBoxScrollBars.Vertical, TabStop = true, Padding = new Padding(15), Text = "" }; }
        private static void Append(RichTextBox box, string text, Color color, Font font) { box.SelectionStart = box.TextLength; box.SelectionLength = 0; box.SelectionColor = color; box.SelectionFont = font; box.AppendText(text); }
    }

    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try
            {
                string warning; Catalog catalog = CatalogCache.Load(out warning);
                Application.Run(new MainForm(catalog, warning));
            }
            catch (Exception error) { MessageBox.Show("Tool Drive Offline could not start.\r\n\r\n" + error.Message, "Tool Drive Offline", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }
    }
}
