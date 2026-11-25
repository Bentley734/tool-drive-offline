using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace ToolDriveOffline
{
    // Widths are logical pixels at 96 DPI. The UI scales them for its current monitor.
    public static class ColumnLayoutStore
    {
        public const int MinimumWidth = 40;
        public const int MaximumWidth = 3000;
        private const int MaximumFileBytes = 32 * 1024;
        private static readonly string[] Names = { "Date", "Venue", "Location", "Sound", "Sources", "Type", "Taper" };
        public static IList<string> AllowedNames { get { return Array.AsReadOnly(Names); } }
        public static string FilePath
        {
            get { return Path.Combine(DesktopBootstrap.Profile, "column-layout.json"); }
        }

        public static Dictionary<string, int> Load(out string warning)
        {
            return Load(FilePath, out warning);
        }

        public static Dictionary<string, int> Load(string path, out string warning)
        {
            warning = null;
            Dictionary<string, int> result = new Dictionary<string, int>(StringComparer.Ordinal);
            try
            {
                if (!File.Exists(path)) return result;
                byte[] bytes;
                using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (MemoryStream data = new MemoryStream())
                {
                    if (file.Length > MaximumFileBytes) throw new InvalidDataException("The column layout exceeded its size limit.");
                    byte[] buffer = new byte[4096];
                    int count;
                    while ((count = file.Read(buffer, 0, buffer.Length)) != 0)
                    {
                        if (data.Length + count > MaximumFileBytes) throw new InvalidDataException("The column layout exceeded its size limit.");
                        data.Write(buffer, 0, count);
                    }
                    bytes = data.ToArray();
                }
                string json = new UTF8Encoding(false, true).GetString(bytes).TrimStart('\uFEFF');
                JavaScriptSerializer serializer = Serializer();
                Dictionary<string, object> root = serializer.DeserializeObject(json) as Dictionary<string, object>;
                object schema, rawWidths;
                int version;
                if (root == null || !root.TryGetValue("schemaVersion", out schema) || !WholeNumber(schema, out version) || version != 1 || !root.TryGetValue("widths", out rawWidths))
                    throw new InvalidDataException("The column layout schema was not recognized.");
                Dictionary<string, object> widths = rawWidths as Dictionary<string, object>;
                if (widths == null) throw new InvalidDataException("The column layout widths were missing.");
                foreach (KeyValuePair<string, object> pair in widths)
                {
                    if (!KnownName(pair.Key)) continue;
                    int width;
                    if (!WholeNumber(pair.Value, out width) || width < MinimumWidth || width > MaximumWidth)
                    {
                        warning = "Some saved column widths were invalid. Default widths are used for those columns.";
                        continue;
                    }
                    result.Add(pair.Key, width);
                }
                return result;
            }
            catch (Exception error)
            {
                if (error is OutOfMemoryException || error is StackOverflowException) throw;
                warning = "Saved column widths could not be loaded. Default widths are available.";
                return new Dictionary<string, int>(StringComparer.Ordinal);
            }
        }

        public static bool Save(IDictionary<string, int> widths, out string warning)
        {
            return Save(FilePath, widths, out warning);
        }

        public static bool Save(string path, IDictionary<string, int> widths, out string warning)
        {
            warning = null;
            string temporary = null;
            try
            {
                if (widths == null) throw new ArgumentNullException("widths");
                Dictionary<string, int> valid = new Dictionary<string, int>(StringComparer.Ordinal);
                foreach (KeyValuePair<string, int> pair in widths)
                {
                    if (!KnownName(pair.Key)) continue;
                    if (pair.Value < MinimumWidth || pair.Value > MaximumWidth) throw new InvalidDataException("A column width was outside the supported range.");
                    valid.Add(pair.Key, pair.Value);
                }
                string json = Serializer().Serialize(new { schemaVersion = 1, widths = valid });
                byte[] bytes = new UTF8Encoding(false, true).GetBytes(json);
                if (bytes.Length > MaximumFileBytes) throw new InvalidDataException("The column layout exceeded its size limit.");
                string fullPath = Path.GetFullPath(path);
                Directory.CreateDirectory(Path.GetDirectoryName(fullPath));
                temporary = fullPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                using (FileStream file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    file.Write(bytes, 0, bytes.Length);
                    file.Flush(true);
                }
                if (File.Exists(fullPath)) File.Replace(temporary, fullPath, null);
                else File.Move(temporary, fullPath);
                return true;
            }
            catch (Exception error)
            {
                if (error is OutOfMemoryException || error is StackOverflowException) throw;
                warning = "Column widths were kept for this session, but could not be saved.";
                return false;
            }
            finally
            {
                try { if (temporary != null && File.Exists(temporary)) File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }

        private static JavaScriptSerializer Serializer()
        {
            return new JavaScriptSerializer { MaxJsonLength = MaximumFileBytes, RecursionLimit = 8 };
        }
        private static bool KnownName(string value)
        {
            return Array.IndexOf(Names, value) >= 0;
        }
        private static bool WholeNumber(object value, out int number)
        {
            number = 0;
            if (!(value is Int32 || value is Int64 || value is Decimal || value is Double || value is Single || value is Int16 || value is Byte)) return false;
            decimal parsed;
            if (!Decimal.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) || Decimal.Truncate(parsed) != parsed || parsed < Int32.MinValue || parsed > Int32.MaxValue) return false;
            number = (int)parsed;
            return true;
        }
    }
}
