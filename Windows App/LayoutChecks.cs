using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;

// Isolated console checks; the app assembly is loaded by reflection, with no UI or profile access.
public static class LayoutChecks
{
    private static Type store;
    private static int assertions;

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
        assertions++;
    }
    private static Dictionary<string, int> Load(string path, out string warning)
    {
        MethodInfo method = store.GetMethod("Load", new Type[] { typeof(string), typeof(string).MakeByRefType() });
        object[] arguments = { path, null };
        Dictionary<string, int> result = (Dictionary<string, int>)method.Invoke(null, arguments);
        warning = (string)arguments[1];
        return result;
    }
    private static bool Save(string path, IDictionary<string, int> values, out string warning)
    {
        MethodInfo method = store.GetMethod("Save", new Type[] { typeof(string), typeof(IDictionary<string, int>), typeof(string).MakeByRefType() });
        object[] arguments = { path, values, null };
        bool result = (bool)method.Invoke(null, arguments);
        warning = (string)arguments[2];
        return result;
    }
    private static void Write(string path, string json)
    {
        File.WriteAllText(path, json, new UTF8Encoding(false));
    }

    public static int Main(string[] args)
    {
        string directory = null;
        try
        {
            if (args.Length != 1) throw new ArgumentException("Pass the app assembly path.");
            Assembly assembly = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            store = assembly.GetType("ToolDriveOffline.ColumnLayoutStore", true);
            string tempRoot = Path.GetFullPath(Path.GetTempPath());
            directory = Path.GetFullPath(Path.Combine(tempRoot, "ToolDriveLayoutChecks-" + Guid.NewGuid().ToString("N")));
            if (!directory.StartsWith(tempRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new Exception("The test directory did not resolve inside the temporary folder.");
            Directory.CreateDirectory(directory);
            string path = Path.Combine(directory, "layout.json");
            string warning;
            Assert(Load(path, out warning).Count == 0 && warning == null, "Missing layout should use defaults silently.");

            Dictionary<string, int> original = new Dictionary<string, int> { { "Date", 110 }, { "Venue", 330 }, { "Location", 220 }, { "Sound", 85 }, { "Sources", 90 }, { "Type", 125 }, { "Taper", 190 } };
            Assert(Save(path, original, out warning) && warning == null, "Seven-column save failed.");
            Dictionary<string, int> loaded = Load(path, out warning);
            Assert(warning == null && loaded.Count == 7, "Seven-column roundtrip did not retain every column.");
            foreach (KeyValuePair<string, int> pair in original) Assert(loaded.ContainsKey(pair.Key) && loaded[pair.Key] == pair.Value, "Column width changed: " + pair.Key);
            Assert(File.ReadAllText(path).Contains("\"schemaVersion\":1"), "Saved layout schema is missing.");

            original["Venue"] = 440;
            Assert(Save(path, original, out warning) && Load(path, out warning)["Venue"] == 440, "Replacing an existing layout failed.");
            Write(path, "{\"schemaVersion\":1,\"widths\":{\"Date\":135,\"Taper\":200,\"FutureColumn\":999999}}");
            loaded = Load(path, out warning);
            Assert(warning == null && loaded.Count == 2 && loaded["Date"] == 135 && loaded["Taper"] == 200, "Partial layouts or unknown columns were mishandled.");

            Write(path, "{\"schemaVersion\":1,\"widths\":{\"Date\":-5,\"Venue\":3001,\"Location\":100000000000,\"Sound\":\"90\",\"Sources\":90.5,\"Type\":true,\"Taper\":180}}");
            loaded = Load(path, out warning);
            Assert(warning != null && loaded.Count == 1 && loaded["Taper"] == 180, "Invalid widths should be skipped without losing valid columns.");
            Write(path, "{\"schemaVersion\":1,\"widths\":{\"Date\":40,\"Venue\":3000}}");
            loaded = Load(path, out warning);
            Assert(warning == null && loaded["Date"] == 40 && loaded["Venue"] == 3000, "Width boundaries should be valid.");

            foreach (string bad in new string[] { "{", "[]", "{\"schemaVersion\":2,\"widths\":{\"Date\":110}}", "{\"schemaVersion\":\"1\",\"widths\":{\"Date\":110}}", "{\"schemaVersion\":1,\"widths\":[]}", "{\"widths\":{\"Date\":110}}" })
            {
                Write(path, bad);
                Assert(Load(path, out warning).Count == 0 && warning != null, "Corrupt or unsupported schema did not safely use defaults.");
            }
            Write(path, new string(' ', 32769));
            Assert(Load(path, out warning).Count == 0 && warning != null, "Oversized layout was accepted.");
            File.WriteAllBytes(path, new byte[] { 0xff, 0xff, 0xff });
            Assert(Load(path, out warning).Count == 0 && warning != null, "Malformed UTF-8 was accepted.");

            Assert(Save(path, original, out warning), "Restoring the valid test layout failed.");
            byte[] before = File.ReadAllBytes(path);
            Assert(!Save(path, new Dictionary<string, int> { { "Date", 0 } }, out warning) && warning != null, "Zero width save should fail.");
            Assert(before.SequenceEqual(File.ReadAllBytes(path)), "Invalid save overwrote the previous layout.");
            Assert(!Save(path, new Dictionary<string, int> { { "Venue", Int32.MaxValue } }, out warning) && warning != null, "Extreme width save should fail.");
            Assert(before.SequenceEqual(File.ReadAllBytes(path)), "Extreme width save overwrote the previous layout.");
            Assert(!Save(path, null, out warning) && warning != null && before.SequenceEqual(File.ReadAllBytes(path)), "Null layout save should preserve the previous file.");
            Assert(!Save(directory, original, out warning) && warning != null, "A directory target should fail without crashing.");
            Assert(!Save(Path.Combine(path, "unwritable.json"), original, out warning) && warning != null, "A file used as a parent folder should fail without crashing.");
            Assert(Save(path, new Dictionary<string, int> { { "Date", 150 }, { "FutureColumn", -999 } }, out warning), "Unknown saved names should be ignored.");
            loaded = Load(path, out warning);
            Assert(loaded.Count == 1 && loaded["Date"] == 150, "Unknown saved name was persisted.");
            Assert(Save(path, new Dictionary<string, int>(), out warning) && Load(path, out warning).Count == 0 && warning == null, "Empty partial layout should safely restore defaults.");
            Assert(Directory.GetFiles(directory, "*.tmp").Length == 0, "An atomic-write temporary file was left behind.");
            Console.WriteLine("PASS " + assertions + " column-layout assertions; only isolated temporary files were used.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
        finally
        {
            // Only this test's named file and an empty, freshly-created directory are removed.
            if (directory != null)
            {
                try
                {
                    string ownFile = Path.Combine(directory, "layout.json");
                    if (File.Exists(ownFile)) File.Delete(ownFile);
                    if (Directory.Exists(directory) && Directory.GetFileSystemEntries(directory).Length == 0) Directory.Delete(directory, false);
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
